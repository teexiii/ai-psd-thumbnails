#Requires -Version 5.1
<#
.SYNOPSIS
    Build the ai-psd-thumbnails MSI installer.

.DESCRIPTION
    1. Copies thumb_viewer.dll (release build) and pdfium.dll into installer\payload\.
    2. Copies installer-ca.exe (release build) into installer\payload\.
    3. Runs `wix build` to produce ai-psd-thumbnails-<version>.msi.

.PARAMETER Version
    Package version string (default: 0.4.0).  Must match the Version attribute in
    ai-psd-thumbnails.wxs.

.PARAMETER OutDir
    Directory to write the output MSI to (default: installer\).

.EXAMPLE
    .\installer\build-msi.ps1
    .\installer\build-msi.ps1 -Version 0.4.0 -OutDir dist\
#>
param(
    [string]$Version = "0.4.0",
    [string]$OutDir  = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# â”€â”€ Paths â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

$RepoRoot    = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$PayloadDir  = Join-Path $PSScriptRoot "payload"
$TargetDir   = Join-Path $RepoRoot "target\release"
$PdfiumSrc   = Join-Path $RepoRoot "third_party\bin\pdfium.dll"
$ThumbDllSrc = Join-Path $TargetDir "thumb_viewer.dll"
$CaExeSrc    = Join-Path $TargetDir "installer-ca.exe"
$MsiOut      = Join-Path $OutDir "ai-psd-thumbnails-$Version.msi"

# â”€â”€ Validate prerequisites â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

Write-Host "==> Checking prerequisites..."

if (-not (Get-Command wix -ErrorAction SilentlyContinue)) {
    Write-Error @"
WiX v4 CLI not found on PATH.
Install with:  dotnet tool install --global wix --version 4.0.6
Then add %USERPROFILE%\.dotnet\tools to PATH.
"@
}

if (-not (Test-Path $ThumbDllSrc)) {
    Write-Error "thumb_viewer.dll not found at: $ThumbDllSrc`nRun: cargo build --workspace --release"
}

if (-not (Test-Path $CaExeSrc)) {
    Write-Error "installer-ca.exe not found at: $CaExeSrc`nRun: cargo build --workspace --release"
}

if (-not (Test-Path $PdfiumSrc)) {
    Write-Error "pdfium.dll not found at: $PdfiumSrc`nEnsure third_party\bin\pdfium.dll is present (bblanchon chromium/7763 win-x64)."
}

# â”€â”€ Assemble payload â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

Write-Host "==> Assembling payload in: $PayloadDir"
New-Item -ItemType Directory -Path $PayloadDir -Force | Out-Null

Copy-Item -Path $ThumbDllSrc -Destination (Join-Path $PayloadDir "thumb_viewer.dll") -Force
Write-Host "    thumb_viewer.dll  <- $ThumbDllSrc"

Copy-Item -Path $PdfiumSrc   -Destination (Join-Path $PayloadDir "pdfium.dll") -Force
Write-Host "    pdfium.dll        <- $PdfiumSrc"

Copy-Item -Path $CaExeSrc    -Destination (Join-Path $PayloadDir "installer-ca.exe") -Force
Write-Host "    installer-ca.exe  <- $CaExeSrc"

# â”€â”€ Run wix build â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

$WxsSources = @(
    (Join-Path $PSScriptRoot "ai-psd-thumbnails.wxs")
    (Join-Path $PSScriptRoot "registry-shellex.wxs")
    (Join-Path $PSScriptRoot "format-selection.wxs")
)

Write-Host "==> Building MSI: $MsiOut"
Write-Host "    Sources: $($WxsSources -join ', ')"

# -arch x64: x64-only package (InstallerVersion=500 enforces 64-bit Windows).
# -ext WixToolset.Util.wixext: needed for util:RestartResource.
# Working directory set to installer\ so relative SourceFile paths in .wxs resolve correctly.
Push-Location $PSScriptRoot
try {
    & wix build `
        $WxsSources `
        -arch x64 `
        -ext WixToolset.Util.wixext `
        -ext WixToolset.UI.wixext `
        -o $MsiOut

    if ($LASTEXITCODE -ne 0) {
        Write-Error "wix build failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "==> MSI built successfully: $MsiOut"
Write-Host ""
Write-Host "NOTE: Do not install this MSI during automated builds -- installation"
Write-Host "      requires elevation and interactive registry verification."
Write-Host "      See installer\README.md for manual installation test instructions."




