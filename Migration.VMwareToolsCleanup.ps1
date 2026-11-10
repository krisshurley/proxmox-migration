#Requires -Version 5.1
# Pure helpers for the experimental, restart-aware VMware Tools cleanup workflow.
function Get-VMwareCleanupIdentity {
    param([string]$StateDirectory)
    $capture=Join-Path $StateDirectory 'PreMigrationState.json'
    $data=Get-Content -LiteralPath $capture -Raw -ErrorAction Stop|ConvertFrom-Json
    if($data.systemIdentity.computerName -ine $env:COMPUTERNAME){throw 'Cleanup capture computer identity mismatch.'}
    $machine=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -ErrorAction Stop).MachineGuid
    [pscustomobject]@{computerName=$env:COMPUTERNAME;machineGuid=[string]$machine;captureSha256=(Get-FileHash $capture -Algorithm SHA256).Hash}
}
function Assert-VMwareCleanupIdentity {
    param($Saved,$Current)
    if($Saved.computerName -ine $Current.computerName -or $Saved.machineGuid -ine $Current.machineGuid -or
       $Saved.captureSha256 -ine $Current.captureSha256){throw 'Saved cleanup state belongs to another VM or capture. No cleanup was performed.'}
}
function Convert-VMwareCleanupBootId {
    param($Value)
    if($Value -is [datetime]){return $Value.ToUniversalTime().ToString('o')}
    if($Value -is [datetimeoffset]){return $Value.UtcDateTime.ToString('o')}
    return [string]$Value
}
function Get-VMwareCleanupPlan {
    param([string]$Stage,$SavedBoot,$CurrentBoot)
    if($Stage -in @('AwaitingMsiReboot','AwaitingResidualReboot') -and ($null -eq $SavedBoot -or [string]::IsNullOrWhiteSpace([string]$SavedBoot) -or $null -eq $CurrentBoot -or [string]::IsNullOrWhiteSpace([string]$CurrentBoot))){throw 'Boot evidence is missing; resume refused.'}
    $SavedBoot=Convert-VMwareCleanupBootId $SavedBoot
    $CurrentBoot=Convert-VMwareCleanupBootId $CurrentBoot
    switch($Stage){
        'ReadyForMsi' {return 'Msi'}
        'ReadyForResiduals' {return 'Residuals'}
        'AwaitingMsiReboot' {if($SavedBoot -eq $CurrentBoot){return 'RestartRequired'};return 'Residuals'}
        'AwaitingResidualReboot' {if($SavedBoot -eq $CurrentBoot){return 'RestartRequired'};return 'Verify'}
        {$_ -in @('Complete','VerificationPending','VerificationFailed')} {return 'Verify'}
        {$_ -in @('MsiInProgress','ResidualsInProgress','Failed')} {throw 'Previous cleanup was interrupted or failed. Review saved logs/state; automatic retry is disabled.'}
        default {throw "Unknown cleanup stage: $Stage"}
    }
}
function Write-VMwareCleanupState {
    param([string]$Path,$State)
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        $State|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $temp -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $temp -Destination $Path -Force -ErrorAction Stop
    } finally {if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue}}
}
function Get-VMwareCleanupWorkerError {
    param([string]$ErrorPath,[string]$Fallback)
    if (Test-Path -LiteralPath $ErrorPath) {
        try {
            $errorRecord=Get-Content -LiteralPath $ErrorPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
            return "$Fallback $($errorRecord.message) Error evidence: $ErrorPath"
        } catch { }
    }
    return "$Fallback Error evidence (if created): $ErrorPath"
}
function Get-VMwareCleanupProducts {
    foreach($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')){
        if(Test-Path $root){foreach($key in Get-ChildItem $root -ErrorAction Stop){
            $value=Get-ItemProperty $key.PSPath -ErrorAction Stop
            if($value.PSObject.Properties['DisplayName'] -and $value.DisplayName -eq 'VMware Tools'){
                [pscustomobject]@{code=$key.PSChildName;version=[string]$value.DisplayVersion}
            }
        }}
    }
}
function Read-VMwareCleanupSingleJson {
    param([string]$Root,[string]$FileName)
    $files=@(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $FileName -ErrorAction Stop)
    if($files.Count -ne 1){throw "Expected one $FileName in the isolated cleanup run; found $($files.Count)."}
    $data=Get-Content -LiteralPath $files[0].FullName -Raw -ErrorAction Stop|ConvertFrom-Json
    # Windows PowerShell 5.1 emits a JSON array as one pipeline object.
    # Enumerate explicitly so callers receive the same records on 5.1 and 7.
    foreach($entry in $data){$entry}
}
function Assert-VMwareResidualAudit {
    param($Inventory)
    foreach($field in @('Products','Drivers','Services','Packages')){
        if($null -eq $Inventory.PSObject.Properties[$field]){throw "Missing audit field: $field"}
        if(@($Inventory.$field).Count){throw "Residual audit still contains $field. Review the audit report."}
    }
    if ($Inventory.PSObject.Properties['EligibleDeviceCount'] -and [int]$Inventory.EligibleDeviceCount -gt 0) {
        throw 'Residual audit still contains eligible absent VMware devices. Review the audit report.'
    }
}
function Get-MigrationToolsCleanupChoice {
    param([string]$StateDirectory)
    $path=Join-Path $StateDirectory 'ToolsCleanupChoice.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $saved=Get-Content -LiteralPath $path -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    $hash=(Get-FileHash (Join-Path $StateDirectory 'PreMigrationState.json') -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($saved.schemaVersion -ne 1 -or $saved.computerName -ine $env:COMPUTERNAME -or $saved.captureSha256 -ne $hash -or $saved.mode -notin @('Automatic','Manual')) {
        throw 'Saved Tools cleanup choice does not match this computer/capture or has an invalid mode. Select the intended capture and review ToolsCleanupChoice.json.'
    }
    return [string]$saved.mode
}
function Save-MigrationToolsCleanupChoice {
    param([string]$StateDirectory,[ValidateSet('Automatic','Manual')][string]$Mode)
    $capture=Join-Path $StateDirectory 'PreMigrationState.json'
    $saved=[pscustomobject]@{schemaVersion=1;computerName=$env:COMPUTERNAME;captureSha256=(Get-FileHash $capture -Algorithm SHA256 -ErrorAction Stop).Hash;mode=$Mode}
    Write-VMwareCleanupState (Join-Path $StateDirectory 'ToolsCleanupChoice.json') $saved
}
function Resolve-MigrationToolsCleanupChoice {
    param([string]$StateDirectory,[ValidateSet('Automatic','Manual')][string]$Mode='Automatic',[switch]$Explicit,[switch]$Interactive)
    if ($Explicit) { return $Mode }
    $saved=Get-MigrationToolsCleanupChoice $StateDirectory
    if ($saved) { Write-Host "Using saved VMware Tools cleanup mode: $saved";return $saved }
    if ($Interactive) {
        Write-Host 'VMware Tools: 1) Automatic cleanup (default)  2) Manual cleanup (keep Tools; continue network restoration and validation)'
        switch(Read-Host 'Select Tools cleanup [1]') {
            '2' { return 'Manual' }
            {$_ -in @('','1')} { return 'Automatic' }
            default { throw 'Invalid Tools cleanup selection.' }
        }
    }
    return $Mode
}
function Write-MigrationRestartInstructions {
    Write-Host ''
    Write-Host '================ RESTART REQUIRED ================' -ForegroundColor Yellow
    Write-Host '1. Restart Windows using Start > Restart.' -ForegroundColor Yellow
    Write-Host '2. Run Migrate-VmwareToProxmox.ps1 and select 3 again.' -ForegroundColor Yellow
    Write-Host 'Step 3 is NOT finished. Final validation is pending.' -ForegroundColor Yellow
    Write-Host 'Keep the capture, cleanup state and backups.' -ForegroundColor Yellow
    Write-Host '==================================================' -ForegroundColor Yellow
}
function Get-MigrationStep3ApprovalContext {
    param([string]$StateDirectory,[System.Collections.IDictionary]$Options,[string]$ScriptDirectory)
    $identity=Get-VMwareCleanupIdentity $StateDirectory
    $uuid=[string](Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop).UUID
    if (-not $uuid -or ([guid]$uuid) -eq [guid]::Empty) { throw 'Target VM UUID is unavailable.' }
    $targets=@(Get-NetAdapter -ErrorAction Stop|Where-Object {$_.Name -notmatch 'Loopback|ISATAP|Teredo|Tunnel' -and $_.InterfaceDescription -notmatch 'Loopback|ISATAP|Teredo|Tunnel'}|ForEach-Object {
        if (-not $_.InterfaceGuid -or ([guid]$_.InterfaceGuid) -eq [guid]::Empty -or -not $_.MacAddress) { throw 'Target adapter identity is unavailable.' }
        [pscustomobject][ordered]@{guid=([guid]$_.InterfaceGuid).ToString('D');mac=([string]$_.MacAddress -replace '[:-]','').ToUpperInvariant();description=[string]$_.InterfaceDescription}
    }|Sort-Object guid,mac)
    if (-not $targets.Count) { throw 'No current target adapter identity.' }
    $files=[ordered]@{}
    foreach($name in @('PreMigrationState.json','NetworkConfiguration.json')) {
        $files[$name]=(Get-FileHash (Join-Path $StateDirectory $name) -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    foreach($name in @('MigrationAssessment/Selection.json','MigrationAssessment/Before/Snapshot.json')) {
        $path=Join-Path $StateDirectory $name
        $files[$name]=if(Test-Path -LiteralPath $path){(Get-FileHash $path -Algorithm SHA256 -ErrorAction Stop).Hash}else{''}
    }
    $settings=[ordered]@{}
    foreach($name in @($Options.Keys|Sort-Object)) {
        $settings[$name]=$Options[$name]
        if ($name -in @('AdapterMappingPath','ApplicationConfigPath') -and $Options[$name]) {
            $files[$name]=(Get-FileHash -LiteralPath $Options[$name] -Algorithm SHA256 -ErrorAction Stop).Hash
        }
    }
    $runtime=[ordered]@{}
    $scripts=@(Get-ChildItem -LiteralPath $ScriptDirectory -Filter '*.ps1' -File -ErrorAction Stop)
    $scripts+=@(Get-ChildItem -LiteralPath (Join-Path $ScriptDirectory VMwareToolsCleanup) -Filter '*.ps1' -File -ErrorAction Stop)
    foreach($file in @($scripts|Sort-Object FullName)) {
        $relative=$file.FullName.Substring($ScriptDirectory.TrimEnd('/','\').Length).TrimStart('/','\') -replace '\\','/'
        $runtime[$relative]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    [pscustomobject][ordered]@{schemaVersion=1;captureDirectory=(Resolve-Path -LiteralPath $StateDirectory -ErrorAction Stop).Path;identity=$identity;targetUuid=([guid]$uuid).ToString('D');targets=$targets;files=$files;options=$settings;runtime=$runtime}
}
function Test-MigrationStep3Approval {
    param([string]$StateDirectory,$Context)
    if ($null -eq $Context) { return $false }
    try {
        $path=Join-Path $StateDirectory 'Step3Approval.json'
        $workflow=Join-Path $StateDirectory 'VMwareToolsCleanup/Workflow.json'
        if (-not (Test-Path -LiteralPath $path) -or -not (Test-Path -LiteralPath $workflow)) { return $false }
        $saved=Get-Content -LiteralPath $path -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
        $state=Get-Content -LiteralPath $workflow -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
        if ($saved.schemaVersion -ne 1 -or $saved.approved -ne $true -or $state.schemaVersion -ne 1 -or
            $state.stage -notin @('AwaitingMsiReboot','AwaitingResidualReboot') -or $Context.options.ToolsCleanupMode -ne 'Automatic') { return $false }
        Assert-VMwareCleanupIdentity $state.identity $Context.identity
        return (($saved.context|ConvertTo-Json -Depth 12 -Compress) -ceq ($Context|ConvertTo-Json -Depth 12 -Compress))
    } catch { return $false }
}
function Save-MigrationStep3Approval {
    param([string]$StateDirectory,$Context)
    if ($null -eq $Context) { return }
    # The caller has already approved the operation. Internal approval-file IO
    # must not introduce extra prompts when -Confirm was explicitly requested.
    & { $ConfirmPreference='None'; Write-VMwareCleanupState (Join-Path $StateDirectory 'Step3Approval.json') ([pscustomobject]@{schemaVersion=1;approved=$true;context=$Context}) }
}
function Clear-MigrationStep3Approval {
    param([string]$StateDirectory)
    if ($StateDirectory) {
        foreach($name in @('Step3Approval.json','OfflineDiskChoice.json')) {
            $path=Join-Path $StateDirectory $name
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -Confirm:$false -ErrorAction Stop }
        }
    }
}
