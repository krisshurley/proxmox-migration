#Requires -Version 5.1
#Requires -RunAsAdministrator
<# Development workflow. No automatic reboot or scheduled tasks. Resume by rerunning step 3.
   Inspects the installed VMware Tools MSI layout before selecting known actions. #>
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
param([Parameter(Mandatory=$true)][string]$StateDirectory)
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Migration.Common.ps1')
. (Join-Path $PSScriptRoot 'Migration.DirectImport.ps1')
. (Join-Path $PSScriptRoot 'Migration.VMwareToolsCleanup.ps1')
$StateDirectory=(Resolve-Path -LiteralPath $StateDirectory -ErrorAction Stop).Path
$identity=Get-VMwareCleanupIdentity $StateDirectory
$root=Join-Path $StateDirectory 'VMwareToolsCleanup'
$statePath=Join-Path $root 'Workflow.json'
$method=Get-MigrationCapturedMethod $StateDirectory
$firstbootNotUsed=$method -eq 'DirectImport'
$null=Assert-MigrationFirstbootComplete -FirstbootNotUsed:$firstbootNotUsed
$boot=(Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o')
$computer=Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
if($computer.Manufacturer -notmatch 'QEMU|Red Hat' -and $computer.Model -notmatch 'QEMU|KVM'){throw 'Cleanup requires a verified QEMU/KVM target.'}
if((Get-Service QEMU-GA -ErrorAction Stop).Status -ne 'Running'){throw 'QEMU Guest Agent must be running.'}
if(-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME,'Run or resume experimental VMware Tools MSI cleanup with backups; manual restarts required')){return}
New-Item -ItemType Directory -Path $root -Force|Out-Null
$lock=$null;$state=$null;$stateValidated=$false
try{
    $lock=[IO.File]::Open((Join-Path $root 'workflow.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    if(Test-Path -LiteralPath $statePath){
        $state=Get-Content $statePath -Raw|ConvertFrom-Json
        if($state.schemaVersion -ne 1){throw 'Unsupported cleanup state schema.'}
        Assert-VMwareCleanupIdentity $state.identity $identity
        $stateValidated=$true
    } else {
        $products=@(Get-VMwareCleanupProducts)
        if($products.Count -gt 1){throw 'Multiple VMware Tools products; review manually.'}
        $stage=if($products.Count){'ReadyForMsi'}else{'ReadyForResiduals'}
        $state=[pscustomobject]@{schemaVersion=1;identity=$identity;stage=$stage;boot=$boot;updatedUtc='';
            product=@($products);msiModified=$false;guestHandlerRestoreSkipped=$false;msiRun='';residualRun='';verificationRun='';lastError='';
            limitations=@('MSI changes, if required, are selected by inspected package content.','Unloaded user profiles and all MSI component references are not fully verified.')}
        Write-VMwareCleanupState $statePath $state
        $stateValidated=$true
    }
    # Recover only the old, read-only verification branch which never ran MSI or
    # residual cleanup. Failed/interrupted mutations remain blocked as before.
    if ($state.stage -eq 'VerificationFailed' -and -not $state.msiRun -and -not $state.residualRun -and
        @($state.product).Count -eq 0 -and @(Get-VMwareCleanupProducts).Count -eq 0) {
        Write-Host 'Resuming residual-only cleanup: previous read-only verification failed after Tools was already removed.'
        $state.stage='ReadyForResiduals';$state.lastError=''
        Write-VMwareCleanupState $statePath $state
    }
    $plan=Get-VMwareCleanupPlan $state.stage $state.boot $boot
    if($plan -eq 'RestartRequired'){
        Write-Warning "Restart Windows manually, then rerun step 3. Cleanup stage: $($state.stage). State: $statePath"
        exit 1
    }
    if($plan -eq 'Msi'){
        $errorPath=Join-Path $root ('msi-error-'+[guid]::NewGuid().ToString('N')+'.json')
        $state.stage='MsiInProgress';$state.msiRun=Join-Path $root ('MSI-'+[guid]::NewGuid().ToString('N'))
        Write-VMwareCleanupState $statePath $state
        $code=Invoke-MigrationChildScript (Join-Path $PSScriptRoot 'Invoke-VMwareToolsMsiUninstall.ps1') @{
            Uninstall=$true;SkipGuestHandlerRestore=$true;FirstbootNotUsed=$firstbootNotUsed;BackupRoot=$state.msiRun
        } -ErrorPath $errorPath
        if($code -ne 0){throw (Get-VMwareCleanupWorkerError $errorPath "MSI worker failed (exit $code); review $($state.msiRun).") }
        $result=Read-VMwareCleanupSingleJson $state.msiRun 'result.json'
        if($result.ExitCode -notin @(0,3010)){throw 'MSI worker result was not successful.'}
        $state|Add-Member NoteProperty msiModified ([bool](Get-MigrationProperty $result 'MSIPatched' $true)) -Force
        $state|Add-Member NoteProperty guestHandlerRestoreSkipped ([bool](Get-MigrationProperty $result 'GuestHandlerRestoreSkipped' $true)) -Force
        $state.limitations=@("MSI modified: $($state.msiModified); Guest Handler restoration skipped: $($state.guestHandlerRestoreSkipped).",'Unloaded user profiles and all MSI component references are not fully verified.')
        $state.stage='AwaitingMsiReboot';$state.boot=$boot;$state.updatedUtc=[datetime]::UtcNow.ToString('o')
        Write-VMwareCleanupState $statePath $state
        Write-Warning "MSI succeeded (exit $($result.ExitCode)). Restart Windows manually and rerun step 3. State: $statePath"
        exit 1
    }
    if($plan -eq 'Residuals'){
        $errorPath=Join-Path $root ('residual-error-'+[guid]::NewGuid().ToString('N')+'.json')
        $state.stage='ResidualsInProgress';$state.residualRun=Join-Path $root ('Residuals-'+[guid]::NewGuid().ToString('N'))
        Write-VMwareCleanupState $statePath $state
        $code=Invoke-MigrationChildScript (Join-Path $PSScriptRoot 'Remove-VMwareToolsResiduals.ps1') @{
            Mode='Cleanup';FirstbootNotUsed=$firstbootNotUsed;BackupRoot=$state.residualRun
        } -ErrorPath $errorPath
        if($code -ne 0){throw (Get-VMwareCleanupWorkerError $errorPath "Residual cleanup worker failed (exit $code); review $($state.residualRun).") }
        $state.stage='AwaitingResidualReboot';$state.boot=$boot;$state.updatedUtc=[datetime]::UtcNow.ToString('o')
        Write-VMwareCleanupState $statePath $state
        Write-Warning "Residual cleanup finished. Restart Windows manually and rerun step 3. State: $statePath"
        exit 1
    }
    if($plan -eq 'Verify'){
        $state.stage='VerificationPending'
        Write-VMwareCleanupState $statePath $state
        $state.verificationRun=Join-Path $root ('Verify-'+[guid]::NewGuid().ToString('N'))
        $auditRoot=Join-Path $state.verificationRun 'ResidualAudit'
        $errorPath=Join-Path $root ('audit-error-'+[guid]::NewGuid().ToString('N')+'.json')
        $code=Invoke-MigrationChildScript (Join-Path $PSScriptRoot 'Remove-VMwareToolsResiduals.ps1') @{
            Mode='Audit';FirstbootNotUsed=$firstbootNotUsed;BackupRoot=$auditRoot
        } -ErrorPath $errorPath
        if($code -ne 0){throw (Get-VMwareCleanupWorkerError $errorPath "Residual audit failed (exit $code).") }
        $inventory=Read-VMwareCleanupSingleJson $auditRoot 'inventory.json'
        Assert-VMwareResidualAudit $inventory
        $finalRoot=Join-Path $state.verificationRun 'Final'
        $errorPath=Join-Path $root ('final-error-'+[guid]::NewGuid().ToString('N')+'.json')
        $code=Invoke-MigrationChildScript (Join-Path $PSScriptRoot 'Test-VMwareToolsFinalState.ps1') @{ReportRoot=$finalRoot} -ErrorPath $errorPath
        if($code -ne 0){throw (Get-VMwareCleanupWorkerError $errorPath "Final checks worker failed (exit $code).") }
        $checks=@(Read-VMwareCleanupSingleJson $finalRoot 'final-checks.json')
        if($checks.Count -ne 8 -or @($checks|Where-Object Status -ne 'PASS').Count){throw 'Final checks contain review items, failed reads or missing checks.'}
        $state.stage='Complete';$state.boot=$boot;$state.updatedUtc=[datetime]::UtcNow.ToString('o');$state.lastError=''
        Write-VMwareCleanupState $statePath $state
        Write-Host "Defined VMware Tools cleanup checks passed. Reports/state: $root"
        Write-Warning ($state.limitations -join ' ')
    }
} catch {
    # Identity/schema failures must not rewrite a foreign or unrecognized state.
    if($stateValidated -and $null -ne $state -and $state.stage -in @('MsiInProgress','ResidualsInProgress')){
        $state.stage='Failed';$state.lastError=$_.Exception.Message;$state.updatedUtc=[datetime]::UtcNow.ToString('o')
        Write-VMwareCleanupState $statePath $state
    } elseif($stateValidated -and $null -ne $state -and $state.stage -eq 'VerificationPending'){
        $state.stage='VerificationFailed';$state.lastError=$_.Exception.Message;$state.updatedUtc=[datetime]::UtcNow.ToString('o')
        Write-VMwareCleanupState $statePath $state
    }
    throw
} finally {if($lock){$lock.Dispose()}}
