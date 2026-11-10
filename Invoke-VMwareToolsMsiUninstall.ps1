#requires -Version 5.1
#requires -RunAsAdministrator
<# Package-inspected development build. Standalone TEST, Windows PowerShell x64. Default: read-only MSI inspection.
   -Uninstall backs up and modifies the exact cached Tools MSI before uninstall.
   This changes a vendor MSI and is not claimed to be a vendor-supported procedure.
   Never use on the source VMware VM. No network changes or automatic reboot. #>
[CmdletBinding()]
param([switch]$Uninstall,[switch]$SkipGuestHandlerRestore,[switch]$FirstbootNotUsed,[string]$BackupRoot='C:\temp\VMwareToolsCleanup')
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
function Release-Com($Value) {
    if($null -ne $Value -and [Runtime.InteropServices.Marshal]::IsComObject($Value)) {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($Value)
    }
}
function Invoke-ComMethod {
    param($Object,[string]$Method,[object[]]$Arguments=@())
    $Object.GetType().InvokeMember($Method,[Reflection.BindingFlags]::InvokeMethod,$null,$Object,$Arguments)
}
function Read-MsiRows {
    param($Database,[string]$Query,[int]$Columns=1)
    $view=$null
    try {
        $view=Invoke-ComMethod $Database 'OpenView' @($Query)
        $null=Invoke-ComMethod $view 'Execute'
        while($true) {
            $record=Invoke-ComMethod $view 'Fetch'
            if($null -eq $record){break}
            try {
                $values=@(for($i=1;$i -le $Columns;$i++) {
                    [string]$record.GetType().InvokeMember('StringData',[Reflection.BindingFlags]::GetProperty,$null,$record,@($i))
                })
                [pscustomobject]@{Values=$values}
            } finally {Release-Com $record}
        }
    } finally {
        if($null -ne $view){try{$null=Invoke-ComMethod $view 'Close'}finally{Release-Com $view}}
    }
}
function Assert-MsiIdentity {
    param([string]$ProductCode,[string]$Name,[string]$Version,[object[]]$Rows)
    $properties=@{}
    foreach($row in $Rows){
        if($row.Values.Count -ne 2 -or $properties.ContainsKey([string]$row.Values[0])){throw 'Duplicate or malformed MSI identity property.'}
        $properties[[string]$row.Values[0]]=[string]$row.Values[1]
    }
    if($Name -ne 'VMware Tools' -or $Version -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$' -or
       $ProductCode -notmatch '^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$') {
        throw 'A valid registered VMware Tools MSI product identity and version are required.'
    }
    if(-not $properties.ContainsKey('ProductCode') -or $properties['ProductCode'] -ine $ProductCode -or
       -not $properties.ContainsKey('ProductName') -or $properties['ProductName'] -ne 'VMware Tools' -or
       -not $properties.ContainsKey('ProductVersion') -or $properties['ProductVersion'] -ne $Version) {
        throw 'Cached MSI identity/version does not match the registered VMware Tools product.'
    }
}
function Get-ValidatedActionPlan {
    param([object[]]$Rows,[switch]$SkipGuestHandlerRestore)
    # Inspect the complete table: a changed name must not hide a known entrypoint,
    # and a changed entrypoint under a known name must not be silently ignored.
    $specs=@(
        @{Name='VM_LogStart';Type='257';Target='VMLogStart'},
        @{Name='VM_CheckRequirements';Type='257';Target='VMCheckRequirements'},
        @{Name='VM_UninstGHIRestGuestHandle';Type='3073';Target='VMUninstallGHIRestoreGuestHandlers'}
    )
    $suffix='(?:\.[0-9a-fA-F]{8}_[0-9a-fA-F]{4}_[0-9a-fA-F]{4}_[0-9a-fA-F]{4}_[0-9a-fA-F]{12})?'
    $seen=@{};$plan=@();$names=@{}
    foreach($row in $Rows) {
        if($row.Values.Count -ne 4){throw 'Malformed CustomAction row.'}
        $name=[string]$row.Values[0];$target=[string]$row.Values[3]
        if([string]::IsNullOrWhiteSpace($name) -or $names.ContainsKey($name)){throw 'Empty or duplicate CustomAction identity.'}
        $names[$name]=$true
        $candidates=@($specs|Where-Object {$name -like ($_.Name+'*') -or $target -eq $_.Target})
        if(-not $candidates.Count){continue} # Unrelated actions are preserved.
        if($candidates.Count -ne 1){throw "Ambiguous CustomAction role: $name"}
        $spec=$candidates[0]
        if($name -cnotmatch ('^'+[regex]::Escape($spec.Name)+$suffix+'$') -or
           $target -cne $spec.Target -or [string]$row.Values[1] -cne $spec.Type -or
           [string]::IsNullOrWhiteSpace([string]$row.Values[2])) {
            throw "Unknown CustomAction layout: $name; type=$($row.Values[1]); source=$($row.Values[2]); target=$target. No MSI modification is permitted."
        }
        if($seen.ContainsKey($spec.Name)){throw "Multiple actions implement the same role: $($spec.Name)"}
        $seen[$spec.Name]=$true
        if($spec.Name -ne 'VM_UninstGHIRestGuestHandle' -or $SkipGuestHandlerRestore){$plan+=$name}
    }
    if(-not $seen.Count){throw 'No recognized VMware Tools CustomAction layout found. Use manual handling; no MSI modification is permitted.'}
    # Missing individual roles are not fabricated or deleted by guessed names.
    return $plan
}
function Assert-MsiActionBinaryReferences {
    param([object[]]$Actions,[string[]]$Plan,[object[]]$BinaryRows)
    foreach($row in $Actions){
        if($row.Values[0] -notin $Plan){continue}
        $source=[string]$row.Values[2]
        if(@($BinaryRows|Where-Object {$_.Values[0] -ceq $source}).Count -ne 1){throw "Custom action Binary stream was not uniquely verified: $source"}
    }
}
function Set-MsiActionChanges {
    param($Database,[object[]]$OriginalRows,[string[]]$Plan)
    foreach($action in $Plan){
        $view=$null
        try {
            $sql='DELETE FROM `CustomAction` WHERE `Action` = ''{0}''' -f $action.Replace("'","''")
            $view=Invoke-ComMethod $Database 'OpenView' @($sql)
            $null=Invoke-ComMethod $view 'Execute'
        } finally {if($null -ne $view){try{$null=Invoke-ComMethod $view 'Close'}finally{Release-Com $view}}}
    }
    $left=@(Read-MsiRows $Database 'SELECT `Action`, `Type`, `Source`, `Target` FROM `CustomAction`' 4)
    if(@($left|Where-Object {$_.Values[0] -in $Plan}).Count){throw 'Selected action removal did not validate; transaction was not committed.'}
    $expected=@($OriginalRows|Where-Object {$_.Values[0] -notin $Plan})
    if($left.Count -ne $expected.Count){throw 'Unrelated CustomAction rows changed; transaction was not committed.'}
    foreach($row in $expected){
        $actual=@($left|Where-Object {$_.Values[0] -ceq $row.Values[0]})
        if($actual.Count -ne 1 -or (@($actual[0].Values|ConvertTo-Json -Compress) -join '') -cne (@($row.Values|ConvertTo-Json -Compress) -join '')){throw 'Unrelated CustomAction content changed; transaction was not committed.'}
    }
}
function Backup-GuestHandlerKeys {
    param([string]$Destination)
    $keys=@()
    foreach($vendor in @('VMware, Inc.','VMware,Inc.')) {
        $machine="HKEY_LOCAL_MACHINE\SOFTWARE\$vendor\VMware Tools\GHI"
        if(Test-Path -LiteralPath ('Registry::'+$machine)){$keys+=$machine}
        foreach($hive in Get-ChildItem 'Registry::HKEY_USERS') {
            $key=$hive.Name+"\Software\$vendor\VMware Tools\GHI"
            if(Test-Path -LiteralPath ('Registry::'+$key)){$keys+=$key}
        }
    }
    $i=0
    foreach($key in $keys) {
        & reg.exe export $key (Join-Path $Destination ("guest-handlers-{0}.reg" -f $i)) /y|Out-Host
        if($LASTEXITCODE -ne 0){throw "Guest Handler backup failed: $key"};$i++
    }
    [pscustomobject]@{Scope='Machine and currently loaded user hives only; unloaded profiles were not loaded.';Keys=@($keys)}|
        ConvertTo-Json -Depth 3|Set-Content (Join-Path $Destination 'guest-handler-backup-scope.json') -Encoding UTF8
}
function Assert-InstallerIdle {
    $mutex=$null;$acquired=$false
    try {
        try{$mutex=[Threading.Mutex]::OpenExisting('Global\_MSIExecute')}catch [Threading.WaitHandleCannotBeOpenedException]{return}
        try{$acquired=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$acquired=$true}
        if(-not $acquired){throw 'Windows Installer is busy. No MSI changes were made.'}
    } finally {if($acquired){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}}
}
$run=Join-Path $BackupRoot ((Get-Date -Format yyyyMMdd-HHmmss)+'-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $run -Force|Out-Null
Start-Transcript -Path (Join-Path $run 'transcript.txt')|Out-Null
$installer=$null;$database=$null;$patched=$false
try {
    if(-not [Environment]::Is64BitProcess -or $PSVersionTable.PSEdition -ne 'Desktop'){throw 'Use 64-bit Windows PowerShell 5.1.'}
    $computer=Get-CimInstance Win32_ComputerSystem
    if($computer.Manufacturer -notmatch 'QEMU|Red Hat' -and $computer.Model -notmatch 'QEMU|KVM'){throw 'Only run on the restored QEMU/KVM test VM.'}
    if((Get-Service QEMU-GA).Status -ne 'Running'){throw 'QEMU Guest Agent must be running.'}
    $common=Join-Path $PSScriptRoot 'Migration.Common.ps1'
    if(-not (Test-Path -LiteralPath $common)){throw 'Place this file beside Migration.Common.ps1 from the test package.'}
    . $common
    $null=Assert-MigrationFirstbootComplete -FirstbootNotUsed:$FirstbootNotUsed
    $present=@(Get-PnpDevice -PresentOnly)
    if(@($present|Where-Object {$_.InstanceId -match '^PCI\\VEN_15AD&' -and $_.Class -in @('SCSIAdapter','Net')}).Count){throw 'Present VMware network/storage hardware remains. MSI test refused.'}
    if(@($present|Where-Object {$_.InstanceId -match '^PCI\\VEN_1AF4&DEV_(1004|1048)&' -and $_.Class -eq 'SCSIAdapter' -and $_.Status -eq 'OK'}).Count -eq 0){throw 'A healthy present PCI VirtIO SCSI controller is required.'}
    $products=@(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue|Where-Object {
        $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -eq 'VMware Tools'
    })
    if($products.Count -ne 1 -or $products[0].PSChildName -notmatch '^\{[0-9A-Fa-f-]{36}\}$'){throw 'A unique VMware Tools MSI registration is required.'}
    $code=[string]$products[0].PSChildName;$null=[guid]$code
    $installer=New-Object -ComObject WindowsInstaller.Installer
    $name=[string]$installer.ProductInfo($code,'ProductName')
    $version=[string]$installer.ProductInfo($code,'VersionString')
    $cache=[string]$installer.ProductInfo($code,'LocalPackage')
    if($cache -notmatch ('^'+[regex]::Escape($env:windir)+'\\Installer\\[^\\]+\.msi$') -or -not (Test-Path -LiteralPath $cache)){throw 'Unexpected or missing Windows Installer cached MSI path.'}
    # Mode 0 is read-only; no MSI writes are possible during default inspection.
    $database=Invoke-ComMethod $installer 'OpenDatabase' @($cache,0)
    $identity=@(Read-MsiRows $database 'SELECT `Property`, `Value` FROM `Property` WHERE `Property` = ''ProductCode'' OR `Property` = ''ProductName'' OR `Property` = ''ProductVersion''' 2)
    Assert-MsiIdentity $code $name $version $identity
    $query='SELECT `Action`, `Type`, `Source`, `Target` FROM `CustomAction`'
    $actions=@(Read-MsiRows $database $query 4)
    $originalHash=(Get-FileHash -LiteralPath $cache -Algorithm SHA256).Hash
    $evidence=[pscustomobject]@{ProductCode=$code;ProductName=$name;Version=$version;LocalPackage=$cache;OriginalSHA256=$originalHash;
        GuestHandlerRestoreRequested=[bool]$SkipGuestHandlerRestore;GuestHandlerRestorePlannedSkip=$false;GuestHandlerRestoreSkipped=$false;MSIPatched=$false;PlannedActions=@();PackageValidation='Inspecting';ValidationError='';
        Actions=@($actions|ForEach-Object {[pscustomobject]@{Action=$_.Values[0];Type=$_.Values[1];Source=$_.Values[2];Target=$_.Values[3]}})}
    try {
        $plan=@(Get-ValidatedActionPlan -Rows $actions -SkipGuestHandlerRestore:$SkipGuestHandlerRestore)
        $binaries=@(Read-MsiRows $database 'SELECT `Name` FROM `Binary`')
        Assert-MsiActionBinaryReferences -Actions $actions -Plan $plan -BinaryRows $binaries
        $ghiSkipped=@($actions|Where-Object {$_.Values[0] -in $plan -and $_.Values[3] -ceq 'VMUninstallGHIRestoreGuestHandlers'}).Count -gt 0
        $evidence.PlannedActions=$plan;$evidence.GuestHandlerRestorePlannedSkip=$ghiSkipped;$evidence.PackageValidation='RecognizedLayout'
    } catch {
        $evidence.PackageValidation='Blocked';$evidence.ValidationError=$_.Exception.Message
        $evidence|ConvertTo-Json -Depth 5|Set-Content (Join-Path $run 'inspection.json') -Encoding UTF8
        throw
    }
    $evidence|ConvertTo-Json -Depth 5|Set-Content (Join-Path $run 'inspection.json') -Encoding UTF8
    $evidence|Format-List ProductCode,ProductName,Version,LocalPackage,OriginalSHA256|Out-Host
    Write-Host "Package layout recognized. Planned action changes: $($plan.Count); Guest Handler planned skip: $ghiSkipped. Full table: $run\inspection.json"
    $evidence.Actions|Where-Object {$_.Action -in $plan}|Format-Table -AutoSize|Out-Host
    Release-Com $database;$database=$null
    if(-not $Uninstall){Write-Host 'INSPECTION ONLY: no MSI, service, driver, or network settings were changed.';Write-Host "Evidence: $run";return}
    if($ghiSkipped){Backup-GuestHandlerKeys $run}
    Assert-InstallerIdle
    $backup=Join-Path $run 'original-cached-tools.msi'
    Copy-Item -LiteralPath $cache -Destination $backup
    if((Get-FileHash $backup -Algorithm SHA256).Hash -ne $originalHash){throw 'MSI backup verification failed.'}
    & reg.exe export $products[0].PSPath.Replace('Microsoft.PowerShell.Core\Registry::','') (Join-Path $run 'uninstall.reg') /y|Out-Host
    if($LASTEXITCODE -ne 0){throw 'Uninstall registry backup failed.'}
    if((Get-FileHash $cache -Algorithm SHA256).Hash -ne $originalHash){throw 'Cached MSI changed after inspection. Refusing modification.'}
    # Only known roles are changed, and every unrelated table row must survive.
    if($plan.Count){
        $database=Invoke-ComMethod $installer 'OpenDatabase' @($cache,1)
        Set-MsiActionChanges -Database $database -OriginalRows $actions -Plan $plan
        $null=Invoke-ComMethod $database 'Commit';$patched=$true
        Release-Com $database;$database=$null
    }
    $evidence.MSIPatched=$patched;$evidence.GuestHandlerRestoreSkipped=($patched -and $ghiSkipped)
    $evidence|Add-Member -NotePropertyName PatchedSHA256 -NotePropertyValue (Get-FileHash $cache -Algorithm SHA256).Hash
    $evidence|ConvertTo-Json -Depth 4|Set-Content (Join-Path $run 'patched.json') -Encoding UTF8
    # Release all Installer handles before launching msiexec.
    Release-Com $installer;$installer=$null
    $log=Join-Path $run 'uninstall-msi.log'
    Write-Host "Starting MSI uninstall. Full log: $log"
    $arguments='/x '+$code+' /qn /norestart /L*v "'+$log+'"'
    $process=Start-Process -FilePath "$env:windir\System32\msiexec.exe" -ArgumentList $arguments -Wait -PassThru
    $process.WaitForExit();$exitCode=$process.ExitCode;$process.Dispose()
    [pscustomobject]@{ExitCode=$exitCode;GuestHandlerRestoreSkipped=$ghiSkipped;MSIPatched=$patched;OriginalMSI=$backup;Log=$log}|ConvertTo-Json|Set-Content (Join-Path $run 'result.json') -Encoding UTF8
    Write-Host "MSI exit code: $exitCode"
    if($exitCode -notin @(0,3010)){throw "MSI uninstall failed ($exitCode). Keep logs and the original cached MSI; do not run other cleanup yet."}
    if($ghiSkipped){Write-Warning 'Guest Handler restoration was intentionally skipped. User integration/association remnants need separate verification.'}
    Write-Host 'MSI reported success. Reboot manually if required and verify actual remaining components. No separate cleanup or automatic reboot was performed.'
    Write-Host "Reports and original MSI: $run"
} catch {
    Write-Host "STOPPED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Reports: $run; MSI transaction committed: $patched. No automatic restoration of MSI or uninstall changes was attempted."
    throw
} finally {Release-Com $database;Release-Com $installer;Stop-Transcript|Out-Null}
