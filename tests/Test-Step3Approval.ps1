#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root Migration.VMwareToolsCleanup.ps1)
$count=0
function Assert($value,$message){if(-not $value){throw $message}}
function Case($name,[scriptblock]$body){& $body;$script:count++;Write-Host "PASS $name"}
function Get-VMwareCleanupIdentity {param($StateDirectory) [pscustomobject][ordered]@{computerName='VM';machineGuid=$script:machineGuid;captureSha256=(Get-FileHash (Join-Path $StateDirectory PreMigrationState.json)).Hash}}
function Get-CimInstance {param($ClassName) Assert ($ClassName -eq 'Win32_ComputerSystemProduct') 'Wrong target query';[pscustomobject]@{UUID=$script:uuid}}
function Get-NetAdapter {
    param($ErrorAction)
    [pscustomobject]@{Name='Ethernet';InterfaceGuid=$script:nicGuid;MacAddress=$script:mac;InterfaceDescription='Red Hat VirtIO Ethernet Adapter';ifIndex=$script:index}
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('step3-approval-tests-'+[guid]::NewGuid().ToString('N'))
$state=Join-Path $temp State;$scripts=Join-Path $temp Scripts
New-Item -ItemType Directory $state,(Join-Path $state VMwareToolsCleanup),(Join-Path $scripts VMwareToolsCleanup)|Out-Null
'capture'|Set-Content (Join-Path $state PreMigrationState.json)
'network'|Set-Content (Join-Path $state NetworkConfiguration.json)
'runtime'|Set-Content (Join-Path $scripts Migrate-VmwareToProxmox.ps1)
'worker'|Set-Content (Join-Path $scripts 'VMwareToolsCleanup/Invoke-MsiUninstall.ps1')
function Context { Get-MigrationStep3ApprovalContext $state $script:options $scripts }
function Set-FixtureWorkflow($stage,$identity) {
    [pscustomobject]@{schemaVersion=1;identity=$identity;stage=$stage}|ConvertTo-Json|Set-Content (Join-Path $state 'VMwareToolsCleanup/Workflow.json')
}
function Fixture {
    $script:machineGuid='MACHINE';$script:uuid='11111111-2222-3333-4444-555555555555';$script:nicGuid='AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';$script:mac='02-00-00-00-00-01';$script:index=10
    $script:options=[ordered]@{MigrationMethod='VeeamFirstboot';ToolsCleanupMode='Automatic';CheckLevel='Migration';RepairOfflineDisks=$false;AdapterMappingPath='';ApplicationConfigPath='';UseExtendedToolsCleanup=$true}
    Clear-MigrationStep3Approval $state
    $script:context=Context
    Set-FixtureWorkflow AwaitingMsiReboot $context.identity
}
try {
    foreach($method in @('VeeamFirstboot','DirectImport')) {
        Case "$method approval covers both planned restarts, not fresh/completed/failed runs" {
            Fixture;$options.MigrationMethod=$method;$context=Context
            Assert (-not (Test-MigrationStep3Approval $state $context)) 'Missing approval accepted'
            Save-MigrationStep3Approval $state $context
            foreach($stage in @('AwaitingMsiReboot','AwaitingResidualReboot')){
                Set-FixtureWorkflow $stage $context.identity
                Assert (Test-MigrationStep3Approval $state (Context)) "Approval not reused at $stage"
            }
            foreach($stage in @('ReadyForMsi','Complete','Failed','MsiInProgress','ResidualsInProgress','VerificationFailed','VerificationPending','Unknown')){
                Set-FixtureWorkflow $stage $context.identity
                Assert (-not (Test-MigrationStep3Approval $state (Context))) "Approval reused at $stage"
            }
        }
    }
    Case 'Changing interface index alone does not invalidate stable adapter approval' {
        Fixture;Save-MigrationStep3Approval $state $context;$script:index=25
        Assert (Test-MigrationStep3Approval $state (Context)) 'Interface index was treated as identity'
    }
    foreach($change in @('machine','uuid','guid','mac','capture','network','method','mode','level','repair','runtime')){
        Case "Changed $change requires renewed approval" {
            Fixture;Save-MigrationStep3Approval $state $context
            $file=$null;$before=$null
            try {
                switch($change){
                    machine {$script:machineGuid='OTHER'}
                    uuid {$script:uuid='AAAAAAAA-2222-3333-4444-555555555555'}
                    guid {$script:nicGuid='BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE'}
                    mac {$script:mac='02-00-00-00-00-02'}
                    method {$options.MigrationMethod='DirectImport'}
                    mode {$options.ToolsCleanupMode='Manual'}
                    level {$options.CheckLevel='Deep'}
                    repair {$options.RepairOfflineDisks=$true}
                    capture {$file=Join-Path $state PreMigrationState.json}
                    network {$file=Join-Path $state NetworkConfiguration.json}
                    runtime {$file=Join-Path $scripts Migrate-VmwareToProxmox.ps1}
                }
                if($file){$before=Get-Content $file -Raw;'changed'|Set-Content $file}
                Assert (-not (Test-MigrationStep3Approval $state (Context))) 'Changed context accepted'
            } finally {if($file){[IO.File]::WriteAllText($file,$before)}}
        }
    }
    Case 'Changing adapter-map file contents at the same path requires renewed approval' {
        Fixture;$map=Join-Path $temp map.json;'old map'|Set-Content $map;$options.AdapterMappingPath=$map;$context=Context
        Save-MigrationStep3Approval $state $context;'new map'|Set-Content $map
        Assert (-not (Test-MigrationStep3Approval $state (Context))) 'Changed mapping file accepted'
    }
    Case 'Copied approval cannot authorize another capture directory' {
        Fixture;Save-MigrationStep3Approval $state $context
        $other=Join-Path $temp OtherState;Copy-Item $state $other -Recurse
        $otherContext=Get-MigrationStep3ApprovalContext $other $options $scripts
        Assert (-not (Test-MigrationStep3Approval $other $otherContext)) 'Copied token accepted'
    }
    Case 'Foreign workflow identity and corrupt approval fail closed' {
        Fixture;Save-MigrationStep3Approval $state $context
        Set-FixtureWorkflow AwaitingMsiReboot ([pscustomobject]@{computerName='FOREIGN';machineGuid='OTHER';captureSha256='OTHER'})
        Assert (-not (Test-MigrationStep3Approval $state $context)) 'Foreign workflow accepted'
        Set-FixtureWorkflow AwaitingMsiReboot $context.identity
        '{invalid'|Set-Content (Join-Path $state Step3Approval.json)
        Assert (-not (Test-MigrationStep3Approval $state $context)) 'Corrupt approval accepted'
        Assert (-not (Test-MigrationStep3Approval $state $null)) 'Unavailable context accepted'
    }
    foreach($method in @('VeeamFirstboot','DirectImport')) {
        Case "$method actual menu phase saves once and resumes both pending stages without ShouldProcess prompts" {
            Fixture;Clear-MigrationStep3Approval $state
            $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root Migrate-VmwareToProxmox.ps1),[ref]$t,[ref]$e)
            $switch=$ast.Find({param($n)$n -is [Management.Automation.Language.SwitchStatementAst] -and $n.Condition.Extent.Text -eq '$Phase'},$true)
            $body=@($switch.Clauses|Where-Object {$_.Item1.Value -eq 'ValidatePost'})[0].Item2.Extent.Text
            $body=$body.Substring(1,$body.Length-2).Replace('$PSScriptRoot','$script:testRuntime')
            $fixture=[scriptblock]::Create('[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact="High")]'+$ast.ParamBlock.Extent.Text+$body)
            $script:testRuntime=$scripts;$script:InteractiveMenu=$false;$script:LevelExplicit=$false;$script:RestartRequired=$false;$script:Step3ApprovalDirectory=''
            $script:received=$null;$script:pending=$true
            function Resolve-MigrationStateDirectory {param($StateDirectory) $state}
            function Get-MigrationCapturedAssessmentLevel {param($StateDirectory) 'Migration'}
            function Assert-MigrationFirstbootComplete {param([switch]$FirstbootNotUsed)
                Assert ($FirstbootNotUsed.IsPresent -eq ($method -eq 'DirectImport')) 'Wrong method gate'
                [pscustomobject]@{state='Complete'}
            }
            function Get-MigrationProperty {param($Value,$Name,$Default) $Default}
            function Invoke-CheckedMigrationScript {param($Name,$Arguments)
                Assert ($Name -eq 'Restore-And-TestMigrationState.ps1') 'Wrong child'
                $script:received=$Arguments
                $script:RestartRequired=$script:pending
                if(-not $script:pending){Set-FixtureWorkflow Complete (Get-VMwareCleanupIdentity $state)}
            }
            $prior=$ConfirmPreference
            try {
                $ConfirmPreference='None'
                & $fixture -Phase ValidatePost -MigrationMethod $method -FirstbootNotUsed:($method -eq 'DirectImport')
                Assert (-not $received.ContainsKey('ResumeApproved')) 'First run skipped initial approval'
                Assert (Test-Path (Join-Path $state Step3Approval.json)) 'Initial approval not saved'
                # Running this suite with -NonInteractive makes any unexpected
                # ShouldProcess prompt throw, rather than silently approving it.
                $ConfirmPreference='High'
                foreach($stage in @('AwaitingMsiReboot','AwaitingResidualReboot')){
                    Set-FixtureWorkflow $stage (Get-VMwareCleanupIdentity $state)
                    & $fixture -Phase ValidatePost -MigrationMethod $method -FirstbootNotUsed:($method -eq 'DirectImport')
                    Assert ($received.ResumeApproved -and $received.RestartBannerHandledByCaller -and -not $received.Confirm) 'Resume did not suppress duplicate prompts/banner'
                }
                # Explicit -Confirm:$false bypasses the prompt for this invocation,
                # but must not be mistaken for inherited continuation approval.
                & $fixture -Phase ValidatePost -MigrationMethod $method -FirstbootNotUsed:($method -eq 'DirectImport') -Confirm:$false
                Assert (-not $received.ContainsKey('ResumeApproved')) 'Explicit confirmation preference ignored'
                $script:pending=$false
                & $fixture -Phase ValidatePost -MigrationMethod $method -FirstbootNotUsed:($method -eq 'DirectImport')
                Assert (-not (Test-Path (Join-Path $state Step3Approval.json))) 'Completed workflow retained approval'
                # Explicit -Confirm must override a reusable token. In this
                # noninteractive test it throws at the prompt before any child.
                Set-FixtureWorkflow AwaitingMsiReboot (Get-VMwareCleanupIdentity $state)
                $ConfirmPreference='None'
                $script:pending=$true
                & $fixture -Phase ValidatePost -MigrationMethod $method -FirstbootNotUsed:($method -eq 'DirectImport')
                $script:received=$null;$caught=$false
                try { & $fixture -Phase ValidatePost -MigrationMethod $method -FirstbootNotUsed:($method -eq 'DirectImport') -Confirm } catch {$caught=$true}
                Assert ($caught -and $null -eq $received -and -not (Test-Path (Join-Path $state Step3Approval.json))) 'Explicit confirmation did not override/revoke reusable approval'

            } finally {$ConfirmPreference=$prior}
        }
    }
    Case 'Actual restart branch prints one standalone banner and suppresses it for the menu caller' {
        $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root Restore-And-TestMigrationState.ps1),[ref]$t,[ref]$e)
        $branch=$ast.Find({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if (Complete-PendingToolsCleanupReport)')},$true)
        Assert ($null -ne $branch) 'Cannot find production restart branch'
        $body=$branch.Extent.Text.Replace('exit 2','return 2').Replace('exit 3010','return 3010')
        $fixture=[scriptblock]::Create('param([bool]$RestartBannerHandledByCaller)'+$body)
        $script:Results=@()
        function Complete-PendingToolsCleanupReport {$true}
        function Write-Reports { [pscustomobject]@{overallStatus='WARNING'} }
        $standalone=@(& $fixture $false 6>&1)
        Assert (@($standalone|Where-Object {$_ -is [int] -and $_ -eq 3010}).Count -eq 1) 'Standalone restart code lost'
        Assert (@($standalone|Where-Object {"$_" -match '^=+ RESTART REQUIRED'}).Count -eq 1) 'Standalone banner count wrong'
        $menu=@(& $fixture $true 6>&1)
        Assert (@($menu|Where-Object {"$_" -match 'RESTART REQUIRED'}).Count -eq 0) 'Child printed menu-owned banner'
        $combined=@($menu)+@(Write-MigrationRestartInstructions 6>&1)
        Assert (@($combined|Where-Object {"$_" -match '^=+ RESTART REQUIRED'}).Count -eq 1) 'Menu output duplicates restart banner'
    }
    Case 'Clearing approval preserves workflow and cleanup choice/backups' {
        Fixture;Save-MigrationStep3Approval $state $context
        $workflow=Join-Path $state 'VMwareToolsCleanup/Workflow.json';$hash=(Get-FileHash $workflow).Hash
        Clear-MigrationStep3Approval $state
        Assert (-not (Test-Path (Join-Path $state Step3Approval.json)) -and (Get-FileHash $workflow).Hash -eq $hash) 'Approval clearing changed workflow'
    }
} finally {Remove-Item $temp -Recurse -Force}
Write-Host "Passed $count step 3 approval tests. Windows identity reads were mocked."
