#Requires -Version 5.1
# Disk repair is opt-in and scoped to unambiguous captured data disks.
function Get-MigrationDiskIdentity {
    param($Disk)
    [pscustomobject][ordered]@{number=[int]$Disk.Number;size=[int64]$Disk.Size;style=[string]$Disk.PartitionStyle;
        guid=([string](Get-MigrationProperty $Disk 'Guid' '')).Trim();signature=([string](Get-MigrationProperty $Disk 'Signature' '')).Trim();
        uniqueId=([string](Get-MigrationProperty $Disk 'UniqueId' '')).Trim();serial=([string](Get-MigrationProperty $Disk 'SerialNumber' '')).Trim()}
}
function Test-MigrationDataDiskMatch {
    param($Source,$Target,[object[]]$Partitions)
    if ([bool](Get-MigrationProperty $Target 'IsBoot' $true) -or [bool](Get-MigrationProperty $Target 'IsSystem' $true)) { return $false }
    if ([int64]$Source.sizeBytes -ne [int64]$Target.Size -or [string]$Source.partitionStyle -ine [string]$Target.PartitionStyle) { return $false }
    $guid=[string](Get-MigrationProperty $Source 'diskGuid' '')
    if ($guid -and $guid -ne [guid]::Empty.ToString()) { return $guid -ieq [string](Get-MigrationProperty $Target 'Guid' '') }
    $signature=[string](Get-MigrationProperty $Source 'diskSignature' '')
    if ($Source.partitionStyle -eq 'MBR' -and $signature -and $signature -ne '0') { return $signature -eq [string](Get-MigrationProperty $Target 'Signature' '') }
    foreach ($pair in @(@('uniqueId','UniqueId'),@('serialNumber','SerialNumber'))) {
        $old=([string](Get-MigrationProperty $Source $pair[0] '')).Trim()
        $now=([string](Get-MigrationProperty $Target $pair[1] '')).Trim()
        if ($old -and $now -and $old -ieq $now) { return $true }
    }
    # Older captures have no persistent GPT/MBR identity. A partition layout is
    # accepted only if it identifies exactly one source AND one current disk.
    $before=@($Partitions|Where-Object diskNumber -eq $Source.diskNumber|Sort-Object partitionNumber)
    if (-not $before.Count) { return $false }
    try { $after=@(Get-Partition -DiskNumber $Target.Number -ErrorAction Stop|Sort-Object PartitionNumber) } catch { return $false }
    if ($after.Count -ne $before.Count) { return $false }
    for($i=0;$i -lt $before.Count;$i++) {
        if ($before[$i].partitionNumber -ne $after[$i].PartitionNumber -or
            [int64]$before[$i].partitionSizeBytes -ne [int64]$after[$i].Size -or
            [string]$before[$i].partitionType -ine [string]$after[$i].Type) { return $false }
    }
    return $true
}
function Get-MigrationDiskRepairPlan {
    param($Capture,[object[]]$Current)
    $sources=@((Get-MigrationProperty $Capture 'disks' @())|Where-Object {
        -not [bool](Get-MigrationProperty $_ 'isBoot' $true) -and -not [bool](Get-MigrationProperty $_ 'isSystem' $true) -and
        $_.partitionStyle -in @('GPT','MBR') -and 'Online' -in @(Get-MigrationProperty $_ 'operationalStatus' @())
    })
    $parts=@(Get-MigrationProperty $Capture 'partitionsAndVolumes' @())
    foreach($disk in @($Current|Where-Object IsOffline)) {
        $identity=Get-MigrationDiskIdentity $disk
        $matches=@($sources|Where-Object { Test-MigrationDataDiskMatch $_ $disk $parts })
        $reason='No unique captured data disk match; left offline for manual review.'
        $source=$null
        if ($matches.Count -eq 1) {
            $otherTargets=@($Current|Where-Object { Test-MigrationDataDiskMatch $matches[0] $_ $parts })
            if ($otherTargets.Count -eq 1) { $source=$matches[0];$reason='' }
        }
        # Reject duplicate current identities even if another copy is a boot or
        # system disk (which must never itself be considered a repair target).
        $identityField=if($identity.guid -and $identity.guid -ne [guid]::Empty.ToString()){'guid'}elseif($identity.style -eq 'MBR' -and $identity.signature -and $identity.signature -ne '0'){'signature'}elseif($identity.uniqueId){'uniqueId'}else{'serial'}
        if ($identity.$identityField -and @($Current|Where-Object { (Get-MigrationDiskIdentity $_).$identityField -ieq $identity.$identityField }).Count -gt 1) {
            $reason='Duplicate current disk identity; manual review required.'
        }
        if ([string](Get-MigrationProperty $disk 'HealthStatus' '') -ne 'Healthy') { $reason='Disk health is not Healthy; manual review required.' }
        if (-not ($identity.guid -or $identity.uniqueId -or $identity.serial -or ($identity.signature -and $identity.signature -ne '0'))) {
            $reason='Current disk identity is unavailable; manual review required.'
        }
        [pscustomobject]@{disk=$disk;identity=$identity;source=$source;eligible=($reason -eq '');reason=$reason}
    }
}
function Resolve-MigrationOfflineDiskRepairChoice {
    param([string]$StateDirectory,[bool]$Requested,[switch]$Explicit,[switch]$Interactive)
    if ($Explicit) { return $Requested }
    $identity=Get-VMwareCleanupIdentity $StateDirectory
    $path=Join-Path $StateDirectory 'OfflineDiskChoice.json'
    if (Test-Path -LiteralPath $path) {
        $saved=Get-Content -LiteralPath $path -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
        Assert-VMwareCleanupIdentity $saved.identity $identity
        if ($saved.schemaVersion -ne 1 -or $saved.repair -isnot [bool]) { throw 'Invalid saved offline disk choice.' }
        return [bool]$saved.repair
    }
    if (-not $Interactive) { return $false }
    $capture=Get-Content -LiteralPath (Join-Path $StateDirectory 'PreMigrationState.json') -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    $plan=@(Get-MigrationDiskRepairPlan $capture @(Get-Disk -ErrorAction Stop))
    foreach($row in $plan) {
        Write-Host ("Offline disk {0}: {1} GB; read-only={2}; {3}" -f $row.disk.Number,[math]::Round($row.disk.Size/1GB,2),$row.disk.IsReadOnly,$(if($row.eligible){'uniquely matched to captured data disk '+$row.source.diskNumber}else{$row.reason}))
    }
    if (-not @($plan|Where-Object eligible).Count) { return $false }
    Write-Host 'Only the verified data disks listed above will be made writable and brought online. Unmatched/ambiguous disks are left unchanged.'
    switch ((Read-Host 'Bring the verified offline data disks online? [y/N]').Trim().ToLowerInvariant()) {
        {$_ -in @('y','yes')} { return $true }
        {$_ -in @('','n','no')} { return $false }
        default { throw 'Invalid offline disk choice. No disks were changed.' }
    }
}
function Save-MigrationOfflineDiskChoice {
    param([string]$StateDirectory,[bool]$Repair)
    $state=[pscustomobject]@{schemaVersion=1;identity=(Get-VMwareCleanupIdentity $StateDirectory);repair=$Repair}
    & { $ConfirmPreference='None';Write-VMwareCleanupState (Join-Path $StateDirectory 'OfflineDiskChoice.json') $state }
}
