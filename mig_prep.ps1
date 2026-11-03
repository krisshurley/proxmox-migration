#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('online', 'offline')]
    [string]$Mode = 'offline',
    [string]$WorkingDirectory = '',
    [string]$StatusPath = '',
    [string]$LogPath = '',
    [ValidateSet('VeeamFirstboot','DirectImport')][string]$MigrationMethod = 'VeeamFirstboot',
    [string]$ExpectedInstallerSha256 = '',
    [switch]$AllowUnsignedInstaller,
    [switch]$KeepArtifacts,
    [string]$InstallerSourcePath = (Join-Path $PSScriptRoot 'virtio-win-guest-tools.exe'),
    [string]$InitScriptSourcePath = (Join-Path $PSScriptRoot 'load-virtio-scsi-on-boot.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Migration.Common.ps1')
if ($MigrationMethod -eq 'DirectImport') { . (Join-Path $PSScriptRoot 'Migration.DirectImport.ps1') }
else { . (Join-Path $PSScriptRoot 'Migration.StorageDriver.ps1') }

function New-MigrationPath {
    param([string]$ScriptName)
    $datestamp = (Get-Date).ToString('yyyy-MM-dd')
    $baseFolder = "C:\VM_migration_$datestamp\$ScriptName"
    if (-not (Test-Path $baseFolder)) {
        New-Item -ItemType Directory -Path $baseFolder -Force | Out-Null
        return $baseFolder
    }
    $final = $baseFolder
    $suffix = 1
    while (Test-Path $final) {
        $suffix++
        $timestamp = (Get-Date).ToString('HHmm')
        $final = "$baseFolder`_$timestamp`_$suffix"
    }
    New-Item -ItemType Directory -Path $final -Force | Out-Null
    return $final
}

$migrationBasePath = New-MigrationPath -ScriptName 'mig_prep'
$installerUrl = 'https://fedora-virt.repo.nfrance.com/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.271-1/virtio-win-guest-tools.exe'
if (-not $WorkingDirectory) { $WorkingDirectory = Join-Path $migrationBasePath 'driver-work' }
if (-not $StatusPath) { $StatusPath = Join-Path $migrationBasePath 'driver-status.json' }
if (-not $LogPath) { $LogPath = Join-Path $migrationBasePath 'driver-install.log' }
$installerPath = Join-Path $WorkingDirectory 'virtio-win-guest-tools.exe'
$initScriptPath = Join-Path $WorkingDirectory 'load-virtio-scsi-on-boot.ps1'
$startedAt = [DateTime]::UtcNow
$stages = [ordered]@{}
$verificationDetails = @{}
$installerStaged = $false
$initScriptStaged = $false

function Write-Log {
    param([string]$Message)
    $Message | Tee-Object -FilePath $LogPath -Append
}

function Set-Stage {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Message = ''
    )
    $stages[$Name] = [ordered]@{
        status = $Status
        message = $Message
    }
    Write-Log ("[{0}] {1}: {2}" -f $Name, $Status, $Message)
}

function Write-Status {
    param(
        [string]$OverallStatus,
        [string]$Message,
        [hashtable]$Details = @{}
    )
    $report = [ordered]@{
        driver = 'VirtIO SCSI (vioscsi)'
        driverPackageVersion = 'virtio-win-0.1.271-1'
        migrationMethod = $MigrationMethod
        status = $OverallStatus
        message = $Message
        startedAtUtc = $startedAt.ToString('o')
        completedAtUtc = [DateTime]::UtcNow.ToString('o')
        stages = $stages
        details = $Details
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $StatusPath -Encoding UTF8
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run as Administrator.'
    }
}

function Get-VMwareToolsUninstallInfo {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    # Many Uninstall subkeys have no DisplayName value at all; under Set-StrictMode, $_.DisplayName
    # would throw for those, so check PSObject.Properties first instead of accessing it directly.
    Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue | Where-Object {
        $displayNameProperty = $_.PSObject.Properties['DisplayName']
        $displayNameProperty -and $displayNameProperty.Value -eq 'VMware Tools'
    } | Select-Object -First 1
}

