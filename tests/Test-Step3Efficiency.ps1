#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$passed=0
function Assert($value,$message){if(-not $value){throw $message}}
function Test($name,[scriptblock]$body){& $body;$script:passed++;Write-Host "PASS $name"}
function Import-Functions($file,$names){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file),[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) "Syntax errors in $file"
    foreach($fn in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
        if($fn.Name -in $names){Set-Item "function:script:$($fn.Name)" ([scriptblock]::Create($fn.Body.Extent.Text.Substring(1,$fn.Body.Extent.Text.Length-2)))}
    }
}
Import-Functions Restore-And-TestMigrationState.ps1 @('Test-MappedNetworkAlreadyRestored','Restore-Network','Complete-PendingToolsCleanupReport','Complete-PostMigrationNetworkChecks')
Import-Functions Remove-VMwareToolsResiduals.ps1 @('Get-CleanupDeviceBindings')
function Fixture {
    $script:source=[pscustomobject]@{interfaceIndex=6;dhcpEnabled=$false;dnsAutomatic=$false;dnsSuffix='example.test';registerThisConnectionAddress=$true;useSuffixWhenRegistering=$false;interfaceMetric=15;dnsServers=@('192.0.2.2','192.0.2.3');ipv4Addresses=@([pscustomobject]@{address='192.0.2.10';prefixLength=24});defaultGateways=@('192.0.2.1')}
    $script:actual=$source|ConvertTo-Json -Depth 6|ConvertFrom-Json
    $actual.interfaceIndex=18 # Reused/changed interface index, verified mapping is authoritative.
    $script:mapping=[pscustomobject]@{source=$source;target=[pscustomobject]@{isVirtIO=$true;adapter=[pscustomobject]@{interfaceIndex=18;interfaceAlias='Ethernet'}}}
    $script:route=[pscustomobject]@{interfaceIndex=6;isPersistentOrStatic=$true;isConnectedRoute=$false;destinationPrefix='0.0.0.0/0';nextHop='192.0.2.1';routeMetric=256;store='PersistentStore';protocol='NetMgmt'}
    $script:PreNetwork=[pscustomobject]@{ipv4Routes=@($route)}
    $script:link='Up';$script:addressState='Preferred';$script:badIdentity=$false;$script:readFail=$false;$script:missingStore='';$script:changes=0;$script:snapshots=0
    $script:ResumeApproved=$false
    $script:NetworkVerifiedLive=$false
    $script:UseExtendedToolsCleanup=$true;$script:StateDirectory=$root;$script:Results=New-Object System.Collections.ArrayList
    $script:calls=New-Object System.Collections.Generic.List[string]
}
function Assert-MigrationTargetIdentity {param($Mapping) if($script:badIdentity){throw 'Identity changed'}}
function Get-NetAdapter {param($InterfaceIndex) Assert ($InterfaceIndex -eq 18) 'Stale interface index used';[pscustomobject]@{Status=$script:link}}
function Get-AdapterRecord {param($nic) if($script:readFail){throw 'Read failure'};$script:actual}
function Get-AdapterIPv4Addresses {param($InterfaceIndex) [pscustomobject]@{AddressState=$script:addressState;IPAddress='192.0.2.10'}}
function Get-MigrationNetRoutes {param($InterfaceIndex,$PolicyStore) Assert ($InterfaceIndex -eq 18) 'Stale route index';if($PolicyStore -ne $script:missingStore){[pscustomobject]@{DestinationPrefix=$route.destinationPrefix;NextHop=$route.nextHop;RouteMetric=256}}}
function Add-Result {param($Name,$State,$Summary) [void]$script:Results.Add([pscustomobject]@{name=$Name;state=$State;summary=$Summary})}
function Add-Action {param($Name,$State,$Summary) $script:calls.Add($State)}
function Write-Log {param($Text,$Color)}
function Save-RollbackState {param($Mapping) $script:snapshots++}
function Restore-AdapterNetwork {param($Mapping,[switch]$Confirm) $script:changes++}
function Restore-StaticRoutes {param($Mapping,[switch]$Confirm) $script:changes++}
function Compare-NetworkState { $script:calls.Add('CompareNetwork');Add-Result Network PASS matched }
function Remove-ObsoleteMigrationRoutes { $script:calls.Add('Routes') }
function Invoke-SafePart {param($Name,[scriptblock]$Body) & $Body}
foreach($method in @('VeeamFirstboot','DirectImport')){
    Test "${method}: matching live network avoids mutations and rollback file" {
        Fixture;$script:MigrationMethod=$method
        Restore-Network @($mapping) -Confirm:$false
        Assert ($changes -eq 0 -and $snapshots -eq 0 -and $script:NetworkVerifiedLive) 'Matching network was modified or not verified'
    }
    Test "${method}: pending restart still verifies network/routes but defers full checks" {
        Fixture;$script:MigrationMethod=$method;$script:ToolsRestartPending=$true
        Assert (Complete-PendingToolsCleanupReport) 'Did not request early report'
        Assert (($calls -join ',') -eq 'CompareNetwork,Routes,DEFERRED_UNTIL_RESTART') 'Wrong intermediate checks'
        Assert ($script:ReportPhase -eq 'IntermediateRestartRequired') 'Not marked intermediate'
        $script:ToolsRestartPending=$false;$calls.Clear()
        Assert (-not (Complete-PendingToolsCleanupReport)) 'Completed/legacy run deferred'
        Assert ($calls.Count -eq 0) 'Completed run repeated intermediate checks'
    }
}
foreach($field in @('dhcpEnabled','dnsAutomatic','dnsSuffix','registerThisConnectionAddress','useSuffixWhenRegistering','interfaceMetric','dnsServers','ipv4Addresses','defaultGateways')){
    Test "Network drift in $field uses existing snapshot and restore path" {
        Fixture
        switch($field){
            dnsServers {$actual.dnsServers=@('192.0.2.3','192.0.2.2')}
            ipv4Addresses {$actual.ipv4Addresses=@()}
            defaultGateways {$actual.defaultGateways=@()}
            dnsSuffix {$actual.dnsSuffix='other.test'}
            interfaceMetric {$actual.interfaceMetric=99}
            default {$actual.$field=-not $source.$field}
        }
        Restore-Network @($mapping) -Confirm:$false
        Assert ($snapshots -eq 1 -and $changes -eq 2) 'Drift was silently skipped'
    }
}
foreach($store in @('ActiveStore','PersistentStore')){
    Test "Missing route in $store prevents shortcut" {Fixture;$script:missingStore=$store;Assert (-not (Test-MappedNetworkAlreadyRestored @($mapping))) 'Missing route ignored'}
}
Test 'One mismatched adapter prevents skipping a multi-NIC plan' {
    Fixture
    $second=$mapping|ConvertTo-Json -Depth 10|ConvertFrom-Json
    $second.target.isVirtIO=$false
    Assert (-not (Test-MappedNetworkAlreadyRestored @($mapping,$second))) 'Partial multi-NIC match authorized shortcut'
}
Test 'Automatic DNS ignores changing leased DNS addresses but still checks assignment mode' {
    Fixture;$source.dhcpEnabled=$true;$actual.dhcpEnabled=$true;$source.dnsAutomatic=$true;$actual.dnsAutomatic=$true
    $actual.dnsServers=@('192.0.2.99')
    Assert (Test-MappedNetworkAlreadyRestored @($mapping)) 'Valid DHCP/DNS state not accepted'
    $actual.dnsAutomatic=$false
    Assert (-not (Test-MappedNetworkAlreadyRestored @($mapping))) 'DNS assignment mode ignored'
}
Test 'Missing network comparison evidence cannot authorize route deletion' {
    Fixture
    function Compare-NetworkState {throw 'Provider failure'}
    $script:NetworkComparisonComplete=$false;$script:NetworkComparisonPassed=$false
    $threw=$false;try{Complete-PostMigrationNetworkChecks}catch{$threw=$true}
    Assert ($threw -and -not $script:NetworkComparisonComplete -and -not $script:NetworkComparisonPassed) 'Failed comparison accepted'
}
Test 'Inherited approval rechecks live network and asks again before drift can mutate settings' {
    Fixture;$script:ResumeApproved=$true
    function Confirm-MigrationResumeNetworkChange {param($Targets,[switch]$Confirm) throw 'Matching network must not prompt'}
    Restore-Network @($mapping) -Confirm:$false
    Assert ($changes -eq 0) 'Matching resume changed network'
    Fixture;$script:ResumeApproved=$true;$actual.interfaceMetric=99
    function Confirm-MigrationResumeNetworkChange {param($Targets,[switch]$Confirm) Assert $Confirm 'Renewed confirmation was not forced';return $false}
    $caught=$false;try{Restore-Network @($mapping) -Confirm:$false}catch{$caught=$true}
    Assert ($caught -and $snapshots -eq 0 -and $changes -eq 0) 'Declined drift restoration changed settings'
    function Confirm-MigrationResumeNetworkChange {param($Targets,[switch]$Confirm) return $true}
    Restore-Network @($mapping) -Confirm:$false
    Assert ($snapshots -eq 1 -and $changes -eq 2) 'Approved drift did not retain snapshot/restore path'
}
Test 'Read failure retains snapshot-before-mutation behavior' {Fixture;$script:readFail=$true;Restore-Network @($mapping) -Confirm:$false;Assert ($snapshots -eq 1 -and $changes -eq 2) 'Read failure authorized skip'}
Test 'Identity change, disconnected link and duplicate IPv4 cannot authorize skip' {
    Fixture;$script:badIdentity=$true;$threw=$false;try{Test-MappedNetworkAlreadyRestored @($mapping)|Out-Null}catch{$threw=$true};Assert $threw 'Identity ignored'
    Fixture;$script:link='Disconnected';Assert (-not (Test-MappedNetworkAlreadyRestored @($mapping))) 'Link ignored'
    Fixture;$script:addressState='Duplicate';Assert (-not (Test-MappedNetworkAlreadyRestored @($mapping))) 'Duplicate ignored'
}
Test 'Legacy default and WhatIf retain previous behavior' {
    Fixture;$script:UseExtendedToolsCleanup=$false;Restore-Network @($mapping) -Confirm:$false
    Assert ($snapshots -eq 1 -and $changes -eq 2) 'Legacy behavior changed'
    Fixture;Restore-Network @($mapping) -WhatIf
    Assert ($snapshots -eq 0 -and $changes -eq 0) 'WhatIf changed settings'
}
Test 'Bulk INF bindings preserve ambiguous/missing evidence and fallback on errors' {
    function Get-PnpDeviceProperty {param($InstanceId,$KeyName)
        foreach($id in @('A','B','B')){[pscustomobject]@{InstanceId=$id;KeyName=$KeyName;Data='oem1.inf'}}
        [pscustomobject]@{InstanceId='C';KeyName=$KeyName} # Provider error object, no Data
    }
    $data=Get-CleanupDeviceBindings @([pscustomobject]@{InstanceId='A'},[pscustomobject]@{InstanceId='B'})
    Assert ($data.Count -eq 1 -and $data.A -eq 'oem1.inf') 'Unknown or duplicate binding accepted'
    function Get-PnpDeviceProperty {throw 'Provider failure'}
    $data=Get-CleanupDeviceBindings @([pscustomobject]@{InstanceId='A'})
    Assert ($data.Count -eq 0) 'Bulk failure did not retain individual fallback'
}
Write-Host "Passed $passed step 3 efficiency tests. Native Windows calls were mocked."
