#Requires -Version 5.1
<# Limited cleanup for previously migrated QEMU/KVM guests. No capture is required.
   Preserves MSI/uninstall metadata, COM+, files, drivers and network configuration. #>
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
param([string]$ReportRoot='C:\temp\VMware-LegacyCleanup')
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Migration.Common.ps1')
function Assert-LegacyToolsTarget {
    $id=[Security.Principal.WindowsIdentity]::GetCurrent()
    $principal=New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run elevated Windows PowerShell as Administrator.' }
    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell.' }
    $computer=Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    if ($computer.Manufacturer -notmatch 'QEMU|Red Hat' -and $computer.Model -notmatch 'QEMU|KVM') { throw 'Limited cleanup requires a verified QEMU/KVM guest.' }
    if ((Get-Service QEMU-GA -ErrorAction Stop).Status -ne 'Running') { throw 'QEMU Guest Agent must be running.' }
    $null=Assert-MigrationFirstbootComplete
}
function Get-LegacyToolsServicePlan {
    $files=@{VMTools=@('vmtoolsd.exe');VGAuthService=@('VMware VGAuth\VGAuthService.exe','VGAuthService.exe');VM3DService=@('vm3dservice.exe');VMVss=@('vmware-vss.exe','vmvss.exe')}
    $roots=@($env:ProgramFiles,${env:ProgramFiles(x86)}|Where-Object {$_}|ForEach-Object {$_.TrimEnd('\')+'\VMware\VMware Tools\'})
    foreach($name in @('VMTools','VGAuthService','VM3DService','VMVss')) {
        $found=@(Get-CimInstance -ClassName Win32_Service -Filter "Name='$name'" -ErrorAction Stop)
        if (-not $found.Count) { continue }
        if ($found.Count -ne 1 -or $found[0].Name -ine $name) { throw "Ambiguous service identity: $name" }
        $svc=$found[0]
        $expected=@(foreach($root in $roots){foreach($file in $files[$name]){$root+$file}})
        $verified=$false
        foreach($exe in $expected){if($svc.PathName -match ('^\s*(?:"'+[regex]::Escape($exe)+'"|'+[regex]::Escape($exe)+')\s*$')){$verified=$true}}
        $reason=''
        if (-not $verified) { $reason='Unexpected executable or COM+-managed service; left unchanged for manual review.' }
        elseif ($svc.State -ne 'Stopped' -or [int]$svc.ProcessId -ne 0) { $reason='Service is not verified stopped with process ID zero; left unchanged.' }
        [pscustomobject]@{name=$name;pathName=[string]$svc.PathName;state=[string]$svc.State;processId=[int]$svc.ProcessId;eligible=($reason -eq '');reason=$reason}
    }
}
function Get-LegacyToolsStartupPlan {
    $roots=@($env:ProgramFiles,${env:ProgramFiles(x86)}|Where-Object {$_}|ForEach-Object {$_.TrimEnd('\')+'\VMware\VMware Tools\vmtoolsd.exe'})
    foreach($path in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $key=Get-Item -LiteralPath $path -ErrorAction Stop
        $name='VMware User Process'
        if ($name -notin @($key.GetValueNames())) { continue }
        $kind=[string]$key.GetValueKind($name)
        $value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $verified=$false
        if ($kind -in @('String','ExpandString') -and $value -is [string]) {
            foreach($exe in $roots){if($value -match ('^\s*(?:"'+[regex]::Escape($exe)+'"|'+[regex]::Escape($exe)+')\s+-n\s+vmusr\s*$')){$verified=$true}}
        }
        [pscustomobject]@{path=$path;name=$name;value=$value;kind=$kind;eligible=$verified;reason=$(if($verified){''}else{'Unexpected startup command; left unchanged.'})}
    }
}
function Invoke-LegacyToolsNative {
    param([ValidateSet('reg.exe','sc.exe')][string]$File,[string[]]$Arguments)
    & $File @Arguments 2>&1|Out-Host
    return [int]$LASTEXITCODE
}
function Invoke-LegacyToolsRemoval {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param([string]$ReportRoot)
    Assert-LegacyToolsTarget
    $services=@(Get-LegacyToolsServicePlan)
    $startup=@(Get-LegacyToolsStartupPlan)
    $todoServices=@($services|Where-Object eligible)
    $todoStartup=@($startup|Where-Object eligible)
    $review=@($services|Where-Object {-not $_.eligible})+@($startup|Where-Object {-not $_.eligible})
    Write-Host "Limited Tools cleanup: $($todoServices.Count) stopped services, $($todoStartup.Count) verified machine startup values; $($review.Count) review items."
    foreach($row in $review){Write-Warning ($row.reason+' '+($row|ConvertTo-Json -Depth 3 -Compress))}
    Write-Host 'MSI registration, Programs entries, COM+, drivers, files and network settings will be preserved.'
    if ($WhatIfPreference) {
        $null=$PSCmdlet.ShouldProcess($env:COMPUTERNAME,'Back up and delete only the listed eligible Tools service registrations and startup values')
        $todoServices|Format-Table name,pathName|Out-Host
        $todoStartup|Format-Table path,name,value|Out-Host
        return 0
    }
    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME,'Back up and delete verified stopped Tools services and startup values; preserve MSI, COM+, files, drivers and network')) { return 1 }
    $lock=$null;$run=$null;$actions=New-Object System.Collections.ArrayList
    try {
        $lock=Enter-MigrationInstallerExecutionLock
        Assert-MigrationNoInstallerClients
        Assert-LegacyToolsTarget
        $run=Join-Path $ReportRoot ((Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $run -Force -ErrorAction Stop|Out-Null
        # Save only plain records. The startup JSON contains exact value/type data,
        # not an entire Run key to blindly restore over unrelated software.
        [pscustomobject]@{computerName=$env:COMPUTERNAME;services=$services;startup=$startup}|
            ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $run 'Before.json') -Encoding UTF8 -ErrorAction Stop
        foreach($svc in $todoServices) {
            $backup=Join-Path $run ($svc.name+'.reg')
            $code=Invoke-LegacyToolsNative reg.exe @('export',('HKLM\SYSTEM\CurrentControlSet\Services\'+$svc.name),$backup,'/y')
            if ($code -ne 0 -or -not (Test-Path -LiteralPath $backup -PathType Leaf) -or (Get-Item -LiteralPath $backup).Length -eq 0) { throw "Registry backup failed for $($svc.name); no deletions started." }
        }
        foreach($svc in $todoServices) {
            Assert-LegacyToolsTarget
            Assert-MigrationNoInstallerClients
            $current=@(Get-LegacyToolsServicePlan|Where-Object name -eq $svc.name)
            if (-not $current.Count) { continue }
            if ($current.Count -ne 1 -or -not $current[0].eligible -or $current[0].pathName -ine $svc.pathName) { throw "Service changed after backup: $($svc.name)" }
            $code=Invoke-LegacyToolsNative sc.exe @('delete',$svc.name)
            if ($code -notin @(0,1060,1072)) { throw "sc.exe delete failed for $($svc.name): $code" }
            [void]$actions.Add([pscustomobject]@{type='Service';name=$svc.name;state='RemovedOrPending';exitCode=$code})
        }
        foreach($entry in $todoStartup) {
            Assert-LegacyToolsTarget
            Assert-MigrationNoInstallerClients
            $current=@(Get-LegacyToolsStartupPlan|Where-Object {$_.path -eq $entry.path -and $_.name -eq $entry.name})
            if (-not $current.Count) { continue }
            if ($current.Count -ne 1 -or -not $current[0].eligible -or $current[0].value -cne $entry.value -or $current[0].kind -ne $entry.kind) { throw 'Startup identity changed after backup.' }
            Remove-ItemProperty -LiteralPath $entry.path -Name $entry.name -ErrorAction Stop
            [void]$actions.Add([pscustomobject]@{type='Startup';path=$entry.path;name=$entry.name;state='Removed'})
        }
        $remainingServices=@(Get-LegacyToolsServicePlan)
        $remainingStartup=@(Get-LegacyToolsStartupPlan)
        $status=if($remainingServices.Count -or $remainingStartup.Count){'ReviewRequired'}else{'CompleteWithinLimitedScope'}
        $report=[pscustomobject]@{computerName=$env:COMPUTERNAME;status=$status;scope='Limited service/startup cleanup, not MSI uninstall';actions=@($actions);remainingServices=$remainingServices;remainingStartup=$remainingStartup;error=''}
        $report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $run 'Report.json') -Encoding UTF8 -ErrorAction Stop
        @("Limited VMware Tools cleanup: $status",'This is not a full uninstall. MSI/Programs, COM+, files, drivers and network were preserved.',
          'Before.json contains startup value backups; service registry backups are separate .reg files.',
          'Service deletion may remain pending until handles close or a planned restart. No automatic restart was performed.',
          ($report|ConvertTo-Json -Depth 6))|Set-Content -LiteralPath (Join-Path $run 'Report.txt') -Encoding UTF8 -ErrorAction Stop
        Write-Host "Limited cleanup result: $status. Reports and backups: $run"
        if ($status -eq 'ReviewRequired') { return 1 }
        return 0
    } catch {
        if ($run -and (Test-Path -LiteralPath $run)) {
            [pscustomobject]@{status='Stopped';error=$_.Exception.Message;actions=@($actions)}|ConvertTo-Json -Depth 5|
                Set-Content -LiteralPath (Join-Path $run 'Failure.json') -Encoding UTF8
        }
        throw
    } finally {Exit-MigrationInstallerExecutionLock $lock}
}
try {
    $result=Invoke-LegacyToolsRemoval -ReportRoot $ReportRoot -WhatIf:$WhatIfPreference
    exit ([int]$result)
} catch {Write-Error $_ -ErrorAction Continue;exit 2}
