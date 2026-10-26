<#
.SYNOPSIS
    Runs pre-migration checks, source preparation, or post-Firstboot validation.
.DESCRIPTION
    Each child script runs in an isolated PowerShell process. Blocking failures stop
    the phase and warning exit codes are propagated. Full validation removes remaining VMware Tools
    using MSI only after Firstboot and target adapter verification.
.PARAMETER DriverPreparation
    Install (default) preserves source VirtIO preparation. FirstbootManaged skips
    it only when the selected restore method supplies boot-critical drivers.
.PARAMETER FirstbootNotUsed
    Explicitly declares a restore method without Guestfs/Firstboot. This cannot
    bypass an existing pending or unverified Firstboot conversion.
.PARAMETER AdapterMappingPath
    Optional complete source-MAC to target-MAC JSON mapping for ValidatePost.
    Omit when source MACs are preserved. Works with menu selection 3 as well.
.PARAMETER DisableVMwareTools
    Enabled by default in Prepare to preserve the original migration workflow.
    Captures original service state before stopping/disabling Tools on the source.
    Use -DisableVMwareTools:$false to keep source services unchanged.
.PARAMETER CheckLevel
    Migration (default) collects bounded local evidence. Deep adds diagnostics
    for this server only. Prepare saves the level with State; ValidatePost reuses it.
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('ReadinessCheck', 'Prepare', 'ValidatePost')][string]$Phase,
    [ValidateSet('Auto', 'DomainController', 'Normal')][string]$ServerType = 'Auto',
    [ValidateSet('Migration', 'Deep')][string]$CheckLevel = 'Migration',
    [ValidateSet('Install', 'FirstbootManaged')][string]$DriverPreparation = 'Install',
    [string]$StateDirectory = '',
    [string]$AdapterMappingPath = '',
    [switch]$FirstbootNotUsed,
    [switch]$RepairOfflineDisks,
    [switch]$RemoveHiddenVMwareAdapters,
    [switch]$DisableVMwareTools = $true,
    [switch]$DeepScan,
    [string]$DnsTestHost = '',
    [string]$ApplicationConfigPath = '',
    [datetime]$MigrationTimestamp,
    [string]$ExpectedInstallerSha256 = '',
    [switch]$AllowUnsignedInstaller
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Migration.Common.ps1')
. (Join-Path $PSScriptRoot 'Migration.Assessment.ps1')
$script:PhaseExitCode = 0
$script:InteractiveMenu = -not $Phase
$script:LevelExplicit = $PSBoundParameters.ContainsKey('CheckLevel')

function New-SourceMigrationAssessment {
    param([switch]$ReuseRecent)
    $selection=Get-MigrationAssessmentSelection
    if ($ReuseRecent -and $selection -and (Test-Path -LiteralPath (Join-Path $selection.outputDirectory 'Snapshot.json')) -and
        ([datetime]::UtcNow - (ConvertTo-AssessmentUtc $selection.capturedAtUtc)).TotalHours -ge 0 -and
        ([datetime]::UtcNow - (ConvertTo-AssessmentUtc $selection.capturedAtUtc)).TotalHours -lt 24 -and
        (-not $script:LevelExplicit -or $selection.checkLevel -eq $CheckLevel)) {
        $before=Read-MigrationAssessmentSnapshot (Join-Path $selection.outputDirectory 'Snapshot.json')
        if ($before.computerName -ieq $env:COMPUTERNAME -and $before.stage -eq 'Before' -and $before.checkLevel -eq $selection.checkLevel) { return $selection }
        Write-Warning 'The previous evidence identity/level does not match; collecting a fresh local before snapshot.'
    }
    if ($ReuseRecent -and $selection -and -not $script:LevelExplicit) { $CheckLevel=[string]$selection.checkLevel }
    $root=Join-Path 'C:\' ('Rutin_migration_'+(Get-Date -Format 'yyyy-MM-dd'))
    $output=Join-Path $root ('MigrationAssessment_Before_'+[guid]::NewGuid().ToString('N'))
    Invoke-CheckedMigrationScript 'Test-MigrationAssessment.ps1' @{Stage='Before';OutputDirectory=$output;CheckLevel=$CheckLevel}
    $selection=[pscustomobject]@{computerName=$env:COMPUTERNAME;checkLevel=$CheckLevel;capturedAtUtc=[datetime]::UtcNow.ToString('o');outputDirectory=$output}
    $selection | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'MigrationAssessmentSelection.json') -Encoding UTF8
    return $selection
}

