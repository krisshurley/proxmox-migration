#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root Migration.VMwareToolsCleanup.ps1)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Remove-VMwareToolsResiduals.ps1'),[ref]$tokens,[ref]$errors)
foreach($fn in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)) {
    Set-Item ('function:'+$fn.Name) ([scriptblock]::Create($fn.Body.Extent.Text.Substring(1,$fn.Body.Extent.Text.Length-2)))
}
$passed=0
function Assert($ok,$message){if(-not $ok){throw $message}}
function Test($name,[scriptblock]$body){& $body;$script:passed++;Write-Host "PASS $name"}
function Throws([scriptblock]$body){$caught=$false;try{& $body|Out-Null}catch{$caught=$true};Assert $caught 'Expected refusal'}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('residual-tests-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $temp|Out-Null
$previousWindows=$env:windir;$env:windir=$temp
$script:badSignature=$false;$script:batchCounts=@();$script:quota=$false;$script:omitId=''
$infText=@'
[Version]
Provider=VMware
[Service]
AddService=pvscsi,2,Driver_Service
[Driver_Service]
ServiceBinary=%12%\pvscsii.sys
'@
$inboxInf=Join-Path $temp 'INF/pvscsii.inf';$inboxBin=Join-Path $temp 'System32/drivers/pvscsii.sys'
$store=Join-Path $temp 'System32/DriverStore/FileRepository/pvscsii.inf_amd64_test'
$null=New-Item -ItemType Directory (Split-Path $inboxInf),(Split-Path $inboxBin),$store -Force
$infText|Set-Content $inboxInf;$infText|Set-Content (Join-Path $store pvscsii.inf)
'inbox-binary'|Set-Content $inboxBin;'inbox-binary'|Set-Content (Join-Path $store pvscsii.sys)
$driver=[pscustomobject]@{Name='pvscsi';State='Stopped';StartMode='Manual';PathName="$env:windir\System32\drivers\pvscsii.sys"}
function Get-AuthenticodeSignature {param($LiteralPath,$ErrorAction)
    [pscustomobject]@{Status=$(if($script:badSignature){'NotSigned'}else{'Valid'});SignerCertificate=[pscustomobject]@{Subject='CN=Microsoft Windows, O=Microsoft Corporation, C=US'}}
}
function Get-PnpDeviceProperty {param($InstanceId,$KeyName,$ErrorAction)
    $script:batchCounts+=@(@($InstanceId).Count)
    if(@($InstanceId).Count -gt 32 -or ($script:quota -and @($InstanceId).Count -gt 1)){throw 'Quota violation'}
    foreach($id in @($InstanceId)) {
        if($id -eq $script:omitId){continue}
        [pscustomobject]@{InstanceId=$id;KeyName=$KeyName;Data='pci.inf'}
    }
}
try {
    Test 'Microsoft-signed inbox PVSCSI is preserved only with exact INF and DriverStore byte evidence' {
        $preserved=Get-PreservedInboxDriver $driver
        Assert ($preserved.Name -eq 'pvscsi' -and $preserved.Reason -match 'preserved') 'Inbox driver not recognized'
        $vendor=$driver.PSObject.Copy();$vendor.PathName="$env:windir\System32\drivers\pvscsi.sys"
        Assert ($null -eq (Get-PreservedInboxDriver $vendor)) 'Vendor PVSCSI was silently classified as inbox'
        Throws {Get-VerifiedDriverFile $driver @()}
    }
    Test 'Missing/mismatched INF, service or SYS evidence blocks classification instead of removing inbox code' {
        foreach($kind in @('service','binary','store','missing')) {
            switch($kind){
                service {$infText.Replace('AddService=pvscsi','AddService=unrelated')|Set-Content $inboxInf}
                binary {'other-binary'|Set-Content $inboxBin}
                store {'other-binary'|Set-Content (Join-Path $store pvscsii.sys)}
                missing {Remove-Item $inboxInf}
            }
            Throws {Get-PreservedInboxDriver $driver}
            $infText|Set-Content $inboxInf;'inbox-binary'|Set-Content $inboxBin;'inbox-binary'|Set-Content (Join-Path $store pvscsii.sys)
        }
    }
    Test 'Invalid or non-Microsoft signature cannot silently pass inbox ownership verification' {
        $script:badSignature=$true;Throws {Get-PreservedInboxDriver $driver};$script:badSignature=$false
        function Get-AuthenticodeSignature {[pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='O=Other Corporation'}}}
        Throws {Get-PreservedInboxDriver $driver}
    }
    Test 'Package cleanup postcondition requires the preserved inbox registration and files to remain intact' {
        $script:preservedDrivers=@(Get-PreservedInboxDriver $driver)
        $script:currentDriver=$driver.PSObject.Copy()
        function Get-CimInstance {param($ClassName,$Filter,$ErrorAction) $script:currentDriver}
        Assert-PreservedInboxDrivers
        $script:currentDriver.PathName='another.sys';Throws {Assert-PreservedInboxDrivers}
        $script:currentDriver=$driver.PSObject.Copy();$script:currentDriver.StartMode='Disabled';Throws {Assert-PreservedInboxDrivers}
    }
    Test 'Large PnP inventories are read in bounded batches, not one quota-prone request' {
        $devices=@(1..100|ForEach-Object {[pscustomobject]@{InstanceId=('device-'+$_)}})
        $script:batchCounts=@();$bindings=Get-CleanupDeviceBindings $devices
        Assert ($bindings.Count -eq 100 -and ($script:batchCounts -join ',') -eq '32,32,32,4') 'Batch bounds or bindings wrong'
    }
    Test 'Batch quota errors retain individual fallback and never invent unknown INF/presence' {
        $script:quota=$true
        $devices=@(1..40|ForEach-Object {[pscustomobject]@{InstanceId=('device-'+$_)}})
        $bindings=Get-CleanupDeviceBindings $devices
        Assert ($bindings.Count -eq 0) 'Failed batch invented binding'
        Assert ((Read-DeviceProperty 'device-1' DEVPKEY_Device_DriverInfPath) -eq 'pci.inf') 'Individual fallback failed'
        $script:omitId='device-2'
        Assert ($null -eq (Read-DeviceProperty 'device-2' DEVPKEY_Device_DriverInfPath)) 'Missing data invented INF'
        Assert ($null -eq (Read-DeviceProperty 'device-2' DEVPKEY_Device_IsPresent -Boolean)) 'Missing data became absent'
    }
    Test 'Final residual audit allows preserved inbox driver but rejects cleanup candidates' {
        $good=[pscustomobject]@{Products=@();Drivers=@();Services=@();Packages=@();PreservedDrivers=@($driver);EligibleDeviceCount=0}
        Assert-VMwareResidualAudit $good
        $good.EligibleDeviceCount=1;Throws {Assert-VMwareResidualAudit $good}
        $good.EligibleDeviceCount=0;$good.Packages=@('oem0.inf');Throws {Assert-VMwareResidualAudit $good}
    }
    Test 'Historical Microsoft PCI bridges and generation counter remain outside device cleanup' {
        foreach($id in @('PCI\VEN_15AD&DEV_07A0&test','PCI\VEN_15AD&DEV_0790&test','ACPI\VMW0001\7','PCI\VEN_15AD&DEV_0779&test')) {
            Assert (-not (Test-CleanupDevice ([pscustomobject]@{Id=$id;INF='pci.inf'}) @())) 'Microsoft-supported device selected'
        }
    }
    Write-Host "Passed $passed residual inventory tests. Windows signatures/PnP were mocked."
} finally {$env:windir=$previousWindows;Remove-Item -LiteralPath $temp -Recurse -Force}
