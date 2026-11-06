#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$count=0
function Assert($value,$message){if(-not $value){throw $message}}
function Throws([scriptblock]$run){$caught=$false;try{& $run|Out-Null}catch{$caught=$true};Assert $caught 'Expected refusal'}
function Case($name,[scriptblock]$run){& $run;$script:count++;Write-Host "PASS $name"}
function Import-Functions($file,$names){
    $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file),[ref]$t,[ref]$e)
    Assert ($e.Count -eq 0) 'Syntax error'
    foreach($fn in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
        if($fn.Name -in $names){Set-Item "function:script:$($fn.Name)" ([scriptblock]::Create($fn.Body.Extent.Text.Substring(1,$fn.Body.Extent.Text.Length-2)))}
    }
}
Import-Functions Invoke-LegacyToolsCleanup.ps1 @('Get-LegacyToolsServicePlan','Get-LegacyToolsStartupPlan','Invoke-LegacyToolsRemoval')
$temp=Join-Path ([IO.Path]::GetTempPath()) ('legacy-tools-tests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $temp|Out-Null
$oldProgramFiles=$env:ProgramFiles;$oldProgramFilesX86=${env:ProgramFiles(x86)}
$env:ProgramFiles='C:\Program Files';${env:ProgramFiles(x86)}='C:\Program Files (x86)'
function Fixture {
    $script:deleted=$false;$script:startupDeleted=$false;$script:backupFail=$false;$script:race=$false;$script:startupRace=$false;$script:deleteFail=$false;$script:blocked=$false;$script:installerBusy=$false;$script:pending=$false
    $script:calls=New-Object System.Collections.Generic.List[string]
    $script:service=[pscustomobject]@{name='VMTools';pathName='"C:\Program Files\VMware\VMware Tools\vmtoolsd.exe"';state='Stopped';processId=0;eligible=$true;reason=''}
    $script:startup=[pscustomobject]@{path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';name='VMware User Process';value='"C:\Program Files\VMware\VMware Tools\vmtoolsd.exe" -n vmusr';kind='String';eligible=$true;reason=''}
}
try {
    Case 'Service identity accepts exact stopped Tools binaries and defers running/unknown/COM+ paths' {
        $script:observed=[pscustomobject]@{Name='VMTools';PathName='"C:\Program Files\VMware\VMware Tools\vmtoolsd.exe"';State='Stopped';ProcessId=0}
        function Get-CimInstance {param($ClassName,$Filter) if($Filter -eq "Name='$($script:observed.Name)'"){$script:observed}}
        $rows=@(Get-LegacyToolsServicePlan);Assert ($rows.Count -eq 1 -and $rows[0].eligible) 'Known service rejected'
        $observed.State='Running';$observed.ProcessId=123;Assert (-not @(Get-LegacyToolsServicePlan)[0].eligible) 'Running service accepted'
        $observed.State='Stopped';$observed.ProcessId=0;$observed.PathName='C:\evil\vmtoolsd.exe';Assert (-not @(Get-LegacyToolsServicePlan)[0].eligible) 'Unknown binary accepted'
        $observed.Name='VMVss';$observed.PathName='C:\Windows\System32\dllhost.exe /Processid:{2B384DDA-2402-43A1-9E9D-2911BD90CF05}'
        Assert (-not @(Get-LegacyToolsServicePlan)[0].eligible) 'COM+ service accepted for deletion'
    }
    Case 'Startup identity accepts only the named value and exact vmusr command in machine Run keys' {
        function Test-Path {param($LiteralPath) $true}
        $script:command='"C:\Program Files\VMware\VMware Tools\vmtoolsd.exe" -n vmusr'
        $script:kind='String';$script:valueNames=@('VMware User Process','Other Software')
        function Get-Item {param($LiteralPath)
            $obj=New-Object PSObject
            $obj|Add-Member ScriptMethod GetValueNames {return $script:valueNames}
            $obj|Add-Member ScriptMethod GetValueKind {param($name) return $script:kind}
            $obj|Add-Member ScriptMethod GetValue {param($name,$default,$options) return $script:command}
            return $obj
        }
        Assert (@(Get-LegacyToolsStartupPlan|Where-Object eligible).Count -eq 2) 'Both machine registry views not recognized'
        $script:command='"C:\Program Files\VMware\VMware Tools\vmtoolsd.exe" -n vmusr & evil.exe'
        Assert (@(Get-LegacyToolsStartupPlan|Where-Object eligible).Count -eq 0) 'Unexpected suffix accepted'
        $script:valueNames=@('Other Software');Assert (@(Get-LegacyToolsStartupPlan).Count -eq 0) 'Unrelated value selected'
    }
    function Assert-LegacyToolsTarget {if($script:blocked){throw 'Target or Firstboot unsafe'}}
    function Get-LegacyToolsServicePlan {
        if(-not $script:deleted -or $script:pending){
            if($script:race -and $script:calls.Contains('Backup')){throw 'Service identity changed'}
            $script:service
        }
    }
    function Get-LegacyToolsStartupPlan {
        if(-not $script:startupDeleted){
            if($script:startupRace -and $script:calls.Contains('Delete')){throw 'Startup changed'}
            $script:startup
        }
    }
    function Enter-MigrationInstallerExecutionLock {$script:calls.Add('Lock');'fixture'}
    function Exit-MigrationInstallerExecutionLock {param($Mutex) if($Mutex){$script:calls.Add('Unlock')}}
    function Assert-MigrationNoInstallerClients {if($script:installerBusy){throw 'Installer active'}}
    function Invoke-LegacyToolsNative {
        param($File,$Arguments)
        if($File -eq 'reg.exe'){
            Assert ($Arguments[0] -eq 'export' -and $Arguments[1] -eq 'HKLM\SYSTEM\CurrentControlSet\Services\VMTools') 'Wrong registry mutation'
            $script:calls.Add('Backup');if($script:backupFail){return 5};'registry backup'|Set-Content -LiteralPath $Arguments[2];return 0
        }
        Assert ($File -eq 'sc.exe' -and ($Arguments -join ' ') -eq 'delete VMTools') 'Unexpected native operation'
        $script:calls.Add('Delete');if($script:deleteFail){return 5};$script:deleted=$true;return 0
    }
    function Remove-ItemProperty {param($LiteralPath,$Name)
        Assert ($LiteralPath -eq $script:startup.path -and $Name -eq 'VMware User Process') 'Unrelated registry value removed'
        $script:calls.Add('Startup');$script:startupDeleted=$true
    }
    Case 'WhatIf writes nothing and never takes a lock or calls deletion' {
        Fixture;$dest=Join-Path $temp preview
        $code=Invoke-LegacyToolsRemoval $dest -WhatIf
        Assert ($code -eq 0 -and $calls.Count -eq 0 -and -not (Test-Path $dest)) 'Preview mutated state'
    }
    Case 'Success backs up everything first and reports preserved MSI/network scope' {
        Fixture;$dest=Join-Path $temp success
        $code=Invoke-LegacyToolsRemoval $dest -Confirm:$false
        Assert ($code -eq 0 -and ($calls -join ',') -eq 'Lock,Backup,Delete,Startup,Unlock') 'Wrong mutation order'
        $report=Get-Content @(Get-ChildItem $dest -Recurse -Filter Report.json)[0].FullName -Raw|ConvertFrom-Json
        Assert ($report.status -eq 'CompleteWithinLimitedScope' -and $report.scope -match 'not MSI uninstall') 'False full uninstall claim'
        $before=Get-Content @(Get-ChildItem $dest -Recurse -Filter Before.json)[0].FullName -Raw|ConvertFrom-Json
        Assert ($before.startup[0].value -eq $startup.value -and $before.startup[0].kind -eq 'String') 'Exact startup backup missing'
    }
    Case 'Already deleted services and startup are a successful no-op' {
        Fixture;$script:deleted=$true;$script:startupDeleted=$true
        Assert ((Invoke-LegacyToolsRemoval (Join-Path $temp empty) -Confirm:$false) -eq 0) 'Missing services treated as failure'
        Assert (($calls -join ',') -eq 'Lock,Unlock') 'Absent entries changed'
    }
    Case 'Registry backup failure prevents all deletions and preserves a failure report' {
        Fixture;$script:backupFail=$true;$dest=Join-Path $temp backup-failure
        Throws {Invoke-LegacyToolsRemoval $dest -Confirm:$false}
        Assert (-not $deleted -and -not $startupDeleted -and $calls[-1] -eq 'Unlock') 'Backup failure allowed mutation or retained lock'
        Assert (@(Get-ChildItem $dest -Recurse -Filter Failure.json).Count -eq 1) 'Missing failure evidence'
    }
    Case 'A failed second service backup prevents deletion of every service and startup value' {
        Fixture
        function Get-LegacyToolsServicePlan {
            $script:service
            [pscustomobject]@{name='VGAuthService';pathName='C:\Program Files\VMware\VMware Tools\VMware VGAuth\VGAuthService.exe';state='Stopped';processId=0;eligible=$true;reason=''}
        }
        function Invoke-LegacyToolsNative {
            param($File,$Arguments)
            Assert ($File -eq 'reg.exe') 'Deletion started before all backups succeeded'
            $script:calls.Add('Backup')
            if($Arguments[1] -match 'VGAuthService$'){return 5}
            'backup'|Set-Content -LiteralPath $Arguments[2];return 0
        }
        Throws {Invoke-LegacyToolsRemoval (Join-Path $temp second-backup) -Confirm:$false}
        Assert (($calls -join ',') -eq 'Lock,Backup,Backup,Unlock' -and -not $startupDeleted) 'Backup failure allowed partial deletion'
    }
    Case 'Target/Firstboot and installer blockers refuse mutations' {
        Fixture;$script:blocked=$true;Throws {Invoke-LegacyToolsRemoval (Join-Path $temp unsafe) -Confirm:$false}
        Assert ($calls.Count -eq 0) 'Unsafe target reached mutating path'
        Fixture;$script:installerBusy=$true;Throws {Invoke-LegacyToolsRemoval (Join-Path $temp installer) -Confirm:$false}
        Assert (($calls -join ',') -eq 'Lock,Unlock') 'Installer blocker did not release lock'
    }
    Case 'Changed service identity after backup and native failures stop remaining deletions' {
        Fixture;$script:race=$true;Throws {Invoke-LegacyToolsRemoval (Join-Path $temp race) -Confirm:$false}
        Assert (-not $deleted -and -not $startupDeleted) 'Changed service deleted'
        Fixture;$script:deleteFail=$true;Throws {Invoke-LegacyToolsRemoval (Join-Path $temp native) -Confirm:$false}
        Assert (-not $startupDeleted -and $calls[-1] -eq 'Unlock') 'Deletion failure continued or retained lock'
    }
    Case 'Startup change after backup is not overwritten' {
        Fixture;$script:startupRace=$true;Throws {Invoke-LegacyToolsRemoval (Join-Path $temp startup-race) -Confirm:$false}
        Assert ($deleted -and -not $startupDeleted) 'Changed startup overwritten'
    }
    Case 'Running or COM+-managed services remain for review while verified startup can be removed' {
        Fixture;$service.eligible=$false;$service.reason='Running or COM+ service'
        Assert ((Invoke-LegacyToolsRemoval (Join-Path $temp review) -Confirm:$false) -eq 1) 'Review item approved'
        Assert (-not $deleted -and $startupDeleted) 'Ineligible service removed or valid startup not cleaned'
    }
    Case 'Pending service deletion reports review instead of unconditional success' {
        Fixture;$script:pending=$true
        Assert ((Invoke-LegacyToolsRemoval (Join-Path $temp pending) -Confirm:$false) -eq 1) 'Pending delete reported complete'
    }
    Case 'Master flag dispatch bypasses the phase menu and cannot combine with migration options' {
        $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root Migrate-VmwareToProxmox.ps1),[ref]$t,[ref]$e)
        $body=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[0].Body.Extent.Text
        $body=$body.Substring(1,$body.Length-2).Replace('exit 1',"return 'CANCELLED'").Replace('exit $script:PhaseExitCode','return $script:PhaseExitCode')
        $fixture=[scriptblock]::Create('[CmdletBinding(SupportsShouldProcess=$true)]'+$ast.ParamBlock.Extent.Text+'$script:PhaseExitCode=0;'+$body)
        function Read-Host {throw 'Must not open menu'}
        function Invoke-CheckedMigrationScript {param($Name,$Arguments)
            Assert ($Name -eq 'Invoke-LegacyToolsCleanup.ps1') 'Wrong child invoked'
            Assert ($Arguments.WhatIf) 'WhatIf not forwarded'
            Assert ($Arguments.Keys.Count -eq 2) 'Migration/capture parameters reached legacy child'
        }
        Assert ((& $fixture -LegacyToolsCleanup -WhatIf) -eq 0) 'Legacy dispatch failed'
        Throws {& $fixture -LegacyToolsCleanup -Phase ValidatePost -WhatIf}
        Throws {& $fixture -LegacyToolsCleanup -StateDirectory 'old-capture' -WhatIf}
    }
} finally {
    $env:ProgramFiles=$oldProgramFiles;${env:ProgramFiles(x86)}=$oldProgramFilesX86
    Remove-Item $temp -Recurse -Force
}
Write-Host "Passed $count legacy Tools cleanup tests. Windows/native calls were mocked."
