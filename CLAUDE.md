# ai-psd-thumbnails

Windows Explorer thumbnail + preview-pane shell extension for `.ai .psd .psb .eps .svg`
(plus thumbnail-only `.pdf`), written in Rust (windows-rs), shipped as a per-machine x64 MSI. Design rationale lives in
`plans/260610-1131-thumb-viewer-shell-extension/`; this file is the operational reference.

## Architecture

```
crates/core          ai-psd-thumbnails-core   — pure decode/render, NO Win32 (unit-testable)
crates/shell         ai-psd-thumbnails-shell  — cdylib `thumb_viewer.dll`, COM in-proc server
crates/installer-ca  installer-ca        — MSI custom-action exe (2 verbs, see Installer)
installer/           WiX v4 authoring + build script
scripts/             dev register/unregister/cache-clear (elevated PowerShell)
third_party/bin/     pdfium.dll (bundled binary, see Pin below)
```

COM objects (both `ThreadingModel=Apartment`):

| Object | CLSID | Interfaces |
|---|---|---|
| Thumbnail provider | `{90E3822E-5F70-40BF-884E-77544797AD41}` | IThumbnailProvider, IInitializeWithStream |
| Preview handler | `{2CFC1F9E-0B23-48C3-AE46-29025209D0D4}` | IPreviewHandler, IInitializeWithStream, IObjectWithSite, IOleWindow |

Format → render path:

| Format | Fast path | Fallback |
|---|---|---|
| `.psd` | resource 1036 embedded JPEG thumb (RGB; 1033 = old BGR) | flattened composite |
| `.psb` | same (Image Resources section layout identical to PSD) | composite (RLE counts widen to 4 bytes) |
| `.ai` (PDF-style) | pdfium page-1 render | — |
| `.ai` (EPS-style) | DOS-EPS TIFF → `%AI_Thumbnail` → XMP `xmpGImg` JPEG | Ghostscript subprocess |
| `.eps` | DOS-EPS embedded TIFF preview → XMP `xmpGImg` JPEG | Ghostscript subprocess |
| `.svg` | resvg/usvg (external hrefs disabled, dims capped) | — |
| `.pdf` | pdfium page-1 render (same route as PDF-style `.ai`; magic `%PDF` → `Ext::Ai`) | — |

## Build

```powershell
cargo build -p ai-psd-thumbnails-core                  # decode lib only
cargo build -p ai-psd-thumbnails-shell --release       # → target/release/thumb_viewer.dll
```

Target: `x86_64-pc-windows-msvc` (x64 only). `.cargo/config.toml` links the MSVC CRT
statically (`+crt-static`): without it the DLL and the CA exe import `VCRUNTIME140.dll`, and the
MSI fails with 1603 on machines that lack the VC++ Redistributable. Keep it. The shell crate links `exports.def` so the four
COM entry points (`DllGetClassObject`, `DllCanUnloadNow`, `DllRegisterServer`,
`DllUnregisterServer`) export undecorated.

## Test

```powershell
cargo test --workspace --exclude installer-ca     # exclusion is REQUIRED
cargo run -p ai-psd-thumbnails-core --example dump -- assets/test-files/sample.svg out.png 256
```

- `--exclude installer-ca` is mandatory: the CA binary has an elevation manifest, so the test
  harness fails with OS error 740 trying to spawn it (it has no tests anyway).
- PDF-path tests need `pdfium.dll`; they skip gracefully when it can't be loaded. Override the
  search path with `PDFIUM_DLL_PATH=<dir>` (default: beside the executable, then
  `third_party/bin/`). Note: pdfium loads from PowerShell-launched processes; bash-launched
  test runs may fail `LoadLibraryExW` (error 126) — use PowerShell.

## Dev register / unregister (elevated PowerShell)

```powershell
scripts/dev-register.ps1      # copies pdfium.dll beside the DLL, then regsvr32 thumb_viewer.dll
scripts/dev-unregister.ps1
scripts/clear-thumb-cache.ps1 # kills dllhost/prevhost, clears thumbcache_*.db, restarts Explorer
```

Dev-loop gotchas:
- Explorer/dllhost/prevhost hold the DLL after first use — unregister + run
  `clear-thumb-cache.ps1` before rebuilding, or the linker fails with a locked-file error.
- The thumbnail cache masks changes: after re-registering, test with **freshly named copies**
  of fixture files, not ones Explorer has already thumbnailed.
- Verify OUR handler actually ran (not a cached/built-in one): Process Monitor filter on
  `dllhost.exe` / `prevhost.exe` loading `thumb_viewer.dll`.

## pdfium pin (exact, supply-chain-relevant)

| What | Value |
|---|---|
| Crate | `pdfium-render = "0.9.1"`, features `pdfium_7763`, `thread_safe`, `image_025` (plan said 0.9.2 — does not exist) |
| Binary | bblanchon `pdfium-binaries` tag `chromium/7763` (pdfium 148.0.7763.0), win-x64 |
| URL | https://github.com/bblanchon/pdfium-binaries/releases/tag/chromium%2F7763 |
| `pdfium.dll` SHA256 | `A63949DC46A7314BBA619AC6CC1B3849627E137F542AE31B2B36B302841F77AE` |

