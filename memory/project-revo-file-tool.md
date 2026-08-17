---
name: project-revo-file-tool
description: "What the phrozen_mighty_REVO_16K project is — a local web tool to manage the resin printer's files, uploads, and prints"
metadata: 
  node_type: memory
  type: project
  originSessionId: 91f056c4-972f-4b31-94af-319ce5f85c8b
---

This directory (`C:\development\phrozen_mighty_REVO_16K`) builds host-side tools to manage a **Phrozen Sonic Mighty 16K Revo** resin printer over the network. NOT firmware.

Main deliverable **`revo_file_server.ps1`**: a self-contained PowerShell script that runs a local web UI on `http://127.0.0.1:8765` and proxies server-side (avoids browser CORS) to the printer on port 3030. A background runspace keeps one receive-only WebSocket open to monitor print status so `/api/status` is instant. Features, all working & verified:
- Browse / download the printer filesystem.
- **Delete** via SDCP `Cmd 259` (the HTTP DELETE verb does NOT work on this firmware). Guarded to `/media/emmc` (→`/local`) and `/mnt` (→`/usb`).
- **Upload** `.ctb` via drag-and-drop or file picker, chunked (1MB) to `/uploadFile/upload`, with a progress bar. Uploads go to onboard/Internal storage only (protocol has no USB upload target).
- **Print** button per file (SDCP `Cmd 128`), enabled only when idle; server re-verifies idle before sending.
- **Rename** (Internal/`/media/emmc` files only): click a filename -> modal. SDCP has NO rename command, so the server does copy-under-new-name (download bytes, re-upload chunked to `/local`) -> verify via HTTP HEAD -> delete original via `Cmd 259`. Idle-gated (server + UI); original left untouched if the copy fails/doesn't verify. No USB rename (no upload target there).
- Live status pill, in-app modal dialogs (not browser `confirm`/`alert`).

**Status monitor hysteresis (fixed 2026-08-17):** the pill used to flap printing<->idle mid-print because the firmware pushes `sdcp/status` only ~every 4s and a push can miss the monitor's listen window (default-to-idle on timeout). The background monitor now: trusts a "printing" push immediately, trusts an explicit non-printing status immediately, but on a SILENT cycle only flips an active print to idle after 3 consecutive silent cycles (~20s). Listen window widened 5000->6000ms. So the pill stays "PRINTING ... layer x/y" for the whole job.

See [[reference-sdcp-revo-printer]] for the protocol details and [[reference-powershell-gotchas]] for the PS 5.1 traps hit while building it.

**How to run:** type **`phrozen`** in any *new* terminal. `C:\Users\dbria\bin\phrozen.cmd` (on user PATH) calls `phrozen_launch.ps1`, which starts the server if needed (minimized window; Ctrl+C to stop) and opens Chrome. Idempotent. Also present: `sdcp_listen.ps1` (safe read-only status listener).

Origin: user (bbeardmore@carvizor.com) couldn't reach the printer "file system" — root cause was a wrong URL (port 80 is dead; the browser/file server is on **port 3030**).

Safety rules for this tool are non-negotiable — see [[feedback-never-disrupt-print]].
