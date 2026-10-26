#Requires -Version 5.1
# Portable comparison, timeout, profile-binding and orchestration regressions.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'Migration.Common.ps1')
. (Join-Path $root 'Migration.Assessment.ps1')
$temp=Join-Path ([IO.Path]::GetTempPath()) ('assessment-tests-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $temp
$passed=0
function Assert { param($Condition,$Message) if (-not $Condition) { throw $Message } }
function Case { param($Name,[scriptblock]$Run) & $Run; $script:passed++; Write-Host "PASS: $Name" }
function Probe { param([object[]]$Data) [pscustomobject]@{state='Collected';data=@($Data);error='';durationMs=1} }
function Snapshot {
    param([string]$Stage='Before')
    [pscustomobject]@{schemaVersion='1.0';computerName='DC05';stage=$Stage;checkLevel='Migration';capturedAtUtc=$(if ($Stage -eq 'Before') {'2026-10-26T08:00:00Z'} else {'2026-10-26T09:00:00Z'});probes=[ordered]@{}}
}
function Replication {
    param([int]$ErrorCode=0,[int]$Failures=0,[string]$Success='old')
    [pscustomobject]@{key='DC04|Schema';partner='DC04';partition='Schema';errorCode=$ErrorCode;failures=$Failures;lastSuccess=$Success;lastFailure='2026-10-26 08:30'}
}
function EventRow {
    param([int]$RecordId=1,[string]$Time='2026-10-26T07:00:00Z',[string]$Message='old failure')
    [pscustomobject]@{recordId=$RecordId;timeUtc=$Time;provider='DFSR';id=1202;level=2;message=$Message}
}
function LogData {
    param([object[]]$Events=@(),[int]$LastId=1,[string]$Created='2026-01-01T00:00:00Z',[bool]$Truncated=$false)
    [pscustomobject]@{events=@($Events);lastRecordId=$LastId;logCreatedUtc=$Created;truncated=$Truncated}
}
function Get-MenuPhaseFixture {
    param($Phase)
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Migrate-VmwareToProxmox.ps1'),[ref]$tokens,[ref]$errors)
    $switch=$ast.Find({param($n) $n -is [Management.Automation.Language.SwitchStatementAst] -and $n.Condition.Extent.Text -eq '$Phase'},$true)
    $body=@($switch.Clauses | Where-Object { $_.Item1.Value -eq $Phase })[0].Item2.Extent.Text
    [scriptblock]::Create('[CmdletBinding(SupportsShouldProcess=$true)]'+$ast.ParamBlock.Extent.Text+$body.Substring(1,$body.Length-2))
}
function Import-MenuFunction {
    param($Name)
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Migrate-VmwareToProxmox.ps1'),[ref]$tokens,[ref]$errors)
    $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true)
    Set-Item "function:script:$Name" ([scriptblock]::Create($fn.Body.Extent.Text.Substring(1,$fn.Body.Extent.Text.Length-2)))
}