function Save-SourceMigrationAssessment {
    param($Selection)
    $state=Resolve-MigrationStateDirectory
    $destination=Join-Path $state 'MigrationAssessment'
    New-Item -ItemType Directory -Path $destination -ErrorAction Stop | Out-Null
    Copy-Item -LiteralPath $Selection.outputDirectory -Destination (Join-Path $destination 'Before') -Recurse -ErrorAction Stop
    # Bind evidence to this exact export; post-migration never follows source absolute paths.
    $Selection | Add-Member NoteProperty captureSha256 (Get-FileHash (Join-Path $state 'PreMigrationState.json') -Algorithm SHA256).Hash -Force
    $Selection | Add-Member NoteProperty beforeSha256 (Get-FileHash (Join-Path $destination 'Before\Snapshot.json') -Algorithm SHA256).Hash -Force
    $Selection | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destination 'Selection.json') -Encoding UTF8
    Write-Host "Saved before evidence and check level $($Selection.checkLevel) with capture: $destination"
}

function Invoke-CheckedMigrationScript {
    param([string]$Name, [hashtable]$Arguments = @{}, [int[]]$WarningCodes = @(1))
    $code = Invoke-MigrationChildScript -Path (Join-Path $PSScriptRoot $Name) -Arguments $Arguments
    if ($code -eq 0) { return }
    if ($code -in $WarningCodes) {
        $script:PhaseExitCode = 1
        Write-Warning "$Name completed with warnings (exit $code). Review its report."
        return
    }
    $exception = New-Object System.InvalidOperationException("$Name failed with exit code $code. The phase was stopped.")
    $exception.Data['MigrationExitCode'] = $code
    throw $exception
}

function Resolve-MigrationServerType {
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $detected = if ([int]$computer.DomainRole -ge 4) { 'DomainController' } else { 'Normal' }
    if ($ServerType -ne 'Auto' -and $ServerType -ne $detected) {
        throw "Selected server type '$ServerType' conflicts with detected type '$detected'."
    }
    return $detected
}

function Write-MigrationCaptureSummary {
    $selectedState = Resolve-MigrationStateDirectory
    $network = Get-Content -LiteralPath (Join-Path $selectedState 'NetworkConfiguration.json') -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    Assert-MigrationNetworkCaptureComplete $network
    $count = @(Get-MigrationProperty $network 'activeAdapters' @() | Where-Object { $_ }).Count
    Write-Host "StateDirectory: $selectedState"
    if ($count -gt 1) {
        $script:PhaseExitCode = 1
        Write-Warning "Captured all $count adapters and their routes. Preparation completed with warnings; preserve every source MAC in Proxmox or supply -AdapterMappingPath in ValidatePost so every NIC and route can be restored safely."
    }
}

