<#
.SYNOPSIS
    Collects bounded, local before/after migration evidence without repairing AD.
.DESCRIPTION
    Local service/share state, local replication metadata and last-24-hour EVTX
    logs. Missing, timed-out or incomparable data is never treated as verified.
    Deep optionally runs the existing DC health script against this computer only.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Before','After')][string]$Stage,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$BaselinePath='',
    [ValidateSet('Migration','Deep')][string]$CheckLevel='Migration',
    [ValidateRange(5,60)][int]$ProbeTimeoutSeconds=20
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Migration.Common.ps1')
. (Join-Path $PSScriptRoot 'Migration.Assessment.ps1')
try {
    # A unique caller-supplied directory prevents overwriting evidence on reruns.
    if (Test-Path -LiteralPath $OutputDirectory) { throw "Assessment directory already exists: $OutputDirectory" }
    New-Item -ItemType Directory -Path $OutputDirectory -ErrorAction Stop | Out-Null
    $started=[datetime]::UtcNow
    $context=[pscustomobject]@{sinceUtc=$started.AddHours(-24).ToString('o');outputDirectory=$OutputDirectory}
    $snapshot=[pscustomobject]@{schemaVersion='1.0';computerName=$env:COMPUTERNAME;stage=$Stage;checkLevel=$CheckLevel;capturedAtUtc=$started.ToString('o');completedAtUtc='';probes=[ordered]@{}}
    $snapshot.probes.Identity=Invoke-AssessmentProbe 'Identity' $context $ProbeTimeoutSeconds
    $isDC=$false
    if ($snapshot.probes.Identity.state -eq 'Collected' -and $snapshot.probes.Identity.data.Count -eq 1) { $isDC=[bool]$snapshot.probes.Identity.data[0].isDC }
    $kinds=@('Services','Log:System','Log:Application')
    if ($isDC) { $kinds+=@('Shares','Replication','ReplicationRaw','Log:Directory Service','Log:DFS Replication','Log:DNS Server') }
    foreach ($kind in $kinds) {
        Write-Host "Local evidence: $kind (limit $ProbeTimeoutSeconds s)"
        $snapshot.probes[$kind]=Invoke-AssessmentProbe $kind $context $ProbeTimeoutSeconds
        if ($kind -eq 'ReplicationRaw' -and $snapshot.probes[$kind].state -eq 'Collected') {
            $snapshot.probes[$kind].data | Set-Content -LiteralPath (Join-Path $OutputDirectory 'Replication.txt') -Encoding UTF8
        }
    }
    $snapshot.completedAtUtc=[datetime]::UtcNow.ToString('o')
    $snapshot.capturedAtUtc=$snapshot.completedAtUtc
    $before=$null
    if ($Stage -eq 'After' -and $BaselinePath -and (Test-Path -LiteralPath $BaselinePath)) {
        try { $before=Read-MigrationAssessmentSnapshot $BaselinePath }
        catch { Write-Warning "Cannot use before evidence: $($_.Exception.Message)" }
    }
    $comparison=@()
    if ($Stage -eq 'After') { $comparison=@(Compare-MigrationAssessment $before $snapshot) }
    else { $comparison=@(Get-MigrationBeforeObservations $snapshot) }
    Write-MigrationAssessmentReport $snapshot $comparison $OutputDirectory
    $deepCode=0
    if ($CheckLevel -eq 'Deep' -and $isDC) {
        $deepTimer=[Diagnostics.Stopwatch]::StartNew()
        $deep=[pscustomobject]@{state='Collected';durationMs=0;detail='See detailed local DC reports.'}
        $deepMode=if ($Stage -eq 'Before') {'PreMigration'} else {'PostMigration'}
        $engine=(Get-Process -Id $PID).Path
        $invocation=@{path=(Join-Path $PSScriptRoot 'Test-DCMigrationHealth.ps1');arguments=@{Mode=$deepMode;ComputerName=@($env:COMPUTERNAME);OutputPath=$OutputDirectory}}
        if ($Stage -eq 'After' -and $BaselinePath -and (Test-Path -LiteralPath $BaselinePath)) {
            $previousDeep=@(Get-ChildItem -LiteralPath (Split-Path $BaselinePath -Parent) -Filter Results.json -Recurse -File)
            if ($previousDeep.Count -eq 1) { $invocation.arguments.CompareWith=$previousDeep[0].FullName }
        }
        $payload=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([Management.Automation.PSSerializer]::Serialize($invocation)))
        $command='$i=[Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String("'+$payload+'"))); $a=$i.arguments; & $i.path @a; exit $LASTEXITCODE'
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        try {
            $console=Invoke-AssessmentNative $engine @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) 300
            $console | Set-Content (Join-Path $OutputDirectory 'DeepConsole.txt') -Encoding UTF8
        } catch {
            $deepCode=1
            $deep.state=if ($_.Exception.Data['DiagnosticExitCode'] -in @(1,2)) {'ReviewRequired'} else {'NotVerified'}
            $deep.detail=$_.Exception.Message
            $_.Exception.Message | Set-Content (Join-Path $OutputDirectory 'DeepStatus.txt') -Encoding UTF8
            Write-Warning 'Deep diagnostics reported deviations or could not be verified; see DeepStatus.txt and the detailed reports.'
        }
        $deep.durationMs=$deepTimer.ElapsedMilliseconds; $deepTimer.Stop()
        $snapshot | Add-Member NoteProperty deepDiagnostics $deep
        Write-MigrationAssessmentReport $snapshot $comparison $OutputDirectory
    }
    Write-Host "Evidence report: $(Join-Path $OutputDirectory 'Report.html')"
    $unavailable=@($snapshot.probes.Values | Where-Object state -ne 'Collected').Count
    $attention=@($comparison | Where-Object classification -in @('NewDeviation','NotVerified','NewEvent','RecurringEvent','ExistingDeviation')).Count
    if ($unavailable -or $attention -or $deepCode) { Write-Warning 'Operational deviations or unverified evidence require review; see the evidence report. Migration action results are reported separately.'; exit 1 }
    exit 0
} catch { Write-Error $_ -ErrorAction Continue; exit 2 }
