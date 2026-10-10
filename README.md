# Laptop Cleaner

A one-click Windows disk cleanup tool with an Arabic + English GUI.

Work laptop filling up again? This tool safely reclaims space from regenerable caches and temporary files — without ever touching your documents, bookmarks, or saved passwords.

---

## Quick start

1. Download the repo (or grab the four files).
2. Double-click **`Clean-Laptop.bat`** for the English UI, or **`Clean-Laptop-AR.bat`** for the Arabic one.
3. Click **Yes** on the UAC prompt → the window opens → press the big button.

No install. Nothing is registered in the system. Fully portable — run it from a desktop, a USB stick, or any folder.

**Requirements:** Windows 10 or 11 (PowerShell 5.1 ships with the OS).

---

## What it cleans

| # | Group |
|---|---|
| 1 | Windows and user temp files + crash reports |
| 2 | Browser caches — Edge / Chrome / Brave / Chromium (all profiles) |
| 3 | App caches — Slack, Discord, Zoom, Notion, VS Code, Teams, Postman, Figma |
| 4 | Installer leftovers — Google updater, WPS update packages |
| 5 | WPS add-on package pool (re-downloaded on demand) |
| 6 | Dev tool caches — pip, npm, pnpm, Yarn |
| 7 | Thumbnail cache and internet cache |
| 8 | Windows upgrade leftovers + `DISM` component store cleanup + built-in Disk Cleanup |

**Typical gain:** 5–15 GB, depending on your usage.

---

## Safety — what it does *not* touch

- ❌ Your libraries and personal files (Desktop, Documents, Downloads, Pictures)
- ❌ **Bookmarks, saved passwords, and browsing history** — only cache directories are removed
- ❌ Saved login data for any application
- ❌ The Recycle Bin (unless you opt in)
- ❌ System files

### Design principles

- **Locked files are skipped silently** instead of being forced or failing the run — you can clean while apps are open.
- **User paths are resolved dynamically** — some corporate machines ship with an empty `%LOCALAPPDATA%`.
- **Paths are validated before deletion** — an invalid path aborts the run instead of deleting the wrong location.
- **A marker file** prevents `DISM` from running more than once every 60 days.
- **Opt-in defaults** for the Recycle Bin and pagefile relocation.

---

## Options in the GUI

| Option | Default | Effect |
|---|---|---|
| Empty the Recycle Bin | Off | Off by default to protect your files |
| Move pagefile from C: to D: | Off | Frees significant space — **requires a restart** |

---

## Logging

Every run writes `laptop-cleaner-log.txt` to your Desktop: free space before and after, amount reclaimed, and duration.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Nothing happens after double-click | Right-click → **Run as administrator** |
| "WPS is running - skipped" | Close WPS and run again |
| "locked" entries | Normal — any file in use by an open app is skipped safely |
| Caches come back | Expected after any cleanup — repeat every month or two |
| "Permissions: standard user" | The UAC request failed — run as administrator manually |

---

## A note on C:

This tool cleans, but **if C: is simply too small** (e.g. 170 GB on a 512 GB drive) it will fill up again. The durable fix is to move large projects and data to another drive, and relocate `pagefile.sys` as well.

**On a machine running Docker or WSL:** `docker_data.vhdx` grows with every use and can reach tens of gigabytes. Move it to a drive with free space.

---

## File layout

```
Clean-Laptop.bat      # English UI launcher
Clean-Laptop-AR.bat   # Arabic UI launcher
clean.ps1             # English engine
clean-ar.ps1          # Arabic engine
```

---

## License

MIT — see `LICENSE`.
