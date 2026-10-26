#Requires -Version 5.1
# Local evidence collection and comparison. Dot-sourcing performs no work.

function ConvertTo-AssessmentUtc {
    param($Value)
    # PowerShell 5.1 keeps JSON dates as strings; newer versions may deserialize
    # them as DateTime. Preserve Kind/offset instead of converting through culture.
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    return [datetimeoffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
}

function Invoke-AssessmentNative {
    param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds = 12)
    $out = [IO.Path]::GetTempFileName(); $err = [IO.Path]::GetTempFileName(); $process = $null
    try {
        # Windows filenames cannot contain double quotes. Quote every argument,
        # including log names/paths with spaces. No command shell is involved.
        $quoted = @($Arguments | ForEach-Object {
            if ($_ -match '"' -or $_.EndsWith('\')) { throw 'Unsupported native argument quoting.' }
            '"' + $_ + '"'
        }) -join ' '
        $process = Start-Process -FilePath $FilePath -ArgumentList $quoted -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError $err -ErrorAction Stop
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            if ($env:OS -eq 'Windows_NT') {
                # Only terminate the diagnostic process tree created above.
                & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null
            } else { $process.Kill() }
            $null=$process.WaitForExit(2000)
            throw "$FilePath timed out after $TimeoutSeconds seconds; not verified."
        }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            $exception=New-Object System.InvalidOperationException("$FilePath exit $($process.ExitCode): $(Get-Content $err -Raw) $(Get-Content $out -Raw)")
            $exception.Data['DiagnosticExitCode']=$process.ExitCode
            throw $exception
        }
        [string](Get-Content $out -Raw)
    } finally {
        if ($null -ne $process) { if (-not $process.HasExited) { $process.Kill() }; $process.Dispose() }
        Remove-Item -LiteralPath $out,$err -Force -ErrorAction SilentlyContinue
    }
}

