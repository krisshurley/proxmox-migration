#requires -Version 5.1
#requires -RunAsAdministrator
# Read-only configuration checks. Only report files are written.
[CmdletBinding()]
param([string]$ReportRoot='C:\temp\VMwareToolsCleanup')
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
$script:checks=New-Object System.Collections.Generic.List[object]
function Check {
    param([string]$Name,[scriptblock]$Read,[switch]$RequireOne)
    try {
        $items=@(& $Read)
        $status=if($RequireOne){if($items.Count -eq 1){'PASS'}else{'REVIEW'}}elseif($items.Count){'REVIEW'}else{'PASS'}
        $script:checks.Add([pscustomobject]@{Check=$Name;Status=$status;Count=$items.Count;Details=@($items|ForEach-Object {[string]$_})})
    } catch {$script:checks.Add([pscustomobject]@{Check=$Name;Status='NOT_CHECKED';Count=$null;Details=@($_.Exception.Message)})}
}
Check 'QEMU Guest Agent running' {
    $svc=Get-Service QEMU-GA
    if($svc.Status -eq 'Running'){'QEMU-GA Running'}
} -RequireOne
Check 'VMware Tools uninstall entries' {
    foreach($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')){
        if(Test-Path $root){foreach($key in Get-ChildItem $root){
            $v=Get-ItemProperty $key.PSPath
            if($v.PSObject.Properties['DisplayName'] -and $v.DisplayName -eq 'VMware Tools'){$key.Name}
        }}
    }
}
Check 'VMware Tools MSI product metadata' {
    foreach($root in @('HKLM:\SOFTWARE\Classes\Installer\Products','HKLM:\SOFTWARE\WOW6432Node\Classes\Installer\Products')){
        if(Test-Path $root){foreach($key in Get-ChildItem $root){
            $v=Get-ItemProperty $key.PSPath
            if($v.PSObject.Properties['ProductName'] -and $v.ProductName -eq 'VMware Tools'){$key.Name}
        }}
    }
    # Check product identity rather than a machine-specific or fixed product code.
    $root='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData'
    if(Test-Path $root){foreach($sid in Get-ChildItem $root){
        $productsPath=Join-Path $sid.PSPath 'Products'
        if(Test-Path $productsPath){foreach($product in Get-ChildItem $productsPath){
            $properties=Join-Path $product.PSPath 'InstallProperties'
            if(Test-Path $properties){
                $value=Get-ItemProperty $properties
                if($value.PSObject.Properties['DisplayName'] -and $value.DisplayName -eq 'VMware Tools'){$properties}
            }
        }}
    }}
}
Check 'VMware Snapshot Provider COM+ application' {
    $catalog=$null;$apps=$null
    try {
        $catalog=New-Object -ComObject COMAdmin.COMAdminCatalog
        $apps=$catalog.GetCollection('Applications');$apps.Populate()
        for($i=0;$i -lt $apps.Count;$i++){
            $app=$apps.Item($i)
            try {
                if($app.Name -eq 'VMware Snapshot Provider' -or $app.Value('ServiceName') -ieq 'vmvss'){
                    '{0}; ID={1}; Service={2}' -f $app.Name,$app.Value('ID'),$app.Value('ServiceName')
                }
            } finally {if([Runtime.InteropServices.Marshal]::IsComObject($app)){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($app)}}
        }
    } finally {
        foreach($obj in @($apps,$catalog)){if($null -ne $obj -and [Runtime.InteropServices.Marshal]::IsComObject($obj)){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($obj)}}
    }
}
Check 'VMware startup commands' {
    Get-CimInstance Win32_StartupCommand|Where-Object {$_.Command -match 'vmtoolsd|\\VMware\\VMware Tools\\'}|
        ForEach-Object {'{0}; {1}; {2}' -f $_.Name,$_.Location,$_.Command}
}
Check 'Guest Handler keys (machine and loaded users only)' {
    foreach($vendor in @('VMware, Inc.','VMware,Inc.')){
        foreach($root in @("HKLM:\SOFTWARE\$vendor\VMware Tools\GHI","HKLM:\SOFTWARE\WOW6432Node\$vendor\VMware Tools\GHI")){
            if(Test-Path -LiteralPath $root){$root}
        }
        foreach($hive in Get-ChildItem 'Registry::HKEY_USERS'){
            $path='Registry::'+$hive.Name+"\Software\$vendor\VMware Tools\GHI"
            if(Test-Path -LiteralPath $path){$path}
        }
    }
}
Check 'Active vmtoolsd processes' {
    Get-CimInstance Win32_Process|Where-Object {$_.Name -ieq 'vmtoolsd.exe' -or $_.ExecutablePath -like '*\VMware\VMware Tools\*'}|
        ForEach-Object {'{0}; PID={1}; {2}' -f $_.Name,$_.ProcessId,$_.ExecutablePath}
}
Check 'Nonempty Tools folders' {
    foreach($path in @("$env:ProgramFiles\VMware\VMware Tools","$env:CommonProgramFiles\VMware\Drivers",
        "$env:CommonProgramFiles\VMware\VMwareToolsInstallerCache","$env:ProgramData\VMware\VMware Tools","$env:ProgramData\VMware\VMware VGAuth")){
        if((Test-Path -LiteralPath $path) -and @(Get-ChildItem -LiteralPath $path -Force).Count){$path}
    }
}
$run=Join-Path $ReportRoot ('Final-'+(Get-Date -Format yyyyMMdd-HHmmss)+'-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run -Force|Out-Null
$script:checks|ConvertTo-Json -Depth 4|Set-Content (Join-Path $run 'final-checks.json') -Encoding UTF8
$report=@(
 'VMware cleanup final verification (read-only configuration checks)',
 ('Computer: '+$env:COMPUTERNAME),
 'Guest Handler scope excludes unloaded user profiles. No assertion that all file associations or all MSI component references are restored.',
 ''
 foreach($c in $script:checks){
  '[{0}] {1}; count={2}' -f $c.Status,$c.Check,$c.Count
  foreach($detail in $c.Details){'  '+$detail}
 }
)
$report|Set-Content (Join-Path $run 'final-checks.txt') -Encoding UTF8
$report|ForEach-Object {Write-Host $_}
Write-Host "Reports: $run"
