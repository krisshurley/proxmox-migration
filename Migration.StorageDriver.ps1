# Targeted storage-package recovery for Veeam preparation. No device, network,
# agent or Firstboot changes are performed here.
function Repair-MigrationVeeamStoragePackage {
    param(
        [string]$InstallerPath,
        [string]$PayloadDirectory = (Join-Path $PSScriptRoot 'direct-import')
    )
    $packages = @(Get-WindowsDriver -Online -ErrorAction Stop | Where-Object {
        ([string]$_.OriginalFileName -split '[\\/]')[-1] -ieq 'vioscsi.inf' -and
        [string]$_.Driver -match '^oem[0-9]+\.inf$'
    })
    # Healthy Veeam preparations do not depend on the fallback payload files.
    if ($packages.Count -gt 0) { return [pscustomobject]@{repaired=$false;rebootRequired=$false} }

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    if ([int]$os.ProductType -eq 1 -or -not [Environment]::Is64BitOperatingSystem) {
        throw 'Automatic storage-package recovery supports x64 Windows Server only. Repair the source storage-driver installation before migration.'
    }
    $folder = switch ([int]$os.BuildNumber) {
        14393 {'2k16'}
        17763 {'2k19'}
        20348 {'2k22'}
        26100 {'2k25'}
        default { throw "Unsupported Windows Server build $($os.BuildNumber) for storage-package recovery; no driver was guessed." }
    }
    # Reuse only the signed SCSI files exported from the pinned installer.
    # The folder name is shared with direct import; no direct-import setup runs.
    $manifest = Join-Path $PayloadDirectory 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw 'Storage package is missing. Copy the complete script folder including direct-import for verified SCSI recovery, or repair the source driver installation.'
    }
    if ((Get-FileHash -LiteralPath $manifest -Algorithm SHA256 -ErrorAction Stop).Hash -ine '64e638d469eaec41269a9e9e84e21c94b548ef2863ecd40bd9b384371c1d6c2e') {
        throw 'Storage recovery manifest SHA-256 mismatch.'
    }
    $data = Get-Content -LiteralPath $manifest -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ((Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256 -ErrorAction Stop).Hash -ine $data.bundleSha256) {
        throw 'Storage recovery payloads do not match the selected installer.'
    }
    $prefix = "drivers/vioscsi/$folder/amd64/"
    foreach ($name in @('vioscsi.inf','vioscsi.cat','vioscsi.sys')) {
        $relative = $prefix + $name
        $entries = @($data.files | Where-Object { $_.path -ceq $relative })
        $path = Join-Path $PayloadDirectory $relative
        if ($entries.Count -ne 1 -or -not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash -ine $entries[0].sha256) {
            throw "Storage recovery payload is missing or altered: $relative"
        }
    }
    $inf = Join-Path $PayloadDirectory ($prefix + 'vioscsi.inf')
    Write-Warning 'No published vioscsi package exists after guest-tools setup. Registering the verified bundled SCSI driver only.'
    & pnputil.exe /add-driver $inf | Out-Host
    $code = $LASTEXITCODE
    if ($code -notin @(0,259,3010)) { throw "Storage-package recovery failed with pnputil exit code $code." }
    $packages = @(Get-WindowsDriver -Online -ErrorAction Stop | Where-Object {
        ([string]$_.OriginalFileName -split '[\\/]')[-1] -ieq 'vioscsi.inf' -and
        [string]$_.Driver -match '^oem[0-9]+\.inf$'
    })
    if ($packages.Count -ne 1) { throw 'Storage-package recovery did not produce one uniquely published vioscsi package.' }
    foreach ($path in @([string]$packages[0].OriginalFileName,(Join-Path $env:windir ('INF/' + $packages[0].Driver)))) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Recovered storage package file is missing: $path" }
    }
    [pscustomobject]@{repaired=$true;rebootRequired=($code -eq 3010);publishedName=[string]$packages[0].Driver}
}
