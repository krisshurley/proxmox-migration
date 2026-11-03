#Requires -Version 5.1
# Portable decision tests. Windows installation/native commands are mocked.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'Migration.Common.ps1')
. (Join-Path $root 'Migration.DirectImport.ps1')
. (Join-Path $root 'Migration.StorageDriver.ps1')
$temp = Join-Path ([IO.Path]::GetTempPath()) ('direct-import-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory $temp
$passed = 0
function Assert { param($Condition,$Message) if (-not $Condition) { throw $Message } }
function Throws { param([scriptblock]$Run,$Pattern) try { & $Run | Out-Null } catch { if ($_.Exception.Message -notmatch $Pattern) { throw }; return }; throw "Expected error: $Pattern" }
function Case { param($Name,[scriptblock]$Run) & $Run; $script:passed++; Write-Host "PASS: $Name" }
function Import-Functions {
    param($File,$Names)
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $File),[ref]$tokens,[ref]$errors)
    foreach ($fn in @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -in $Names })) {
        Set-Item "function:script:$($fn.Name)" ([scriptblock]::Create($fn.Body.Extent.Text.Substring(1,$fn.Body.Extent.Text.Length-2)))
    }
}
function Get-RunnerFixture {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Migrate-VmwareToProxmox.ps1'),[ref]$tokens,[ref]$errors)
    $body=@($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[0].Body
    # Execute the real runner, omitting only Windows elevation checks and process exit.
    $statements=@($body.Statements | Where-Object { $_.Extent.Text -notmatch 'WindowsIdentity|WindowsPrincipal|IsInRole' -and $_ -isnot [Management.Automation.Language.ExitStatementAst] } | ForEach-Object { $_.Extent.Text })
    $setup='$script:InteractiveMenu=-not $Phase; $script:MethodExplicit=$PSBoundParameters.ContainsKey("MigrationMethod"); $script:LevelExplicit=$PSBoundParameters.ContainsKey("CheckLevel"); $script:PhaseExitCode=0;'
    [scriptblock]::Create('[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact="High")]'+$ast.ParamBlock.Extent.Text+$setup+($statements -join "`n"))
}
function Invoke-PreparationFixture {
    param([switch]$MissingNet,[switch]$MissingSerial,[switch]$MissingScsi,[switch]$MissingAgent,[switch]$FailPayload,[switch]$FailStaging,[switch]$UnverifiedStage,[switch]$MsiReboot,[switch]$Keep)
    $script:directCalls=@(); $script:stagedPaths=@()
    $script:netReady=-not $MissingNet; $script:serialReady=-not $MissingSerial; $script:agentReady=-not $MissingAgent
    $script:scsiReady=-not $MissingScsi
    $work=Join-Path $temp ([guid]::NewGuid().ToString('N')); $null=New-Item -ItemType Directory $work
    function Get-CimInstance { [pscustomobject]@{ProductType=3;BuildNumber='17763'} }
    function Get-MigrationGuestDriverPackages {
        param($Name)
        if (($Name -eq 'NetKVM' -and $script:netReady) -or ($Name -eq 'vioserial' -and $script:serialReady) -or ($Name -eq 'vioscsi' -and $script:scsiReady)) { [pscustomobject]@{Driver='oem1.inf'} }
    }
    function Get-MigrationDirectImportAgent { if ($script:agentReady) { [pscustomobject]@{Name='QEMU-GA';State='Stopped';StartMode='Auto'} } }
    function Set-Service { param($Name,$StartupType) Assert ($Name -eq 'QEMU-GA' -and $StartupType -eq 'Automatic') 'Unexpected service change'; $script:directCalls+='Automatic' }
    function Get-MigrationDirectImportPayloadDirectory {
        param($InstallerPath)
        if ($FailPayload) { throw 'Payload verification failed' }
        $payloads=Join-Path $work 'source-payloads'
        foreach ($name in @('vioscsi','NetKVM','vioserial')) {
            $inf=if ($name -eq 'NetKVM') {'netkvm.inf'} elseif ($name -eq 'vioscsi') {'vioscsi.inf'} else {'vioser.inf'}
            foreach ($folder in @('2k19/amd64','2k22/amd64','2k19/x86')) {
                $dir=Join-Path (Join-Path (Join-Path $payloads 'drivers') $name) $folder
                $null=New-Item -ItemType Directory $dir -Force
                Set-Content -LiteralPath (Join-Path $dir $inf) -Value 'fixture'
            }
        }
        Set-Content -LiteralPath (Join-Path $payloads 'qemu-ga-x86_64.msi') -Value 'fixture'
        return $payloads
    }
    function Invoke-MigrationDirectImportProcess {
        param($FilePath,$Arguments,$LogPath,$SuccessCodes)
        $script:directCalls+=$Arguments
        Assert ($FilePath -eq 'msiexec.exe' -and $Arguments -match '^/i ' -and $Arguments -match '/norestart') 'Runtime attempted layout/admin extraction or could restart Windows'
        $script:agentReady=$true
        if ($MsiReboot) { return 3010 }
        return 0
    }
    function pnputil.exe {
        param($AddDriver,$Path)
        Assert ($AddDriver -eq '/add-driver' -and $args.Count -eq 0) 'Unexpected PnP operation'
        Assert ($Path -match '2k19[/\\]amd64') 'Wrong OS/architecture driver staged'
        $script:stagedPaths+=$Path
        $global:LASTEXITCODE=if ($FailStaging) {5} else {0}
        if (-not $UnverifiedStage) {
            if ($Path -match 'netkvm.inf$') { $script:netReady=$true } elseif ($Path -match 'vioscsi.inf$') { $script:scsiReady=$true } else { $script:serialReady=$true }
        }
        'Driver package staged'
    }
    $script:directWork=$work
    Initialize-MigrationDirectImportGuest -InstallerPath 'reviewed-bundle.exe' -WorkingDirectory $work -LogDirectory $work -KeepArtifacts:$Keep
}
function Invoke-PackageResolutionFixture {
    param([string]$Variant='StaleHint')
    $oldWindir=$env:windir; $env:windir=$temp
    $current='C:\DriverStore\vioscsi.inf_amd64_current\vioscsi.inf'
    function Get-WindowsDriver {
        if ($Variant -eq 'ProviderFailure') { throw 'Driver Store unavailable' }
        [pscustomobject]@{Driver='oem14.inf';OriginalFileName='C:\DriverStore\vmxnet3.inf_amd64_old\vmxnet3.inf'}
        if ($Variant -ne 'MissingScsi') { [pscustomobject]@{Driver='oem22.inf';OriginalFileName=$current} }
        if ($Variant -in @('Ambiguous','ExactPath','ValidOem')) { [pscustomobject]@{Driver='oem23.inf';OriginalFileName='C:\DriverStore\vioscsi.inf_amd64_other\vioscsi.inf'} }
    }
    function Test-Path { param($LiteralPath,$PathType) -not ($Variant -eq 'MissingFile' -and $LiteralPath -match 'oem22.inf$') }
    $preferredPath=if ($Variant -eq 'ExactPath') {$current} else {''}
    $preferredOem=if ($Variant -eq 'ValidOem') {'oem23.inf'} elseif ($Variant -eq 'NoHint') {''} else {'oem14.inf'}
    try { Resolve-VirtioPublishedDriverPackage -DriverName vioscsi -PreferredInfPath $preferredPath -PreferredPublishedName $preferredOem }
    finally { $env:windir=$oldWindir }
}
function Invoke-InitializerSelectionFixture {
    param([switch]$Strict, [switch]$DriverDatabase, [switch]$MissingPublished,
        [switch]$StaleHint, [switch]$MissingInf, [switch]$WrongInf,
        [switch]$StageFailure, [switch]$NoRegistration, [int]$StageExitCode=0, [switch]$Bind,
        [switch]$BundledRecovery, [string]$RecoveryPayloadDirectory=(Join-Path $root 'direct-import'),
        [int]$RecoveryBuild=17763, [switch]$InventoryFailure,
        [string]$RecoveryInstallerPath=(Join-Path $root 'virtio-win-guest-tools.exe'))
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'load-virtio-scsi-on-boot.ps1'),[ref]$tokens,[ref]$errors)
    $selection=$ast.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -eq '$VerifyPublishedPackage'},$true)
    $rebootCheck=$ast.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -eq '$verifiedPackage.rebootRequired'},$true)
    $binding=$ast.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -eq '$useNewSyntax' -and $node.Extent.Text.Contains('"$oemInf"')},$true)
    $bindCode=if ($Bind) { '$useNewSyntax=$true;'+$binding.Extent.Text+'; Assert-VirtioDriverPreparation -ExitCode $LASTEXITCODE -DriverName $drv.Name -PublishedInfName $oemInfName;' } else {''}
    $fixture=[scriptblock]::Create($ast.ParamBlock.Extent.Text+$selection.Extent.Text+$rebootCheck.Extent.Text+$bindCode+'; [pscustomobject]@{inf=$infFullPath;oem=$oemInfName;bindingInf=$oemInf;reboot=$rebootRequired}')
    $rebootRequired=$false
    $drv=@{Name='vioscsi';InfFile='vioscsi.inf';DeviceDesc='VirtIO SCSI'}
    $currentInfPath=''; $virtioBasePath='installer-registry-hint'
    $script:driverStoreQueries=0; $script:storageStageCalls=@(); $script:storageBindingCalls=@(); $script:storageRegistered=-not $MissingPublished
    $originalInf=if ($WrongInf) {'C:\DriverStore\vmxnet3.inf'} else {'C:\DriverStore\vioscsi.inf'}
    function Get-WindowsDriver {
        $script:driverStoreQueries++
        if ($InventoryFailure) { throw 'Driver Store unavailable' }
        if ($StaleHint) { [pscustomobject]@{Driver='oem14.inf';OriginalFileName='C:\DriverStore\vmxnet3.inf'} }
        if ($script:storageRegistered) { [pscustomobject]@{Driver=$(if ($StaleHint) {'oem26.inf'} else {'oem9.inf'});OriginalFileName=$(if ($Bind) {'/DriverStore/vioscsi.inf'} else {'C:\DriverStore\vioscsi.inf'})} }
    }
    function Join-Path { param($Path,$ChildPath) "$Path/$ChildPath" }
    function Test-Path {
        param($Path,$LiteralPath,$PathType)
        if ($LiteralPath) { $Path=$LiteralPath }
        if ($BundledRecovery -and $Path.StartsWith($RecoveryPayloadDirectory)) { return (Microsoft.PowerShell.Management\Test-Path -LiteralPath $Path -PathType Leaf) }
        if ($Path -like '*StartOverride') { return $false }
        if ($MissingInf -and $Path -eq $originalInf) { return $false }
        -not ($DriverDatabase -and $Path -eq $virtioBasePath)
    }
    function Get-ItemProperty {
        param($Path,$LiteralPath)
        if ($LiteralPath) { $Path=$LiteralPath }
        if ($Path -like '*Services\vioscsi') { return [pscustomobject]@{Start=0} }
        if ($Path -eq $virtioBasePath) { [pscustomobject]@{strongname=$originalInf;oem=$(if ($StaleHint) {'oem14.inf'} else {'oem9.inf'})} }
        else { [pscustomobject]@{'(default)'='oem9.inf'} }
    }
    function Get-ChildItem { [pscustomobject]@{Name='DriverDatabase\vioscsi.inf_amd64';PSPath='driver-package'} }
    function Get-CimInstance { [pscustomobject]@{ProductType=3;BuildNumber=$RecoveryBuild} }
    function Get-MigrationDirectImportPayloadDirectory { throw 'Veeam used direct-import assets' }
    function Initialize-MigrationDirectImportGuest { throw 'Veeam installed direct-import guest components' }
    function pnputil.exe {
        param($Operation,$Path)
        if ($Bind -and $args.Count -eq 1 -and $args[0] -eq '/install') {
            Assert ($Operation -eq '/add-driver' -and $Path -match 'oem26.inf$' -and $Path -notmatch 'oem14.inf$') 'Final binding used the stale VMware package'
            $script:storageBindingCalls+=$Path
            $global:LASTEXITCODE=259
            return
        }
        $expectedInf=if ($BundledRecovery) { Join-Path $RecoveryPayloadDirectory 'drivers/vioscsi/2k19/amd64/vioscsi.inf' } else { $originalInf }
        Assert ($Operation -eq '/add-driver' -and $Path -eq $expectedInf -and $Path -notmatch 'oem[0-9]+\.inf$' -and $args.Count -eq 0) 'Wrong INF, hardware-install flag or unrelated OEM package used for registration'
        $script:storageStageCalls+=@{operation=$Operation;path=$Path}
        if ($StageFailure) { $global:LASTEXITCODE=5;return }
        $global:LASTEXITCODE=$StageExitCode
        if (-not $NoRegistration) { $script:storageRegistered=$true }
        'Storage package registered'
    }
    function pnputil { pnputil.exe @args }
    if ($BundledRecovery) {
        $recovery=Repair-MigrationVeeamStoragePackage -InstallerPath $RecoveryInstallerPath -PayloadDirectory $RecoveryPayloadDirectory
        if ($recovery.rebootRequired) { $rebootRequired=$true }
    }
    if ($Strict) { & $fixture -VerifyPublishedPackage } else { & $fixture }
}
function Invoke-InitializerRoutingFixture {
    param([switch]$Direct)
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'mig_prep.ps1'),[ref]$tokens,[ref]$errors)
    $routing=$ast.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text -match '& powershell.exe[^\r\n]+-VerifyPublishedPackage'},$true)
    $fixture=[scriptblock]::Create($ast.ParamBlock.Extent.Text.Replace('$PSScriptRoot','$root')+$routing.Extent.Text)
    $initScriptPath='reviewed-init.ps1'
    $script:initializerCalls=@()
    function powershell.exe {
        param([switch]$NoProfile,[switch]$NonInteractive,$ExecutionPolicy,$File,$Driver,[switch]$VerifyPublishedPackage)
        $script:initializerCalls+=@{strict=[bool]$VerifyPublishedPackage;file=$File;driver=$Driver;noProfile=[bool]$NoProfile;nonInteractive=[bool]$NonInteractive;policy=$ExecutionPolicy}
        $global:LASTEXITCODE=0
    }
    if ($Direct) { & $fixture -MigrationMethod DirectImport } else { & $fixture }
}
try {
    Case 'Real exported payloads match the reviewed installer and all runtime hashes' {
        $directory=Get-MigrationDirectImportPayloadDirectory -InstallerPath (Join-Path $root 'virtio-win-guest-tools.exe') -PayloadDirectory (Join-Path $root 'direct-import')
        Assert ($directory -eq (Join-Path $root 'direct-import')) 'Wrong payload directory'
    }
    Case 'Missing and altered offline payloads cannot bypass verification' {
        $copy=Join-Path $temp 'payload-copy'
        Copy-Item -LiteralPath (Join-Path $root 'direct-import') -Destination $copy -Recurse
        $installer=Join-Path $root 'virtio-win-guest-tools.exe'
        $driver=Join-Path $copy 'drivers/vioscsi/2k19/amd64/vioscsi.inf'
        Set-Content -LiteralPath $driver -Value 'altered'
        Throws { Get-MigrationDirectImportPayloadDirectory -InstallerPath $installer -PayloadDirectory $copy } 'missing or altered'
        Remove-Item -LiteralPath $driver
        Throws { Get-MigrationDirectImportPayloadDirectory -InstallerPath $installer -PayloadDirectory $copy } 'missing or altered'
        Set-Content -LiteralPath (Join-Path $copy 'manifest.json') -Value '{}'
        Throws { Get-MigrationDirectImportPayloadDirectory -InstallerPath $installer -PayloadDirectory $copy } 'manifest SHA-256 mismatch'
        Throws { Get-MigrationDirectImportPayloadDirectory -InstallerPath $installer -PayloadDirectory $temp } 'Missing direct-import'
    }
    Case 'Prepared offline payloads cannot be used with a different installer' {
        $other=Join-Path $temp 'different-installer.exe'; Set-Content -LiteralPath $other -Value 'different'
        Throws { Get-MigrationDirectImportPayloadDirectory -InstallerPath $other -PayloadDirectory (Join-Path $root 'direct-import') } 'do not match'
    }
    Import-Functions 'load-virtio-scsi-on-boot.ps1' @('Resolve-VirtioPublishedDriverPackage','Assert-VirtioDriverPreparation')
    Case 'Healthy Veeam initialization preserves its package without restaging or direct-import dependencies' {
        $result=Invoke-InitializerSelectionFixture
        Assert ($result.oem -eq 'oem9.inf' -and $result.inf -eq 'C:\DriverStore\vioscsi.inf') 'Healthy Veeam package changed'
        Assert ($script:storageStageCalls.Count -eq 0) 'Healthy storage package was reinstalled'
    }
    Case 'Default Veeam initialization retains its DriverDatabase fallback' {
        $result=Invoke-InitializerSelectionFixture -DriverDatabase
        Assert ($result.oem -eq 'oem9.inf' -and $script:storageStageCalls.Count -eq 0) 'Healthy Veeam fallback was changed'
    }
    Case 'Direct initialization still blocks a missing published package before device writes' {
        Throws { Invoke-InitializerSelectionFixture -Strict -MissingPublished } 'No published vioscsi.inf package'
        Assert ($script:driverStoreQueries -eq 1) 'Direct import did not verify the package'
    }
    Case 'Veeam repairs the reported stale OEM mapping by registering the original storage INF only' {
        $result=Invoke-InitializerSelectionFixture -StaleHint -MissingPublished
        Assert ($result.oem -eq 'oem26.inf' -and $script:driverStoreQueries -eq 2 -and $script:storageStageCalls.Count -eq 1) 'Stale OEM mapping was not repaired and independently rechecked'
    }
    Case 'Reported Veeam scenario uses the repaired package in the real final binding statement and 259 verification' {
        $result=Invoke-InitializerSelectionFixture -StaleHint -MissingPublished -Bind
        Assert ($result.bindingInf -match 'oem26.inf$' -and $script:storageBindingCalls.Count -eq 1 -and $script:storageStageCalls.Count -eq 1) 'Repaired package did not reach final binding'
    }
    Case 'Veeam recovers when both the old OEM mapping and original INF are stale, then binds the verified replacement' {
        $result=Invoke-InitializerSelectionFixture -StaleHint -MissingPublished -MissingInf -BundledRecovery -Bind
        Assert ($result.oem -eq 'oem26.inf' -and $script:storageStageCalls.Count -eq 1 -and $script:storageBindingCalls.Count -eq 1) 'Missing source-INF recovery did not reach verified binding'
    }
    Case 'Healthy Veeam preparation never reads fallback payloads or requires a supported fallback build' {
        $result=Invoke-InitializerSelectionFixture -BundledRecovery -RecoveryPayloadDirectory 'absent-payload-folder' -RecoveryBuild 99999
        Assert ($result.oem -eq 'oem9.inf' -and $script:storageStageCalls.Count -eq 0) 'Healthy package unexpectedly required fallback assets'
    }
    Case 'Bundled recovery rejects unsupported builds and unavailable inventory without installing anything' {
        Throws { Invoke-InitializerSelectionFixture -MissingPublished -BundledRecovery -RecoveryBuild 99999 } 'Unsupported Windows Server build'
        Assert ($script:storageStageCalls.Count -eq 0) 'Wrong OS package staged'
        Throws { Invoke-InitializerSelectionFixture -MissingPublished -BundledRecovery -InventoryFailure } 'Driver Store unavailable'
        Assert ($script:storageStageCalls.Count -eq 0) 'Inventory error treated as absent package'
    }
    Case 'Bundled recovery does not approve failed installation or missing registration and preserves a reboot requirement' {
        Throws { Invoke-InitializerSelectionFixture -MissingPublished -BundledRecovery -StageFailure } 'exit code 5'
        Throws { Invoke-InitializerSelectionFixture -MissingPublished -BundledRecovery -NoRegistration } 'did not produce one uniquely published'
        Assert ((Invoke-InitializerSelectionFixture -MissingPublished -BundledRecovery -StageExitCode 3010).reboot) 'Recovery reboot requirement lost'
    }
    Case 'Veeam recovery verifies only its SCSI subset, rejects altered storage payloads and needs no network or agent files' {
        $copy=Join-Path $temp 'storage-only'
        $null=New-Item -ItemType Directory $copy
        Copy-Item (Join-Path $root 'direct-import/manifest.json') $copy
        $target=Join-Path $copy 'drivers/vioscsi/2k19'
        $null=New-Item -ItemType Directory $target -Force
        Copy-Item (Join-Path $root 'direct-import/drivers/vioscsi/2k19/amd64') $target -Recurse
        $result=Invoke-InitializerSelectionFixture -MissingPublished -StaleHint -MissingInf -BundledRecovery -RecoveryPayloadDirectory $copy -Bind
        Assert ($result.oem -eq 'oem26.inf') 'Recovery depended on network/agent payloads'
        Set-Content (Join-Path $target 'amd64/vioscsi.sys') 'altered'
        Throws { Invoke-InitializerSelectionFixture -MissingPublished -BundledRecovery -RecoveryPayloadDirectory $copy } 'missing or altered'
        Assert ($script:storageStageCalls.Count -eq 0) 'Altered driver was staged'
        Remove-Item (Join-Path $target 'amd64/vioscsi.sys')
        Throws { Invoke-InitializerSelectionFixture -MissingPublished -BundledRecovery -RecoveryPayloadDirectory $copy } 'missing or altered'
        Set-Content (Join-Path $copy 'manifest.json') '{}'
        Throws { Invoke-InitializerSelectionFixture -MissingPublished -BundledRecovery -RecoveryPayloadDirectory $copy } 'manifest SHA-256 mismatch'
        Remove-Item (Join-Path $copy 'manifest.json')
        Throws { Invoke-InitializerSelectionFixture -MissingPublished -BundledRecovery -RecoveryPayloadDirectory $copy } 'Copy the complete script folder'
        $other=Join-Path $temp 'unmatched-bundle.exe'; Set-Content $other 'other'
        Throws { Invoke-InitializerSelectionFixture -MissingPublished -BundledRecovery -RecoveryInstallerPath $other } 'do not match the selected installer'
        Assert ($script:storageStageCalls.Count -eq 0) 'Unverified recovery files were used'
    }
    Case 'Real Prepare component routing keeps Veeam recovery separate and propagates its reboot requirement' {
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'mig_prep.ps1'),[ref]$tokens,[ref]$errors)
        $route=$ast.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -eq '$MigrationMethod -eq ''DirectImport''' -and $node.Extent.Text.Contains('Initialize-MigrationDirectImportGuest')},$true)
        $block=[scriptblock]::Create($route.Extent.Text+'; $directRebootRequired')
        $installerPath='reviewed-installer.exe'; $script:recoveryCalls=0; $MigrationMethod='VeeamFirstboot'
        function Set-Stage { param($Name,$Status,$Message) }
        function Initialize-MigrationDirectImportGuest { throw 'Veeam ran direct components' }
        function Repair-MigrationVeeamStoragePackage { param($InstallerPath) Assert ($InstallerPath -eq 'reviewed-installer.exe') 'Wrong installer'; $script:recoveryCalls++; [pscustomobject]@{repaired=$true;rebootRequired=$true;publishedName='oem26.inf'} }
        Assert ((& $block) -eq $true -and $script:recoveryCalls -eq 1) 'Prepare skipped storage recovery or lost its reboot requirement'
    }
    Case 'Veeam selects an already registered correct storage package instead of the stale VMware OEM hint' {
        $result=Invoke-InitializerSelectionFixture -StaleHint
        Assert ($result.oem -eq 'oem26.inf' -and $script:storageStageCalls.Count -eq 0) 'Wrong OEM package selected or unnecessary installation performed'
    }
    Case 'Missing or unrelated original INF blocks storage registration' {
        Throws { Invoke-InitializerSelectionFixture -StaleHint -MissingPublished -MissingInf } 'original vioscsi.inf is missing or invalid'
        Assert ($script:storageStageCalls.Count -eq 0) 'Missing INF was used'
        Throws { Invoke-InitializerSelectionFixture -StaleHint -MissingPublished -WrongInf } 'original vioscsi.inf is missing or invalid'
        Assert ($script:storageStageCalls.Count -eq 0) 'VMware network INF was registered'
    }
    Case 'Failed registration and successful exit without a published package never approve Veeam initialization' {
        Throws { Invoke-InitializerSelectionFixture -StaleHint -MissingPublished -StageFailure } 'exit code 5'
        Throws { Invoke-InitializerSelectionFixture -StaleHint -MissingPublished -NoRegistration } 'No published vioscsi.inf package'
    }
    Case 'Storage registration reboot requirement is retained and 259 needs actual package evidence' {
        Assert ((Invoke-InitializerSelectionFixture -StaleHint -MissingPublished -StageExitCode 3010).reboot) 'Registration reboot requirement lost'
        Assert ((Invoke-InitializerSelectionFixture -StaleHint -MissingPublished -StageExitCode 259).oem -eq 'oem26.inf') 'Verified package registration was rejected'
        Throws { Invoke-InitializerSelectionFixture -StaleHint -MissingPublished -NoRegistration -StageExitCode 259 } 'No published vioscsi.inf package'
    }
    foreach ($direct in @($false,$true)) {
        Case "Actual driver preparation invokes strict initialization only for direct import: $direct" {
            Invoke-InitializerRoutingFixture -Direct:$direct
            Assert ($script:initializerCalls.Count -eq 1) 'Initialization invocation missing or duplicated'
            $call=$script:initializerCalls[0]
            Assert ($call.strict -eq $direct) 'Wrong method enabled strict package selection'
            Assert ($call.file -eq 'reviewed-init.ps1' -and $call.driver -eq 'scsi' -and $call.noProfile -and $call.nonInteractive -and $call.policy -eq 'Bypass') 'Existing Windows child process arguments changed'
        }
    }
    Case 'Reused OEM number belonging to vmxnet3 never becomes the SCSI package' {
        $result=Invoke-PackageResolutionFixture
        Assert ($result.publishedName -eq 'oem22.inf' -and $result.originalInfPath -match 'vioscsi.inf$') 'VMware OEM package was selected'
    }
    Case 'A stale registry hint with no published SCSI package fails before device changes' {
        Throws { Invoke-PackageResolutionFixture MissingScsi } 'No published vioscsi.inf package'
    }
    Case 'Multiple SCSI versions require a verified exact path or valid OEM hint' {
        Throws { Invoke-PackageResolutionFixture Ambiguous } 'Multiple vioscsi.inf packages'
        Assert ((Invoke-PackageResolutionFixture ExactPath).publishedName -eq 'oem22.inf') 'Exact package path was ignored'
        Assert ((Invoke-PackageResolutionFixture ValidOem).publishedName -eq 'oem23.inf') 'Verified existing OEM hint was changed'
    }
    Case 'Missing hints are supported while missing files and enumeration failures remain blocking' {
        Assert ((Invoke-PackageResolutionFixture NoHint).publishedName -eq 'oem22.inf') 'Unique package required obsolete installer registry data'
        Throws { Invoke-PackageResolutionFixture MissingFile } 'file is missing'
        Throws { Invoke-PackageResolutionFixture ProviderFailure } 'Driver Store unavailable'
    }
    Case 'Direct SCSI staging and OEM resolution happen before native device creation' {
        $prep=Get-Content -LiteralPath (Join-Path $root 'mig_prep.ps1') -Raw
        Assert ($prep.IndexOf('Initialize-MigrationDirectImportGuest -InstallerPath') -lt $prep.IndexOf('& powershell.exe')) 'Direct components were prepared after SCSI initialization'
        $init=Get-Content -LiteralPath (Join-Path $root 'load-virtio-scsi-on-boot.ps1') -Raw
        Assert ($init.IndexOf('$verifiedPackage = Resolve-VirtioPublishedDriverPackage') -lt $init.IndexOf('[DeviceInstaller]::CreateSoftwareDeviceWithHardwareId')) 'Device changes preceded verified OEM selection'
    }
    Case 'Legacy captures default to Veeam without any driver or service changes' {
        Assert ((Get-MigrationCapturedMethod $temp) -eq 'VeeamFirstboot') 'Legacy capture changed default'
    }
    Case 'Direct method is bound to the selected capture and computer' {
        $state=Join-Path $temp 'state'; $selectionDir=Join-Path $state 'MigrationAssessment'; $null=New-Item -ItemType Directory $selectionDir -Force
        $capture=Join-Path $state 'PreMigrationState.json'; Set-Content $capture '{}'
        $selection=[pscustomobject]@{migrationMethod='DirectImport';computerName=$env:COMPUTERNAME;captureSha256=(Get-FileHash $capture).Hash}
        $selection | ConvertTo-Json | Set-Content (Join-Path $selectionDir 'Selection.json')
        Assert ((Get-MigrationCapturedMethod $state) -eq 'DirectImport') 'Direct method not restored'
        Set-Content $capture '{"changed":true}'
        Throws { Get-MigrationCapturedMethod $state } 'does not match'
        $selection.migrationMethod='invalid'; $selection | ConvertTo-Json | Set-Content (Join-Path $selectionDir 'Selection.json')
        Throws { Get-MigrationCapturedMethod $state } 'Invalid captured'
    }
    Case 'Serial package detection uses vioser.inf and published OEM names do not matter' {
        function Get-WindowsDriver { param([switch]$Online) @([pscustomobject]@{Driver='oem7.inf';OriginalFileName='C:\DriverStore\netkvm.inf'},[pscustomobject]@{Driver='oem8.inf';OriginalFileName='C:\DriverStore\vioser.inf'}) }
        Assert (@(Get-MigrationGuestDriverPackages NetKVM).Count -eq 1) 'NetKVM missing'
        Assert (@(Get-MigrationGuestDriverPackages vioserial).Count -eq 1) 'Serial INF name incorrect'
    }
    Case 'Unknown OS and x86 never select a guessed driver' {
        Assert ((Get-MigrationDirectImportDriverFolder 20348 amd64) -eq '2k22\amd64') 'Wrong server mapping'
        Throws { Get-MigrationDirectImportDriverFolder 19045 amd64 } 'Unsupported'
        Throws { Get-MigrationDirectImportDriverFolder 17763 x86 } 'x64'
    }
    Case 'Already installed source components need no extraction or reinstallation and may be stopped' {
        $result=Invoke-PreparationFixture
        Assert ($result.agentState -eq 'Stopped' -and $script:directCalls.Count -eq 1) 'Source running status was required or installer ran unnecessarily'
    }
    Case 'Missing components are staged offline for the matching OS and architecture' {
        $result=Invoke-PreparationFixture -MissingNet -MissingSerial -MissingAgent
        Assert ($script:stagedPaths.Count -eq 2 -and $result.agentInstalled) 'Missing components were not installed'
        Assert (Test-Path -LiteralPath (Join-Path $script:directWork 'source-payloads/qemu-ga-x86_64.msi')) 'Reviewed source payloads were deleted'
    }
    Case 'MSI reboot requirement survives subsequent successful driver commands' {
        Assert ((Invoke-PreparationFixture -MissingAgent -MsiReboot).rebootRequired) 'Reboot requirement lost'
    }
    Case 'Missing SCSI package is staged before the boot initializer can use a stale OEM hint' {
        $result=Invoke-PreparationFixture -MissingScsi
        Assert ($result.scsiStaged -and $script:stagedPaths.Count -eq 1 -and $script:stagedPaths[0] -match 'vioscsi.inf$') 'Missing SCSI package was not repaired'
    }
    Case 'KeepArtifacts does not remove the reviewed offline source payloads' {
        $null=Invoke-PreparationFixture -MissingNet -Keep
        Assert (@(Get-ChildItem -LiteralPath $script:directWork -Directory).Count -eq 1) 'Source payloads removed'
    }
    Case 'Failed payload validation or driver staging cannot approve direct preparation' {
        Throws { Invoke-PreparationFixture -MissingNet -FailPayload } 'Payload verification failed'
        Throws { Invoke-PreparationFixture -MissingSerial -FailStaging } 'PnPUtil failed'
        Throws { Invoke-PreparationFixture -MissingNet -UnverifiedStage } 'missing from Windows Driver Store'
    }
    Case 'Native MSI failures are blocking and 3010 is preserved' {
        function Start-Process { [pscustomobject]@{ExitCode=3010} }
        Assert ((Invoke-MigrationDirectImportProcess 'msiexec.exe' '/i fixture /qn /norestart' 'fixture.log') -eq 3010) 'Lost MSI code'
        function Start-Process { [pscustomobject]@{ExitCode=1603} }
        Throws { Invoke-MigrationDirectImportProcess 'msiexec.exe' '/i fixture' 'fixture.log' } '1603'
    }
    Case 'Agent registration without its executable is rejected' {
        function Get-CimInstance { [pscustomobject]@{Name='QEMU-GA';PathName='"C:\Missing\qemu-ga.exe" -d';State='Stopped'} }
        Throws { Get-MigrationDirectImportAgent } 'executable is missing'
    }
    Case 'Agent WhatIf never starts a service' {
        function Get-MigrationDirectImportAgent { [pscustomobject]@{Name='QEMU-GA';State='Stopped'} }
        function Start-Service { throw 'WhatIf started service' }
        Start-MigrationDirectImportAgent -WhatIf
    }
    Import-Functions 'Test-MigrationReadiness.ps1' @('Test-DirectImportComponents')
    foreach ($driverMode in @('BeforePrepare','Installed')) {
        Case "Direct source readiness reports missing components at the appropriate stage: $driverMode" {
            $StorageDriverMode=$driverMode
            function Invoke-ReadOnlyCheck { param($Name,$Action) & $Action }
            function Get-MigrationGuestDriverPackages { @() }
            function Get-MigrationDirectImportAgent { $null }
            function Add-CheckResult { param($Name,$State,$Summary,$Details) $script:sourceResult=@{state=$State;details=@($Details)} }
            Test-DirectImportComponents
            Assert ($script:sourceResult.state -eq $(if ($driverMode -eq 'BeforePrepare') {'WARNING'} else {'FAIL'})) 'Wrong source readiness severity'
            Assert ($script:sourceResult.details.Count -eq 4) 'Missing component details were dropped'
        }
    }
    Case 'Readiness accepts a stopped agent on VMware when installation is complete' {
        $StorageDriverMode='Installed'
        function Invoke-ReadOnlyCheck { param($Name,$Action) & $Action }
        function Get-MigrationGuestDriverPackages { [pscustomobject]@{Driver='oem1.inf'} }
        function Get-MigrationDirectImportAgent { [pscustomobject]@{State='Stopped';StartMode='Auto'} }
        function Add-CheckResult { param($Name,$State,$Summary) Assert ($State -eq 'PASS') 'Source agent was required to run' }
        Test-DirectImportComponents
    }
    Import-Functions 'Test-MigrationReadiness.ps1' @('Test-VirtIODrivers')
    foreach ($readinessMethod in @('VeeamFirstboot','DirectImport')) {
        Case "Staged guest drivers are recognized for direct import without changing Veeam detection: $readinessMethod" {
            $RequiredStorageDriver='vioscsi'; $StorageDriverMode='BeforePrepare'
            function Join-Path { param($Path,$ChildPath) "$Path/$ChildPath" }
            function Invoke-ReadOnlyCheck { param($Name,$Action) & $Action }
            function Get-CimInstance { param($ClassName) if ($ClassName -eq 'Win32_SystemDriver') { [pscustomobject]@{Name='vioscsi';State='Stopped';StartMode='Manual';PathName='vioscsi.sys'} } }
            function Get-Command { $null }
            function Test-Path { $false }
            function Get-Service { $null }
            function Get-MigrationGuestDriverPackages { [pscustomobject]@{Driver='oem99.inf'} }
            function Add-CheckResult { param($Name,$State,$Summary,$Details) $script:readinessResult=@{state=$State;details=@($Details)} }
            Test-VirtIODrivers -MigrationMethod $readinessMethod
            Assert ($script:readinessResult.state -eq $(if ($readinessMethod -eq 'DirectImport') {'PASS'} else {'WARNING'})) 'Staged driver evidence was handled incorrectly'
        }
    }
    Import-Functions 'Migrate-VmwareToProxmox.ps1' @('New-SourceMigrationAssessment')
    foreach ($method in @('VeeamFirstboot','DirectImport')) {
        Case "Real runner passes only the selected preparation method: $method" {
            function Resolve-MigrationServerType { 'Normal' }
            function New-SourceMigrationAssessment { param([switch]$ReuseRecent,$MigrationMethod) [pscustomobject]@{checkLevel='Migration';migrationMethod=$MigrationMethod} }
            function Save-SourceMigrationAssessment { param($Selection) Assert ($Selection.migrationMethod -eq $method) 'Wrong method saved' }
            function Write-MigrationCaptureSummary { }
            $script:runnerCalls=@()
            function Invoke-CheckedMigrationScript { param($Name,$Arguments,$WarningCodes) $script:runnerCalls+=@{name=$Name;arguments=$Arguments} }
            & (Get-RunnerFixture) -Phase Prepare -MigrationMethod $method -Confirm:$false
            $driverArguments=$script:runnerCalls[0].arguments
            if ($method -eq 'VeeamFirstboot') { Assert ($driverArguments.Count -eq 0) 'Legacy installer arguments changed' }
            else { Assert ($driverArguments.MigrationMethod -eq 'DirectImport') 'Direct preparation not selected' }
            Assert ($script:runnerCalls[1].arguments.DisableVMwareTools) 'Original Tools capture/disable workflow changed'
        }
    }
    Case 'Direct import cannot skip source driver preparation with FirstbootManaged' {
        Throws { & (Get-RunnerFixture) -Phase Prepare -MigrationMethod DirectImport -DriverPreparation FirstbootManaged -Confirm:$false } 'requires source driver installation'
    }
    Case 'Direct component preparation failure blocks export and Tools shutdown' {
        function Resolve-MigrationServerType { 'Normal' }
        function New-SourceMigrationAssessment { [pscustomobject]@{checkLevel='Migration'} }
        function Invoke-CheckedMigrationScript { param($Name,$Arguments,$WarningCodes) Assert ($Name -eq 'mig_prep.ps1') 'Export was allowed after driver failure'; throw 'Direct components failed' }
        Throws { & (Get-RunnerFixture) -Phase Prepare -MigrationMethod DirectImport -Confirm:$false } 'Direct components failed'
    }
    Case 'Direct Prepare WhatIf never launches installation or capture' {
        function Resolve-MigrationServerType { 'Normal' }
        function New-SourceMigrationAssessment { throw 'WhatIf captured source evidence' }
        function Invoke-CheckedMigrationScript { throw 'WhatIf launched preparation' }
        & (Get-RunnerFixture) -Phase Prepare -MigrationMethod DirectImport -WhatIf
    }
    foreach ($answer in @('','2')) {
        Case "Interactive preparation defaults to Veeam and opts into direct import: '$answer'" {
            function Get-MigrationAssessmentSelection { $null }
            $script:answers=@('2',$answer); $script:answerIndex=0
            function Read-Host { $value=$script:answers[$script:answerIndex]; $script:answerIndex++; return $value }
            function Resolve-MigrationServerType { 'Normal' }
            function New-SourceMigrationAssessment { param([switch]$ReuseRecent,$MigrationMethod) [pscustomobject]@{checkLevel='Migration';migrationMethod=$MigrationMethod} }
            function Save-SourceMigrationAssessment { }
            function Write-MigrationCaptureSummary { }
            $script:runnerCalls=@()
            function Invoke-CheckedMigrationScript { param($Name,$Arguments,$WarningCodes) $script:runnerCalls+=@{name=$Name;arguments=$Arguments} }
            & (Get-RunnerFixture) -Confirm:$false
            $driverArguments=$script:runnerCalls[0].arguments
            if ($answer -eq '') { Assert ($driverArguments.Count -eq 0) 'Enter changed legacy default' }
            else { Assert ($driverArguments.MigrationMethod -eq 'DirectImport') 'Direct menu selection was ignored' }
        }
    }
    foreach ($remembered in @('VeeamFirstboot','DirectImport')) {
        foreach ($interactive in @($false,$true)) {
            Case "Prepare reuses saved $remembered without a method prompt; interactive=$interactive" {
                function Get-MigrationAssessmentSelection { [pscustomobject]@{computerName=$env:COMPUTERNAME;migrationMethod=$remembered;capturedAtUtc='2020-01-01T00:00:00Z'} }
                $script:methodPrompts=0
                function Read-Host { param($Prompt) Assert ($Prompt -eq 'Select phase') 'Saved method prompted again'; $script:methodPrompts++; '2' }
                function Resolve-MigrationServerType { 'Normal' }
                function New-SourceMigrationAssessment { param([switch]$ReuseRecent,$MigrationMethod) Assert ($ReuseRecent -and $MigrationMethod -eq $remembered) 'Remembered method did not reach evidence refresh'; [pscustomobject]@{checkLevel='Migration';migrationMethod=$MigrationMethod} }
                function Save-SourceMigrationAssessment { param($Selection) Assert ($Selection.migrationMethod -eq $remembered) 'Wrong method persisted for step 3' }
                function Write-MigrationCaptureSummary { }
                $script:runnerCalls=@()
                function Invoke-CheckedMigrationScript { param($Name,$Arguments,$WarningCodes) $script:runnerCalls+=@{name=$Name;arguments=$Arguments} }
                $parameters=@{Confirm=$false}
                if (-not $interactive) { $parameters.Phase='Prepare' }
                & (Get-RunnerFixture) @parameters
                $driverArguments=$script:runnerCalls[0].arguments
                Assert ($script:methodPrompts -eq $(if ($interactive) {1} else {0})) 'Extra method prompt'
                if ($remembered -eq 'DirectImport') { Assert ($driverArguments.MigrationMethod -eq $remembered) 'Direct choice was lost' }
                else { Assert ($driverArguments.Count -eq 0) 'Veeam installation arguments changed' }
            }
        }
    }
    Case 'Explicit Prepare method overrides the remembered preference without reading stale settings' {
        function Get-MigrationAssessmentSelection { throw 'Explicit method unnecessarily loaded saved settings' }
        function Resolve-MigrationServerType { 'Normal' }
        function New-SourceMigrationAssessment { param([switch]$ReuseRecent,$MigrationMethod) Assert ($MigrationMethod -eq 'VeeamFirstboot') 'Explicit override ignored'; [pscustomobject]@{checkLevel='Migration'} }
        function Save-SourceMigrationAssessment { }
        function Write-MigrationCaptureSummary { }
        function Invoke-CheckedMigrationScript { }
        & (Get-RunnerFixture) -Phase Prepare -MigrationMethod VeeamFirstboot -Confirm:$false
    }
    Case 'Remembered method rejects another computer and invalid values and ignores legacy missing choices' {
        Assert ($null -eq (Get-MigrationRememberedMethod -Selection $null)) 'Missing preference was invented'
        Assert ($null -eq (Get-MigrationRememberedMethod -Selection ([pscustomobject]@{computerName='unrelated.example';migrationMethod='DirectImport'}))) 'Another computer supplied a preference'
        Assert ($null -eq (Get-MigrationRememberedMethod -Selection ([pscustomobject]@{computerName=$env:COMPUTERNAME}))) 'Legacy capture invented a choice'
        Throws { Get-MigrationRememberedMethod -Selection ([pscustomobject]@{computerName=$env:COMPUTERNAME;migrationMethod='Unknown'}) } 'Invalid remembered'
    }
    Case 'Both preferences survive JSON persistence and another computer cannot replace them' {
        Import-Functions 'Migration.Assessment.ps1' @('Get-MigrationAssessmentSelection')
        $oldComputerName=$env:COMPUTERNAME
        $env:COMPUTERNAME='TEST-MIGRATION-VM'
        try {
            $search=Join-Path $temp 'remembered-choices'
            $current=Join-Path $search 'VM_migration_2026-11-03'
            $other=Join-Path $search 'VM_migration_2099-01-01'
            $null=New-Item -ItemType Directory -Path $current,$other -Force
            [pscustomobject]@{computerName='OTHER-VM';migrationMethod='DirectImport';capturedAtUtc='2099-01-01T00:00:00Z'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $other 'MigrationAssessmentSelection.json')
            foreach ($choice in @('VeeamFirstboot','DirectImport')) {
                [pscustomobject]@{computerName=$env:COMPUTERNAME;migrationMethod=$choice;capturedAtUtc='2026-11-03T08:00:00Z'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $current 'MigrationAssessmentSelection.json')
                $loaded=Get-MigrationAssessmentSelection -SearchRoot $search
                Assert ((Get-MigrationRememberedMethod -Selection $loaded) -eq $choice) 'Stored method was lost or replaced by another VM'
            }
            $legacy=Join-Path $search 'Previous_migration_2026-11-02'
            $null=New-Item -ItemType Directory -Path $legacy
            foreach ($choice in @('VeeamFirstboot','DirectImport')) {
                [pscustomobject]@{computerName=$env:COMPUTERNAME;migrationMethod=$choice;capturedAtUtc='2026-11-04T08:00:00Z'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $legacy 'MigrationAssessmentSelection.json')
                $loaded=Get-MigrationAssessmentSelection -SearchRoot $search
                Assert ((Get-MigrationRememberedMethod -Selection $loaded) -eq $choice) 'Legacy prefix lost the saved method or directory names overrode metadata'
            }
        } finally { $env:COMPUTERNAME=$oldComputerName }
    }
    Case 'Readiness still offers a fresh method choice for a new migration' {
        $script:answers=@('1','1','1');$script:answerIndex=0
        function Read-Host { $value=$script:answers[$script:answerIndex];$script:answerIndex++;$value }
        function Get-MigrationAssessmentSelection { throw 'Step 1 silently reused an old method' }
        function Resolve-MigrationServerType { 'Normal' }
        function New-SourceMigrationAssessment { param($MigrationMethod) Assert ($MigrationMethod -eq 'VeeamFirstboot') 'Readiness choice was not saved' }
        function Invoke-CheckedMigrationScript { }
        & (Get-RunnerFixture) -Confirm:$false
        Assert ($script:answerIndex -eq 3) 'New migration omitted its method selection'
    }
    foreach ($pending in @($false,$true)) {
        Case "Direct post automatically declares no Firstboot but pending conversion still blocks: $pending" {
            function Resolve-MigrationStateDirectory { $temp }
            function Get-MigrationCapturedMethod { 'DirectImport' }
            function Get-MigrationCapturedAssessmentLevel { 'Migration' }
            function Resolve-MigrationServerType { 'Normal' }
            function Get-MigrationFirstbootState { [pscustomobject]@{state=$(if ($pending) {'Pending'} else {'NotDetected'});pendingScripts=@('fixture.ps1')} }
            function Confirm-MigrationFirstbootIdleRunner { $null }
            $script:runnerCalls=@()
            function Invoke-CheckedMigrationScript { param($Name,$Arguments,$WarningCodes) $script:runnerCalls+=@{name=$Name;arguments=$Arguments} }
            if ($pending) {
                Throws { & (Get-RunnerFixture) -Phase ValidatePost -Confirm:$false } 'MIG-FIRSTBOOT'
                Assert ($script:runnerCalls.Count -eq 0) 'Pending Firstboot allowed restoration'
            } else {
                & (Get-RunnerFixture) -Phase ValidatePost -Confirm:$false
                Assert ($script:runnerCalls[0].arguments.FirstbootNotUsed -and $script:runnerCalls[0].arguments.MigrationMethod -eq 'DirectImport') 'Direct method was not inferred from the capture'
            }
            Throws { & (Get-RunnerFixture) -Phase ValidatePost -MigrationMethod VeeamFirstboot -Confirm:$false } 'differs from'
        }
    }
    Case 'Legacy post still blocks when Firstboot completion cannot be established' {
        function Resolve-MigrationStateDirectory { $temp }
        function Get-MigrationCapturedMethod { 'VeeamFirstboot' }
        function Get-MigrationCapturedAssessmentLevel { 'Migration' }
        function Resolve-MigrationServerType { 'Normal' }
        function Get-MigrationFirstbootState { [pscustomobject]@{state='NotDetected'} }
        function Invoke-CheckedMigrationScript { throw 'Unexpected restoration' }
        Throws { & (Get-RunnerFixture) -Phase ValidatePost -Confirm:$false } 'cannot be established'
    }
    Import-Functions 'Restore-And-TestMigrationState.ps1' @('Test-QemuAgentAndVMwareTools')
    foreach ($method in @('VeeamFirstboot','DirectImport')) {
        Case "Post check keeps legacy agent severity and enforces direct components: $method" {
            function Get-VMwareToolsServices { @() }
            function Get-VMwareToolsProducts { @() }
            function Get-Service { $null }
            function Get-MigrationGuestDriverPackages { @() }
            $script:results=@()
            function Add-Result { param($Name,$State,$Summary,$Details) $script:results+=@{name=$Name;state=$State} }
            function Add-Action { }
            Test-QemuAgentAndVMwareTools -MigrationMethod $method
            $agent=@($script:results | Where-Object name -eq 'QEMU Guest Agent')[0]
            $expected=if ($method -eq 'DirectImport') {'FAIL'} else {'WARNING'}
            Assert ($agent.state -eq $expected) 'Agent severity changed incorrectly'
            Assert (@($script:results | Where-Object { $_.name -like 'Direct import*' }).Count -eq $(if ($method -eq 'DirectImport') {2} else {0})) 'Direct checks leaked into legacy flow'
        }
    }
    Write-Host "Direct import tests passed: $passed"
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
