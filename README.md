# Phrozen Print Manager

A self-contained, host-side tool to manage a **Phrozen Sonic Mighty 16K Revo** resin
printer over the local network. It is **not** firmware — it runs on your PC and talks to
the printer's built-in HTTP file server and SDCP WebSocket on port `3030`.

`revo_file_server.ps1` starts a small local web UI on `http://127.0.0.1:8765` and proxies
requests to the printer **server-side** (so there are no browser CORS issues).

## Features

- **Browse / download** the printer filesystem.
- **Upload** `.ctb` files by drag-and-drop or file picker — chunked (1 MB) with a progress
  bar. Uploads land in onboard/Internal storage (`/local`); the protocol has no USB upload
  target.
- **Print** a file (SDCP `Cmd 128`) — enabled only when the printer is idle; the server
  re-verifies idle before sending.
- **Delete** (SDCP `Cmd 259` — the HTTP `DELETE` verb does not work on this firmware).
  Restricted to `/media` and `/mnt` so you can never remove system files.
- **Rename** an Internal file — click its name. SDCP has no rename command, so the tool
  copies the file to the new name and then deletes the original (idle-gated; the original
  is left untouched if the copy fails to verify). Internal storage only.
- **Live status pill** — read-only. A background, receive-only WebSocket monitors print
  status. It uses hysteresis so the pill stays `PRINTING ... layer x/y` for the whole job
  instead of flickering (this firmware only streams status while printing, so silence is
  treated as idle only after several consecutive silent cycles).

## Safety

This tool **never** sends a disruptive command (stop / pause / continue). The only write
commands it can send are **start-print** and **delete/rename** (copy+delete), and only when
the printer is verified idle — enforced in both the UI and the server. Status detection is
receive-only and physically cannot interrupt a print.

## Usage

```powershell
# start the server (opens your browser automatically)
./revo_file_server.ps1

# options
./revo_file_server.ps1 -PrinterIp 192.168.1.187 -PrinterPort 3030 -LocalPort 8765 -NoBrowser
```

Press `Ctrl+C` in the server window to stop.

`phrozen_launch.ps1` is a convenience launcher (starts the server if needed and opens the
browser, idempotent). `sdcp_listen.ps1` is a safe, read-only status listener for debugging.

## How it talks to the printer

- **Discovery:** UDP broadcast the ASCII string `M99999` to port `3000`; the printer
  replies with JSON containing its `Id` and `MainboardID`.
- **HTTP file server** on `3030` serves directory listings and file downloads.
- **File upload:** `POST /uploadFile/upload`, `multipart/form-data`, sequential 1 MB
  chunks with an `Offset` field.
- **SDCP WebSocket** at `ws://<ip>:3030/websocket` for status and control commands.

Protocol reference:
<https://github.com/cbd-tech/SDCP-Smart-Device-Control-Protocol-V3.0.0>

## `memory/`

Project notes captured while building this tool — the printer's protocol details, the
non-negotiable safety rules, and PowerShell 5.1 gotchas hit along the way.

## Requirements

- Windows with PowerShell 5.1+
- The printer reachable on your LAN (only port `3030` is open; port `80` is dead)