function Get-AssessmentLocalEvidence {
    param([string]$Kind, $Context)
    $ErrorActionPreference = 'Stop'
    switch ($Kind) {
        'Identity' {
            $cs=Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 8
            $os=Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 8
            [pscustomobject]@{computerName=$cs.Name;isDC=([int]$cs.DomainRole -ge 4);domain=$cs.Domain;bootUtc=$os.LastBootUpTime.ToUniversalTime().ToString('o')}
        }
        'Services' {
            $names=@('NTDS','DNS','Netlogon','DFSR','Kdc','W32Time','IsmServ')
            Get-CimInstance Win32_Service -OperationTimeoutSec 8 | Where-Object { $_.StartMode -eq 'Auto' -or $_.Name -in $names } |
                ForEach-Object { [pscustomobject]@{name=$_.Name;state=$_.State;startMode=$_.StartMode} }
        }
        'Shares' {
            Get-CimInstance Win32_Share -OperationTimeoutSec 8 | Where-Object Name -in @('SYSVOL','NETLOGON') |
                ForEach-Object { [pscustomobject]@{name=$_.Name;path=$_.Path;accessible=(Test-Path -LiteralPath $_.Path -PathType Container)} }
        }
        'Connectivity' {
            $hostName=$Context.hostName
            if ($hostName) {
                try { Resolve-DnsName $hostName -ErrorAction Stop | Out-Null; [pscustomobject]@{name='DNS connectivity';state='PASS';summary="Resolved $hostName."} }
                catch { [pscustomobject]@{name='DNS connectivity';state='FAIL';summary=$_.Exception.Message} }
            }
            foreach ($gateway in @($Context.gateways)) {
                $ok=Test-Connection $gateway -Count 1 -Quiet -ErrorAction SilentlyContinue
                [pscustomobject]@{name='Gateway ICMP';state=$(if ($ok) {'PASS'} else {'WARNING'});summary="Gateway $gateway responded=$ok."}
            }
            foreach ($port in @($Context.ports)) {
                if (-not $hostName -or [int]$port -lt 1 -or [int]$port -gt 65535) { throw 'Application connectivity requires a hostname and valid ports.' }
                $ok=Test-NetConnection -ComputerName $hostName -Port ([int]$port) -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction Stop
                [pscustomobject]@{name='Application connectivity';state=$(if ($ok) {'PASS'} else {'FAIL'});summary="TCP $hostName port $port reachable=$ok."}
            }
        }
        'Replication' {
            # Local DSA only, no domain discovery or remote ADWS sweep.
            $raw=Invoke-AssessmentNative 'repadmin.exe' @('/showrepl','localhost','/csv')
            $rows=@($raw | ConvertFrom-Csv)
            if ($rows.Count -eq 0 -or -not $rows[0].PSObject.Properties['Last Failure Status']) {
                throw 'No recognizable replication CSV rows; no partners/unsupported locale cannot be verified automatically. Review Replication.txt.'
            }
            foreach ($row in $rows) {
                if (-not $row.'Source DSA' -or -not $row.'Naming Context' -or -not $row.'Last Success Time') { throw 'Incomplete replication CSV identity/time columns.' }
                $code=0; $failures=0
                if (-not [int]::TryParse([string]$row.'Last Failure Status',[ref]$code) -or
                    -not [int]::TryParse([string]$row.'Number of Failures',[ref]$failures)) { throw 'Unrecognized replication result columns.' }
                [pscustomobject]@{key=([string]$row.'Source DSA'+'|'+[string]$row.'Naming Context');partner=$row.'Source DSA';partition=$row.'Naming Context';errorCode=$code;failures=$failures;lastSuccess=$row.'Last Success Time';lastFailure=$row.'Last Failure Time'}
            }
        }
        'ReplicationRaw' { Invoke-AssessmentNative 'repadmin.exe' @('/showrepl','localhost') }
        default {
            if ($Kind -notlike 'Log:*') { throw "Unknown evidence kind $Kind" }
            $log=$Kind.Substring(4)
            $info=Get-WinEvent -ListLog $log -ErrorAction Stop
            $since=[datetime]::Parse($Context.sinceUtc).ToUniversalTime()
            # Bounded last-24-hour EVTX exports retain all levels for recovery evidence.
            $export=Join-Path $Context.outputDirectory (($log -replace '[^a-zA-Z0-9-]','_')+'.evtx')
            $startUtc=$since.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture)
            $query="/q:*[System[TimeCreated[@SystemTime>='$startUtc']]]"
            $null=Invoke-AssessmentNative 'wevtutil.exe' @('epl',$log,$export,$query,'/ow:true')
            if (-not (Test-Path -LiteralPath $export -PathType Leaf)) { throw 'EVTX export did not create a file.' }
            $events=@()
            try { $events=@(Get-WinEvent -FilterHashtable @{LogName=$log;Level=1,2,3;StartTime=$since} -MaxEvents 501 -ErrorAction Stop) }
            catch { if ($_.FullyQualifiedErrorId -notmatch 'NoMatchingEventsFound') { throw } }
            $latest=@(Get-WinEvent -LogName $log -MaxEvents 1 -ErrorAction SilentlyContinue)
            $logFile=Get-Item -LiteralPath ([Environment]::ExpandEnvironmentVariables($info.LogFilePath)) -Force -ErrorAction Stop
            [pscustomobject]@{logName=$log;exportFile=[IO.Path]::GetFileName($export);truncated=($events.Count -gt 500);logCreatedUtc=$logFile.CreationTimeUtc.ToString('o');lastRecordId=$(if ($latest.Count) {[long]$latest[0].RecordId} else {0});events=@($events | Select-Object -First 500 | ForEach-Object {
                [pscustomobject]@{recordId=[long]$_.RecordId;timeUtc=$_.TimeCreated.ToUniversalTime().ToString('o');provider=$_.ProviderName;id=$_.Id;level=$_.Level;message=$_.Message}
            })}
        }
    }
}

