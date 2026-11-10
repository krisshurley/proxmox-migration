#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
$script:RepositoryRoot=Split-Path -Parent $PSScriptRoot
$script:Passed=0
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-Throws([scriptblock]$Action){$caught=$false;try{& $Action|Out-Null}catch{$caught=$true};Assert-True $caught 'Expected a blocking error.'}
function Import-Functions([string]$File,[string[]]$Names){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepositoryRoot $File),[ref]$tokens,[ref]$errors)
    Assert-True ($errors.Count -eq 0) "Syntax error in $File"
    foreach($fn in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
        if($fn.Name -in $Names){Set-Item "function:script:$($fn.Name)" ([scriptblock]::Create($fn.Body.Extent.Text.Substring(1,$fn.Body.Extent.Text.Length-2).Replace('$PSScriptRoot','$script:RepositoryRoot')))}
    }
}
function Test-Case([string]$Name,[scriptblock]$Body){& $Body;$script:Passed++;Write-Host "PASS $Name"}
Import-Functions 'Migration.VMwareToolsCleanup.ps1' @('Assert-VMwareCleanupIdentity','Convert-VMwareCleanupBootId','Get-VMwareCleanupPlan','Write-VMwareCleanupState','Read-VMwareCleanupSingleJson','Assert-VMwareResidualAudit','Get-VMwareCleanupWorkerError')
Import-Functions 'Migration.Common.ps1' @('Get-MigrationProperty')
Import-Functions 'VMwareToolsCleanup/Invoke-MsiUninstall.ps1' @('Assert-MsiIdentity','Get-ValidatedActionPlan')
Import-Functions 'VMwareToolsCleanup/Remove-Residuals.ps1' @('Test-CleanupDevice','Read-DeviceProperty')
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('tools-workflow-tests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $testRoot|Out-Null
try{
    Test-Case 'JSON arrays are enumerated consistently with Windows PowerShell 5.1 semantics' {
        $fixture=Join-Path $testRoot 'Json51';New-Item -ItemType Directory $fixture|Out-Null
        @(1..8|ForEach-Object {[pscustomobject]@{Status='PASS';Index=$_}})|ConvertTo-Json|Set-Content (Join-Path $fixture 'final-checks.json')
        # Simulate 5.1: ConvertFrom-Json emits the entire array as one object.
        function ConvertFrom-Json {
            [CmdletBinding()]param([Parameter(ValueFromPipeline=$true)]$InputObject)
            process { ,(Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $InputObject) }
        }
        $checks=@(Read-VMwareCleanupSingleJson $fixture 'final-checks.json')
        Assert-True ($checks.Count -eq 8) 'JSON array was wrapped as one check.'
        Assert-True (@($checks|Where-Object Status -ne 'PASS').Count -eq 0) 'Check records were changed.'
        '{"Products":[],"Drivers":[],"Services":[],"Packages":[]}'|Set-Content (Join-Path $fixture 'inventory.json')
        $inventory=Read-VMwareCleanupSingleJson $fixture 'inventory.json'
        Assert-VMwareResidualAudit $inventory
    }
    Test-Case 'Workflow startup imports resolve both migration methods in a real fresh process' {
        Import-Functions 'Migration.Common.ps1' @('Invoke-MigrationChildScript')
        $source=Get-Content (Join-Path $script:RepositoryRoot 'Invoke-VMwareToolsCleanup.ps1') -Raw
        $begin=$source.IndexOf('Set-StrictMode')
        $end=$source.IndexOf('$StateDirectory=(Resolve-Path')
        Assert-True ($begin -ge 0 -and $end -gt $begin) 'Cannot locate production worker startup.'
        # Run the actual import preamble, not a duplicate list and not mocked helpers.
        $preamble=$source.Substring($begin,$end-$begin).Replace('$PSScriptRoot','$RepositoryRoot')
        $probe=Join-Path $testRoot 'startup-probe.ps1'
        $probeSource=@'
param([string]$RepositoryRoot,[string]$StateDirectory,[string]$OutputPath)
$env:COMPUTERNAME='TEST-CLEANUP-CHILD'
'@ + "`n" + $preamble + @'

foreach($name in @('Get-MigrationCapturedMethod','Assert-MigrationFirstbootComplete','Invoke-MigrationChildScript','Get-VMwareCleanupIdentity','Get-VMwareCleanupPlan')) {
    $null=Get-Command $name -ErrorAction Stop
}
$method=Get-MigrationCapturedMethod $StateDirectory
[pscustomobject]@{method=$method}|ConvertTo-Json|Set-Content -LiteralPath $OutputPath -Encoding UTF8
'@
        $probeSource|Set-Content -LiteralPath $probe -Encoding UTF8
        $fixture=Join-Path $testRoot 'StartupCapture';New-Item -ItemType Directory $fixture|Out-Null
        $capture=Join-Path $fixture 'PreMigrationState.json'
        '{"systemIdentity":{"computerName":"TEST-CLEANUP-CHILD"}}'|Set-Content $capture -Encoding UTF8
        $selection=Join-Path $fixture 'MigrationAssessment\Selection.json'
        New-Item -ItemType Directory (Split-Path -Parent $selection) -Force|Out-Null
        foreach($method in @('VeeamFirstboot','DirectImport')){
            [pscustomobject]@{migrationMethod=$method;computerName='TEST-CLEANUP-CHILD';captureSha256=(Get-FileHash $capture).Hash}|
                ConvertTo-Json|Set-Content $selection -Encoding UTF8
            $output=Join-Path $testRoot ($method+'-startup.json')
            $code=Invoke-MigrationChildScript $probe @{RepositoryRoot=$script:RepositoryRoot;StateDirectory=$fixture;OutputPath=$output}
            Assert-True ($code -eq 0) "Fresh-process startup failed for $method"
            Assert-True ((Get-Content $output -Raw|ConvertFrom-Json).method -eq $method) 'Wrong captured method.'
        }
    }
    Test-Case 'VM/capture mismatch cannot resume' {
        $a=[pscustomobject]@{computerName='TEST';machineGuid='A';captureSha256='HASH'}
        Assert-VMwareCleanupIdentity $a $a
        foreach($field in @('computerName','machineGuid','captureSha256')){
            $b=[pscustomobject]@{computerName='TEST';machineGuid='A';captureSha256='HASH'};$b.$field='OTHER'
            Assert-Throws {Assert-VMwareCleanupIdentity $a $b}
        }
    }
    Test-Case 'Both restart checkpoints require a changed boot' {
        foreach($stage in @('AwaitingMsiReboot','AwaitingResidualReboot')){
            Assert-True ((Get-VMwareCleanupPlan $stage 'A' 'A') -eq 'RestartRequired') 'Same boot passed.'
        }
        Assert-True ((Get-VMwareCleanupPlan AwaitingMsiReboot A B) -eq 'Residuals') 'Wrong MSI resume.'
        Assert-True ((Get-VMwareCleanupPlan AwaitingResidualReboot A B) -eq 'Verify') 'Wrong residual resume.'
    }
    Test-Case 'Interrupted or failed MSI/residual work cannot retry automatically' {
        foreach($stage in @('MsiInProgress','ResidualsInProgress','Failed','invalid')){Assert-Throws {Get-VMwareCleanupPlan $stage A B}}
    }
    Test-Case 'Complete state only rechecks; it cannot uninstall again' {Assert-True ((Get-VMwareCleanupPlan Complete A B) -eq 'Verify') 'Complete state mutated.'}
    Test-Case 'Residual verification rejects missing evidence or remaining packages' {
        $good=[pscustomobject]@{Products=@();Drivers=@();Services=@();Packages=@()};Assert-VMwareResidualAudit $good
        Assert-Throws {Assert-VMwareResidualAudit ([pscustomobject]@{Products=@();Drivers=@();Services=@()})}
        $good.Packages=@('oem1.inf');Assert-Throws {Assert-VMwareResidualAudit $good}
    }
    Test-Case 'Safe source/cached MSI identity and exact action set' {
        $code='{AB3D2C12-464D-4520-8DF4-4011143F05F6}'
        $rows=@([pscustomobject]@{Values=@('ProductCode',$code)},[pscustomobject]@{Values=@('ProductName','VMware Tools')},[pscustomobject]@{Values=@('ProductVersion','13.0.10.0')})
        Assert-MsiIdentity $code 'VMware Tools' '13.0.10.0' $rows
        Assert-Throws {Assert-MsiIdentity $code 'Another product' '13.0.10.0' $rows}
        Assert-Throws {Assert-MsiIdentity $code 'VMware Tools' '12.5.0' $rows}
        $ghi='VM_UninstGHIRestGuestHandle.869A7E00_8665_0000_83A8_EF0F76CF0001'
        $action=[pscustomobject]@{Values=@($ghi,'3073','_toolsinstutil.dll','VMUninstallGHIRestoreGuestHandlers')}
        Assert-True (@(Get-ValidatedActionPlan @($action) -SkipGuestHandlerRestore).Count -eq 1) 'Reviewed action rejected.'
        $action.Values[3]='OtherFunction';Assert-Throws {Get-ValidatedActionPlan @($action) -SkipGuestHandlerRestore}
    }
    Test-Case 'Residual device selection preserves Microsoft bridges and active replacement mouse' {
        foreach($id in @('PCI\VEN_15AD&DEV_07A0&test','ACPI\VMW0001\7','PCI\VEN_15AD&DEV_0779&test','ACPI\PNP0F13\new')){
            Assert-True (-not (Test-CleanupDevice ([pscustomobject]@{Id=$id;INF='msmouse.inf'}) @())) "Unrelated device selected: $id"
        }
        Assert-True (Test-CleanupDevice ([pscustomobject]@{Id='HID\VID_0E0F&PID_0003&MI_00\old';INF='oem23.---'}) @()) 'Reviewed old mouse missed.'
    }
    Test-Case 'Missing Data and non-Boolean presence remain unknown, never false' {
        function Get-PnpDeviceProperty {param($InstanceId,$KeyName,$ErrorAction) $script:PnpResponse}
        foreach($response in @([pscustomobject]@{Status='Error'},[pscustomobject]@{KeyName='present';Data='False'})){
            $script:PnpResponse=$response;Assert-True ($null -eq (Read-DeviceProperty x present -Boolean)) 'Unknown was coerced to false.'
        }
        $script:PnpResponse=[pscustomobject]@{KeyName='present';Data=$false}
        Assert-True ((Read-DeviceProperty x present -Boolean) -eq $false) 'Verified absence rejected.'
    }
    Test-Case 'Missing boot evidence cannot authorize destructive resumption' {
        Assert-Throws {Get-VMwareCleanupPlan AwaitingMsiReboot '' 'B'}
        Assert-Throws {Get-VMwareCleanupPlan AwaitingResidualReboot 'A' ''}
    }
    $script:ToolsCleanupMode='Automatic'
    Import-Functions 'Restore-And-TestMigrationState.ps1' @('Invoke-PostMigrationToolsCleanup')
    Test-Case 'Extended step 3 WhatIf does not create checkpoints or invoke a worker' {
        $Mode='Full';$StateDirectory=$testRoot;$UseExtendedToolsCleanup=$true
        $script:PreState=[pscustomobject]@{systemIdentity=[pscustomobject]@{computerName=$env:COMPUTERNAME}}
        $script:AdapterMappings=@([pscustomobject]@{target=[pscustomobject]@{isVirtIO=$true}})
        function Assert-MigrationTargetIdentity {param($Mapping)}
        function Assert-MigrationFirstbootComplete {param([switch]$FirstbootNotUsed)}
        function Invoke-MigrationChildScript {throw 'Worker must not run in WhatIf'}
        function Add-Action {param($Name,$Status,$Message) Assert-True ($Status -eq 'WHATIF') 'Wrong preview status'}
        Invoke-PostMigrationToolsCleanup -WhatIf
        Assert-True (-not (Test-Path (Join-Path $testRoot 'VMwareToolsCleanup'))) 'Preview wrote checkpoint'
    }
    Test-Case 'Verified Full route reports restart and never calls legacy service fallback' {
        $Mode='Full';$StateDirectory=$testRoot;$UseExtendedToolsCleanup=$true
        $script:PreState=[pscustomobject]@{systemIdentity=[pscustomobject]@{computerName=$env:COMPUTERNAME}}
        $script:AdapterMappings=@([pscustomobject]@{target=[pscustomobject]@{isVirtIO=$true}})
        function Assert-MigrationTargetIdentity {param($Mapping)}
        function Assert-MigrationFirstbootComplete {param([switch]$FirstbootNotUsed)}
        function Remove-VMwareToolsUninstall {throw 'Unexpected legacy fallback'}
        function Invoke-MigrationChildScript {
            param($Path,$Arguments)
            $dir=Join-Path $Arguments.StateDirectory 'VMwareToolsCleanup';New-Item -ItemType Directory $dir -Force|Out-Null
            '{"stage":"AwaitingMsiReboot"}'|Set-Content (Join-Path $dir 'Workflow.json');return 1
        }
        $script:Statuses=@();$script:Messages=@()
        function Add-Result {param($Name,$Status,$Message,$Details) $script:Statuses+=$Status;$script:Messages+=@($Message)+@($Details)}
        function Add-Action {param($Name,$Status,$Message)}
        Invoke-PostMigrationToolsCleanup -Confirm:$false
        Assert-True (($script:Statuses -join ',') -eq 'WARNING') ('Restart was not reported as warning: '+($script:Messages -join '; '))
        Remove-Item (Join-Path $testRoot 'VMwareToolsCleanup') -Recurse -Force
    }
    # Execute the real workflow body with all Windows/native operations replaced by fixtures.
    # The body retains real checkpoint persistence, file locking and stage transitions.
    $source=Get-Content (Join-Path $script:RepositoryRoot 'Invoke-VMwareToolsCleanup.ps1') -Raw
    $body=$source.Substring($source.IndexOf('$StateDirectory=(Resolve-Path'))
    $body=$body.Replace('$PSScriptRoot','$script:RepositoryRoot').Replace('exit 1',"return 'RESTART_REQUIRED'")
    Set-Item function:script:Run-Workflow ([scriptblock]::Create("[CmdletBinding(SupportsShouldProcess=`$true)]param([string]`$StateDirectory)`n"+$body))
    $script:FixtureIdentity=[pscustomobject]@{computerName='TEST';machineGuid='MACHINE';captureSha256='HASH'}
    function Get-VMwareCleanupIdentity {param($StateDirectory) $script:FixtureIdentity}
    function Get-MigrationCapturedMethod {param($StateDirectory) if($script:FixtureMethod){$script:FixtureMethod}else{'VeeamFirstboot'}}
    function Assert-MigrationFirstbootComplete {param([switch]$FirstbootNotUsed)
        $expected=$script:FixtureMethod -eq 'DirectImport'
        Assert-True ($FirstbootNotUsed.IsPresent -eq $expected) 'Wrong Firstboot gate for selected method'
        [pscustomobject]@{state='Complete'}}
    function Get-CimInstance {param($ClassName,$ErrorAction) if($ClassName -eq 'Win32_OperatingSystem'){[pscustomobject]@{LastBootUpTime=$script:Boot}}else{[pscustomobject]@{Manufacturer='QEMU';Model='KVM'}}}
    function Get-Service {param($Name,$ErrorAction) [pscustomobject]@{Status='Running'}}
    $script:NoProduct=$false
    function Get-VMwareCleanupProducts {if($script:NoProduct){return};[pscustomobject]@{code='{AB3D2C12-464D-4520-8DF4-4011143F05F6}';version=$script:FixtureToolsVersion}}
    $script:Calls=New-Object System.Collections.Generic.List[string]
    $script:FailWorker=$false;$script:FailVerification=$false
    function Invoke-MigrationChildScript {
        param($Path,$Arguments)
        if($Path -match 'Invoke-MsiUninstall|Remove-Residuals'){ Assert-True ([bool]$Arguments.FirstbootNotUsed -eq ($script:FixtureMethod -eq 'DirectImport')) 'Wrong Firstboot flag forwarded to worker' }
        if($Path -match 'Invoke-MsiUninstall'){
            $script:Calls.Add('MSI');if($script:FailWorker){return 99}
            New-Item -ItemType Directory $Arguments.BackupRoot -Force|Out-Null
            [pscustomobject]@{ExitCode=3010;MSIPatched=$true;GuestHandlerRestoreSkipped=($script:FixtureToolsVersion -eq '13.0.10.0')}|ConvertTo-Json|Set-Content (Join-Path $Arguments.BackupRoot 'result.json');return 0
        }
        if($Path -match 'Remove-Residuals'){
            $script:Calls.Add('Residual-'+$Arguments.Mode)
            if($Arguments.Mode -eq 'Audit'){
                New-Item -ItemType Directory $Arguments.BackupRoot -Force|Out-Null
                '{"Products":[],"Drivers":[],"Services":[],"Packages":[]}'|Set-Content (Join-Path $Arguments.BackupRoot 'inventory.json')
            }
            return 0
        }
        if($Path -match 'Test-FinalState'){
            $script:Calls.Add('Verify');New-Item -ItemType Directory $Arguments.ReportRoot -Force|Out-Null
            @(1..8|ForEach-Object {[pscustomobject]@{Status=$(if($script:FailVerification -and $_ -eq 1){'REVIEW'}else{'PASS'})}})|ConvertTo-Json|Set-Content (Join-Path $Arguments.ReportRoot 'final-checks.json');return 0
        }
        throw "Unexpected native worker: $Path"
    }
    $script:FixtureMethod='VeeamFirstboot'
    $script:FixtureToolsVersion='13.0.10.0'
    $stateDir=Join-Path $testRoot 'State';New-Item -ItemType Directory $stateDir|Out-Null
    $script:Boot=[datetime]'2026-11-05T01:00:00Z'
    Test-Case 'WhatIf creates no state and launches no workers' {
        Run-Workflow $stateDir -WhatIf
        Assert-True (-not (Test-Path (Join-Path $stateDir 'VMwareToolsCleanup'))) 'WhatIf wrote state.'
        Assert-True ($script:Calls.Count -eq 0) 'WhatIf launched a worker.'
    }
    Test-Case 'Real orchestrator resumes across two boots and never reruns MSI' {
        $null=Run-Workflow $stateDir -Confirm:$false
        $null=Run-Workflow $stateDir -Confirm:$false
        Assert-True (($script:Calls -join ',') -eq 'MSI') 'MSI repeated before reboot.'
        $script:Boot=$script:Boot.AddHours(1);$null=Run-Workflow $stateDir -Confirm:$false
        $null=Run-Workflow $stateDir -Confirm:$false
        Assert-True (($script:Calls -join ',') -eq 'MSI,Residual-Cleanup') 'Residuals repeated before reboot.'
        $script:Boot=$script:Boot.AddHours(1);$null=Run-Workflow $stateDir -Confirm:$false
        $path=Join-Path (Join-Path $stateDir 'VMwareToolsCleanup') 'Workflow.json'
        $state=Get-Content $path -Raw|ConvertFrom-Json
        Assert-True ($state.stage -eq 'Complete') 'Workflow did not complete.'
        $null=Run-Workflow $stateDir -Confirm:$false
        Assert-True (@($script:Calls|Where-Object {$_ -eq 'MSI'}).Count -eq 1) 'MSI reran on completed state.'
    }
    Test-Case 'DirectImport uses the same two restart checkpoints and explicitly bypasses only Firstboot' {
        $script:FixtureMethod='DirectImport'
        $script:FixtureToolsVersion='12.5.0'
        $count=$script:Calls.Count
        $directState=Join-Path $testRoot 'DirectState';New-Item -ItemType Directory $directState|Out-Null
        try {
            $null=Run-Workflow $directState -Confirm:$false
            $null=Run-Workflow $directState -Confirm:$false
            $script:Boot=$script:Boot.AddHours(1);$null=Run-Workflow $directState -Confirm:$false
            $script:Boot=$script:Boot.AddHours(1);$null=Run-Workflow $directState -Confirm:$false
            $state=Get-Content (Join-Path $directState 'VMwareToolsCleanup/Workflow.json') -Raw|ConvertFrom-Json
            Assert-True ($state.stage -eq 'Complete') 'Direct import did not complete'
            Assert-True (-not $state.guestHandlerRestoreSkipped -and $state.msiModified) 'Actual package-specific skip result was not preserved'
            Assert-True ((@($script:Calls|Select-Object -Skip $count) -join ',') -eq 'MSI,Residual-Cleanup,Residual-Audit,Verify') 'Wrong direct import sequence'
        } finally { $script:FixtureMethod='VeeamFirstboot';$script:FixtureToolsVersion='13.0.10.0';while($script:Calls.Count -gt $count){$script:Calls.RemoveAt($script:Calls.Count-1)} }
    }
    Test-Case 'Failed final verification is recorded and retries only read-only checks' {
        $script:FailVerification=$true
        Assert-Throws {Run-Workflow $stateDir -Confirm:$false}
        $path=Join-Path (Join-Path $stateDir 'VMwareToolsCleanup') 'Workflow.json'
        Assert-True ((Get-Content $path -Raw|ConvertFrom-Json).stage -eq 'VerificationFailed') 'Stale completed status retained.'
        $script:FailVerification=$false
        $null=Run-Workflow $stateDir -Confirm:$false
        Assert-True (@($script:Calls|Where-Object {$_ -eq 'MSI'}).Count -eq 1) 'Verification failure repeated MSI.'
    }
    Test-Case 'Concurrent orchestration cannot launch another worker' {
        $path=Join-Path (Join-Path $stateDir 'VMwareToolsCleanup') 'workflow.lock'
        $handle=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try {
            $count=$script:Calls.Count
            Assert-Throws {Run-Workflow $stateDir -Confirm:$false}
            Assert-True ($script:Calls.Count -eq $count) 'Concurrent worker launched.'
        } finally {$handle.Dispose()}
    }
    Test-Case 'Foreign state cannot launch workers or be rewritten' {
        $path=Join-Path (Join-Path $stateDir 'VMwareToolsCleanup') 'Workflow.json'
        $hash=(Get-FileHash $path).Hash;$count=$script:Calls.Count
        $script:FixtureIdentity.machineGuid='OTHER'
        Assert-Throws {Run-Workflow $stateDir -Confirm:$false}
        Assert-True ((Get-FileHash $path).Hash -eq $hash) 'Foreign state was rewritten.'
        Assert-True ($script:Calls.Count -eq $count) 'Worker launched for foreign state.'
        $script:FixtureIdentity.machineGuid='MACHINE'
    }
    foreach($method in @('VeeamFirstboot','DirectImport')) {
        Test-Case "${method}: already removed Tools enters residual cleanup without MSI" {
            $script:FixtureMethod=$method;$script:NoProduct=$true
            $folder=Join-Path $testRoot ('NoProduct-'+$method);New-Item -ItemType Directory $folder|Out-Null
            $count=$script:Calls.Count
            try {
                $null=Run-Workflow $folder -Confirm:$false
                $null=Run-Workflow $folder -Confirm:$false
                $path=Join-Path $folder 'VMwareToolsCleanup/Workflow.json'
                Assert-True ((Get-Content $path -Raw|ConvertFrom-Json).stage -eq 'AwaitingResidualReboot') 'Residual-only restart checkpoint missing'
                $script:Boot=$script:Boot.AddHours(1);$null=Run-Workflow $folder -Confirm:$false
                Assert-True ((Get-Content $path -Raw|ConvertFrom-Json).stage -eq 'Complete') 'Residual-only flow did not complete'
                Assert-True ((@($script:Calls|Select-Object -Skip $count) -join ',') -eq 'Residual-Cleanup,Residual-Audit,Verify') 'Residual-only flow ran MSI or repeated cleanup'
            } finally {$script:NoProduct=$false;$script:FixtureMethod='VeeamFirstboot'}
        }
        Test-Case "${method}: old read-only verification failure can recover, completed state cannot reclean" {
            $script:FixtureMethod=$method;$script:NoProduct=$true
            $folder=Join-Path $testRoot ('OldVerify-'+$method);$dir=Join-Path $folder 'VMwareToolsCleanup';New-Item -ItemType Directory $dir -Force|Out-Null
            $path=Join-Path $dir 'Workflow.json'
            $state=[pscustomobject]@{schemaVersion=1;identity=$script:FixtureIdentity;stage='VerificationFailed';boot=$script:Boot.ToUniversalTime().ToString('o');updatedUtc='';product=@();msiModified=$false;guestHandlerRestoreSkipped=$false;msiRun='';residualRun='';verificationRun='';lastError='Residual audit failed (exit 99).';limitations=@()}
            Write-VMwareCleanupState $path $state
            try {
                $count=$script:Calls.Count;$null=Run-Workflow $folder -Confirm:$false
                Assert-True ((@($script:Calls|Select-Object -Skip $count) -join ',') -eq 'Residual-Cleanup') 'Old verification did not enter residual-only path'
                $script:Boot=$script:Boot.AddHours(1);$null=Run-Workflow $folder -Confirm:$false
                $count=$script:Calls.Count;$null=Run-Workflow $folder -Confirm:$false
                Assert-True ((@($script:Calls|Select-Object -Skip $count) -join ',') -eq 'Residual-Audit,Verify') 'Completed cleanup was repeated'
            } finally {$script:NoProduct=$false;$script:FixtureMethod='VeeamFirstboot'}
        }
    }
    Test-Case 'Worker failure persists Failed and prevents repeated MSI changes' {
        $failedDir=Join-Path $testRoot 'FailedState';New-Item -ItemType Directory $failedDir|Out-Null
        $script:FailWorker=$true;Assert-Throws {Run-Workflow $failedDir -Confirm:$false}
        $path=Join-Path (Join-Path $failedDir 'VMwareToolsCleanup') 'Workflow.json'
        Assert-True ((Get-Content $path -Raw|ConvertFrom-Json).stage -eq 'Failed') 'Failure checkpoint missing.'
        $count=$script:Calls.Count;Assert-Throws {Run-Workflow $failedDir -Confirm:$false}
        Assert-True ($script:Calls.Count -eq $count) 'Failed MSI automatically retried.'
    }
    Write-Host "Passed $script:Passed VMware cleanup tests. Native Windows/MSI calls were mocked."
} finally {Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
