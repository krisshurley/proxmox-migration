# Direct ESXi import support. Loaded without side effects; Veeam remains the default.
function Get-MigrationRememberedMethod {
    param($Selection)
    if (-not $Selection -or (Get-MigrationProperty $Selection 'computerName' '') -ine $env:COMPUTERNAME) { return $null }
    $method = [string](Get-MigrationProperty $Selection 'migrationMethod' '')
    if (-not $method) { return $null }
    if ($method -notin @('VeeamFirstboot','DirectImport')) { throw 'Invalid remembered migration method. Rerun step 1 or explicitly select -MigrationMethod for Prepare.' }
    # Method preference survives evidence expiry. Prepare independently refreshes
    # before evidence when it is missing, incompatible or older than 24 hours.
    return $method
}

function Get-MigrationCapturedMethod {
    param([string]$StateDirectory)
    $path = Join-Path $StateDirectory 'MigrationAssessment\Selection.json'
    if (-not (Test-Path -LiteralPath $path)) { return 'VeeamFirstboot' }
    $selection = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $method = [string](Get-MigrationProperty $selection 'migrationMethod' 'VeeamFirstboot')
    if ($method -notin @('VeeamFirstboot','DirectImport')) { throw 'Invalid captured migration method.' }
    if ($method -eq 'DirectImport') {
        if ($selection.computerName -ine $env:COMPUTERNAME -or
            $selection.captureSha256 -ne (Get-FileHash -LiteralPath (Join-Path $StateDirectory 'PreMigrationState.json') -Algorithm SHA256 -ErrorAction Stop).Hash) {
            throw 'Direct import method does not match the selected capture/identity.'
        }
    }
    return $method
}

function Get-MigrationGuestDriverPackages {
    param([string]$Name)
    $infName = if ($Name -eq 'vioserial') { 'vioser' } else { $Name }
    # Inventory Driver Store packages, not only devices attached to the VMware source.
    @(Get-WindowsDriver -Online -ErrorAction Stop | Where-Object {
        ([string]$_.OriginalFileName -split '[\\/]')[-1] -ieq "$infName.inf"
    })
}

function Get-MigrationDirectImportAgent {
    $services = @(Get-CimInstance -ClassName Win32_Service -Filter "Name='QEMU-GA'" -ErrorAction Stop)
    if ($services.Count -gt 1) { throw 'Ambiguous QEMU Guest Agent service.' }
    if ($services.Count -eq 0) { return $null }
    $agent = $services[0]
    $path = [string]$agent.PathName
    if ($path -notmatch '^\s*(?:"(?<exe>[^"]+\.exe)"|(?<exe>.+?\.exe))(?=\s|$)') {
        throw 'QEMU Guest Agent executable path could not be verified.'
    }
    $exe = $Matches.exe
    if ([IO.Path]::GetFileName($exe) -ine 'qemu-ga.exe' -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw 'QEMU Guest Agent service exists but its executable is missing or unexpected.'
    }
    return $agent
}

function Invoke-MigrationDirectImportProcess {
    param([string]$FilePath, [string]$Arguments, [string]$LogPath, [int[]]$SuccessCodes = @(0,3010))
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru -ErrorAction Stop
    if ($process.ExitCode -notin $SuccessCodes) {
        throw "Direct import preparation failed: $FilePath returned $($process.ExitCode). Review $LogPath."
    }
    return [int]$process.ExitCode
}

function Get-MigrationDirectImportDriverFolder {
    param([int]$Build, [string]$Architecture)
    if ($Architecture -ne 'amd64') { throw 'Direct import preparation currently supports x64 Windows Server only.' }
    $os = switch ($Build) {
        14393 { '2k16' }
        17763 { '2k19' }
        20348 { '2k22' }
        26100 { '2k25' }
        default { throw "Unsupported Windows Server build $Build; no driver directory was guessed." }
    }
    return "$os\$Architecture"
}

