#requires -Version 5.1
# Test revision r8: residual cleanup after successful modified-MSI uninstall; no Microsoft troubleshooter calls.
#requires -RunAsAdministrator
<# Standalone TEST utility. No networking changes, no forced package removal,
   no MSI registry purge, no automatic reboot. Windows Server 2019+ x64. #>
[CmdletBinding()]
param(
    [ValidateSet('Audit','Cleanup')][string]$Mode = 'Audit',
    [switch]$FirstbootNotUsed,
    [string]$BackupRoot = 'C:\temp\VMwareToolsCleanup'
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$run = Join-Path $BackupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run -Force | Out-Null
Start-Transcript -Path (Join-Path $run 'transcript.txt') | Out-Null
function Native {
    param([string]$Exe,[string[]]$Arguments)
    & $Exe @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed: $LASTEXITCODE" }
}
function Backup-Service([string]$Name) {
    Native reg.exe @('export',"HKLM\SYSTEM\CurrentControlSet\Services\$Name",(Join-Path $run "$Name.reg"),'/y')
}
function Products {
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (Test-Path $key) {
            Get-ChildItem $key | ForEach-Object {
                $p = Get-ItemProperty $_.PSPath
                if ($p.PSObject.Properties['DisplayName'] -and $p.DisplayName -eq 'VMware Tools') { $p }
            }
        }
    }
}
function Read-DeviceProperty {
    param([string]$InstanceId,[string]$KeyName,[switch]$Boolean)
    # Some PnP provider responses contain status/error objects without Data.
    # Unknown presence must never be treated as verified absence.
    try {
        $responses = @(Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $KeyName -ErrorAction Stop)
        $usable = @($responses | Where-Object {
            $null -ne $_ -and $null -ne $_.PSObject.Properties['Data'] -and
            $null -ne $_.PSObject.Properties['KeyName'] -and $_.KeyName -eq $KeyName
        })
        if ($usable.Count -ne 1) { return $null }
        $data = $usable[0].PSObject.Properties['Data'].Value
        if ($Boolean) {
            if ($data -is [bool]) { return $data }
            return $null
        }
        if ($data -is [string] -and -not [string]::IsNullOrWhiteSpace($data)) { return $data }
        return $null
    } catch { return $null }
}
function Test-CleanupDevice {
    param($Device,[object[]]$Packages)
    # Only Tools package bindings and explicitly reviewed old endpoint hardware.
    # Do not delete PCI bridges/root ports, generation counters or controllers using Microsoft drivers.
    $published=@($Packages | ForEach-Object Published)
    if ($Device.INF -and $Device.INF -in $published) { return $true }
    return [bool]($Device.Id -match '^HID\\VID_0E0F&PID_0003&MI_00\\' -or
        $Device.Id -match '^PCI\\VEN_15AD&DEV_(07B0|0740|0405)&' -or
        $Device.Id -match '^ACPI\\VMW0003\\' -or
        $Device.Id -match '^SCSI\\(DISK&VEN_VMWARE&PROD_VIRTUAL_DISK|CDROM&VEN_NECVMWAR&PROD_VMWARE_SATA_CD00)\\')
}
function Get-PreservedInboxDriver {
    param($Driver)
    if ($Driver.Name -ine 'pvscsi' -or $Driver.PathName -ine "$env:windir\System32\drivers\pvscsii.sys") { return $null }
    $inf=Join-Path $env:windir 'INF\pvscsii.inf'
    $binary=[string]$Driver.PathName
    if (-not (Test-Path -LiteralPath $inf -PathType Leaf) -or -not (Test-Path -LiteralPath $binary -PathType Leaf)) {
        throw 'Windows inbox PVSCSI evidence is incomplete; no driver removal is authorized.'
    }
    $text=Get-Content -LiteralPath $inf -Raw -ErrorAction Stop
    if ($text -notmatch '(?im)^\s*AddService\s*=\s*pvscsi\s*,' -or $text -notmatch '(?im)^\s*ServiceBinary\s*=\s*%12%\\pvscsii\.sys\s*(?:;.*)?$') {
        throw 'Windows inbox PVSCSI INF does not match the service/binary; review manually.'
    }
    $hash=(Get-FileHash -LiteralPath $inf -Algorithm SHA256 -ErrorAction Stop).Hash
    $binaryHash=(Get-FileHash -LiteralPath $binary -Algorithm SHA256 -ErrorAction Stop).Hash
    $stores=@(Get-ChildItem (Join-Path $env:windir 'System32\DriverStore\FileRepository') -Directory -Filter 'pvscsii.inf_*' -ErrorAction Stop | Where-Object {
        $storeInf=Join-Path $_.FullName 'pvscsii.inf';$storeBinary=Join-Path $_.FullName 'pvscsii.sys'
        (Test-Path -LiteralPath $storeInf -PathType Leaf) -and (Test-Path -LiteralPath $storeBinary -PathType Leaf) -and
        (Get-FileHash -LiteralPath $storeInf -Algorithm SHA256 -ErrorAction Stop).Hash -eq $hash -and
        (Get-FileHash -LiteralPath $storeBinary -Algorithm SHA256 -ErrorAction Stop).Hash -eq $binaryHash
    })
    if (-not $stores.Count) { throw 'Windows inbox PVSCSI files could not be matched to DriverStore; review manually.' }
    $signature=Get-AuthenticodeSignature -LiteralPath $binary -ErrorAction Stop
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {
        throw 'Windows inbox PVSCSI signature could not be verified; review manually.'
    }
    [pscustomobject]@{Name=[string]$Driver.Name;State=[string]$Driver.State;StartMode=[string]$Driver.StartMode;PathName=$binary;Reason='Verified Windows inbox PVSCSI: preserved, not a Tools remnant';InfHash=$hash;BinaryHash=$binaryHash}
}
function Assert-PreservedInboxDrivers {
    foreach($saved in $script:preservedDrivers) {
        $current=@(Get-CimInstance Win32_SystemDriver -Filter "Name='$($saved.Name)'" -ErrorAction Stop)
        if ($current.Count -ne 1 -or $current[0].PathName -ine $saved.PathName -or
            $current[0].StartMode -ne $saved.StartMode) { throw 'Preserved Windows inbox driver registration changed. Review the saved registry backup.' }
        $proof=Get-PreservedInboxDriver $current[0]
        if ($null -eq $proof -or $proof.InfHash -ne $saved.InfHash -or $proof.BinaryHash -ne $saved.BinaryHash) {
            throw 'Preserved Windows inbox driver files changed. Review the saved evidence.'
        }
    }
}
function Get-VerifiedDriverFile {
    param($Driver,[object[]]$Packages)
    $files=@{vmci='vmci.sys';vmmouse='vmmouse.sys';vmusbmouse='vmusbmouse.sys';vmxnet3ndis6='vmxnet3.sys';VMMemCtl='vmmemctl.sys';pvscsi='pvscsi.sys'}
    $path=[string]$Driver.PathName
    if ($files.ContainsKey($Driver.Name)) {
        $expected="$env:windir\System32\drivers\$($files[$Driver.Name])"
        if ($path -ine $expected) { throw "Unexpected driver path: $($Driver.Name)" }
        return $expected
    }
    if ($Driver.Name -notin @('vm3dmp','vm3dmp-debug','vm3dmp-stats','vm3dmp_loader')) {
        throw "Unsupported driver: $($Driver.Name)"
    }
    $base=[regex]::Escape("$env:windir\System32\DriverStore\FileRepository\")
    if ($path -notmatch ('^'+$base+'vm3d\.inf_amd64_[a-f0-9]+\\[^\\]+\.sys$')) {
        throw "Unexpected graphics driver path: $path"
    }
    $storeInf=Join-Path (Split-Path -Parent $path) 'vm3d.inf'
    if (-not (Test-Path -LiteralPath $storeInf)) { throw 'Graphics INF is missing; ownership cannot be verified.' }
    $hash=(Get-FileHash -LiteralPath $storeInf -Algorithm SHA256).Hash
    if (@($Packages | Where-Object { $_.Original -eq 'vm3d' -and $_.Hash -eq $hash }).Count -eq 0) {
        throw 'Graphics SYS path does not belong to an inventoried/exported VMware package.'
    }
    return $path
}
function Get-ReportText {
    param($Object,[string]$Property)
    if ($null -eq $Object) { return '' }
    $p=$Object.PSObject.Properties[$Property]
    if ($null -eq $p -or $null -eq $p.Value) { return '' }
    return [string]$p.Value
}
function New-InventoryReport {
    # Do not serialize raw CIM, Registry provider, COM or extended PS objects.
    [pscustomobject]@{
        Computer=[string]$env:COMPUTERNAME
        Mode=[string]$Mode
        EligibleDeviceCount=@($script:devices|Where-Object { Test-CleanupDevice $_ $script:packages }).Count
        PreservedDrivers=@($script:preservedDrivers)
        Products=@(foreach($p in $script:products) {
            [pscustomobject]@{
                DisplayName=(Get-ReportText $p 'DisplayName')
                DisplayVersion=(Get-ReportText $p 'DisplayVersion')
                ProductCode=(Get-ReportText $p 'PSChildName')
                InstallSource=(Get-ReportText $p 'InstallSource')
            }
        })
        Drivers=@(foreach($d in $script:drivers) {
            [pscustomobject]@{Name=[string]$d.Name;State=[string]$d.State;StartMode=[string]$d.StartMode;PathName=[string]$d.PathName}
        })
        Services=@(foreach($v in $script:services) {
            $com=$null
            if($null -ne $v.comApplication) {
                $com=[pscustomobject]@{
                    Id=[string]$v.comApplication.id;Name=[string]$v.comApplication.name
                    ServiceName=[string]$v.comApplication.serviceName
                    DLLs=@($v.comApplication.dlls | ForEach-Object { [string]$_ })
                }
            }
            [pscustomobject]@{Name=[string]$v.name;State=[string]$v.state;StartMode=[string]$v.startMode;PathName=[string]$v.pathName;COMApplication=$com}
        })
        Packages=@(foreach($p in $script:packages) {
            [pscustomobject]@{Published=[string]$p.Published;Original=[string]$p.Original;Hash=[string]$p.Hash}
        })
        Devices=@(foreach($d in $script:devices) {
            [pscustomobject]@{Name=[string]$d.Name;Id=[string]$d.Id;INF=[string]$d.INF;Present=$d.Present}
        })
    }
}
function Get-CleanupDeviceBindings {
    param([object[]]$Devices)
    # One provider call for INF bindings instead of one per historical device.
    # On bulk-read failure retain the existing per-device fallback.
    $bindings=@{};$duplicates=@{}
    if (-not $Devices.Count) { return $bindings }
    # Bound provider requests: large arrays can hit the PnP/WMI quota on busy guests.
    for ($offset=0;$offset -lt $Devices.Count;$offset+=32) {
        $last=[math]::Min($offset+31,$Devices.Count-1)
        try {
            $rows=@(Get-PnpDeviceProperty -InstanceId @($Devices[$offset..$last]|ForEach-Object InstanceId) -KeyName DEVPKEY_Device_DriverInfPath -ErrorAction Stop)
            foreach ($row in $rows) {
                if ($null -eq $row -or $null -eq $row.PSObject.Properties['InstanceId'] -or
                    $null -eq $row.PSObject.Properties['KeyName'] -or $row.KeyName -ne 'DEVPKEY_Device_DriverInfPath' -or
                    $null -eq $row.PSObject.Properties['Data'] -or $row.Data -isnot [string]) { continue }
                $id=[string]$row.InstanceId
                if ($bindings.ContainsKey($id)) { $duplicates[$id]=$true }
                $bindings[$id]=[string]$row.Data
            }
        } catch { Write-Host 'PnP property batch unavailable; missing bindings will be retried individually.' }
    }
    foreach ($id in $duplicates.Keys) { $bindings.Remove($id) }
    return $bindings
}
function Inventory {
    $script:services = @(Get-VerifiedVMwareServiceRemnants)
    $detectedDrivers = @(Get-CimInstance Win32_SystemDriver | Where-Object {
        $_.Name -in @('vmci','vmmouse','vmusbmouse','vmxnet3ndis6','VMMemCtl','pvscsi',
                      'vm3dmp','vm3dmp-debug','vm3dmp-stats','vm3dmp_loader')
    })
    $script:preservedDrivers=@()
    $script:drivers=@(foreach($driver in $detectedDrivers) {
        $preserved=Get-PreservedInboxDriver $driver
        if ($null -ne $preserved) { $script:preservedDrivers+=@($preserved) } else { $driver }
    })
    # Match published INF bytes to a narrowly named VMware DriverStore INF.
    # Never rely on OEM numbers, which differ between machines.
    $originals = @('vmxnet3','vmci','efifw','pvscsi','vmusbmouse','vmmouse','vm3d')
    $knownHashes = @{}
    foreach ($original in $originals) {
        foreach ($dir in @(Get-ChildItem "$env:windir\System32\DriverStore\FileRepository" -Directory -Filter "${original}.inf_*")) {
            $file = Join-Path $dir.FullName "$original.inf"
            if (-not (Test-Path $file)) { continue }
            $content = Get-Content -LiteralPath $file -Raw
            if ($content -notmatch '(?i)VMware|Broadcom') { continue }
            $knownHashes[(Get-FileHash $file -Algorithm SHA256).Hash] = $original
        }
    }
    $script:packages = @(foreach ($file in Get-ChildItem "$env:windir\INF" -Filter 'oem*.inf' -File) {
        $hash = (Get-FileHash $file.FullName -Algorithm SHA256).Hash
        if ($knownHashes.ContainsKey($hash)) {
            [pscustomobject]@{ Published=$file.Name; Original=$knownHashes[$hash]; Hash=$hash }
        }
    })
    $allDevices=@(Get-PnpDevice -ErrorAction Stop)
    $bindings=Get-CleanupDeviceBindings $allDevices
    $script:devices = @(foreach ($dev in $allDevices) {
        $inf = if ($bindings.ContainsKey($dev.InstanceId)) { $bindings[$dev.InstanceId] } else { [string](Read-DeviceProperty -InstanceId $dev.InstanceId -KeyName DEVPKEY_Device_DriverInfPath) }
        if ($dev.InstanceId -match '^(PCI\\VEN_15AD&|ACPI\\VMW|HID\\VID_0E0F&)' -or
            $dev.InstanceId -match '^SCSI\\(DISK&VEN_VMWARE|CDROM&VEN_NECVMWAR)' -or
            $inf -in @($script:packages | ForEach-Object Published)) {
            $present = Read-DeviceProperty -InstanceId $dev.InstanceId -KeyName DEVPKEY_Device_IsPresent -Boolean
            [pscustomobject]@{ Name=$dev.FriendlyName; Id=$dev.InstanceId; INF=$inf; Present=$present }
        }
    })
    $script:products = @(Products)
    $eligible=@($script:devices | Where-Object { Test-CleanupDevice $_ $script:packages })
    Write-Host ("VMware inventory: {0} devices eligible for review, {1} driver packages, {2} driver registrations, {3} services. Full inventory: {4}" -f $eligible.Count,$script:packages.Count,$script:drivers.Count,$script:services.Count,(Join-Path $run 'inventory.json'))
    foreach($preserved in $script:preservedDrivers) { Write-Host ("Preserved Windows inbox driver: {0}; {1}" -f $preserved.Name,$preserved.PathName) }
    New-InventoryReport | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $run 'inventory.json') -Encoding UTF8
}
function Get-MigrationComServiceApplications {
    # Read the catalog only. Do not activate, shut down or delete COM+ applications.
    $catalog=$null; $applications=$null
    try {
        $catalog = New-Object -ComObject COMAdmin.COMAdminCatalog -ErrorAction Stop
        $applications = $catalog.GetCollection('Applications')
        $applications.Populate()
        for ($i=0; $i -lt $applications.Count; $i++) {
            $application=$null; $components=$null
            try {
                $application=$applications.Item($i)
                if ([string]$application.Value('ServiceName') -ine 'VMVss') { continue }
                $components=$applications.GetCollection('Components', $application.Key)
                $components.Populate()
                $dlls=@(for ($j=0; $j -lt $components.Count; $j++) {
                    $component=$null
                    try { $component=$components.Item($j); [string]$component.Value('DLL') }
                    finally { if ($null -ne $component -and [Runtime.InteropServices.Marshal]::IsComObject($component)) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($component) } }
                })
                [pscustomobject]@{id=[string]$application.Value('ID');name=[string]$application.Value('Name');serviceName=[string]$application.Value('ServiceName');dlls=$dlls}
            } finally {
                foreach ($com in @($components,$application)) { if ($null -ne $com -and [Runtime.InteropServices.Marshal]::IsComObject($com)) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($com) } }
            }
        }
    } finally {
        foreach ($com in @($applications,$catalog)) { if ($null -ne $com -and [Runtime.InteropServices.Marshal]::IsComObject($com)) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($com) } }
    }
}
function Get-VerifiedVMwareComService {
    param($Service, [string[]]$ToolsRoots)
    if ($Service.Name -ine 'VMVss') { throw 'Only VMVss may use the COM+ service verification path.' }
    $pattern='^\s*"?' + [regex]::Escape($env:SystemRoot.TrimEnd('\') + '\System32\dllhost.exe') + '"?\s+/Processid:(?<id>\{[0-9a-fA-F-]{36}\})\s*$'
    if ($Service.PathName -notmatch $pattern) { throw "Unexpected COM+ service command line: $($Service.PathName)" }
    $applicationId=[guid]$Matches['id']
    $applications=@(Get-MigrationComServiceApplications)
    if ($applications.Count -ne 1) { throw 'A unique COM+ application for VMVss could not be verified.' }
    $application=$applications[0]
    if ([guid]$application.id -ne $applicationId -or $application.serviceName -ine 'VMVss' -or $application.name -ine 'VMware Snapshot Provider') {
        throw 'VMVss command line does not match the VMware Snapshot Provider COM+ catalog identity.'
    }
    $expected=@($ToolsRoots | ForEach-Object { $_ + 'Drivers\vss\VCBSnapshotProvider.dll' })
    # Newer Tools packages install the same provider under Common Files.
    # Permit that exact DLL only; keep the application/service/GUID checks above.
    $expected+=@($env:CommonProgramFiles, ${env:CommonProgramFiles(x86)} | Where-Object { $_ } | ForEach-Object {
        $_.TrimEnd('\') + '\VMware\Drivers\vss\VCBSnapshotProvider.dll'
    })
    if (@($application.dlls).Count -eq 0 -or @($application.dlls | Where-Object { $_ -notin $expected }).Count) {
        throw "VMVss COM+ components are not exclusively the expected VMware Tools snapshot provider DLL. Observed DLLs: $(@($application.dlls) -join '; ')"
    }
    # Snapshot catalog evidence alongside the service backup. The catalog and DLLs are preserved.
    return $application
}
function Get-VerifiedVMwareServiceRemnants {
    $executables = @{ VMTools='vmtoolsd.exe'; VGAuthService=@('VMware VGAuth\VGAuthService.exe','VGAuthService.exe'); VMVss=@('vmware-vss.exe','vmvss.exe'); VM3DService='vm3dservice.exe' }
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)} | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') + '\VMware\VMware Tools\' })
    foreach ($name in @('VMTools','VGAuthService','VMVss','VM3DService')) {
        $found = @(Get-CimInstance -ClassName Win32_Service -Filter "Name='$name'" -ErrorAction Stop)
        if ($found.Count -eq 0) { continue }
        if ($found.Count -ne 1 -or $found[0].Name -ine $name) { throw "Ambiguous Tools service identity: $name" }
        $service = $found[0]
        $binary = ''
        if ($service.PathName -match '^\s*(?:"(?<exe>[^"]+\.exe)"|(?<exe>.+?\.exe))(?=\s|$)') { $binary = $Matches['exe'] }
        $expected = @(foreach ($root in $roots) { foreach ($relative in @($executables[$name])) { $root + $relative } })
        $comApplication=$null
        if (-not $binary -or $binary -notin $expected) {
            if ($name -ne 'VMVss') { throw "Unexpected executable for $name; service cleanup refused: $($service.PathName)" }
            $comApplication=Get-VerifiedVMwareComService -Service $service -ToolsRoots $roots
        }
        [pscustomobject]@{ name=$name; pathName=[string]$service.PathName; state=[string]$service.State; startMode=[string]$service.StartMode; binary=$binary; comApplication=$comApplication }
    }
}

try {
    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell.' }
    $computer = Get-CimInstance Win32_ComputerSystem
    if ($computer.Manufacturer -notmatch 'QEMU|Red Hat' -and $computer.Model -notmatch 'QEMU|KVM') {
        throw "Target is not recognized as QEMU/KVM: $($computer.Manufacturer), $($computer.Model)."
    }
    $agent = Get-Service QEMU-GA
    if ($agent.Status -ne 'Running') { throw 'QEMU Guest Agent must be running.' }
    $firstboot = @(Get-CimInstance Win32_Service | Where-Object Name -eq 'firstboot')
    # Audit is read-only and must not be blocked by an idle Firstboot wrapper.
    # Mutating modes reuse the migration gate, including its verified-idle check.
    if ($Mode -ne 'Audit' -and ($firstboot.Count -or (Test-Path 'C:\Program Files\Guestfs\Firstboot'))) {
        $common = Join-Path (Split-Path -Parent $PSScriptRoot) 'Migration.Common.ps1'
        if (-not (Test-Path -LiteralPath $common)) {
            throw 'Place this utility beside Migration.Common.ps1 from the supplied migration test package.'
        }
        . $common
        $state = Assert-MigrationFirstbootComplete -FirstbootNotUsed:$FirstbootNotUsed
        Write-Host ("Firstboot verified: {0}" -f $state.state)
    }
    Inventory
    if ($Mode -eq 'Audit') {
        Write-Host 'AUDIT ONLY. No VMware configuration was changed.'
        Write-Host 'Inventory recorded for read-only residual verification.'
    } else {
        if (@(Products).Count) {
            throw 'VMware Tools product registration remains. This residual-only build will not run MSI or Microsoft troubleshooters. No cleanup performed.'
        }
        if ($script:services.Count) {
            throw 'Tools service registrations remain after MSI uninstall. Review them before residual cleanup. No cleanup performed.'
        }
        if (@($script:devices | Where-Object { $_.Present -ne $false }).Count) {
            throw 'VMware devices are present or their presence is unknown. Review inventory; switch the mouse to Microsoft PS/2 if applicable, reboot, and retry. No cleanup performed.'
        }
        if (@($script:drivers | Where-Object State -ne 'Stopped').Count) {
            throw 'A VMware driver is still running. Use Prepare for VMMemCtl, reboot and retry. No cleanup performed.'
        }
        if (@($script:services | Where-Object { $_.state -ne 'Stopped' -or $_.startMode -ne 'Disabled' }).Count) {
            throw 'Tools services must already be stopped and disabled by migration Prepare. No cleanup performed.'
        }
        if (@(Get-CimInstance Win32_Process | Where-Object ExecutablePath -like '*\VMware\*').Count) {
            throw 'A process from a VMware folder is running. Close it and retry.'
        }
        # Backup every service and driver package before any deletion.
        foreach ($s in @($script:services) + @($script:drivers)) {
            $name = if ($s.PSObject.Properties['name']) { $s.name } else { $s.Name }
            Backup-Service $name
        }
        foreach($saved in $script:preservedDrivers) { Backup-Service $saved.Name }
        foreach ($p in $script:packages) {
            $destination = Join-Path $run $p.Published
            New-Item -ItemType Directory $destination | Out-Null
            Native pnputil.exe @('/export-driver',$p.Published,$destination)
        }
        foreach ($d in $script:drivers) {
            $file=Get-VerifiedDriverFile -Driver $d -Packages $script:packages
            if (Test-Path -LiteralPath $file) {
                Copy-Item -LiteralPath $file -Destination (Join-Path $run ($d.Name+'-'+(Split-Path -Leaf $file)))
            }
        }
        $cleanupDevices=@($script:devices | Where-Object { Test-CleanupDevice $_ $script:packages })
        $cleanupDevices | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $run 'device-removal-plan.json') -Encoding UTF8
        $index=0
        foreach ($d in $cleanupDevices) {
            Native reg.exe @('export',("HKLM\SYSTEM\CurrentControlSet\Enum\"+$d.Id),(Join-Path $run ("device-{0}.reg" -f $index)),'/y')
            $index++
        }
        # Export verified COM+ applications before removing their catalog entries.
        $catalog = New-Object -ComObject COMAdmin.COMAdminCatalog
        foreach ($s in @($script:services | Where-Object comApplication)) {
            $catalog.ExportApplication($s.comApplication.id,(Join-Path $run 'VMware-Snapshot-Provider.msi'),0)
        }
        Write-Host "Backups completed: $run"
        # Use SetupAPI to remove ONLY individually verified absent devices on Server 2019.
        # No /remove-device switch dependency and no recursive parent removal.
        if (-not ('VMwareAbsentDevice' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class VMwareAbsentDevice {
 [StructLayout(LayoutKind.Sequential)] struct DATA { public int cbSize; public Guid ClassGuid; public uint DevInst; public IntPtr Reserved; }
 [DllImport("setupapi.dll", SetLastError=true)] static extern IntPtr SetupDiCreateDeviceInfoList(IntPtr cls, IntPtr parent);
 [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetupDiOpenDeviceInfo(IntPtr h,string id,IntPtr parent,uint flags,ref DATA data);
 [DllImport("setupapi.dll", SetLastError=true)] static extern bool SetupDiCallClassInstaller(uint fn,IntPtr h,ref DATA data);
 [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr h);
 public static void Remove(string id) {
  IntPtr h=SetupDiCreateDeviceInfoList(IntPtr.Zero,IntPtr.Zero);
  if(h==new IntPtr(-1)) throw new System.ComponentModel.Win32Exception();
  try { DATA d=new DATA(); d.cbSize=Marshal.SizeOf(typeof(DATA));
   if(!SetupDiOpenDeviceInfo(h,id,IntPtr.Zero,0,ref d)) throw new System.ComponentModel.Win32Exception();
   if(!SetupDiCallClassInstaller(5,h,ref d)) throw new System.ComponentModel.Win32Exception();
  } finally {SetupDiDestroyDeviceInfoList(h);}
 }
}
'@
        }
        foreach ($d in $cleanupDevices) {
            $presence = Read-DeviceProperty -InstanceId $d.Id -KeyName DEVPKEY_Device_IsPresent -Boolean
            if ($presence -ne $false) { throw "Device is present or presence is unknown: $($d.Id)" }
            [VMwareAbsentDevice]::Remove($d.Id)
            Write-Host "Removed absent device: $($d.Id)"
        }
        foreach ($p in $script:packages) {
            # Deliberately omit /force and /uninstall. In-use packages must fail.
            Native pnputil.exe @('/delete-driver',$p.Published)
            Assert-PreservedInboxDrivers
        }
        foreach ($s in @($script:services | Where-Object comApplication)) {
            $apps=$catalog.GetCollection('Applications'); $apps.Populate()
            for ($i=$apps.Count-1;$i -ge 0;$i--) {
                $app=$apps.Item($i)
                if ([string]$app.Value('ID') -eq $s.comApplication.id) {
                    if ($app.Name -ne 'VMware Snapshot Provider' -or $app.Value('ServiceName') -ine 'vmvss') { throw 'COM identity changed.' }
                    $apps.Remove($i); $null=$apps.SaveChanges()
                }
            }
        }
        foreach ($s in @($script:services) + @($script:drivers)) {
            $remaining = Get-Item "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.name)" -ErrorAction SilentlyContinue
            if ($remaining) {
                $current = @(Get-CimInstance Win32_Service -Filter "Name='$($s.name)'") + @(Get-CimInstance Win32_SystemDriver -Filter "Name='$($s.name)'")
                if (@($current | Where-Object State -ne 'Stopped').Count) { throw "Service/driver became active: $($s.name)" }
                Native sc.exe @('delete',$s.name)
            }
        }
        # Preserve protected SYS files. Do not take ownership or change Windows ACLs.
        $key='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        $value=Get-ItemProperty $key
        if ($value.PSObject.Properties['VMware User Process']) {
            $command=[string]$value.'VMware User Process'
            $expected='"' + $env:ProgramFiles + '\VMware\VMware Tools\vmtoolsd.exe" -n vmusr'
            if ($command -ine $expected) { throw 'Unexpected VMware autostart command.' }
            Native reg.exe @('export','HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',(Join-Path $run 'Run.reg'),'/y')
            Remove-ItemProperty $key -Name 'VMware User Process'
        }
        $remainingProducts=@(Products)
        if ($remainingProducts.Count) {
            throw 'VMware Tools registration appeared during cleanup. No MSI fallback is enabled; program folders were preserved.'
        } else {
            $folders=@{
                Tools="$env:ProgramFiles\VMware\VMware Tools"
                Drivers="$env:CommonProgramFiles\VMware\Drivers"
                InstallerCache="$env:CommonProgramFiles\VMware\VMwareToolsInstallerCache"
                DataTools="$env:ProgramData\VMware\VMware Tools"
                VGAuth="$env:ProgramData\VMware\VMware VGAuth"
            }
            $driverDir=$folders['Drivers']
            if (Test-Path $driverDir) {
                $allowed=@('efifw','memctl','mouse','pvscsi','video_wddm','vmci','vmxnet3','vss')
                if (@(Get-ChildItem $driverDir -Force | Where-Object Name -notin $allowed).Count) {
                    throw 'Unexpected content in Common Files VMware Drivers. Folder quarantine refused.'
                }
            }
            foreach ($label in $folders.Keys) {
                if (Test-Path -LiteralPath $folders[$label]) {
                    Move-Item -LiteralPath $folders[$label] -Destination (Join-Path $run $label)
                    Write-Host "Quarantined: $($folders[$label])"
                }
            }
        }
        Assert-PreservedInboxDrivers
        Write-Host 'CLEANUP PASS FINISHED. Reboot and run Audit. This is component cleanup, not proof of a complete MSI uninstall.'
    }
    Write-Host "Evidence and backups: $run"
} catch {
    Write-Host "STOPPED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Evidence/backups (if any): $run. See the transcript for completed actions. Do not restore an entire Run.reg blindly."
    throw
} finally { Stop-Transcript | Out-Null }
