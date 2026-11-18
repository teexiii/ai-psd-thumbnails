param(
    [Parameter(Mandatory=$true)][string]$Msi,
    [string]$BaselineMsi
)
# Read-only database inspection and native costing. Never executes installation.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Get-ComProperty($Object, [string]$Name, $Arguments) {
    $Object.GetType().InvokeMember($Name, 'GetProperty', $null, $Object, $Arguments)
}
function Set-ComProperty($Object, [string]$Name, $Arguments) {
    $null = $Object.GetType().InvokeMember($Name, 'SetProperty', $null, $Object, $Arguments)
}
function Get-Rows($Database, [string]$Table) {
    $view = $Database.OpenView("SELECT * FROM ``$Table``")
    $null = $view.Execute()
    try {
        while ($record = $view.Fetch()) {
            $row = @()
            for ($n = 1; $n -le (Get-ComProperty $record 'FieldCount' $null); $n++) {
                $row += Get-ComProperty $record 'StringData' @($n)
            }
            ,$row
        }
    } finally { $null = $view.Close() }
}
$installer = New-Object -ComObject WindowsInstaller.Installer
$msiPath = (Resolve-Path $Msi).Path
$db = $installer.OpenDatabase($msiPath, 0)
$formats = @('AI','PSD','PSB','EPS','PDF','SVG')
$features = @(Get-Rows $db 'Feature')
$membership = @(Get-Rows $db 'FeatureComponents')
$registry = @(Get-Rows $db 'Registry')
$components = @(Get-Rows $db 'Component')
$events = @(Get-Rows $db 'ControlEvent')
$controls = @(Get-Rows $db 'Control')
$sequence = @(Get-Rows $db 'InstallUISequence')
Assert ($features.Count -eq 7) 'Expected shared core and six format features'
foreach ($ext in $formats) {
    $feature = @($features | Where-Object { $_[0] -eq "Handler_$ext" })
    Assert ($feature.Count -eq 1 -and $feature[0][5] -eq '1') "$ext must default to level 1"
    $members = @($membership | Where-Object { $_[0] -eq "Handler_$ext" } | ForEach-Object { $_[1] })
    $expected = if ($ext -eq 'PDF') { 1 } else { 2 }
    Assert ($members.Count -eq $expected) "Wrong registration count for $ext"
    foreach ($member in $members) {
        $values = @($registry | Where-Object { $_[5] -eq $member })
        Assert ($values.Count -eq 1) "Expected one value per extension component: $member"
        Assert ($values[0][2] -like "SystemFileAssociations\.$($ext.ToLower())\*") "Cross-format registry ownership: $member"
        Assert (@($membership | Where-Object { $_[1] -eq $member }).Count -eq 1) "Shared optional component: $member"
    }
    Assert (@($controls | Where-Object { $_[0] -eq 'FormatsDlg' -and $_[1] -eq $ext -and $_[2] -eq 'CheckBox' }).Count -eq 1) "Missing $ext checkbox"
    foreach ($event in @('AddLocal','Remove')) {
        Assert (@($events | Where-Object { $_[0] -eq 'FormatsDlg' -and $_[1] -eq 'Next' -and $_[2] -eq $event -and $_[3] -eq "Handler_$ext" }).Count -eq 1) "Missing $event for $ext"
    }
    $init = @($sequence | Where-Object { $_[0] -eq "SetFORMAT_$ext" })
    $migration = @($sequence | Where-Object { $_[0] -eq 'MigrateFeatureStates' })
    $welcome = @($sequence | Where-Object { $_[0] -eq 'WelcomeDlg' })
    Assert ([int]$init[0][2] -gt [int]$migration[0][2] -and [int]$init[0][2] -lt [int]$welcome[0][2]) 'Checkbox initialization must follow migration and precede welcome'
}
# Exhaustively ask the actual MSI engine to cost all 64 feature combinations.
# ADDLOCAL is the unattended equivalent of the checkbox AddLocal/Remove events.
for ($mask = 0; $mask -lt 64; $mask++) {
    $session = $installer.OpenPackage($msiPath, 1)
    try {
        $selected = @('Complete')
        for ($n = 0; $n -lt 6; $n++) {
            if ($mask -band (1 -shl $n)) { $selected += "Handler_$($formats[$n])" }
        }
        Set-ComProperty $session 'Property' @('ADDLOCAL', ($selected -join ','))
        foreach ($action in @('CostInitialize','FileCost','CostFinalize')) {
            Assert ($session.DoAction($action) -eq 1) "Costing failed: $action, mask $mask"
        }
        Assert ((Get-ComProperty $session 'FeatureRequestState' @('Complete')) -eq 3) "Shared engine absent: $mask"
        foreach ($component in $components) {
            $owner = @($membership | Where-Object { $_[1] -eq $component[0] })[0][0]
            $wanted = if ($selected -contains $owner) { 3 } else { 2 }
            $state = Get-ComProperty $session 'ComponentRequestState' @($component[0])
            Assert (($wanted -eq 3 -and $state -eq 3) -or ($wanted -eq 2 -and $state -in @(-1,2))) "Unexpected component plan: $($component[0]), mask $mask, state $state"
        }
        # Check native evaluation of the AI action guard for every combination.
        Assert ($session.EvaluateCondition('&Handler_AI = 3') -eq [int]($selected -contains 'Handler_AI')) "Incorrect AI action guard: $mask"
    } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($session) }
}
# Explicit SVG removal (used by unattended installers) must not change any other feature.
$session = $installer.OpenPackage($msiPath, 1)
try {
    Set-ComProperty $session 'Property' @('ADDLOCAL', 'ALL')
    Set-ComProperty $session 'Property' @('REMOVE', 'Handler_SVG')
    foreach ($action in @('CostInitialize','FileCost','CostFinalize')) { Assert ($session.DoAction($action) -eq 1) $action }
    foreach ($feature in $features) {
        $wanted = if ($feature[0] -eq 'Handler_SVG') { 2 } else { 3 }
        $actual = Get-ComProperty $session 'FeatureRequestState' @($feature[0])
        Assert (($wanted -eq 3 -and $actual -eq 3) -or ($wanted -eq 2 -and $actual -in @(-1,2))) "SVG removal changed another feature: $($feature[0])"
    }
} finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($session) }
$execute = @(Get-Rows $db 'InstallExecuteSequence')
Assert (@($execute | Where-Object { $_[0] -eq 'CA_RestoreAiProgId' -and $_[1] -eq '&Handler_AI = 3' }).Count -eq 1) 'AI cleanup must depend on the AI feature'
Assert (@($execute | Where-Object { $_[0] -eq 'CA_NotifyAssocChanged' -and $_[1] -eq 'NOT UPGRADINGPRODUCTCODE' }).Count -eq 1) 'Refresh must cover final uninstall and skip old-product removal'
$upgrade = @(Get-Rows $db 'Upgrade' | Where-Object { $_[6] -eq 'WIX_UPGRADE_DETECTED' })
Assert ($upgrade.Count -eq 1 -and ([int]$upgrade[0][4] -band 1) -eq 1) 'Feature migration must remain enabled'
$removeOld = @($execute | Where-Object { $_[0] -eq 'RemoveExistingProducts' })
$initialize = @($execute | Where-Object { $_[0] -eq 'InstallInitialize' })
$process = @($execute | Where-Object { $_[0] -eq 'ProcessComponents' })
Assert ([int]$removeOld[0][2] -gt [int]$initialize[0][2] -and [int]$removeOld[0][2] -lt [int]$process[0][2]) 'Keep old-product removal transactional and before new components'
# No unattended overrides: all six on, shared core on.
$session = $installer.OpenPackage($msiPath, 1)
try {
    foreach ($action in @('CostInitialize','FileCost','CostFinalize')) { Assert ($session.DoAction($action) -eq 1) $action }
    foreach ($feature in $features) {
        Assert ((Get-ComProperty $session 'FeatureRequestState' @($feature[0])) -eq 3) "Default feature absent: $($feature[0])"
    }
} finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($session) }
if ($BaselineMsi) {
    $oldDb = $installer.OpenDatabase((Resolve-Path $BaselineMsi).Path, 0)
    $oldComponents = @(Get-Rows $oldDb 'Component')
    $oldRegistry = @(Get-Rows $oldDb 'Registry')
    foreach ($old in $oldComponents) {
        $new = @($components | Where-Object { $_[0] -eq $old[0] })
        Assert ($new.Count -eq 1 -and ($new[0] -join '|') -eq ($old -join '|')) "Existing component identity/key path changed: $($old[0])"
    }
    foreach ($old in $oldRegistry) {
        # The product version marker legitimately differs between releases.
        if ($old[5] -eq 'CMP_InstallMarker') { continue }
        $new = @($registry | Where-Object { $_[0] -eq $old[0] })
        Assert ($new.Count -eq 1 -and ($new[0] -join '|') -eq ($old -join '|')) "Existing registry row changed: $($old[0])"
    }
}
Write-Output 'PASS: MSI schema/ownership, six checkboxes, initialization sequence, 64 native component plans, default all-on, SVG removal, migration/removal sequencing, AI guard, optional baseline identity check.'