function Invoke-AssessmentMainFixture {
    param([string]$Stage='Before',[string]$Level='Migration',[string]$Baseline='', [switch]$DeepFailure,[switch]$DeepTimeout)
    $out=Join-Path $temp ('main-'+[guid]::NewGuid().ToString('N'))
    $script:lastAssessmentOutput=$out
    function Invoke-AssessmentProbe {
        param($Kind,$Context,$TimeoutSeconds)
        switch ($Kind) {
            Identity { Probe @([pscustomobject]@{computerName=$env:COMPUTERNAME;isDC=$true;domain='test.example';bootUtc='2026-10-26T07:00:00Z'}) }
            Services { Probe @([pscustomobject]@{name='NTDS';state='Running';startMode='Auto'}) }
            Shares { Probe @([pscustomobject]@{name='SYSVOL';path='test';accessible=$true},[pscustomobject]@{name='NETLOGON';path='test';accessible=$true}) }
            Replication { Probe @(Replication 0 0 $Stage) }
            ReplicationRaw { Probe @('Local replication output') }
            default { Probe @(LogData @() 1) }
        }
    }
    function Invoke-AssessmentNative {
        $script:deepCalls++
        if ($DeepTimeout) { throw 'Deep diagnostic timeout' }
        if ($DeepFailure) { $e=New-Object System.InvalidOperationException('DC operational failure'); $e.Data['DiagnosticExitCode']=2; throw $e }
        'Deep output'
    }
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Test-MigrationAssessment.ps1'),[ref]$tokens,[ref]$errors)
    $body=@($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[0].Extent.Text
    # Keep the real main flow, replacing process exits with fixture returns only.
    $body=($body -replace 'exit ([012])','return $1').Replace('$PSScriptRoot','$root')
    $fixture=[scriptblock]::Create($ast.ParamBlock.Extent.Text+$body)
    & $fixture -Stage $Stage -OutputDirectory $out -CheckLevel $Level -BaselinePath $Baseline
}

try {
    Case 'All PowerShell files parse' {
        foreach ($file in Get-ChildItem $root -Filter '*.ps1') {
            $tokens=$null; $errors=$null
            $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
            Assert ($errors.Count -eq 0) "$($file.Name): $errors"
        }
    }
    Case 'Missing and wrong-computer baselines never imply success' {
        $after=Snapshot After; $after.probes.Services=Probe @([pscustomobject]@{name='NTDS';state='Running'})
        $rows=@(Compare-MigrationAssessment $null $after)
        Assert (@($rows | Where-Object classification -eq 'NotVerified').Count -gt 0) 'Missing baseline passed'
        $before=Snapshot; $before.computerName='OtherDC'
        $rows=@(Compare-MigrationAssessment $before $after)
        Assert ($rows[0].classification -eq 'NotVerified') 'Wrong identity passed'
    }
    Case 'Future and after-stage baselines are rejected' {
        $before=Snapshot After; $after=Snapshot After
        Assert ((Compare-MigrationAssessment $before $after)[0].classification -eq 'NotVerified') 'After snapshot accepted as baseline'
        $before=Snapshot; $before.capturedAtUtc='2027-01-01T00:00:00Z'
        Assert ((Compare-MigrationAssessment $before $after)[0].classification -eq 'NotVerified') 'Future baseline passed'
    }
    Case 'Existing stopped services differ from new regression and recovery' {
        $before=Snapshot; $after=Snapshot After
        $before.probes.Services=Probe @([pscustomobject]@{name='NTDS';state='Running'},[pscustomobject]@{name='DNS';state='Stopped'},[pscustomobject]@{name='DFSR';state='Stopped'},[pscustomobject]@{name='VMTools';state='Running'})
        $after.probes.Services=Probe @([pscustomobject]@{name='NTDS';state='Stopped'},[pscustomobject]@{name='DNS';state='Stopped'},[pscustomobject]@{name='DFSR';state='Running'})
        $rows=@(Compare-MigrationAssessment $before $after)
        Assert (($rows | Where-Object check -eq 'NTDS').classification -eq 'NewDeviation') 'New stopped core service hidden'
        Assert (($rows | Where-Object check -eq 'DNS').classification -eq 'ExistingDeviation') 'Existing problem became migration failure'
        Assert (($rows | Where-Object check -eq 'DFSR').classification -eq 'Recovered') 'Recovery missing'
        Assert (@($rows | Where-Object check -eq 'VMTools').Count -eq 0) 'Expected Tools removal flagged'
    }
    Case 'SYSVOL disappearance is new while a pre-existing absent share remains documented' {
        $before=Snapshot; $after=Snapshot After
        $before.probes.Shares=Probe @([pscustomobject]@{name='SYSVOL';accessible=$true})
        $after.probes.Shares=Probe @()
        $rows=@(Compare-MigrationAssessment $before $after)
        Assert (($rows | Where-Object check -eq 'SYSVOL').classification -eq 'NewDeviation') 'Lost SYSVOL passed'
        Assert (($rows | Where-Object check -eq 'NETLOGON').classification -eq 'ExistingDeviation') 'Old missing share not retained'
    }
    Case 'Replication preserves old errors and distinguishes new failures recovery and no new attempt' {
        foreach ($variant in @('Existing','New','Recovered','NoAttempt')) {
            $before=Snapshot; $after=Snapshot After
            $before.probes.Replication=Probe @(Replication 1908 6)
            switch ($variant) {
                Existing { $data=Replication 1908 6; $expected='ExistingDeviation' }
                New { $data=Replication 1908 7; $expected='NewDeviation' }
                Recovered { $data=Replication 0 0 'new'; $expected='Recovered' }
                NoAttempt { $before.probes.Replication=Probe @(Replication); $data=Replication; $expected='NotVerified' }
            }
            $after.probes.Replication=Probe @($data)
            Assert ((Compare-MigrationAssessment $before $after)[0].classification -eq $expected) "Bad replication comparison $variant"
        }
    }
    Case 'Missing replication partition does not count as recovery' {
        $before=Snapshot; $after=Snapshot After
        $before.probes.Replication=Probe @(Replication 1908 6); $after.probes.Replication=Probe @()
        Assert ((Compare-MigrationAssessment $before $after)[0].classification -eq 'NotVerified') 'Empty replication passed'
    }
    Case 'Copied events differ from recurring events and newly observed messages' {
        $before=Snapshot; $after=Snapshot After
        $before.probes['Log:System']=Probe @(LogData @(EventRow))
        $after.probes['Log:System']=Probe @(LogData @((EventRow),(EventRow 2 '2026-10-26T08:30:00Z'),(EventRow 3 '2026-10-26T08:31:00Z' 'different cause')) 3)
        $rows=@(Compare-MigrationAssessment $before $after)
        Assert (($rows.classification -join ',') -eq 'ExistingDeviation,RecurringEvent,NewEvent') 'Event identity/recurrence misclassified'
    }
    Case 'Cleared logs and truncated windows are explicitly unverified' {
        $before=Snapshot; $after=Snapshot After
        $before.probes['Log:System']=Probe @(LogData @(EventRow) 200)
        $after.probes['Log:System']=Probe @(LogData @(EventRow) 1 '2026-10-26T08:15:00Z' $true)
        $rows=@(Compare-MigrationAssessment $before $after)
        Assert (@($rows | Where-Object classification -eq 'NotVerified').Count -eq 2) 'Log reset or cap passed'
        Assert (@($rows | Where-Object classification -eq 'ExistingDeviation').Count -eq 0) 'Reused record ID counted as copied'
    }
    Case 'Probe failures and timeouts are unverified' {
        $before=Snapshot; $after=Snapshot After
        $before.probes.Services=Probe @([pscustomobject]@{name='NTDS';state='Running'})
        $after.probes.Services=[pscustomobject]@{state='NotVerified';data=@();error='timeout'}
        Assert ((Compare-MigrationAssessment $before $after)[0].classification -eq 'NotVerified') 'Timeout passed'
        $script:removed=$false
        function Start-Job { [pscustomobject]@{State='Running'} }
        function Wait-Job { }
        function Remove-Job { $script:removed=$true }
        $probe=Invoke-AssessmentProbe 'Identity' ([pscustomobject]@{}) 1
        Assert ($probe.state -eq 'NotVerified' -and $script:removed) 'Timeout failed to clean up or returned success'
    }
    Case 'Before report retains operational problems without failing the migration' {
        $before=Snapshot
        $before.probes.Services=Probe @([pscustomobject]@{name='NTDS';state='Stopped';startMode='Auto'})
        Assert ((Get-MigrationBeforeObservations $before).classification -eq 'ExistingDeviation') 'Before failure not documented'
    }
    Case 'Snapshot JSON round trip and HTML escaping retain usable evidence' {
        $before=Snapshot; $before.probes.Services=Probe @([pscustomobject]@{name='NTDS';state='Running'})
        $rows=@([pscustomobject]@{check='<service>';classification='NewDeviation';detail='<script>alert(1)</script>'})
        Write-MigrationAssessmentReport $before $rows $temp
        $read=Read-MigrationAssessmentSnapshot (Join-Path $temp 'Snapshot.json')
        Assert ($read.probes.Contains('Services') -and $read.probes.Services.data[0].name -eq 'NTDS') 'JSON map round trip failed'
        $html=Get-Content (Join-Path $temp 'Report.html') -Raw
        Assert ($html -notmatch '<script>' -and $html -match '&lt;script&gt;') 'Report permits log HTML injection'
    }
    Case 'repadmin CSV parser captures only local partner partition rows' {
        function Invoke-AssessmentNative {
            param($FilePath,$Arguments)
            Assert (($Arguments -join ' ') -eq '/showrepl localhost /csv') 'Domain-wide replication query'
            'showrepl_COLUMNS,Destination DSA,Source DSA,Naming Context,Number of Failures,Last Failure Time,Last Success Time,Last Failure Status',
            'showrepl_INFO,DC05,DC04,Schema,6,10/26/2026 08:30,10/26/2026 07:00,1908'
        }
        $data=@(Get-AssessmentLocalEvidence Replication $null)
        Assert ($data.Count -eq 1 -and $data[0].errorCode -eq 1908 -and $data[0].key -eq 'DC04|Schema') 'Replication CSV lost result'
    }
    Case 'No partners or localized unknown CSV is not automatically healthy' {
        function Invoke-AssessmentNative { 'localized unknown response' }
        $caught=$false; try { Get-AssessmentLocalEvidence Replication $null } catch { $caught=$true }
        Assert $caught 'Unknown CSV passed'
    }
    Case 'Legacy profile defaults to Migration with missing before evidence' {
        Assert ((Get-MigrationCapturedAssessmentLevel $temp) -eq 'Migration') 'Legacy profile failed'
    }
    Case 'Captured level is bound to the exact machine export and before snapshot' {
        $state=Join-Path $temp 'State'; $dest=Join-Path $state 'MigrationAssessment'; $pre=Join-Path $dest 'Before'
        $null=New-Item -ItemType Directory -Path $pre -Force
        '{}' | Set-Content (Join-Path $state 'PreMigrationState.json')
        $snapshot=Snapshot; $snapshot.computerName=$env:COMPUTERNAME; $snapshot.checkLevel='Deep'
        $snapshot | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $pre 'Snapshot.json')
        $selection=@{computerName=$env:COMPUTERNAME;checkLevel='Deep';captureSha256=(Get-FileHash (Join-Path $state 'PreMigrationState.json')).Hash;beforeSha256=(Get-FileHash (Join-Path $pre 'Snapshot.json')).Hash}
        $selection | ConvertTo-Json | Set-Content (Join-Path $dest 'Selection.json')
        Assert ((Get-MigrationCapturedAssessmentLevel $state) -eq 'Deep') 'Saved profile not restored'
        'changed' | Set-Content (Join-Path $state 'PreMigrationState.json')
        $caught=$false; try { Get-MigrationCapturedAssessmentLevel $state } catch { $caught=$true }
        Assert $caught 'Mismatched capture accepted'
    }
    Case 'Default orchestration skips deep and domain-wide tests; deep scope stays explicit' {
        $menu=Get-Content (Join-Path $root 'Migrate-VmwareToProxmox.ps1') -Raw
        Assert ($menu -notmatch "Invoke-CheckedMigrationScript 'Test-DCMigrationHealth.ps1'") 'Menu still directly scans entire domain'
        Assert ($menu -match "CheckLevel = 'Migration'" -and $menu -match 'Get-MigrationCapturedAssessmentLevel') 'Default/profile reuse missing'
        $assessment=Get-Content (Join-Path $root 'Test-MigrationAssessment.ps1') -Raw
        Assert ($assessment -match "CheckLevel -eq 'Deep' -and" -and $assessment -match 'ComputerName=@\(\$env:COMPUTERNAME\)') 'Deep diagnostics are not local/optional'
    }
    Case 'Readiness phase defaults to local migration evidence and no domain-wide child' {
        $script:calls=@(); $script:beforeCount=0
        function Invoke-CheckedMigrationScript { param($Name,$Arguments) $script:calls+=@([pscustomobject]@{name=$Name;arguments=$Arguments}) }
        function New-SourceMigrationAssessment { $script:beforeCount++ }
        $role='DomainController'
        & (Get-MenuPhaseFixture ReadinessCheck)
        Assert ($script:calls.Count -eq 1 -and $script:calls[0].name -eq 'Test-MigrationReadiness.ps1' -and $script:calls[0].arguments.CheckLevel -eq 'Migration' -and $script:beforeCount -eq 1) 'Default phase still invokes deep/domain checks'
    }
    Case 'Post phase uses stored Deep level and forwards WhatIf without collecting evidence' {
        $script:called=$null; $script:LevelExplicit=$false
        function Resolve-MigrationStateDirectory { 'state' }
        function Get-MigrationCapturedAssessmentLevel { 'Deep' }
        function Assert-MigrationFirstbootComplete { [pscustomobject]@{state='Complete'} }
        function Invoke-CheckedMigrationScript { param($Name,$Arguments) $script:called=[pscustomobject]@{name=$Name;arguments=$Arguments} }
        & (Get-MenuPhaseFixture ValidatePost) -WhatIf
        Assert ($script:called.name -eq 'Restore-And-TestMigrationState.ps1' -and $script:called.arguments.CheckLevel -eq 'Deep' -and $script:called.arguments.WhatIf) 'Stored level or preview was lost'
    }
    Case 'Explicit conflicting post level stops before the restoration child' {
        $script:called=$false; $script:LevelExplicit=$true
        function Resolve-MigrationStateDirectory { 'state' }
        function Get-MigrationCapturedAssessmentLevel { 'Deep' }
        function Invoke-CheckedMigrationScript { $script:called=$true }
        $caught=$false; try { & (Get-MenuPhaseFixture ValidatePost) -CheckLevel Migration -WhatIf } catch { $caught=$true }
        Assert ($caught -and -not $script:called) 'Conflicting level bypassed the manifest'
    }
    Case 'Prepare reuses a recent before selection without rerunning deep checks' {
        Import-MenuFunction New-SourceMigrationAssessment
        $script:LevelExplicit=$false; $CheckLevel='Migration'
        $before=Snapshot; $before.computerName=$env:COMPUTERNAME; $before.checkLevel='Deep'
        $before | ConvertTo-Json -Depth 15 | Set-Content (Join-Path $temp 'Snapshot.json')
        $selectionFixture=[pscustomobject]@{computerName=$env:COMPUTERNAME;checkLevel='Deep';capturedAtUtc=[datetime]::UtcNow.ToString('o');outputDirectory=$temp}
        function Get-MigrationAssessmentSelection { $selectionFixture }
        function Invoke-CheckedMigrationScript { throw 'Unexpected diagnostic rerun' }
        $selection=New-SourceMigrationAssessment -ReuseRecent
        Assert ($selection.checkLevel -eq 'Deep') 'Prepare discarded the saved level'
    }
    Case 'Prepare copies all before evidence and binds both hashes to the new export' {
        Import-MenuFunction Save-SourceMigrationAssessment
        $source=Join-Path $temp 'source'; $stateFixture=Join-Path $temp 'capture'
        $null=New-Item -ItemType Directory -Path $source,$stateFixture
        $snapshot=Snapshot; $snapshot.computerName=$env:COMPUTERNAME
        $snapshot | ConvertTo-Json -Depth 15 | Set-Content (Join-Path $source 'Snapshot.json')
        'test export' | Set-Content (Join-Path $source 'System.evtx')
        '{}' | Set-Content (Join-Path $stateFixture 'PreMigrationState.json')
        function Resolve-MigrationStateDirectory { $stateFixture }
        Save-SourceMigrationAssessment ([pscustomobject]@{computerName=$env:COMPUTERNAME;checkLevel='Migration';capturedAtUtc=[datetime]::UtcNow.ToString('o');outputDirectory=$source})
        Assert (Test-Path (Join-Path $stateFixture 'MigrationAssessment/Before/System.evtx')) 'EVTX was not carried with State'
        Assert ((Get-MigrationCapturedAssessmentLevel $stateFixture) -eq 'Migration') 'Bound saved manifest could not be read'
        'tampered' | Set-Content (Join-Path $stateFixture 'MigrationAssessment/Before/Snapshot.json')
        $caught=$false; try { Get-MigrationCapturedAssessmentLevel $stateFixture } catch { $caught=$true }
        Assert $caught 'Changed before evidence accepted'
    }
    Case 'Real background probe failure returns unverified and releases its job' {
        $jobsBefore=@(Get-Job).Count
        $probe=Invoke-AssessmentProbe 'UnknownProbe' ([pscustomobject]@{}) 5
        Assert ($probe.state -eq 'NotVerified' -and @(Get-Job).Count -eq $jobsBefore) 'Failed real job passed or leaked'
    }
    Case 'Real collector main creates before and after reports without invoking Deep in Migration mode' {
        $script:deepCalls=0
        $beforeCode=Invoke-AssessmentMainFixture
        $baseline=Join-Path $script:lastAssessmentOutput 'Snapshot.json'
        $afterCode=Invoke-AssessmentMainFixture -Stage After -Baseline $baseline
        Assert ($beforeCode -eq 0 -and $afterCode -eq 0 -and $script:deepCalls -eq 0) 'Quick main invoked Deep or failed comparison'
        $summary=Get-Content (Join-Path $script:lastAssessmentOutput 'AssessmentSummary.json') -Raw | ConvertFrom-Json
        Assert ($summary.baselineCompared -and $summary.operationalStatus -eq 'NoObservedDeviation') 'Quick summary not bound to before'
    }
    Case 'Real collector main completes legacy post capture with unverified warning' {
        $code=Invoke-AssessmentMainFixture -Stage After
        $summary=Get-Content (Join-Path $script:lastAssessmentOutput 'AssessmentSummary.json') -Raw | ConvertFrom-Json
        Assert ($code -eq 1 -and $summary.operationalStatus -eq 'NotVerified' -and -not $summary.baselineCompared) 'Legacy post silently passed'
    }
    Case 'Real collector main keeps unhealthy Deep diagnostics separate and nonblocking' {
        $script:deepCalls=0
        $code=Invoke-AssessmentMainFixture -Level Deep -DeepFailure
        $summary=Get-Content (Join-Path $script:lastAssessmentOutput 'AssessmentSummary.json') -Raw | ConvertFrom-Json
        Assert ($code -eq 1 -and $script:deepCalls -eq 1 -and $summary.operationalStatus -eq 'ReviewRequired') 'Existing Deep issue blocked migration or was hidden'
    }
    Case 'Same event record ID with changed text is not proof of a copied pre-existing error' {
        $before=Snapshot; $after=Snapshot After
        $before.probes['Log:System']=Probe @(LogData @(EventRow))
        $after.probes['Log:System']=Probe @(LogData @(EventRow 1 '2026-10-26T07:00:00Z' 'different payload'))
        Assert ((Compare-MigrationAssessment $before $after)[0].classification -eq 'NewEvent') 'Record ID alone concealed a new message'
    }
    Case 'Deep timeout remains unverified even when the quick observations look healthy' {
        $script:deepCalls=0
        $code=Invoke-AssessmentMainFixture -Level Deep -DeepTimeout
        $summary=Get-Content (Join-Path $script:lastAssessmentOutput 'AssessmentSummary.json') -Raw | ConvertFrom-Json
        Assert ($code -eq 1 -and $summary.operationalStatus -eq 'NotVerified') 'Deep timeout was treated as healthy or merely an existing failure'
    }
    Write-Host "Assessment tests passed: $passed"
} finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
