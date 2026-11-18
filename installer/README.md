# ai-psd-thumbnails MSI Installer

WiX v4 per-machine x64 MSI that installs the ai-psd-thumbnails shell extension.

## Build Prerequisites

| Prerequisite | Version | Install command |
|---|---|---|
| .NET SDK | 6.0+ | https://dotnet.microsoft.com/download |
| WiX v4 CLI | 4.0.6 | `dotnet tool install --global wix --version 4.0.6` |
| WixToolset.Util.wixext | 4.0.6 | `wix extension add --global WixToolset.Util.wixext/4.0.6` |
| WixToolset.UI.wixext | 4.0.6 | `wix extension add --global WixToolset.UI.wixext/4.0.6` |
| Rust / cargo | 1.75+ x64-MSVC | https://rustup.rs |

After installing WiX, add `%USERPROFILE%\.dotnet\tools` to your `PATH`.

## Build

```powershell
# From repo root — builds all crates including installer-ca.exe
cargo build --workspace --release

# Assemble payload and produce MSI
.\installer\build-msi.ps1
```

Output: `installer\ai-psd-thumbnails-0.4.0.msi`

## Selecting formats

The MSI presents six checkboxes: AI, PSD, PSB, EPS, PDF and SVG. All are
selected on a fresh installation. PDF registers thumbnails only, as before.
The setup EXE shows this MSI dialog during interactive installation too.
Use the MSI's **Change** maintenance option to change formats later.

`Complete` retains the shared DLLs, COM classes and preview-handler enumeration.
Each `Handler_<FORMAT>` feature owns only that extension's existing registry
components. Their GUIDs and key paths are unchanged. Deselecting SVG affects only
its thumbnail and preview values; it never removes the common COM engine.
Selecting no formats is allowed and leaves the shared engine installed.