function Invoke-AssessmentProbe {
    param([string]$Kind, $Context, [int]$TimeoutSeconds=20)
    $timer=[Diagnostics.Stopwatch]::StartNew(); $job=$null
    try {
        $job=Start-Job -ScriptBlock {
            param($helper,$kind,$context)
            . $helper
            Get-AssessmentLocalEvidence -Kind $kind -Context $context
        } -ArgumentList (Join-Path $PSScriptRoot 'Migration.Assessment.ps1'),$Kind,$Context
        $null=Wait-Job $job -Timeout $TimeoutSeconds
        if ($job.State -ne 'Completed') { throw "Probe $Kind timed out or failed; not verified." }
        $data=@(Receive-Job $job -ErrorAction Stop)
        if ($Kind -in @('Identity','Services','Replication') -and $data.Count -eq 0) { throw 'No usable evidence returned.' }
        [pscustomobject]@{state='Collected';durationMs=$timer.ElapsedMilliseconds;data=$data;error=''}
    } catch {
        [pscustomobject]@{state='NotVerified';durationMs=$timer.ElapsedMilliseconds;data=@();error=$_.Exception.Message}
    } finally {
        if ($null -ne $job) { Remove-Job $job -Force -ErrorAction SilentlyContinue }
        $timer.Stop()
    }
}