function Get-MigrationDirectImportPayloadDirectory {
    param([string]$InstallerPath, [string]$PayloadDirectory = (Join-Path $PSScriptRoot 'direct-import'))
    $manifest = Join-Path $PayloadDirectory 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw 'Missing direct-import offline payload folder. Copy the complete script folder, including direct-import, and retry Prepare.' }
    $expectedManifest = '64e638d469eaec41269a9e9e84e21c94b548ef2863ecd40bd9b384371c1d6c2e'
    if ((Get-FileHash -LiteralPath $manifest -Algorithm SHA256 -ErrorAction Stop).Hash -ine $expectedManifest) { throw 'Direct import payload manifest SHA-256 mismatch.' }
    $data = Get-Content -LiteralPath $manifest -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ((Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256 -ErrorAction Stop).Hash -ine $data.bundleSha256) { throw 'Offline direct import payloads do not match the selected installer. Use the complete reviewed package.' }
    foreach ($file in $data.files) {
        if ($file.path -notmatch '^(drivers/(NetKVM|vioscsi|vioserial)/(2k16|2k19|2k22|2k25)/amd64/[^/\\]+|qemu-ga-x86_64\.msi)$') { throw 'Invalid direct import payload path.' }
        $path = Join-Path $PayloadDirectory $file.path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash -ine $file.sha256) { throw "Direct import payload is missing or altered: $($file.path)" }
    }
    return $PayloadDirectory
}

function Initialize-MigrationDirectImportGuest {
    param([string]$InstallerPath, [string]$WorkingDirectory, [string]$LogDirectory, [switch]$KeepArtifacts)
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    if ([int]$os.ProductType -eq 1) { throw 'Direct import preparation supports Windows Server only.' }
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { 'x86' }
    $driverFolder = Get-MigrationDirectImportDriverFolder -Build ([int]$os.BuildNumber) -Architecture $arch
    $missing = @('vioscsi','NetKVM','vioserial' | Where-Object { @(Get-MigrationGuestDriverPackages $_).Count -eq 0 })
    $agent = Get-MigrationDirectImportAgent
    $rebootRequired = $false
    if ($missing.Count -or -not $agent) {
        # Build-time extraction is byte-exact and pinned to the reviewed bundle.
        # Runtime does not depend on Burn layout, cache state, or administrative MSI images.
        $payloads = Get-MigrationDirectImportPayloadDirectory -InstallerPath $InstallerPath
        foreach ($name in $missing) {
            $infName = if ($name -eq 'vioserial') { 'vioser' } else { $name }
            $inf = Join-Path $payloads ("drivers\$name\$driverFolder\$infName.inf")
            if (-not (Test-Path -LiteralPath $inf -PathType Leaf)) { throw "Missing reviewed $name driver for $driverFolder." }
            $pnputilLog = Join-Path $LogDirectory ("direct-$name-pnputil.log")
            $output = & pnputil.exe /add-driver $inf 2>&1
            $code = $LASTEXITCODE
            $output | Out-File -LiteralPath $pnputilLog -Encoding utf8
            if ($code -notin @(0,3010)) { throw "PnPUtil failed for $name (exit $code). Review $pnputilLog." }
            if ($code -eq 3010) { $rebootRequired = $true }
        }
        if (-not $agent) {
            $agentMsi = Join-Path $payloads 'qemu-ga-x86_64.msi'
            $agentLog = Join-Path $LogDirectory 'direct-qemu-agent-install.log'
            $code = Invoke-MigrationDirectImportProcess 'msiexec.exe' ('/i "{0}" /qn /norestart /L*v "{1}"' -f $agentMsi,$agentLog) $agentLog
            if ($code -eq 3010) { $rebootRequired = $true }
        }
    }
    foreach ($name in @('vioscsi','NetKVM','vioserial')) {
        if (@(Get-MigrationGuestDriverPackages $name).Count -eq 0) { throw "Direct import is not ready: $name is missing from Windows Driver Store." }
    }
    $agent = Get-MigrationDirectImportAgent
    if (-not $agent) { throw 'Direct import is not ready: QEMU Guest Agent is not installed.' }
    Set-Service -Name $agent.Name -StartupType Automatic -ErrorAction Stop
    $agent = Get-MigrationDirectImportAgent
    if (-not $agent -or $agent.StartMode -ne 'Auto') { throw 'QEMU Guest Agent automatic startup could not be verified.' }
    # On VMware there is no virtio-serial channel. Running status is checked on Proxmox.
    [pscustomobject]@{scsiStaged=$true;netKvmStaged=$true;virtioSerialStaged=$true;agentInstalled=$true;agentState=$agent.State;rebootRequired=$rebootRequired}
}

function Start-MigrationDirectImportAgent {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param()
    $agent = Get-MigrationDirectImportAgent
    if (-not $agent) { throw 'QEMU Guest Agent is missing. Install it from the reviewed VirtIO package.' }
    if ($agent.State -eq 'Running') { return }
    if ($PSCmdlet.ShouldProcess($agent.Name, 'Start the installed QEMU Guest Agent on the verified Proxmox target')) {
        Start-Service -Name $agent.Name -ErrorAction Stop
        $service = Get-Service -Name $agent.Name -ErrorAction Stop
        $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [timespan]::FromSeconds(20))
    }
}
