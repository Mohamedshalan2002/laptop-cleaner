# Laptop Cleaner

A one-click Windows disk cleanup tool with an Arabic + English GUI.

Work laptop filling up again? This tool safely reclaims space from regenerable caches and temporary files — without ever touching your documents, bookmarks, or saved passwords.

---

## Quick start

1. Download the repo (or grab the four files).
2. Double-click **`Clean-Laptop.bat`** for the English UI, or **`Clean-Laptop-AR.bat`** for the Arabic one.
3. A dialog asks whether to request administrator rights — **Yes** unlocks the system steps (pagefile move, deep Windows cleanup), **No** still runs every user-level cleanup.
4. Press the big button.

No install. Nothing is registered in the system. Fully portable — run it from a desktop, a USB stick, or any folder.

**Requirements:** Windows 10 or 11 (PowerShell 5.1 ships with the OS).

---

## What it cleans

| # | Group |
|---|---|
| 1 | Windows and user temp files + crash reports |
| 2 | **Dead Ollama leftovers** — interrupted downloads (`*-partial*`), orphaned models when the store lives on another drive, downloaded update packages |
| 3 | Browser caches — Edge / Chrome / Brave / Chromium (all profiles) |
| 4 | **Notion's background cache** — the `Service Worker` cache, often the single biggest app cache (several GB) |
| 5 | App caches — Slack, Discord, Zoom, VS Code, Teams, Postman, Figma |
| 6 | Installer leftovers — Google updater, WPS update packages |
| 7 | **Old WPS versions** — keeps only the newest version directory, removes the rest (often 1.5 GB per stale version) |
| 8 | **WeChat leftovers** — downloaded update packages (re-fetched constantly, often >1 GB) and logs |
| 9 | Dev tool caches — pip, npm, pnpm, Yarn, npx (direct removal, no Python needed) |
| 10 | WPS add-on package pool (re-downloaded on demand) |
| 11 | Anytxt search index (rebuilt automatically) |
| 12 | Thumbnail cache and internet cache |
| 13 | Windows upgrade leftovers + `DISM` component store cleanup + built-in Disk Cleanup *(admin)* |

**Typical gain:** 5–15 GB per run, depending on your usage.

---

## The pagefile fix (root cause)

The "Move pagefile from C: to D:" option used to be a no-op on machines where the registry was already set to D: while the *active* pagefile kept living on C: — growing back after every restart and eating all freed space.

This version fixes the actual chain:

1. **It detects the active pagefile** (`Win32_PageFileUsage` / `C:\pagefile.sys`), not just the registry value.
2. **It disables crash-dump writing** (`CrashDumpEnabled = 0`). Windows requires a pagefile on the *system volume* to write crash dumps — when none is configured there, Windows silently creates a temporary, system-managed pagefile on C: at every boot, which then grows and fills the disk. This was the reason the file "came back".
3. It turns off automatic pagefile management and writes `D:\pagefile.sys 8192 16384` (REG_MULTI_SZ).
4. **It verifies every value it writes** and reports exactly what happened.
5. **It offers the restart itself** — the move only takes effect at boot.
6. On the next run it confirms the state: if the file is gone, you'll see "already set"; if it came back despite a correct setup, it tells you the manual fallback (`sysdm.cpl` → Advanced → Virtual Memory).

**Trade-off:** disabling crash dumps means no `minidump` files after a BSOD (they're only useful for diagnosing kernel crashes). If you want them back: `sysdm.cpl` → Advanced → Startup and Recovery → set "Write debugging information" back to your preferred option — but then Windows will re-create a pagefile on C: again.

---

## Options in the GUI

| Option | Default | Effect |
|---|---|---|
| Move pagefile from C: to D: | **On** | Frees the current `C:\pagefile.sys` size after a restart — needs admin |
| Empty the Recycle Bin | Off | Off by default to protect your files |
| Wipe the Docker WSL disk | Off | Removes all Docker images/containers (~5 GB) |
| Wipe the Android SDK | Off | Re-downloaded by Android Studio on demand (~2 GB) |

The window always shows the permission status (green = admin, orange = standard user) so system steps are never silently skipped.

---

## Safety — what it does *not* touch

- ❌ Your libraries and personal files (Desktop, Documents, Downloads, Pictures)
- ❌ **Bookmarks, saved passwords, and browsing history** — only cache directories are removed
- ❌ Notion's local data (`IndexedDB`, `Local Storage`) — only its regenerable caches
- ❌ The newest WPS version — only older, stale ones
- ❌ Ollama models on the official store — only interrupted downloads and orphans on C:
- ❌ The Recycle Bin (unless you opt in)
- ❌ System files

### Design principles

- **Locked files are skipped silently** instead of being forced or failing the run — you can clean while apps are open.
- **User paths are resolved dynamically** — some corporate machines ship with an empty `%LOCALAPPDATA%`.
- **Elevation is safe across accounts**: if you accept the UAC prompt with a *different* admin account, the tool passes the original user's paths to the elevated instance, so it cleans the right profile.
- **Paths are validated before deletion** — an invalid path aborts the run instead of deleting the wrong location.
- **A marker file** prevents `DISM` from running more than once every 60 days.

---

## Logging

Every run writes a log to your Desktop — `laptop-cleaner-log.txt` (English UI) or `سجل-التنظيف.txt` (Arabic UI): free space before and after, amount reclaimed, and duration.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Nothing happens after double-click | Right-click → **Run as administrator** |
| Pagefile still on C: after a restart | Run the tool as admin once more — if it says the setup was already correct, use `sysdm.cpl` → Advanced → Virtual Memory manually |
| "Notion is running" | Close Notion and run again — its Service Worker cache alone can be several GB |
| "WPS is running - skipped" | Close WPS and run again |
| "locked" entries | Normal — any file in use by an open app is skipped safely |
| Caches come back | Expected after any cleanup — repeat every month or two |
| Garbled Arabic text | Make sure `clean-ar.ps1` is saved as UTF-8 **with BOM** |

---

## A note on C:

This tool cleans, but **if C: is simply too small** it will fill up again. The durable fixes are: move large projects and data to another drive, relocate `pagefile.sys` (this tool does it properly now), and relocate big app data (Docker's `docker_data.vhdx` grows with every use and can reach tens of gigabytes).

---

## File layout

```
Clean-Laptop.bat      # English UI launcher
Clean-Laptop-AR.bat   # Arabic UI launcher
clean.ps1             # English engine
clean-ar.ps1          # Arabic engine (UTF-8 with BOM - required)
```

---

## License

MIT — see `LICENSE`.
