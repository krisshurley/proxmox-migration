#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'Migration.Common.ps1')
. (Join-Path $root 'Migration.VMwareToolsCleanup.ps1')
. (Join-Path $root 'Migration.Disks.ps1')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Restore-And-TestMigrationState.ps1'),[ref]$tokens,[ref]$errors)
$fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Repair-OfflineDisks'},$true)
Set-Item function:Repair-OfflineDisks ([scriptblock]::Create($fn.Body.Extent.Text.Substring(1,$fn.Body.Extent.Text.Length-2)))
$passed=0
function Assert($ok,$message){if(-not $ok){throw $message}}
function Test($name,[scriptblock]$body){& $body;$script:passed++;Write-Host "PASS $name"}
function Throws([scriptblock]$body){$caught=$false;try{& $body|Out-Null}catch{$caught=$true};Assert $caught 'Expected block'}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('disk-tests-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $temp|Out-Null
function Fixture {
    $script:PreState=[pscustomobject]@{disks=@(1..3|ForEach-Object {
        [pscustomobject]@{diskNumber=$_;sizeBytes=$(if($_ -eq 1){300GB}else{50GB});partitionStyle='GPT';diskGuid=('10000000-0000-0000-0000-00000000000'+$_);uniqueId='old'+$_;serialNumber='old'+$_;isBoot=$false;isSystem=$false;operationalStatus=@('Online')}
    });partitionsAndVolumes=@(1..3|ForEach-Object {
        [pscustomobject]@{diskNumber=$_;partitionNumber=1;partitionSizeBytes=$(if($_ -eq 1){299GB}else{49GB});partitionType='Basic'}
    })}
    $script:disks=@($script:PreState.disks|ForEach-Object {
        [pscustomobject]@{Number=$_.diskNumber+10;Size=$_.sizeBytes;PartitionStyle='GPT';Guid=$_.diskGuid;UniqueId=('new'+$_.diskNumber);SerialNumber=('new'+$_.diskNumber);IsBoot=$false;IsSystem=$false;HealthStatus='Healthy';FriendlyName='QEMU disk';IsOffline=$true;IsReadOnly=$true}
    })
    $script:Mode='Full';$script:RepairOfflineDisks=$true;$script:RootPath=$temp
    $script:writes=0;$script:readCount=0;$script:swapIdentity=$false;$script:results=@();$script:actions=@();$script:answer='';$script:prompts=0
}
function Get-Disk {param($Number,$ErrorAction)
    $script:readCount++
    if($script:swapIdentity -and $script:readCount -gt 1){$script:disks[0].Guid='20000000-0000-0000-0000-000000000001'}
    if($PSBoundParameters.ContainsKey('Number')){$script:disks|Where-Object Number -eq $Number}else{$script:disks}
}
function Get-Partition {param($DiskNumber,$ErrorAction)
    $disk=@($script:disks|Where-Object Number -eq $DiskNumber)[0]
    [pscustomobject]@{PartitionNumber=1;Size=$(if($disk.Size -eq 300GB){299GB}else{49GB});Type='Basic'}
}
function Get-CimInstance {[pscustomobject]@{Manufacturer='QEMU';Model='KVM'}}
function Set-Disk {param($Number,[Nullable[bool]]$IsReadOnly,[Nullable[bool]]$IsOffline,$Confirm,$ErrorAction)
    $script:writes++;$d=@($script:disks|Where-Object Number -eq $Number)[0]
    if($PSBoundParameters.ContainsKey('IsReadOnly')){$d.IsReadOnly=[bool]$IsReadOnly}
    if($PSBoundParameters.ContainsKey('IsOffline')){$d.IsOffline=[bool]$IsOffline}
}
function Invoke-DiskpartOnline {throw 'Unexpected diskpart call'}
function Add-Result {param($Name,$State,$Summary,$Details) $script:results+=@([pscustomobject]@{name=$Name;state=$State;summary=$Summary;details=$Details})}
function Add-Action {param($Name,$State,$Summary) $script:actions+=@([pscustomobject]@{name=$Name;state=$State;summary=$Summary})}
function Read-Host {param($Prompt) $script:prompts++;$script:answer}
function Get-VMwareCleanupIdentity {param($StateDirectory) [pscustomobject]@{computerName='TEST';machineGuid='TEST-ID';captureSha256=(Get-FileHash (Join-Path $StateDirectory PreMigrationState.json)).Hash}}
try {
    Test 'Persistent GUIDs distinguish two equal-sized disks across index changes' {
        Fixture;$plan=@(Get-MigrationDiskRepairPlan $PreState $disks)
        Assert (@($plan|Where-Object eligible).Count -eq 3) 'Verified disks were not uniquely matched'
        Assert ($plan[2].source.diskNumber -eq 3 -and $plan[2].disk.Number -eq 13) 'Disk numbers were treated as identity'
    }
    Test 'Legacy capture offers unique layout but leaves equal-sized identical layouts offline' {
        Fixture;foreach($d in $PreState.disks){$d.PSObject.Properties.Remove('diskGuid')}
        $plan=@(Get-MigrationDiskRepairPlan $PreState $disks)
        Assert (@($plan|Where-Object eligible).Count -eq 1 -and $plan[0].eligible) 'Ambiguous legacy disks were accepted or unique layout blocked'
    }
    Test 'Conflicting persistent GUID never falls back to matching size/layout' {
        Fixture;$disks[0].Guid='20000000-0000-0000-0000-000000000001'
        Assert (-not @(Get-MigrationDiskRepairPlan $PreState $disks)[0].eligible) 'GUID mismatch ignored'
    }
    Test 'Foreign boot/system/RAW/unhealthy disks and absent current identity are left untouched' {
        foreach($kind in @('boot','system','raw','unhealthy','unknown')) {
            Fixture
            switch($kind){boot {$disks[0].IsBoot=$true};system {$disks[0].IsSystem=$true};raw {$disks[0].PartitionStyle='RAW'};unhealthy {$disks[0].HealthStatus='Unhealthy'};unknown {$disks[0].Guid='';$disks[0].UniqueId='';$disks[0].SerialNumber=''}}
            Assert (-not @(Get-MigrationDiskRepairPlan $PreState $disks)[0].eligible) "Unsafe disk selected: $kind"
        }
    }
    Test 'Duplicate current identity cannot authorize repair even if only one copy is offline' {
        Fixture;$extra=$disks[0].PSObject.Copy();$extra.Number=99;$extra.IsOffline=$false;$script:disks+=@($extra)
        Assert (-not @(Get-MigrationDiskRepairPlan $PreState $disks)[0].eligible) 'Duplicate target was not blocked'
    }
    Test 'Explicit repair saves before-state and verifies read-only removal and online state' {
        Fixture;Repair-OfflineDisks -Confirm:$false
        Assert ($writes -eq 6 -and @($disks|Where-Object IsOffline).Count -eq 0) 'Verified repair did not complete'
        Assert ($results[-1].state -eq 'PASS' -and @($actions|Where-Object state -eq APPLIED).Count -eq 3) 'Repair not reported'
        Assert (@(Get-ChildItem $temp -Filter DiskOnlineBefore-*.json).Count -eq 3) 'Before-state backup missing'
    }
    Test 'Without opt-in, WhatIf and read-only comparison modes cannot mutate disks' {
        Fixture;$script:RepairOfflineDisks=$false;Repair-OfflineDisks -Confirm:$false;Assert ($writes -eq 0) 'Default repaired disks'
        Fixture;Repair-OfflineDisks -WhatIf;Assert ($writes -eq 0) 'WhatIf changed disks'
        Fixture;$script:Mode='ValidateOnly';Repair-OfflineDisks -Confirm:$false;Assert ($writes -eq 0) 'Read-only mode changed disks'
    }
    Test 'Index reuse detected after approval blocks writes and diskpart fallback' {
        Fixture;$script:swapIdentity=$true;$script:disks=@($disks[0]);Repair-OfflineDisks -Confirm:$false
        Assert ($writes -eq 0 -and $results[-1].state -eq 'FAIL') 'Changed target was mutated'
    }
    Test 'Backup failure blocks changes to the selected disk' {
        Fixture;$script:disks=@($disks[0]);$script:RootPath=Join-Path $temp 'missing/parent';Repair-OfflineDisks -Confirm:$false
        Assert ($writes -eq 0 -and $results[-1].state -eq 'FAIL') 'Write preceded successful backup'
    }
    Test 'Legacy ambiguity leaves two disks offline while repairing only the uniquely matched disk' {
        Fixture;foreach($d in $PreState.disks){$d.PSObject.Properties.Remove('diskGuid')}
        Repair-OfflineDisks -Confirm:$false
        Assert ($writes -eq 2 -and -not $disks[0].IsOffline -and $disks[1].IsOffline -and $disks[2].IsOffline -and $results[-1].state -eq 'WARNING') 'Ambiguous old-capture disks were changed'
    }
    Test 'Diskpart fallback is allowed only after backup and a stable verified identity' {
        Fixture;$script:disks=@($disks[0])
        function Set-Disk {throw 'Native Set-Disk failure'}
        function Invoke-DiskpartOnline {param($DiskNumber) Assert (@(Get-ChildItem $temp -Filter DiskOnlineBefore-*.json).Count -gt 0) 'Fallback ran before backup';$script:writes++;$script:disks[0].IsReadOnly=$false;$script:disks[0].IsOffline=$false}
        Repair-OfflineDisks -Confirm:$false
        Assert ($writes -eq 1 -and $results[-1].state -eq 'PASS') 'Safe diskpart fallback failed'
    }
    Test 'Duplicate identity on a current boot disk blocks the offline data clone' {
        Fixture;$extra=$disks[0].PSObject.Copy();$extra.Number=99;$extra.IsOffline=$false;$extra.IsBoot=$true;$script:disks+=@($extra)
        Assert (-not @(Get-MigrationDiskRepairPlan $PreState $disks)[0].eligible) 'Boot clone collision was ignored'
    }
    Test 'Interactive default is leave offline; affirmative choice is scoped and cached across restarts' {
        Fixture;$capture=Join-Path $temp 'Choice';New-Item -ItemType Directory $capture|Out-Null
        $PreState|ConvertTo-Json -Depth 6|Set-Content (Join-Path $capture PreMigrationState.json)
        Assert (-not (Resolve-MigrationOfflineDiskRepairChoice $capture -Requested:$false -Interactive)) 'Default enabled repair'
        $script:answer='y';Assert (Resolve-MigrationOfflineDiskRepairChoice $capture -Requested:$false -Interactive) 'Yes was ignored'
        Save-MigrationOfflineDiskChoice $capture $true
        $before=$prompts;Assert (Resolve-MigrationOfflineDiskRepairChoice $capture -Requested:$false -Interactive) 'Saved choice not reused'
        Assert ($prompts -eq $before) 'Saved choice prompted again'
        Assert (-not (Resolve-MigrationOfflineDiskRepairChoice $capture -Requested:$false -Explicit -Interactive)) 'Explicit false ignored'
        Clear-MigrationStep3Approval $capture
        Assert (-not (Test-Path (Join-Path $capture OfflineDiskChoice.json))) 'Completion retained disk consent'
    }
    Test 'Noninteractive invocation never prompts or enables disk repair by default' {
        Fixture;$capture=Join-Path $temp Choice
        Assert (-not (Resolve-MigrationOfflineDiskRepairChoice $capture -Requested:$false)) 'Noninteractive enabled repair'
        Assert ($prompts -eq 0) 'Noninteractive prompted'
    }
    Test 'Child process errors are persisted before a worker can create its transcript' {
        $probe=Join-Path $temp fail.ps1;"throw 'worker-startup-sentinel'"|Set-Content $probe
        $errorFile=Join-Path $temp errors/failure.json
        $code=Invoke-MigrationChildScript $probe @{} -ErrorPath $errorFile
        Assert ($code -eq 99 -and (Test-Path $errorFile)) 'Startup error evidence missing'
        $record=Get-Content $errorFile -Raw|ConvertFrom-Json
        Assert ($record.message -match 'worker-startup-sentinel' -and $record.position -match 'fail.ps1' -and $record.scriptStackTrace) 'Original error/position lost'
    }
    Write-Host "Passed $passed offline disk and child-diagnostic tests. Windows disk operations were mocked."
} finally {Remove-Item -LiteralPath $temp -Recurse -Force}