Contract: pdfium is bound **once per process** (`OnceLock`) and every pdfium call is serialized
process-wide via the crate's `thread_safe` feature (global FFI mutex). STA apartment threading
does NOT make this safe by itself — Explorer's surrogate runs multiple concurrent STA threads
against the shared instance. If you bump the crate, the `pdfium_XXXX` feature and the binary
tag must move together; record the new SHA256 here.

## MSI

```powershell
installer/build-msi.ps1       # assembles installer/payload/ + wix build → ai-psd-thumbnails-<ver>.msi
```

- WiX **4.0.6** via `dotnet tool install --global wix --version 4.0.6` (WiX ≥5 needs .NET 8;
  this machine has .NET 6) + `wix extension add --global WixToolset.Util.wixext/4.0.6`.
- Per-machine (HKLM, x64), MajorUpgrade enabled. Bundles `thumb_viewer.dll`, `pdfium.dll`,
  `installer-ca.exe` into `Program Files\ai-psd-thumbnails\`.
- Custom actions (`installer-ca.exe`): `restore-ai-progid` (deferred, no-impersonate —
  restores `.ai` → `Adobe.Illustrator.28` if a SageThumbs leftover hijacked it) and
  `notify-assoc-changed` (commit, **impersonated** — `SHChangeNotify` from session 0 is a
  silent no-op).
- Uninstall removes only our keys (declarative components). Install testing requires elevation:
  see `installer/README.md` for the manual test matrix.

## Registry contract (do not violate)

Everything we write lives in association-neutral locations; we NEVER touch a default ProgID,
file association, or OpenWith entry. `.ai` stays `Adobe.Illustrator.28`.

| Key | Value |
|---|---|
| `HKCR\SystemFileAssociations\.<ext>\ShellEx\{e357fccd-a995-4576-b01f-234630154e96}` | thumbnail CLSID |
| `HKCR\SystemFileAssociations\.<ext>\shellex\{8895b1c6-b41f-4c1c-a562-0d564250836f}` | preview CLSID |
| `HKCR\CLSID\{our two CLSIDs}` | InprocServer32, `ThreadingModel=Apartment` |
| `AppID` named **value** on preview CLSID | `{6d2b5079-2f0b-48dd-ab7f-97cec514d30b}` (prevhost) |

Thumbnail is registered for 6 exts (`.ai .psd .psb .eps .svg .pdf`); preview for 5 (NOT
`.pdf`). `.pdf` is thumbnail-only: Explorer ships no built-in `.pdf` thumbnail provider so the
`{e357fccd}` slot is free, but the preview pane is already owned by the OS/Edge PDF handler at
the ext level, which would shadow ours — so we don't author a `.pdf` preview row. Any
higher-precedence thumbnail handler a user installs later (Acrobat at ext/ProgID level) wins
over our `SystemFileAssociations` entry by design — we are a polite fallback, never a hijacker.
The split lives in `crates/shell/src/register.rs` (`THUMB_EXTS` vs `PREVIEW_EXTS`).

MSI: each extension's ShellEx components belong to their own optional feature
(`Handler_AI/PSD/PSB/EPS/PDF/SVG`, Level 1 = default on, chosen in `installer/format-selection.wxs`);
the DLLs, CLSIDs and PreviewHandlers entry stay in the hidden, always-installed `Complete`.
Keep these feature IDs and component GUIDs stable: MSI migrates feature selections across
upgrades by feature ID. Silent install: `ADDLOCAL=ALL REMOVE=Handler_SVG`. Validate with
`installer/test-msi.ps1 -Msi <msi> [-BaselineMsi <previous release msi>]`.

NEVER author, modify, or delete the `HKCR\AppID\{6d2b5079-...}` **key** itself — it is
OS-owned and shared by every preview handler on the machine.

## Feature flags

- `gs-fallback` (crates/core, **default-on**): renders previewless EPS / old EPS-style `.ai`
  by spawning the user's installed Ghostscript (`gswin64c.exe`/`gswin32c.exe`) as an isolated
  subprocess (`-dSAFER`, ppmraw output, 15s kill-timeout, no console window). Discovery:
  `GS_PROG` env → `Program Files[ (x86)]\gs\gs*\bin` → PATH; cached per process. Ghostscript
  (AGPL) is NEVER bundled, linked, or loaded in-process — only executed at arm's length if
  already installed; machines without it fall through to NoThumbnail. The default-on shift
  from the original off-by-default plan is intentional: the subprocess pattern removes the
  AGPL-linking concern that motivated the gate, and runtime detection is the real switch.

## Bootstrapper bundle (optional GS auto-install)

```powershell
installer/build-bundle.ps1    # → ai-psd-thumbnails-setup-<ver>.exe (builds the MSI first)
```

- WiX Burn bundle (`installer/bundle.wxs`, needs `WixToolset.Bal.wixext/4.0.6` global).
- Chains the OFFICIAL Ghostscript installer via `DownloadUrl` (fetched from the Artifex
  GitHub release at install time, SHA512-pinned in bundle.wxs — never embedded, so the
  setup exe distributes zero AGPL bytes) → then `ai-psd-thumbnails.msi`.
- Ghostscript step is skipped when any GS is already installed (HKLM `SOFTWARE\GPL
  Ghostscript`, both bitness views), is non-vital (decline/fail ≠ abort), and `Permanent`
  (uninstalling ai-psd-thumbnails never removes Ghostscript — separate ARP entry).
- When bumping the pinned GS release: update `DownloadUrl`, `Size`, and SHA512 `Hash` in
  bundle.wxs together.
