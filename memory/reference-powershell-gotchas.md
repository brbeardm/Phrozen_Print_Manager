---
name: reference-powershell-gotchas
description: "PowerShell 5.1 traps that caused real misdiagnoses on this project (string $var:, JSON array unwrap, ANSI file encoding, self-matching process filters, Task Wait leaks, blocking HttpListener)"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 91f056c4-972f-4b31-94af-319ce5f85c8b
---

PS 5.1 pitfalls hit while building the Revo tool ([[project-revo-file-tool]]) — each cost real debugging time:

1. **`"$Ip:3030"` does not expand `$Ip`** — the `:` makes PS parse `$Ip:` as a drive/scope qualifier → empty host (`ws://$Ip:3030/...` became `ws:///...`). This masqueraded as "printer refusing the WebSocket." Use `${Ip}` or the format op `("...{0}..." -f $Ip)`. Same for `$_:` and `$PID:`.

2. **`ConvertTo-Json` unwraps a single-element array into a scalar** — `@{FileList=@('x')} | ConvertTo-Json` → `"FileList":"x"` (breaks APIs that require an array). Build the JSON array manually: `'[' + (($a|%{$_|ConvertTo-Json}) -join ',') + ']'`.

3. **PS 5.1 reads `.ps1` files as ANSI, not UTF-8** — literal non-ASCII in the script (✓ … — “ ”) gets mangled at runtime (✓ showed as "ace"). Keep script source ASCII: use `✓`-style JS escapes or HTML entities, and hyphens/`...` instead of em-dash/ellipsis.

4. **Process filters match their own command line** — `Get-CimInstance Win32_Process | ? { $_.CommandLine -like '*revo_file_server*' }` matches the very command running it, so `Stop-Process` can kill your own shell (exit 255) and counts are inflated by +1. Always exclude `$PID`.

5. **`.Wait(<timeout>)` returns a bool that leaks into function output** — a bare `$task.Wait(3000)` adds `True` to the pipeline, so a function returning a hashtable returns `@($true, $obj)` and JSON came out as `[true,{...}]`. Prefix with `[void]`.

6. **HttpListener is single-threaded/blocking** — a slow handler (e.g. a 5s status listen) freezes the whole server; even `GET /` times out. Offload continuous/slow work to a background `runspace` writing a `[hashtable]::Synchronized(@{})` that fast handlers just read.

7. **PATH changes via `[Environment]::SetEnvironmentVariable(...,'User')` only affect NEW terminals**, not already-open ones.
