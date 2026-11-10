#Requires -Version 5.1
[CmdletBinding()]param()
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$count=0
function Assert($value,$message){if(-not $value){throw $message}}
function Throws([scriptblock]$run){$caught=$false;try{& $run|Out-Null}catch{$caught=$true};Assert $caught 'Expected blocked package'}
function Case($name,[scriptblock]$run){& $run;$script:count++;Write-Host "PASS $name"}
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Invoke-VMwareToolsMsiUninstall.ps1'),[ref]$t,[ref]$e)
Assert ($e.Count -eq 0) 'MSI worker syntax error'
foreach($fn in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
    Set-Item "function:script:$($fn.Name)" ([scriptblock]::Create($fn.Body.Extent.Text.Substring(1,$fn.Body.Extent.Text.Length-2)))
}
function Row([string]$name,[string]$type='257',[string]$source='package-instutil.dll',[string]$target='VMCheckRequirements') { [pscustomobject]@{Values=@($name,$type,$source,$target)} }
$code='{11111111-2222-3333-4444-555555555555}'
foreach($version in @('10.3.10','11.3.5','12.5.0','13.0.10.0','14.2.1.0')){
    Case "Matching identity is version-independent: $version (synthetic fixture)" {
        $properties=@([pscustomobject]@{Values=@('ProductCode',$code)},[pscustomobject]@{Values=@('ProductName','VMware Tools')},[pscustomobject]@{Values=@('ProductVersion',$version)})
        Assert-MsiIdentity $code 'VMware Tools' $version $properties
        Throws {Assert-MsiIdentity '{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}' 'VMware Tools' $version $properties}
        Throws {Assert-MsiIdentity $code 'Other Software' $version $properties}
        Throws {Assert-MsiIdentity $code 'VMware Tools' '99.0.0' $properties}
        Throws {Assert-MsiIdentity $code 'VMware Tools' $version @($properties+$properties[0])}
    }
}
Case 'Original 13.0.10 signatures still yield exactly the three tested changes' {
    $rows=@((Row VM_CheckRequirements 257 _toolsinstutil.dll VMCheckRequirements),(Row VM_LogStart 257 _toolsinstutil.dll VMLogStart),(Row VM_UninstGHIRestGuestHandle.869A7E00_8665_0000_83A8_EF0F76CF0001 3073 _toolsinstutil.dll VMUninstallGHIRestoreGuestHandlers))
    Assert (@(Get-ValidatedActionPlan $rows -SkipGuestHandlerRestore).Count -eq 3) 'Old package no longer recognized'
}
foreach($ghiActionName in @('VM_UninstGHIRestGuestHandle','VM_UninstGHIRestGuestHandle.AAAAAAAA_BBBB_CCCC_DDDD_EEEEEEEEEEEE')) {
    Case "Guest Handler name can use an absent or different GUID suffix: $ghiActionName" {
        $rows=@((Row $ghiActionName 3073 another-binary.dll VMUninstallGHIRestoreGuestHandlers))
        Assert ((@(Get-ValidatedActionPlan $rows -SkipGuestHandlerRestore) -join ',') -ceq $ghiActionName) 'Dynamic identity lost'
        Assert (@(Get-ValidatedActionPlan $rows).Count -eq 0) 'Guest Handler bypass applied without request'
    }
}
Case 'Missing individual actions need no fabricated deletion' {
    Assert ((@(Get-ValidatedActionPlan @((Row VM_CheckRequirements)) -SkipGuestHandlerRestore) -join ',') -eq 'VM_CheckRequirements') 'Missing log/GHI rejected'
    Assert ((@(Get-ValidatedActionPlan @((Row VM_LogStart 257 custom.dll VMLogStart)) -SkipGuestHandlerRestore) -join ',') -eq 'VM_LogStart') 'Missing requirement check rejected'
}
Case 'Unrelated custom actions are preserved in the full-table plan' {
    $rows=@((Row OtherAction 3073 other.dll OtherFunction),(Row VM_CheckRequirements))
    Assert ((@(Get-ValidatedActionPlan $rows -SkipGuestHandlerRestore) -join ',') -eq 'VM_CheckRequirements') 'Unrelated action selected'
}
Case 'Unknown or empty layout cannot authorize MSI modification' {
    Throws {Get-ValidatedActionPlan @((Row OtherAction)) -SkipGuestHandlerRestore}
    Throws {Get-ValidatedActionPlan @() -SkipGuestHandlerRestore}
}
Case 'Known-name/entrypoint mismatch, changed type and blank DLL fail closed' {
    Throws {Get-ValidatedActionPlan @((Row VM_CheckRequirements 257 a.dll OtherFunction))}
    Throws {Get-ValidatedActionPlan @((Row RenamedCheck 257 a.dll VMCheckRequirements))}
    Throws {Get-ValidatedActionPlan @((Row VM_CheckRequirements 1 a.dll VMCheckRequirements))}
    Throws {Get-ValidatedActionPlan @((Row VM_CheckRequirements 257 '' VMCheckRequirements))}
    Throws {Get-ValidatedActionPlan @((Row VM_UninstGHIRestGuestHandle.invalid 3073 a.dll VMUninstallGHIRestoreGuestHandlers)) -SkipGuestHandlerRestore}
}
Case 'Multiple actions with the same semantic role and duplicate names are refused' {
    $row=Row VM_CheckRequirements
    Throws {Get-ValidatedActionPlan @($row,$row)}
    Throws {Get-ValidatedActionPlan @($row,(Row VM_CheckRequirements.AAAAAAAA_BBBB_CCCC_DDDD_EEEEEEEEEEEE))}
}
Case 'Selected DLL references must identify exactly one real Binary table stream' {
    $rows=@((Row VM_CheckRequirements));$plan=@('VM_CheckRequirements');$binary=[pscustomobject]@{Values=@('package-instutil.dll')}
    Assert-MsiActionBinaryReferences $rows $plan @($binary)
    Throws {Assert-MsiActionBinaryReferences $rows $plan @()}
    Throws {Assert-MsiActionBinaryReferences $rows $plan @($binary,$binary)}
}
function Fixture {
    $script:original=@((Row VM_CheckRequirements),(Row VM_LogStart 257 a.dll VMLogStart),(Row Unrelated 3073 b.dll KeepThisFunction))
    $script:table=@($script:original);$script:sql=@();$script:damage=$false;$script:retain=$false
}
function Invoke-ComMethod {
    param($Object,$Method,$Arguments)
    if($Method -eq 'OpenView'){
        $sql=[string]$Arguments[0];$script:sql+=@($sql)
        Assert ($sql -match '^DELETE FROM `CustomAction` WHERE `Action` = ''([^'']+)''$') 'SQL does not target exact inspected action'
        return $Matches[1]
    }
    if($Method -eq 'Execute'){
        if(-not $script:retain){$script:table=@($script:table|Where-Object {$_.Values[0] -ne $Object})}
        if($script:damage){$script:table=@()}
    }
}
function Read-MsiRows {param($Database,$Query,$Columns) $script:table}
function Release-Com {param($Value)}
Case 'Mutation deletes only selected rows and preserves every other field' {
    Fixture
    Set-MsiActionChanges dummy $original @('VM_CheckRequirements')
    Assert ($table.Count -eq 2 -and $table[0].Values[0] -eq 'VM_LogStart' -and $table[1].Values[3] -eq 'KeepThisFunction') 'Unrelated rows changed'
    Assert ($sql.Count -eq 1) 'Extra mutation attempted'
}
Case 'Retained selected action or missing unrelated row prevents transaction commit' {
    Fixture;$script:retain=$true;Throws {Set-MsiActionChanges dummy $original @('VM_CheckRequirements')}
    Fixture;$script:damage=$true;Throws {Set-MsiActionChanges dummy $original @('VM_CheckRequirements')}
}
Case 'Changed unrelated action content prevents transaction commit' {
    Fixture
    function Read-MsiRows {param($Database,$Query,$Columns)
        foreach($row in $script:table){if($row.Values[0] -eq 'Unrelated'){Row Unrelated 3073 b.dll ChangedFunction}else{$row}}
    }
    Throws {Set-MsiActionChanges dummy $original @('VM_CheckRequirements')}
}
Write-Host "Passed $count dynamic MSI tests. Packages are synthetic fixtures, not Windows compatibility claims."
