#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root Migration.VMwareToolsCleanup.ps1)
$count=0
function Assert($condition,$text){if(-not $condition){throw $text}}
function Case($name,[scriptblock]$body){& $body;$script:count++;Write-Host "PASS $name"}
function Throws([scriptblock]$body){$caught=$false;try{& $body|Out-Null}catch{$caught=$true};Assert $caught 'Expected refusal'}
function Import-Function($file,$name){
    $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file),[ref]$t,[ref]$e)
    Assert ($e.Count -eq 0) 'Syntax errors'
    $fn=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))[0]
    Set-Item "function:script:$name" ([scriptblock]::Create($fn.Body.Extent.Text.Substring(1,$fn.Body.Extent.Text.Length-2).Replace('$PSScriptRoot','$script:root')))
}
Import-Function Restore-And-TestMigrationState.ps1 Invoke-PostMigrationToolsCleanup
Import-Function Migrate-VmwareToProxmox.ps1 Invoke-CheckedMigrationScript
$temp=Join-Path ([IO.Path]::GetTempPath()) ('tools-choice-tests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $temp|Out-Null
try {
    '{"systemIdentity":{"computerName":"fixture"}}'|Set-Content (Join-Path $temp PreMigrationState.json)
    Case 'First menu defaults to automatic and does not write preferences before approval' {
        function Read-Host {param($Prompt) ''}
        Assert ((Resolve-MigrationToolsCleanupChoice $temp -Interactive) -eq 'Automatic') 'Default changed'
        Assert (-not (Test-Path (Join-Path $temp ToolsCleanupChoice.json))) 'Menu wrote preference'
    }
    Case 'Manual selection persists with exact capture identity and is reused without another prompt' {
        function Read-Host {param($Prompt) '2'}
        $mode=Resolve-MigrationToolsCleanupChoice $temp -Interactive
        Assert ($mode -eq 'Manual') 'Manual selection lost'
        Save-MigrationToolsCleanupChoice $temp $mode
        function Read-Host {throw 'Unexpected repeated prompt'}
        Assert ((Resolve-MigrationToolsCleanupChoice $temp -Interactive) -eq 'Manual') 'Saved choice ignored'
    }
    Case 'Explicit selection overrides saved choice without touching cleanup workflow' {
        $workflow=Join-Path $temp VMwareToolsCleanup;New-Item -ItemType Directory $workflow|Out-Null
        $state=Join-Path $workflow Workflow.json
        '{"stage":"Failed","lastError":"fixture"}'|Set-Content $state
        $hash=(Get-FileHash $state).Hash
        Assert ((Resolve-MigrationToolsCleanupChoice $temp -Mode Automatic -Explicit) -eq 'Automatic') 'Explicit automatic ignored'
        Save-MigrationToolsCleanupChoice $temp Manual
        Assert ((Get-FileHash $state).Hash -eq $hash) 'Cleanup state overwritten'
    }
    Case 'Foreign/corrupt saved choices cannot be silently reused' {
        $file=Join-Path $temp ToolsCleanupChoice.json
        $saved=Get-Content $file -Raw|ConvertFrom-Json
        $saved.captureSha256='OTHER';$saved|ConvertTo-Json|Set-Content $file
        Throws {Get-MigrationToolsCleanupChoice $temp}
        Save-MigrationToolsCleanupChoice $temp Automatic
        $saved=Get-Content $file -Raw|ConvertFrom-Json;$saved.computerName='FOREIGN';$saved|ConvertTo-Json|Set-Content $file
        Throws {Get-MigrationToolsCleanupChoice $temp}
        '{bad json'|Set-Content $file
        Throws {Get-MigrationToolsCleanupChoice $temp}
    }
    foreach($method in @('VeeamFirstboot','DirectImport')) {
        Case "$method manual mode leaves failed/pending Tools workflow alone" {
            $Mode='Full';$ToolsCleanupMode='Manual';$MigrationMethod=$method
            $script:ToolsRestartPending=$false;$script:messages=@();$script:actions=@()
            function Add-Result {param($Name,$State,$Summary) $script:messages+=@($State,$Summary)}
            function Add-Action {param($Type,$State,$Summary) $script:actions+=@($State,$Summary)}
            function Assert-MigrationTargetIdentity {throw 'Unexpected automatic cleanup gate'}
            function Invoke-MigrationChildScript {throw 'Unexpected MSI/residual worker'}
            function Remove-VMwareToolsUninstall {throw 'Unexpected legacy uninstall'}
            Invoke-PostMigrationToolsCleanup
            Assert ($script:messages[0] -eq 'WARNING' -and $script:messages[1] -match 'validation continue') 'Manual cleanup not reported'
            Assert (-not $script:ToolsRestartPending -and $script:actions[0] -eq 'MANUAL_REVIEW') 'Manual mode deferred other validation'
        }
    }
    foreach($method in @('VeeamFirstboot','DirectImport')) {
        Case "$method menu forwards manual choice and preserves method/Firstboot semantics" {
            $tokens=$null;$errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root Migrate-VmwareToProxmox.ps1),[ref]$tokens,[ref]$errors)
            $phaseSwitch=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.SwitchStatementAst] -and $n.Condition.Extent.Text -eq '$Phase'},$true))[0]
            $body=@($phaseSwitch.Clauses|Where-Object {$_.Item1.Value -eq 'ValidatePost'})[0].Item2.Extent.Text
            $fixture=[scriptblock]::Create('[CmdletBinding(SupportsShouldProcess=$true)]'+$ast.ParamBlock.Extent.Text+$body.Substring(1,$body.Length-2))
            $script:InteractiveMenu=$true;$script:LevelExplicit=$false;$script:forwarded=$null;$script:RestartRequired=$false
            function Resolve-MigrationStateDirectory {param($StateDirectory) $temp}
            function Get-MigrationCapturedAssessmentLevel {param($StateDirectory) 'Migration'}
            function Assert-MigrationFirstbootComplete {param([switch]$FirstbootNotUsed)
                Assert ($FirstbootNotUsed.IsPresent -eq ($method -eq 'DirectImport')) 'Wrong method gate'
                [pscustomobject]@{state='Complete'}
            }
            function Get-MigrationProperty {param($Object,$Name,$Default) $Default}
            function Invoke-CheckedMigrationScript {param($Name,$Arguments) $script:forwarded=$Arguments}
            & $fixture -Phase ValidatePost -MigrationMethod $method -FirstbootNotUsed:($method -eq 'DirectImport') -ToolsCleanupMode Manual -Confirm:$false
            Assert ($script:forwarded.ToolsCleanupMode -eq 'Manual' -and $script:forwarded.Mode -eq 'Full') 'Manual mode disabled Full restoration'
            if($method -eq 'DirectImport'){Assert ($script:forwarded.FirstbootNotUsed -and $script:forwarded.MigrationMethod -eq 'DirectImport') 'Direct import flags lost'}
        }
    }
    Case 'Restart status is distinct from generic warnings and unrelated child failures' {
        $script:PhaseExitCode=0;$script:RestartRequired=$false
        function Invoke-MigrationChildScript {param($Path,$Arguments) 3010}
        Invoke-CheckedMigrationScript Restore-And-TestMigrationState.ps1
        Assert ($script:PhaseExitCode -eq 1 -and $script:RestartRequired) 'Restart signal lost'
        Throws {Invoke-CheckedMigrationScript mig_prep.ps1}
        $script:RestartRequired=$false
        function Invoke-MigrationChildScript {param($Path,$Arguments) 1}
        Invoke-CheckedMigrationScript Restore-And-TestMigrationState.ps1
        Assert (-not $script:RestartRequired) 'Generic warning requested reboot'
        function Invoke-MigrationChildScript {param($Path,$Arguments) 2}
        Throws {Invoke-CheckedMigrationScript Restore-And-TestMigrationState.ps1}
    }
    Case 'Restart banner explicitly states next action and incomplete final validation' {
        $output=(Write-MigrationRestartInstructions 6>&1|Out-String)
        Assert ($output -match 'RESTART REQUIRED' -and $output -match 'select 3 again' -and $output -match 'NOT finished') 'Incomplete banner'
    }
} finally {Remove-Item $temp -Recurse -Force}
Write-Host "Passed $count Tools cleanup choice tests. Windows/MSI calls were mocked."
