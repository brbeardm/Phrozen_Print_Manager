---
name: reference-sdcp-revo-printer
description: Technical facts about the Phrozen Sonic Mighty 16K Revo printer and its SDCP/HTTP interfaces on port 3030
metadata: 
  node_type: memory
  type: reference
  originSessionId: 91f056c4-972f-4b31-94af-319ce5f85c8b
---

**Phrozen Sonic Mighty 16K Revo** on the LAN. Verify IP before use (DHCP), but observed:
- IP `192.168.1.187`, MAC `cc-b8-5e-30-19-71`
- MainboardID `c38f5ec2ded90100`; discovery `Id` (32-char UUID) `f25273b12b094c5a8b9513a30ca60049`
- Firmware `V1.0.8`, SDCP `V3.0.0`
- **Only port 3030 is open.** Port 80 is dead (that was the user's "can't reach files" confusion).

**Discovery:** UDP broadcast the ASCII string `M99999` to port 3000 → printer replies JSON with `Id`, `MainboardID`, firmware.

**HTTP file server on 3030** (no auth): serves the entire Linux root filesystem as "Index of /" directory listings. Print files live in `/media/emmc/` (= SDCP "/local") and `/media/emmc0/`; USB mounts under `/mnt/` or `/media/` when inserted. Directory rows: `<td><a href=NAME>…<td name=MTIME>…<td name=SIZE>` where size `-1` = folder; hrefs are URL-encoded. Files download via GET (verified). **The HTTP `DELETE` verb does NOT actually remove files** (returns 404 but the file stays) — delete must go through SDCP `Cmd 259` (below). Use HTTP HEAD (404 = gone) to verify a delete.

**Gotcha:** an SDCP `Cmd 259` delete briefly (~1s) knocks the HTTP directory listing offline — an immediate re-list returns a connection error ("printer returned 0"). Retry a couple times before trusting an empty result (the tool does this, plus optimistic row removal, so it never flashes a false-empty view).

**File upload:** HTTP `POST http://<ip>:3030/uploadFile/upload`, `multipart/form-data`, sent in **1MB chunks with sequential `Offset`**. Form fields (this order): `S-File-MD5` (can be empty), `Check`="0" to disable MD5 verification (works — no MD5 needed), `Offset`, `Uuid` (same per file), `TotalSize`, `File` (binary part, filename = stored name). Success response `{"code":"000000","success":true}`. Uploads land in onboard `/local` only; **no USB upload target exists** in the protocol.

**SDCP WebSocket on 3030:** `ws://192.168.1.187:3030/websocket`.
- Request envelope: `{"Id": <32-char discovery Id>, "Data":{"Cmd":N,"Data":{…},"RequestID":<32hex>,"MainboardID":"c38f5ec2ded90100","TimeStamp":<unixsec>,"From":0}, "Topic":"sdcp/request/<MainboardID>"}`. The top-level `Id` MUST be the 32-char discovery UUID or the printer resets the socket.
- Responses arrive on `sdcp/response/<id>`; `Data.Data.Ack==0` = success (2 = file-not-found etc.).
- Key commands: `0`=status refresh, `1`=attributes, `128`=start print `{Filename:"/local/<name>",StartLayer:0}`, `258`=retrieve file list `{Url:"/local/"}`, `259`=batch delete `{FileList:["/local/<name>"],FolderList:[]}` (Ack 0 = success; response may include `ErrData`), `129`=pause, `130`=STOP, `131`=continue (129/130/131 all **dangerous — never send, see [[feedback-never-disrupt-print]]**). Build `FileList` JSON manually — PowerShell `ConvertTo-Json` unwraps a 1-element array into a scalar (see [[reference-powershell-gotchas]]).
- **No rename/move command exists** in SDCP V3.0.0 (verified against the spec). To rename, copy the file under the new name (download bytes -> chunked re-upload to `/local`) then delete the original via `Cmd 259`. Internal (`/media/emmc`) only, since upload has no USB target.
- This firmware pushes `sdcp/status/<id>` messages ONLY while printing (~every 4s, `CurrentStatus:[1]`). **Silence = idle** — the tool uses a receive-only listen to detect state.
- The WS server is low-capacity/fragile: rapid reconnects cause transient upgrade refusals; use one clean connection, close cleanly.

Spec: https://github.com/cbd-tech/SDCP-Smart-Device-Control-Protocol-V3.0.0