try {
    if (-not $Phase) {
        Write-Host '1) ReadinessCheck  2) Prepare  3) ValidatePost  4) Exit'
        switch (Read-Host 'Select phase') {
            '1' { $Phase = 'ReadinessCheck' }
            '2' { $Phase = 'Prepare' }
            '3' { $Phase = 'ValidatePost' }
            '4' { exit 0 }
            default { throw 'Invalid phase selection.' }
        }
    }
    if ($script:InteractiveMenu -and $Phase -eq 'ReadinessCheck' -and -not $script:LevelExplicit) {
        Write-Host 'Check level: 1) Migration checks (default)  2) Deep checks for this server'
        switch (Read-Host 'Select level [1]') {
            '2' { $CheckLevel='Deep' }
            { $_ -in @('','1') } { $CheckLevel='Migration' }
            default { throw 'Invalid check level selection.' }
        }
        $script:LevelExplicit=$true
    }
    if ($StateDirectory -and $Phase -ne 'ValidatePost') { throw '-StateDirectory selects a restore baseline and is only supported with ValidatePost.' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script in an elevated Administrator PowerShell session.'
    }
    $role = Resolve-MigrationServerType
    Write-Host "Phase: $Phase. Detected server type: $role."
    switch ($Phase) {
        'ReadinessCheck' {
            $readinessArgs = @{CheckLevel=$CheckLevel}
            if ($DriverPreparation -eq 'FirstbootManaged') { $readinessArgs.StorageDriverMode = 'RestoreInjected' }
            Invoke-CheckedMigrationScript 'Test-MigrationReadiness.ps1' $readinessArgs
            if (-not $WhatIfPreference) { $null=New-SourceMigrationAssessment }
        }
        'Prepare' {
            $prepareAction = 'Prepare the source VM and capture migration state'
            if ($DisableVMwareTools) { $prepareAction += ', then stop and disable VMware Tools services (preserving original service state)' }
            if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, $prepareAction)) {
                $assessment=New-SourceMigrationAssessment -ReuseRecent
                if ($DriverPreparation -eq 'Install') {
                    $driverArgs = @{}
                    if ($ExpectedInstallerSha256) { $driverArgs.ExpectedInstallerSha256 = $ExpectedInstallerSha256 }
                    if ($AllowUnsignedInstaller) { $driverArgs.AllowUnsignedInstaller = $true }
                    Invoke-CheckedMigrationScript 'mig_prep.ps1' $driverArgs -WarningCodes @(3010)
                } else {
                    Write-Warning 'Source driver installation skipped. Confirm that the restore method supplies boot-critical storage drivers before the first Windows boot.'
                    $script:PhaseExitCode = 1
                }
                # The standalone exporter is read-only by default; Prepare preserves the original service-disable workflow.
                $exportArgs = @{}
                if ($DisableVMwareTools) { $exportArgs.DisableVMwareTools = $true; $exportArgs.Confirm = $false }
                Invoke-CheckedMigrationScript 'Export-MigrationState.ps1' $exportArgs -WarningCodes @(50)
                Write-MigrationCaptureSummary
                Save-SourceMigrationAssessment $assessment
            } elseif (-not $WhatIfPreference) { $script:PhaseExitCode = 1 }
        }
        'ValidatePost' {
            $selectedState = Resolve-MigrationStateDirectory -StateDirectory $StateDirectory
            $capturedLevel=Get-MigrationCapturedAssessmentLevel $selectedState
            if ($script:LevelExplicit -and $CheckLevel -ne $capturedLevel) { throw 'Check level differs from the before capture. Run extra deep diagnostics separately to preserve comparable assessment levels.' }
            $CheckLevel=$capturedLevel
            Write-Host "Check level from capture: $CheckLevel"
            # Also checked by the standalone restore script; never race Firstboot.
            $firstboot = Assert-MigrationFirstbootComplete -FirstbootNotUsed:$FirstbootNotUsed
            Write-Host "Firstboot status: $($firstboot.state)"
            if ((Get-MigrationProperty $firstboot 'completionEvidence' '') -eq 'VerifiedIdleUninstalledRunner') {
                Write-Host 'Firstboot work is complete; the uninstalled runner is verified idle. No additional restart is needed for the Firstboot gate.'
            }
            if (-not $WhatIfPreference -and -not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Restore captured network settings, uninstall remaining VMware Tools (including backed-up service cleanup if MSI fails) on the verified target, and validate after Firstboot')) {
                $script:PhaseExitCode = 1
                break
            }
            $restoreArgs = @{ Mode = 'Full'; StateDirectory = $selectedState; Confirm = $false; CheckLevel=$CheckLevel }
            if ($AdapterMappingPath) { $restoreArgs.AdapterMappingPath = $AdapterMappingPath }
            if ($FirstbootNotUsed) { $restoreArgs.FirstbootNotUsed = $true }
            if ($RepairOfflineDisks) { $restoreArgs.RepairOfflineDisks = $true }
            if ($RemoveHiddenVMwareAdapters) { $restoreArgs.RemoveHiddenVMwareAdapters = $true }
            if ($DeepScan) { $restoreArgs.DeepScan = $true }
            if ($DnsTestHost) { $restoreArgs.DnsTestHost = $DnsTestHost }
            if ($ApplicationConfigPath) { $restoreArgs.ApplicationConfigPath = $ApplicationConfigPath }
            if ($PSBoundParameters.ContainsKey('MigrationTimestamp')) { $restoreArgs.MigrationTimestamp = $MigrationTimestamp.ToString('o') }
            if ($WhatIfPreference) { $restoreArgs.WhatIf = $true }
            Invoke-CheckedMigrationScript 'Restore-And-TestMigrationState.ps1' $restoreArgs
        }
    }
    if ($WhatIfPreference) { Write-Host "$Phase preview completed; no preparation or restoration was applied." }
    elseif ($script:PhaseExitCode -eq 0) { Write-Host "$Phase completed successfully." }
    else { Write-Warning "$Phase completed with warnings. Review the reports before approving the migration." }
    exit $script:PhaseExitCode
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    $code = Get-MigrationProperty $_.Exception.Data 'MigrationExitCode' 2
    exit ([int]$code)
}