function Get-AssessmentEventSignature {
    param($Event)
    # Exact message included; same provider/ID alone does not prove same cause.
    $text='{0}|{1}|{2}|{3}' -f $Event.provider,$Event.id,$Event.level,($Event.message -replace '\s+',' ').Trim()
    $hash=[Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','') }
    finally { $hash.Dispose() }
}

function Compare-MigrationAssessment {
    param($Before, $After)
    $rows=New-Object System.Collections.ArrayList
    function Add-AssessmentDifference { param($Check,$Classification,$Detail) [void]$rows.Add([pscustomobject]@{check=$Check;classification=$Classification;detail=$Detail}) }
    $compatible=$null -ne $Before -and $Before.schemaVersion -eq '1.0' -and $Before.stage -eq 'Before' -and $Before.computerName -ieq $After.computerName -and
        (ConvertTo-AssessmentUtc $Before.capturedAtUtc) -lt (ConvertTo-AssessmentUtc $After.capturedAtUtc)
    if (-not $compatible) { Add-AssessmentDifference 'Baseline' 'NotVerified' 'No compatible before snapshot for this computer. Current observations are not proof of migration success.' }
    foreach ($kind in @($After.probes.Keys)) {
        $current=$After.probes[$kind]
        $previous=$null
        if ($compatible -and $Before.probes.Contains($kind)) { $previous=$Before.probes[$kind] }
        if ($current.state -ne 'Collected') { Add-AssessmentDifference $kind 'NotVerified' $current.error; continue }
        if ($kind -in @('Identity','Services','Replication') -and @($current.data).Count -eq 0) { Add-AssessmentDifference $kind 'NotVerified' 'Collector returned no usable rows.'; continue }
        if ($null -eq $previous -or $previous.state -ne 'Collected') {
            Add-AssessmentDifference $kind 'NotVerified' 'Comparable before evidence is unavailable; review the current snapshot.'
            continue
        }
        if ($kind -eq 'Services') {
            foreach ($service in @($previous.data)) {
                if ($service.name -in @('VMTools','VGAuthService','VMVss','VM3DService')) { continue }
                $now=@($current.data | Where-Object name -eq $service.name)
                if ($now.Count -ne 1) { Add-AssessmentDifference $service.name 'NewDeviation' 'Previously captured service is missing or ambiguous.'; continue }
                $wasRunning=$service.state -eq 'Running'; $isRunning=$now[0].state -eq 'Running'
                if ($wasRunning -and -not $isRunning) { Add-AssessmentDifference $service.name 'NewDeviation' "Was Running; now $($now[0].state)." }
                elseif (-not $wasRunning -and -not $isRunning) { Add-AssessmentDifference $service.name 'ExistingDeviation' "Not running before or after ($($service.state) -> $($now[0].state))." }
                elseif (-not $wasRunning -and $isRunning) { Add-AssessmentDifference $service.name 'Recovered' 'Now Running.' }
            }
        } elseif ($kind -eq 'Shares') {
            foreach ($name in @('SYSVOL','NETLOGON')) {
                $had=@($previous.data | Where-Object { $_.name -eq $name -and $_.accessible }).Count -gt 0
                $has=@($current.data | Where-Object { $_.name -eq $name -and $_.accessible }).Count -gt 0
                if (-not $has) { Add-AssessmentDifference $name $(if ($had) {'NewDeviation'} else {'ExistingDeviation'}) 'Local DC share missing.' }
                elseif (-not $had) { Add-AssessmentDifference $name 'Recovered' 'Local DC share now present.' }
            }
        } elseif ($kind -eq 'Replication') {
            foreach ($old in @($previous.data)) {
                $now=@($current.data | Where-Object key -eq $old.key)
                if ($now.Count -ne 1) { Add-AssessmentDifference $old.key 'NotVerified' 'Captured replication partner/partition is missing or ambiguous.'; continue }
                $new=$now[0]
                if ($new.errorCode -ne 0 -or $new.failures -gt 0) {
                    $same=$old.errorCode -eq $new.errorCode -and $old.failures -gt 0
                    # Repeated old errors remain visible; increased failures are new evidence.
                    $category=if ($same -and $new.failures -le $old.failures) {'ExistingDeviation'} else {'NewDeviation'}
                    Add-AssessmentDifference $old.key $category "Error=$($new.errorCode); failures=$($new.failures); last success=$($new.lastSuccess); last failure=$($new.lastFailure)."
                } elseif ($new.lastSuccess -eq $old.lastSuccess) {
                    Add-AssessmentDifference $old.key 'NotVerified' 'No new successful replication attempt is recorded since the before snapshot.'
                } elseif ($old.errorCode -ne 0 -or $old.failures -gt 0) {
                    Add-AssessmentDifference $old.key 'Recovered' "Replication now succeeds; last success=$($new.lastSuccess)."
                }
            }
            foreach ($new in @($current.data)) {
                if (@($previous.data | Where-Object key -eq $new.key).Count -eq 0) { Add-AssessmentDifference $new.key 'NotVerified' 'New replication partner/partition; no before comparison.' }
            }
        } elseif ($kind -like 'Log:*') {
            $old=$previous.data[0]; $new=$current.data[0]
            if ($old.truncated -or $new.truncated) { Add-AssessmentDifference $kind 'NotVerified' 'Event summary capped at 500 entries. Review EVTX exports.' }
            $continuous=$old.logCreatedUtc -and $new.logCreatedUtc -and (ConvertTo-AssessmentUtc $old.logCreatedUtc) -eq (ConvertTo-AssessmentUtc $new.logCreatedUtc) -and $new.lastRecordId -ge $old.lastRecordId
            if (-not $continuous) { Add-AssessmentDifference $kind 'NotVerified' 'Log creation/record sequence changed; old record IDs are not trusted.' }
            $prior=@{}; $priorRecords=@{}
            foreach ($event in @($old.events)) {
                $signature=Get-AssessmentEventSignature $event
                $prior[$signature]=$true
                $priorRecords[[string]$event.recordId]=[pscustomobject]@{signature=$signature;timeUtc=(ConvertTo-AssessmentUtc $event.timeUtc)}
            }
            foreach ($event in @($new.events)) {
                $sig=Get-AssessmentEventSignature $event
                $record=$priorRecords[[string]$event.recordId]
                $copied=$continuous -and $null -ne $record -and $record.signature -eq $sig -and
                    $record.timeUtc -eq (ConvertTo-AssessmentUtc $event.timeUtc) -and
                    (ConvertTo-AssessmentUtc $event.timeUtc) -le (ConvertTo-AssessmentUtc $Before.capturedAtUtc)
                $category=if ($copied) {'ExistingDeviation'} elseif ($prior.ContainsKey($sig)) {'RecurringEvent'} else {'NewEvent'}
                Add-AssessmentDifference $kind $category "$($event.timeUtc) [$($event.provider)/$($event.id)] $($event.message)"
            }
        }
    }
    if ($rows.Count -eq 0) { Add-AssessmentDifference 'Comparison' 'NoDeviation' 'No difference found in the comparable evidence. Event and replication evidence do not replace application acceptance tests.' }
    return @($rows)
}

function Get-MigrationBeforeObservations {
    param($Snapshot)
    foreach ($kind in $Snapshot.probes.Keys) {
        $probe=$Snapshot.probes[$kind]
        if ($probe.state -ne 'Collected') {
            [pscustomobject]@{check=$kind;classification='NotVerified';detail=$probe.error}
            continue
        }
        if ($kind -eq 'Services') {
            foreach ($service in @($probe.data | Where-Object { $_.state -ne 'Running' -and $_.name -notin @('VMTools','VGAuthService','VMVss','VM3DService') })) {
                [pscustomobject]@{check=$service.name;classification='ExistingDeviation';detail="Before: state=$($service.state), start=$($service.startMode)."}
            }
        } elseif ($kind -eq 'Shares') {
            foreach ($name in @('SYSVOL','NETLOGON')) {
                if (@($probe.data | Where-Object { $_.name -eq $name -and $_.accessible }).Count -eq 0) { [pscustomobject]@{check=$name;classification='ExistingDeviation';detail='DC share absent before migration.'} }
            }
        } elseif ($kind -eq 'Replication') {
            foreach ($partner in @($probe.data | Where-Object { $_.errorCode -ne 0 -or $_.failures -gt 0 })) {
                [pscustomobject]@{check=$partner.key;classification='ExistingDeviation';detail="Before: error=$($partner.errorCode); failures=$($partner.failures); last success=$($partner.lastSuccess)."}
            }
        } elseif ($kind -like 'Log:*') {
            if ($probe.data[0].truncated) { [pscustomobject]@{check=$kind;classification='NotVerified';detail='Event summary capped at 500 entries; review EVTX.'} }
            foreach ($event in @($probe.data[0].events)) {
                [pscustomobject]@{check=$kind;classification='ExistingDeviation';detail="$($event.timeUtc) [$($event.provider)/$($event.id)] $($event.message)"}
            }
        }
    }
}

function Read-MigrationAssessmentSnapshot {
    param([string]$Path)
    $snapshot=Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $map=[ordered]@{}
    foreach ($property in $snapshot.probes.PSObject.Properties) { $map[$property.Name]=$property.Value }
    $snapshot.probes=$map
    $snapshot
}

function Write-MigrationAssessmentReport {
    param($Snapshot, [object[]]$Comparison, [string]$OutputDirectory)
    $snapshotPath=Join-Path $OutputDirectory 'Snapshot.json'
    $Snapshot | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $snapshotPath -Encoding UTF8
    ConvertTo-Json -InputObject @($Comparison) -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'Comparison.json') -Encoding UTF8
    $unverified=@($Comparison | Where-Object classification -eq 'NotVerified').Count -gt 0 -or @($Snapshot.probes.Values | Where-Object state -ne 'Collected').Count -gt 0
    $review=@($Comparison | Where-Object classification -in @('NewDeviation','NewEvent','RecurringEvent')).Count -gt 0
    $deep=Get-MigrationProperty $Snapshot 'deepDiagnostics' $null
    if ($deep) {
        if ($deep.state -eq 'NotVerified') { $unverified=$true }
        if ($deep.state -eq 'ReviewRequired') { $review=$true }
    }
    $status=if ($unverified) {'NotVerified'} elseif ($review) {'ReviewRequired'} elseif (@($Comparison | Where-Object classification -eq 'ExistingDeviation').Count) {'ExistingDeviationsDocumented'} else {'NoObservedDeviation'}
    [ordered]@{operationalStatus=$status;stage=$Snapshot.stage;checkLevel=$Snapshot.checkLevel;computerName=$Snapshot.computerName;capturedAtUtc=$Snapshot.capturedAtUtc;baselineCompared=($Snapshot.stage -eq 'After' -and -not @($Comparison | Where-Object { $_.check -eq 'Baseline' -and $_.classification -eq 'NotVerified' }).Count);note='Migration action results are in PostMigrationReport. This evidence is not full application acceptance.'} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'AssessmentSummary.json') -Encoding UTF8
    $labels=@{ExistingDeviation='Befintlig avvikelse';NewDeviation='Ny avvikelse';Recovered='Återhämtad';NotVerified='Ej verifierat';NewEvent='Ny logghändelse - utred';RecurringEvent='Återkommande logghändelse - utred';NoDeviation='Ingen avvikelse'}
    $lines=@('Migreringskontroll / driftunderlag',"Server: $($Snapshot.computerName)","UTC: $($Snapshot.capturedAtUtc)","Kontrollnivå: $($Snapshot.checkLevel)","Driftunderlag: $status",'Migreringsåtgärdernas resultat finns separat i PostMigrationReport.','Logghändelser är observationer, inte automatiskt bevis på felorsak eller återhämtning.','')
    foreach ($group in @($Comparison | Group-Object classification)) { $lines+="$($labels[$group.Name]): $($group.Count)" }
    $lines+=''
    foreach ($key in $Snapshot.probes.Keys) { $lines+="$key : $($Snapshot.probes[$key].state), $($Snapshot.probes[$key].durationMs) ms; $($Snapshot.probes[$key].error)" }
    if ($deep) { $lines+="Deep diagnostics: $($deep.state), $($deep.durationMs) ms; $($deep.detail)" }
    foreach ($row in $Comparison) { $lines+="[$($labels[$row.classification])] $($row.check): $($row.detail)" }
    $lines | Set-Content -LiteralPath (Join-Path $OutputDirectory 'Report.txt') -Encoding UTF8
    $encoded=[Net.WebUtility]::HtmlEncode(($lines -join "`r`n"))
    "<!doctype html><html><head><meta charset='utf-8'><title>Migreringskontroll</title></head><body><h1>Migreringskontroll / driftunderlag</h1><pre>$encoded</pre></body></html>" | Set-Content -LiteralPath (Join-Path $OutputDirectory 'Report.html') -Encoding UTF8
}