try {
    New-Item -ItemType Directory -Path $WorkingDirectory -Force | Out-Null
    $logParent = Split-Path -Parent $LogPath
    $statusParent = Split-Path -Parent $StatusPath
    if ($logParent) { New-Item -ItemType Directory -Path $logParent -Force | Out-Null }
    if ($statusParent) { New-Item -ItemType Directory -Path $statusParent -Force | Out-Null }
    Write-Log "Starting VirtIO SCSI driver setup."

    Assert-Administrator
    Assert-MigrationArtifactPaths -SourcePaths @($InstallerSourcePath, $InitScriptSourcePath) -DestinationPaths @($installerPath, $initScriptPath)
    Set-Stage 'prerequisites' 'Succeeded' 'Running with administrator privileges.'

    if ($Mode -eq 'offline') {
        if (-not $InstallerSourcePath -or -not $InitScriptSourcePath) {
            throw '-Mode offline requires -InstallerSourcePath and -InitScriptSourcePath.'
        }
        if (-not (Test-Path $InstallerSourcePath -PathType Leaf)) {
            throw "InstallerSourcePath must point to virtio-win-guest-tools.exe, not a directory: $InstallerSourcePath"
        }
        if (-not (Test-Path $InitScriptSourcePath -PathType Leaf)) {
            throw "InitScriptSourcePath must point to load-virtio-scsi-on-boot.ps1, not a directory: $InitScriptSourcePath"
        }
        Copy-Item -Path $InstallerSourcePath -Destination $installerPath -Force
        $installerStaged = $true
        Copy-Item -Path $InitScriptSourcePath -Destination $initScriptPath -Force
        $initScriptStaged = $true
        $stageMessage = 'Used local offline installer and reviewed init script.'
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        try {
            $installerStaged = $true
            Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
            if (-not (Test-Path -LiteralPath $InitScriptSourcePath -PathType Leaf)) { throw 'The reviewed local initialization script is required in online mode too.' }
            Copy-Item -LiteralPath $InitScriptSourcePath -Destination $initScriptPath -Force
            $initScriptStaged = $true
        } catch {
            throw "Online download failed. For a machine without internet access, copy virtio-win-guest-tools.exe and load-virtio-scsi-on-boot.ps1 locally and rerun with -Mode offline -InstallerSourcePath '<path to installer>' -InitScriptSourcePath '<path to init script>'. Original error: $($_.Exception.Message)"
        }
        $stageMessage = 'Downloaded installer and used the reviewed local init script.'
    }
    $installerHash = Test-MigrationInstallerTrust -Path $installerPath -ExpectedSha256 $ExpectedInstallerSha256 -AllowUnsignedInstaller:$AllowUnsignedInstaller
    Set-Stage 'download' 'Succeeded' "$stageMessage SHA-256: $installerHash"

    # Preserve the existing Veeam path; the direct importer needs the WiX bundle's
    # explicit install/no-restart switches and independent component verification.
    $installArguments = '/S'
    if ($MigrationMethod -eq 'DirectImport') {
        $directOS = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if ([int]$directOS.ProductType -eq 1) { throw 'Direct import preparation supports Windows Server only.' }
        $architecture = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { 'x86' }
        $null = Get-MigrationDirectImportDriverFolder -Build ([int]$directOS.BuildNumber) -Architecture $architecture
        $null = Get-MigrationDirectImportPayloadDirectory -InstallerPath $installerPath
        Set-Stage 'directImportPayloads' 'Succeeded' 'Reviewed offline payloads and installer hashes verified.'
        if (-not $logParent) { $logParent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($LogPath)) }
        $installArguments = '/install /quiet /norestart /log "{0}"' -f (Join-Path $logParent 'direct-guest-tools.log')
    }
    $installProcess = Start-Process -FilePath $installerPath -ArgumentList $installArguments -Wait -PassThru
    if ($installProcess.ExitCode -notin @(0, 3010)) {
        throw "Guest tools installer failed with exit code $($installProcess.ExitCode)."
    }
    Set-Stage 'installation' 'Succeeded' 'virtio-win-guest-tools.exe completed successfully.'

    $directRebootRequired = $false
    if ($MigrationMethod -eq 'DirectImport') {
        Set-Stage 'directImportComponents' 'Running' 'Staging SCSI, NetKVM and VirtIO Serial; verifying QEMU Guest Agent installation before SCSI initialization.'
        $components = Initialize-MigrationDirectImportGuest -InstallerPath $installerPath -WorkingDirectory $WorkingDirectory -LogDirectory $logParent -KeepArtifacts:$KeepArtifacts
        $directRebootRequired = $components.rebootRequired
        Set-Stage 'directImportComponents' 'Succeeded' 'SCSI, NetKVM and VirtIO Serial are in Driver Store. QEMU Guest Agent is installed with automatic startup; it need not run on VMware. Enable QEMU Guest Agent in the Proxmox VM options.'
    } else {
        Set-Stage 'storagePackage' 'Running' 'Checking the published SCSI package after guest-tools setup.'
        $storagePackage = Repair-MigrationVeeamStoragePackage -InstallerPath $installerPath
        $directRebootRequired = $storagePackage.rebootRequired
        $storageMessage = if ($storagePackage.repaired) { "Recovered the missing SCSI package as $($storagePackage.publishedName); no network or agent components were installed by recovery." } else { 'Published SCSI package exists; no recovery was needed.' }
        Set-Stage 'storagePackage' 'Succeeded' $storageMessage
    }

    if ($MigrationMethod -eq 'DirectImport') {
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $initScriptPath -Driver scsi -VerifyPublishedPackage
    } else {
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $initScriptPath -Driver scsi
    }
    if ($LASTEXITCODE -notin @(0, 3010)) {
        throw "VirtIO SCSI initialization script failed with exit code $LASTEXITCODE."
    }
    $initializationRebootRequired = $LASTEXITCODE -eq 3010
    Set-Stage 'initialization' 'Succeeded' 'load-virtio-scsi-on-boot.ps1 completed successfully.'

    $service = Get-CimInstance Win32_SystemDriver -Filter "Name='vioscsi'" -ErrorAction SilentlyContinue
    $criticalPaths = @(
        'HKLM:\SYSTEM\CurrentControlSet\Control\CriticalDeviceDatabase\PCI#VEN_1AF4&DEV_1004',
        'HKLM:\SYSTEM\CurrentControlSet\Control\CriticalDeviceDatabase\PCI#VEN_1AF4&DEV_1004&SUBSYS_00081AF4&REV_00'
    )
    $criticalEntries = foreach ($path in $criticalPaths) {
        if (Test-Path $path) {
            $entry = Get-ItemProperty -Path $path
            [pscustomobject]@{ path = $path; service = $entry.Service }
        }
    }
    $verificationDetails = @{
        servicePresent = [bool]$service
        serviceState = if ($service) { $service.State } else { $null }
        criticalDeviceEntries = @($criticalEntries)
    }
    $failedChecks = @()
    if (-not $service) { $failedChecks += 'vioscsi service' }
    elseif ($service.StartMode -ne 'Boot') { $failedChecks += 'vioscsi boot start mode' }
    if (@($criticalEntries).Count -lt 2) { $failedChecks += 'critical-device entry count' }
    if (@($criticalEntries) | Where-Object service -ne 'vioscsi') { $failedChecks += 'critical-device service mapping' }
    $verificationDetails.failedChecks = $failedChecks
    if ($failedChecks.Count -gt 0) {
        throw "Independent verification failed: $($failedChecks -join ', ')."
    }
    Set-Stage 'verification' 'Succeeded' 'vioscsi service and critical-device entries are present.'

    if ($MigrationMethod -eq 'DirectImport') {
        $verificationDetails.directImportComponents = $components
    }

    $vmwareToolsInfo = Get-VMwareToolsUninstallInfo
    if ($vmwareToolsInfo) {
        $verificationDetails.vmwareToolsDetected = $true
        Set-Stage 'vmwareToolsDetection' 'Detected' "VMware Tools is installed (product code $($vmwareToolsInfo.PSChildName)). It remains installed on the source; Firstboot may remove it after restore."
    } else {
        $verificationDetails.vmwareToolsDetected = $false
        Set-Stage 'vmwareToolsDetection' 'NotDetected' 'VMware Tools is not installed.'
    }

    Write-Status 'Succeeded' 'VirtIO SCSI driver installed, initialized, and verified.' $verificationDetails
    Write-Log "Completed successfully. Status written to $StatusPath"
    if ($installProcess.ExitCode -eq 3010 -or $initializationRebootRequired -or $directRebootRequired) { Write-Log 'Installer requires a planned reboot. Review readiness before the final migration backup/import.'; exit 3010 }
    exit 0
}
catch {
    $failedStage = ($stages.Keys | Where-Object { $stages[$_].status -eq 'Running' } | Select-Object -Last 1)
    if ($failedStage) { Set-Stage $failedStage 'Failed' $_.Exception.Message }
    else { Set-Stage 'execution' 'Failed' $_.Exception.Message }
    Write-Status 'Failed' $_.Exception.Message $verificationDetails
    Write-Log "FAILED: $($_.Exception.Message)"
    exit 1
}
finally {
    if (-not $KeepArtifacts) {
        if ($installerStaged) { Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue }
        if ($initScriptStaged) { Remove-Item -LiteralPath $initScriptPath -Force -ErrorAction SilentlyContinue }
    }
}