For unattended MSI installation, use standard MSI feature properties (not the
UI's checkbox properties):

```powershell
# Fresh install: all handlers except SVG
msiexec /i ai-psd-thumbnails-0.4.0.msi /qn ADDLOCAL=ALL REMOVE=Handler_SVG

# Fresh install: only PSD and PSB, with the required shared engine
msiexec /i ai-psd-thumbnails-0.4.0.msi /qn ADDLOCAL=Complete,Handler_PSD,Handler_PSB

# Maintenance: remove SVG, keeping the other installed features
msiexec /i ai-psd-thumbnails-0.4.0.msi /qn REMOVE=Handler_SVG
```

Checkboxes are initialized after `CostFinalize`/`MigrateFeatureStates`, using
MSI's resolved feature states. Back/Next retains the user's choices. Stable
feature IDs allow later major upgrades to migrate selected/absent states;
upgrading the old single-feature package enables all newly introduced features
by default. Explicit `ADDLOCAL`/`REMOVE` overrides take precedence over migration.
Retain the existing early `RemoveExistingProducts` schedule: old registrations
are removed inside the transaction before selected new components are written.
Do not distribute this as a same-version replacement: the maintainer must assign
a newer product version when releasing it.

The existing SageThumbs AI cleanup now runs only when AI is requested locally.
Association-change notification also runs after format removal/final uninstall,
but skips the old-product removal phase of a major upgrade.

MSI does not save/restore another provider's previous registry values. Leaving
SVG unchecked on a fresh install avoids writing its registration. Removing SVG
from an existing installation deletes this product's registered values; it does
not automatically restore a provider previously overwritten. An upgrade from
the old all-format MSI still uninstalls that old MSI's SVG components. If a
third-party provider has subsequently replaced those same values, the old MSI
may delete them: re-register that provider after the upgrade. No new registry
cleanup actions or broad key deletions are introduced here.

### Installer regression checks

```powershell
.\installer\test-msi.ps1 -Msi .\installer\ai-psd-thumbnails-0.4.0.msi
# Optionally compare component/registry identities with the official old MSI:
.\installer\test-msi.ps1 -Msi .\installer\ai-psd-thumbnails-0.4.0.msi -BaselineMsi .\ai-psd-thumbnails-0.3.0.msi
wix msi validate .\installer\ai-psd-thumbnails-0.4.0.msi
```

The regression script reads MSI tables and costs all 64 combinations with the
native MSI engine. It never installs or writes shell registrations. On a clean
Windows VM, additionally verify:

- Fresh install: defaults all checked; clear only SVG with an existing SVG provider,
  then confirm that provider's values are unchanged and all other handlers work.
- Back/Next, cancellation, keyboard navigation and all-unchecked selection.
- Change: disable and re-enable each format; repair must not re-enable absent ones.
- Upgrade 0.3.0 to a newer version with SVG unchecked; then upgrade between two
  newer versions and confirm that unchecked features stay absent. Repeat silently.
- Uninstall and forced-failure rollback: remove only owned registrations/files,
  preserve the OS-owned surrogate AppID and unrelated values, restore the prior
  product/feature states on failed upgrade. Verify Explorer refresh after removal.
- Interactive setup EXE reaches the checkbox page; silent setup stays silent.

## What Gets Installed

- `%ProgramFiles%\ai-psd-thumbnails\thumb_viewer.dll` — COM shell extension (thumbnail + preview)
- `%ProgramFiles%\ai-psd-thumbnails\pdfium.dll` — bblanchon pdfium-binaries chromium/7763 win-x64

### Registry (per-machine HKLM/HKCR, declarative, clean rollback on uninstall)

| Key | Value |
|---|---|
| `HKCR\CLSID\{90E3822E...}\InprocServer32` | `[ProgramFiles]\ai-psd-thumbnails\thumb_viewer.dll`, `ThreadingModel=Apartment` |
| `HKCR\CLSID\{2CFC1F9E...}\InprocServer32` | same dll, `ThreadingModel=Apartment` |
| `HKCR\CLSID\{2CFC1F9E...}` | `AppID={6d2b5079-...}` (value only; the OS-owned `HKCR\AppID\{6d2b5079-...}` key is never touched) |
| `HKCR\SystemFileAssociations\.<ext>\ShellEx\{e357fccd-...}` | `{CLSID-A}` (selected .ai .psd .psb .eps .svg .pdf) |
| `HKCR\SystemFileAssociations\.<ext>\shellex\{8895b1c6-...}` | `{CLSID-B}` (selected .ai .psd .psb .eps .svg) |
| `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\PreviewHandlers\{2CFC1F9E-...}` | `"ai-psd-thumbnails Preview"` |

**Never authored:** `HKCR\.<ext>` default (ProgID), `HKCR\.<ext>\ShellEx`, `HKCR\AppID\{6d2b5079-...}`.

### Custom Actions

| CA | Schedule | Impersonate | Action |
|---|---|---|---|
| `CA_RestoreAiProgId` | deferred (elevated) | no (SYSTEM) | Reads `HKCR\.ai` default; if `SageThumbsImage.ai` → restores to `Adobe.Illustrator.28`. No-op otherwise. Runs only when AI is selected locally. |
| `CA_NotifyAssocChanged` | commit | yes (user session) | `SHChangeNotify(SHCNE_ASSOCCHANGED)` so Explorer refreshes without manual cache clear. Also runs on final uninstall; skips old-product removal during upgrade. |

## Manual Installation Test Instructions

> Do NOT install during automated CI builds — requires elevation and interactive session.

1. Build the MSI: `.\installer\build-msi.ps1`
2. Open an elevated PowerShell prompt.
3. Install: `msiexec /i installer\ai-psd-thumbnails-0.1.0.msi /l*v install.log`
4. Verify registry with regedit:
   - `HKCR\SystemFileAssociations\.ai\ShellEx\{e357fccd-...}` = `{90E3822E-...}`
   - `HKCR\SystemFileAssociations\.ai\shellex\{8895b1c6-...}` = `{2CFC1F9E-...}`
   - Repeat for .psd .psb .eps .svg
   - `HKCR\AppID\{6d2b5079-...}` still has `DllSurrogate=...prevhost.exe` (unchanged)
5. Open Explorer, navigate to a folder with .ai/.psd/.psb/.eps/.svg files.
   - Thumbnails should appear. Use ProcMon to confirm `dllhost.exe` loads OUR DLL (not a cached/embedded thumbnail).
   - Press Alt+P for preview pane; select a file. Preview should render.
6. Test SageThumbs cleanup:
   ```powershell
   # Set leftover
   reg add "HKCR\.ai" /ve /d "SageThumbsImage.ai" /f
   # Repair install
   msiexec /fv installer\ai-psd-thumbnails-0.1.0.msi /l*v repair.log
   # Verify restored
   (Get-ItemProperty "HKCR:\.ai")."(default)"  # should be Adobe.Illustrator.28
   ```
7. Upgrade test: bump version to 0.2.0 in `ai-psd-thumbnails.wxs`, rebuild MSI, install over 0.1.0. No duplicate keys; DLL replaced.
8. Uninstall:
   ```powershell
   msiexec /x installer\ai-psd-thumbnails-0.1.0.msi /l*v uninstall.log
   ```
   - Our registry keys removed; `HKCR\AppID\{6d2b5079-...}` still present.
   - Other preview handlers (Office PDF etc.) still work.

## DLL Locked During Upgrade / Uninstall

RestartManager is configured to ask Explorer/dllhost/prevhost to release the DLL.
Real-world effect is limited since Explorer re-loads shell-extension DLLs on demand
and dllhost/prevhost surrogates are short-lived. If the MSI reports a reboot is needed,
run the cache-clearing script first:

```powershell
# From an elevated PowerShell — kills dllhost/prevhost and clears thumbcache
.\scripts\clear-thumb-cache.ps1
# Then retry the upgrade/uninstall
```

## pdfium.dll Provenance

`third_party\bin\pdfium.dll` is sourced from [bblanchon/pdfium-binaries](https://github.com/bblanchon/pdfium-binaries)
release tag `chromium/7763`, asset `pdfium-win-x64.tgz`. Verify SHA-256 against the
release manifest before distributing.

## Code-Signing

The MSI is not code-signed in this build. For distribution, sign with:
```powershell
signtool sign /fd sha256 /tr http://timestamp.digicert.com /td sha256 `
    /f <cert.pfx> /p <password> installer\ai-psd-thumbnails-0.1.0.msi
```