function Get-MigrationAssessmentSelection {
    param([string]$SearchRoot='C:\')
    $candidates=@(Get-ChildItem -LiteralPath $SearchRoot -Directory -Filter 'Rutin_migration_*' -ErrorAction Stop | ForEach-Object {
        $file=Join-Path $_.FullName 'MigrationAssessmentSelection.json'
        if (Test-Path -LiteralPath $file) {
            $data=Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($data.computerName -ieq $env:COMPUTERNAME) { $data }
        }
    } | Sort-Object capturedAtUtc -Descending)
    if ($candidates.Count) { $candidates[0] }
}

function Get-MigrationCapturedAssessmentLevel {
    param([string]$StateDirectory)
    $path=Join-Path $StateDirectory 'MigrationAssessment\Selection.json'
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Warning 'Legacy capture: no assessment level/before evidence. Using Migration; missing evidence will be reported as not verified.'
        return 'Migration'
    }
    $selection=Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($selection.computerName -ine $env:COMPUTERNAME -or $selection.checkLevel -notin @('Migration','Deep')) { throw 'Invalid captured assessment identity/level.' }
    $capture=Join-Path $StateDirectory 'PreMigrationState.json'
    $beforeFile=Join-Path $StateDirectory 'MigrationAssessment\Before\Snapshot.json'
    if ($selection.captureSha256 -ne (Get-FileHash -LiteralPath $capture -Algorithm SHA256).Hash -or
        $selection.beforeSha256 -ne (Get-FileHash -LiteralPath $beforeFile -Algorithm SHA256).Hash) { throw 'Assessment does not match the selected capture/before evidence.' }
    $before=Read-MigrationAssessmentSnapshot $beforeFile
    if ($before.computerName -ine $selection.computerName -or $before.checkLevel -ne $selection.checkLevel -or $before.stage -ne 'Before' -or $before.schemaVersion -ne '1.0') { throw 'Invalid before evidence identity/level/schema.' }
    return [string]$selection.checkLevel
}
