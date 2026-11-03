# CDiskDoctor · C: Drive Space Doctor

> A dependency-free Windows tool for diagnosing, cleaning, and relocating C: drive space. Pure PowerShell, no network access, no telemetry.

**English** | [中文](README.md)

When your C: drive runs out of space, the usual advice is "clear temp files". But the real culprits are usually **application data inside AppData** — WeChat, Feishu, CapCut, WPS and friends can each occupy several gigabytes.

CDiskDoctor does three things:

1. **See** — scan the entire C: drive and show where the space actually went
2. **Clean** — remove confirmed junk from a strict whitelist, skipping any file in use
3. **Relocate** — move large directories to another drive and leave a junction behind, so applications keep working unchanged

---

## Quick start

```
1. Download this repository (Code → Download ZIP, or git clone)
2. Extract it anywhere
3. Right-click Run.cmd → Run as administrator
4. Choose 1 to generate a report (read-only), then choose 3 to clean
```

Or call the scripts directly:

```powershell
# Analyze and generate an HTML report (read-only)
powershell -ExecutionPolicy Bypass -File src\CDiskDoctor.ps1 -Mode Analyze -OpenReport

# Preview reclaimable space (deletes nothing)
powershell -ExecutionPolicy Bypass -File src\CDiskDoctor.ps1 -Mode Clean -DryRun

# Run the safe cleanup
powershell -ExecutionPolicy Bypass -File src\CDiskDoctor.ps1 -Mode Clean -Apply
```

---

## What it cleans

### Whitelisted (only these paths are touched)

| Category | Content | Risk |
|---|---|---|
| TempUser / TempWindows | User and system temp files | Safe |
| CrashDump | Crash dumps, WER reports | Safe |
| WinLogs | Windows and CBS logs | Safe |
| UpdateCache | Windows Update download cache | Safe |
| ThumbCache / IconCache | Thumbnail and icon caches (auto-rebuilt) | Safe |
| UpdaterFiles | Installer leftovers from app updaters | Safe |
| EdgeCache / ChromeCache | Browser caches | Safe |
| RecycleBin | Recycle bin | **Irreversible** |
| AppCache | CapCut / Feishu / WPS / WeChat caches | Confirm first |
| DevCache | npm / pnpm / pip / uv caches | Confirm first |
| Prefetch | Prefetch data | Confirm first |
| SearchIndex | Windows search index | Confirm first |

### Never touched

- Desktop, Documents, Downloads, Pictures, Videos, Music
- Anything under `C:\Windows`, `C:\Program Files`, `C:\ProgramData`
- Any path outside the whitelist

Files modified within the last 2 days are skipped by default, so an installer running in the background is never disturbed.

---

## Relocating large directories

Large AppData folders can be moved to another drive, leaving a **junction** in place.
Applications continue to read and write the same path — they never notice — while the data physically lives elsewhere.

### Step 1: find out what can be moved

```powershell
powershell -ExecutionPolicy Bypass -File src\Classify.ps1 -MinMB 200 -OpenReport
```

Output is grouped into four buckets:

| Bucket | Meaning | Recommended action |
|---|---|---|
| A — Direct move | Standalone personal files | Plain move |
| B — App data | Large folders under AppData | Move + junction |
| C — Programs | Program Files | Uninstall, reinstall to the large drive |
| D — Loose files | Leftover downloads and installers | Delete or move |

### Step 2: perform the migration

```powershell
# Single folder (preview only)
powershell -ExecutionPolicy Bypass -File src\CDiskDoctor.ps1 -Mode Migrate `
  -Path "C:\Users\<you>\AppData\Roaming\SomeApp" -Target "D:\MovedData"

# Add -Apply to execute
powershell -ExecutionPolicy Bypass -File src\CDiskDoctor.ps1 -Mode Migrate `
  -Path "C:\Users\<you>\AppData\Roaming\SomeApp" -Target "D:\MovedData" -Apply

# Batch migration
powershell -ExecutionPolicy Bypass -File src\Migrate-All.ps1 `
  -Target "D:\MovedData" -Apply `
  -Paths "C:\Users\<you>\AppData\Roaming\AppA,C:\Users\<you>\AppData\Roaming\AppB"

# Roll back
powershell -ExecutionPolicy Bypass -File src\Migrate-All.ps1 -Rollback "C:\Users\<you>\AppData\Roaming\SomeApp" -Apply
```

The pipeline is: `robocopy → verify file count → rename source → mklink /J → verify junction → delete source`.
**If any step fails, the partial copy is removed and the source directory is left untouched.** There is no half-migrated state.

---

## ⚠️ Close the application first (including background processes)

This is the most common pitfall. Closing the main window does **not** stop an application — most have resident background processes holding files open.

| Application | Processes to end |
|---|---|
| WPS Office | `wps.exe`, `wpscloudsvr.exe` |
| WeChat | `Weixin.exe`, `WeChatAppEx.exe` |
| Feishu / Lark | `Feishu.exe` |
| CapCut (JianyingPro) | `JianyingPro.exe`, `JianyingProTray.exe`, `VEDetector.exe` |
| QQ Music | `QQMusic.exe`, `WeChatAppEx.exe` (QQ Music ships a mini-program runtime too) |
| Quark Drive | `quark_cloud_drive.exe` |

The migrator detects locked directories and **skips them, keeping the source intact**. Close the process and re-run.

---

## Requirements

- Windows 10 / 11 (x64)
- Windows PowerShell 5.1 (built in — nothing to install)
- Administrator privileges (required for system directories and junctions)

---

## FAQ

**The .ps1 does nothing when I double-click it.**
Windows blocks scripts by default. Use `Run.cmd`, or pass `-ExecutionPolicy Bypass` explicitly.

**My antivirus flags it.**
Any script that deletes files in bulk can trip heuristic engines. The full source is here — read it. Start with `-DryRun` to preview.

**Can it delete my files by accident?**
Cleanup only touches the built-in whitelist and skips files modified in the last 2 days. Migration verifies and can be rolled back. **However, emptying the recycle bin is irreversible.**

**Will applications still work after migration?**
Yes. Junctions are transparent to applications. Use `-Rollback` to undo.

**ARM64 / Windows Server?**
Untested. The scripts are architecture-agnostic, but path rules may need adjustment.

---

## Important for contributors

Every `.ps1` in this project must be **UTF-8 with BOM**.
Windows PowerShell 5.1 decodes BOM-less UTF-8 files using the ANSI code page (GBK on Simplified Chinese systems). A Chinese comment can then swallow the trailing newline and merge the next line of code into the comment — producing baffling syntax errors.

After editing, run:

```powershell
powershell -ExecutionPolicy Bypass -File tools\Fix-Bom.ps1 -Root .
```

CI checks both the BOM and the syntax.

---

## Disclaimer

This tool **deletes files and moves directories**. That is inherently risky.

- Back up anything important first
- Run `-Mode Analyze` and `-Mode Clean -DryRun` to see the impact before committing
- The author accepts no liability for data loss
- Evaluate carefully before using it on a production or corporate machine

## License

[MIT](LICENSE)