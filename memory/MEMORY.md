# Memory index

- [Revo file tool (project)](project-revo-file-tool.md) — local web tool (run via `phrozen`) to browse/download/delete/upload/print/rename on the resin printer; status pill uses hysteresis so it stays "printing" the whole job. Mirrored to GitHub repo brbeardm/Phrozen_Print_Manager
- [SDCP + Revo printer (reference)](reference-sdcp-revo-printer.md) — printer IP/IDs, port 3030 HTTP file server, SDCP WebSocket envelope, Cmd 128/259, upload endpoint, idle=silence
- [Never disrupt a print (feedback)](feedback-never-disrupt-print.md) — only receive-only status + idle-verified start-print; I once cancelled a real print with a stop command
- [PowerShell 5.1 gotchas (reference)](reference-powershell-gotchas.md) — $var: drive-parse, JSON 1-elem array unwrap, ANSI file mangling, self-matching process filters, .Wait() bool leak, blocking HttpListener
