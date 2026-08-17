<#
  Phrozen Sonic Mighty 16K Revo - Local File Manager
  Runs a small web UI on http://127.0.0.1:8765 that talks to the printer's
  built-in HTTP file server on port 3030 (server-side, so no browser CORS issues).

  Browse / download from anywhere; DELETE is restricted to /media and /mnt only
  (so you can never remove system files and brick the printer).

  Usage:  right-click > Run with PowerShell   (or)   ./revo_file_server.ps1
          then your browser opens automatically. Ctrl+C in this window to stop.
#>
param(
  [string]$PrinterIp = "192.168.1.187",
  [int]$PrinterPort  = 3030,
  [int]$LocalPort    = 8765,
  [switch]$NoBrowser
)
$ErrorActionPreference = "Stop"
$PBASE = "http://${PrinterIp}:${PrinterPort}"

# ---------- printer HTTP helpers (server-side; no CORS) ----------
function Printer-Request([string]$method,[string]$path,[int]$timeoutMs=15000){
  $uri = $PBASE + $path
  $r = [System.Net.HttpWebRequest]::Create($uri)
  $r.Method = $method
  $r.Timeout = $timeoutMs
  $r.ReadWriteTimeout = $timeoutMs
  $r.AllowAutoRedirect = $false
  try {
    $resp = $r.GetResponse()
    $code = [int]$resp.StatusCode
    $ms = New-Object System.IO.MemoryStream
    $resp.GetResponseStream().CopyTo($ms)
    $resp.Close()
    return @{ code=$code; bytes=$ms.ToArray() }
  } catch [System.Net.WebException] {
    if ($_.Exception.Response) {
      $code = [int]$_.Exception.Response.StatusCode
      $_.Exception.Response.Close()
      return @{ code=$code; bytes=@() }
    }
    return @{ code=0; bytes=@(); err=$_.Exception.Message }
  }
}

# Build + send a multipart/form-data POST (used for SDCP chunked file upload).
function Post-Multipart([string]$url,$fields,[string]$fileField,[string]$fileName,[byte[]]$fileBytes){
  $boundary = "----RevoBoundary" + [guid]::NewGuid().ToString("N")
  $enc = [System.Text.Encoding]::UTF8
  $ms = New-Object System.IO.MemoryStream
  foreach($k in $fields.Keys){
    $part = "--$boundary`r`nContent-Disposition: form-data; name=`"$k`"`r`n`r`n$($fields[$k])`r`n"
    $pb = $enc.GetBytes($part); $ms.Write($pb,0,$pb.Length)
  }
  $head = "--$boundary`r`nContent-Disposition: form-data; name=`"$fileField`"; filename=`"$fileName`"`r`nContent-Type: application/octet-stream`r`n`r`n"
  $hb = $enc.GetBytes($head); $ms.Write($hb,0,$hb.Length)
  $ms.Write($fileBytes,0,$fileBytes.Length)
  $tail = "`r`n--$boundary--`r`n"; $tb = $enc.GetBytes($tail); $ms.Write($tb,0,$tb.Length)
  $body = $ms.ToArray()
  $r = [System.Net.HttpWebRequest]::Create($url)
  $r.Method = "POST"; $r.ContentType = "multipart/form-data; boundary=$boundary"
  $r.Timeout = 60000; $r.ReadWriteTimeout = 60000; $r.ContentLength = $body.Length
  try {
    $rs = $r.GetRequestStream(); $rs.Write($body,0,$body.Length); $rs.Close()
    $resp = $r.GetResponse(); $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $txt = $sr.ReadToEnd(); $resp.Close()
    return @{ code=200; body=$txt }
  } catch [System.Net.WebException] {
    if ($_.Exception.Response) { $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); $txt = $sr.ReadToEnd(); $_.Exception.Response.Close(); return @{ code=[int]$_.Exception.Response.StatusCode; body=$txt } }
    return @{ code=0; body=$_.Exception.Message }
  }
}

# parse an "Index of" directory listing into entries
function Parse-Listing([string]$html,[string]$curPath){
  $entries = @()
  $rx = [regex]'<tr><td><a href="([^"]+)">.*?</a></td><td name=(-?\d+)>[^<]*</td><td name=(-?\d+)>[^<]*</td></tr>'
  foreach($m in $rx.Matches($html)){
    $href = $m.Groups[1].Value
    if ($href -eq '..' -or $href -eq '#') { continue }
    $size = [long]$m.Groups[3].Value
    $mtime= [long]$m.Groups[2].Value
    $isDir = ($size -lt 0) -or $href.EndsWith('/')
    $name = [System.Uri]::UnescapeDataString($href.TrimEnd('/'))
    $full = ($curPath.TrimEnd('/')) + '/' + $href   # keep href encoded for API calls
    $entries += @{ name=$name; href=$href; path=$full; isDir=$isDir; size=(&{ if($isDir){0}else{$size} }); mtime=$mtime }
  }
  return $entries
}

# ---------- SDCP (printer control) helpers ----------
# SAFETY: this tool NEVER sends a stop/pause/disruptive command. The ONLY command
# it can send is Cmd 128 (start print), and only after confirming the printer is idle.
$script:SDCP = $null
function Get-SdcpDiscovery {
  if ($script:SDCP) { return $script:SDCP }
  try {
    $u = New-Object Net.Sockets.UdpClient; $u.Client.ReceiveTimeout = 2000
    $m = [Text.Encoding]::ASCII.GetBytes("M99999")
    [void]$u.Send($m,$m.Length,(New-Object Net.IPEndPoint([Net.IPAddress]::Parse($PrinterIp),3000)))
    $re = New-Object Net.IPEndPoint([Net.IPAddress]::Any,0)
    $o = ([Text.Encoding]::UTF8.GetString($u.Receive([ref]$re))) | ConvertFrom-Json
    $u.Close()
    $script:SDCP = @{ connId=$o.Id; mainboardId=$o.Data.MainboardID }
  } catch { $script:SDCP = $null }
  return $script:SDCP
}

# Receive-only. Sends NOTHING to the printer, so it can never interrupt a print.
# This firmware streams status only while printing; silence => idle.
function Get-PrinterState {
  $st = [ordered]@{ state="idle"; filename=""; current=0; total=0; percent=0 }
  $cts = New-Object System.Threading.CancellationTokenSource
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  try { [void]$ws.ConnectAsync([Uri]("ws://{0}:{1}/websocket" -f $PrinterIp,$PrinterPort),$cts.Token).Wait(3000) } catch { $st.state="unreachable"; return $st }
  if ($ws.State -ne 'Open') { $st.state="unreachable"; return $st }
  $buf = New-Object byte[] 131072
  $seg = New-Object System.ArraySegment[byte] (,$buf)
  $pending = $ws.ReceiveAsync($seg,$cts.Token)
  $deadline = [DateTime]::UtcNow.AddMilliseconds(5500)
  while ([DateTime]::UtcNow -lt $deadline -and $ws.State -eq 'Open') {
    if (-not $pending.Wait(200)) { continue }
    try { $r = $pending.Result } catch { break }
    if ($r.MessageType -eq 'Close') { break }
    $t = [Text.Encoding]::UTF8.GetString($buf,0,$r.Count)
    if ($t -like '*sdcp/status*') {
      try {
        $o = $t | ConvertFrom-Json; $cs = $o.Status.CurrentStatus[0]; $pi = $o.Status.PrintInfo
        if ($cs -eq 1) {
          $st.state="printing"; $st.filename=$pi.Filename; $st.current=[int]$pi.CurrentLayer; $st.total=[int]$pi.TotalLayer
          if ($pi.TotalLayer -gt 0) { $st.percent=[math]::Round(100.0*$pi.CurrentLayer/$pi.TotalLayer) }
        } else { $st.state="idle" }
      } catch {}
      break
    }
    $seg = New-Object System.ArraySegment[byte] (,$buf); $pending = $ws.ReceiveAsync($seg,$cts.Token)
  }
  try { $ws.Abort() } catch {}; try { $ws.Dispose() } catch {}
  return $st
}

# Sends Cmd 128 (start print) ONLY. Caller must have verified idle first.
function Send-StartPrint([string]$filename) {
  $d = Get-SdcpDiscovery
  if (-not $d) { return @{ ok=$false; error="discovery failed" } }
  $cts = New-Object System.Threading.CancellationTokenSource
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  try { [void]$ws.ConnectAsync([Uri]("ws://{0}:{1}/websocket" -f $PrinterIp,$PrinterPort),$cts.Token).Wait(3000) } catch { return @{ ok=$false; error="ws connect failed" } }
  if ($ws.State -ne 'Open') { return @{ ok=$false; error="ws not open" } }
  Start-Sleep -Milliseconds 300
  $envObj = @{ Id=$d.connId; Data=@{ Cmd=128; Data=@{ Filename=$filename; StartLayer=0 }; RequestID=[guid]::NewGuid().ToString("N"); MainboardID=$d.mainboardId; TimeStamp=[int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); From=0 }; Topic="sdcp/request/$($d.mainboardId)" }
  $b = [Text.Encoding]::UTF8.GetBytes(($envObj | ConvertTo-Json -Depth 8 -Compress))
  try { $ws.SendAsync((New-Object System.ArraySegment[byte] (,$b)),'Text',$true,$cts.Token).Wait() } catch { try{$ws.Dispose()}catch{}; return @{ ok=$false; error="send failed" } }
  $buf = New-Object byte[] 131072; $seg = New-Object System.ArraySegment[byte] (,$buf); $pending = $ws.ReceiveAsync($seg,$cts.Token)
  $deadline = [DateTime]::UtcNow.AddSeconds(6); $ack = $null
  while ([DateTime]::UtcNow -lt $deadline -and $ws.State -eq 'Open') {
    if (-not $pending.Wait(200)) { continue }
    try { $r = $pending.Result } catch { break }
    if ($r.MessageType -eq 'Close') { break }
    $t = [Text.Encoding]::UTF8.GetString($buf,0,$r.Count)
    if ($t -like '*sdcp/response*') { try { $o=$t|ConvertFrom-Json; if ($o.Data.Cmd -eq 128) { $ack=[int]$o.Data.Data.Ack; break } } catch {} }
    $seg = New-Object System.ArraySegment[byte] (,$buf); $pending = $ws.ReceiveAsync($seg,$cts.Token)
  }
  try { $ws.Abort() } catch {}; try { $ws.Dispose() } catch {}
  if ($null -eq $ack) { return @{ ok=$false; error="no ack from printer" } }
  return @{ ok=($ack -eq 0); ack=$ack }
}

# Deletes files via SDCP Cmd 259 (the HTTP DELETE verb does NOT remove files on
# this firmware). FileList is built manually to guarantee a JSON array even for 1 file.
function Send-DeleteFiles([string[]]$files) {
  $d = Get-SdcpDiscovery
  if (-not $d) { return @{ ok=$false; error="discovery failed" } }
  $cts = New-Object System.Threading.CancellationTokenSource
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  try { [void]$ws.ConnectAsync([Uri]("ws://{0}:{1}/websocket" -f $PrinterIp,$PrinterPort),$cts.Token).Wait(3000) } catch { return @{ ok=$false; error="ws connect failed" } }
  if ($ws.State -ne 'Open') { return @{ ok=$false; error="ws not open" } }
  Start-Sleep -Milliseconds 300
  $fa = '[' + (($files | ForEach-Object { $_ | ConvertTo-Json }) -join ',') + ']'
  $rid = [guid]::NewGuid().ToString("N"); $ts = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $json = '{"Id":"' + $d.connId + '","Data":{"Cmd":259,"Data":{"FileList":' + $fa + ',"FolderList":[]},"RequestID":"' + $rid + '","MainboardID":"' + $d.mainboardId + '","TimeStamp":' + $ts + ',"From":0},"Topic":"sdcp/request/' + $d.mainboardId + '"}'
  $b = [Text.Encoding]::UTF8.GetBytes($json)
  try { $ws.SendAsync((New-Object System.ArraySegment[byte] (,$b)),'Text',$true,$cts.Token).Wait() } catch { try{$ws.Dispose()}catch{}; return @{ ok=$false; error="send failed" } }
  $buf = New-Object byte[] 131072; $seg = New-Object System.ArraySegment[byte] (,$buf); $pending = $ws.ReceiveAsync($seg,$cts.Token)
  $deadline = [DateTime]::UtcNow.AddSeconds(6); $ack = $null; $errData = @()
  while ([DateTime]::UtcNow -lt $deadline -and $ws.State -eq 'Open') {
    if (-not $pending.Wait(200)) { continue }
    try { $r = $pending.Result } catch { break }
    if ($r.MessageType -eq 'Close') { break }
    $t = [Text.Encoding]::UTF8.GetString($buf,0,$r.Count)
    if ($t -like '*sdcp/response*') { try { $o=$t|ConvertFrom-Json; if ($o.Data.Cmd -eq 259) { $ack=[int]$o.Data.Data.Ack; if ($o.Data.Data.ErrData) { $errData=@($o.Data.Data.ErrData) }; break } } catch {} }
    $seg = New-Object System.ArraySegment[byte] (,$buf); $pending = $ws.ReceiveAsync($seg,$cts.Token)
  }
  try { $ws.Abort() } catch {}; try { $ws.Dispose() } catch {}
  if ($null -eq $ack) { return @{ ok=$false; error="no ack from printer" } }
  return @{ ok=($ack -eq 0); ack=$ack; errData=$errData }
}

function Is-DeletableRoot([string]$p){
  $d = [System.Uri]::UnescapeDataString($p)
  return ($d -like '/media/*') -or ($d -like '/mnt/*')
}

# ---------- local web server ----------
$html = @'
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Revo File Manager</title><style>
:root{--bg:#0f1216;--panel:#171b21;--panel2:#1e242c;--line:#2a323d;--txt:#e6edf3;--mut:#8b98a5;--acc:#4aa3ff;--ok:#3fb950;--err:#f85149;--warn:#d29922}
*{box-sizing:border-box}body{margin:0;font:14px/1.45 -apple-system,Segoe UI,Roboto,Arial,sans-serif;background:var(--bg);color:var(--txt)}
header{padding:12px 18px;background:var(--panel);border-bottom:1px solid var(--line);display:flex;gap:12px;align-items:center;flex-wrap:wrap}
header h1{font-size:15px;margin:0;font-weight:600}.sp{flex:1}
.pill{font-size:12px;padding:3px 9px;border-radius:999px;background:var(--panel2);color:var(--mut);border:1px solid var(--line)}
main{padding:16px 18px;max-width:1050px;margin:0 auto}
.bar{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:12px}
button{background:var(--panel2);border:1px solid var(--line);color:var(--txt);border-radius:7px;padding:7px 12px;cursor:pointer;font:inherit}
button:hover{border-color:var(--acc)}button:disabled{opacity:.45;cursor:not-allowed}
button.danger{background:#3a1d1d;border-color:#7a3030;color:#ffd6d6}button.q{padding:5px 10px}
.crumbs{font-size:13px;color:var(--mut);margin-bottom:8px;word-break:break-all}
.crumbs a{color:var(--acc);cursor:pointer;text-decoration:none}
table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);font-size:13px}
th{color:var(--mut);font-weight:500}td.size,td.date{color:var(--mut);white-space:nowrap}td.size{text-align:right}
tr.dir td.name{color:var(--acc);cursor:pointer}.chk{width:32px}
td.name.ren{cursor:pointer}td.name.ren:hover{color:var(--acc);text-decoration:underline}
a.dl{color:var(--acc);text-decoration:none}.muted{color:var(--mut)}.empty{padding:22px;text-align:center;color:var(--mut)}
#msg{margin:10px 0;padding:10px 12px;border-radius:8px;display:none;white-space:pre-wrap;font-size:13px}
#msg.ok{display:block;background:#12291a;border:1px solid #204a2c;color:#9be7ac}
#msg.err{display:block;background:#2a1414;border:1px solid #5a2626;color:#ffb4b4}
#msg.warn{display:block;background:#2a2410;border:1px solid #5a4f1f;color:#f0dd9a}
.roots button{background:#12202f}
#statusPill{font-weight:600}
.st-idle{color:var(--ok);border-color:#20402a;background:#12291a}
.st-printing{color:#cfe6ff;border-color:#2b5c91;background:#122437}
.st-unknown{color:var(--warn);border-color:#4a3c17;background:#241f10}
button.print{background:#123021;border-color:#2e6b47;color:#bff0d0;padding:4px 9px;margin-left:8px}
button.primary{background:#1d3a5c;border-color:#2b5c91;color:#cfe6ff}
td.act{white-space:nowrap}
.upzone{border:1.5px dashed var(--line);border-radius:10px;padding:14px 16px;text-align:center;color:var(--mut);margin-bottom:12px;transition:border-color .15s,background .15s;cursor:pointer}
.upzone.drag{border-color:var(--acc);background:#12202f;color:var(--txt)}
.upzone a{color:var(--acc);text-decoration:underline}
.upbar{height:10px;background:var(--panel2);border-radius:6px;overflow:hidden;margin-top:12px}
.upfill{height:100%;width:0;background:linear-gradient(90deg,#2b5c91,#4aa3ff);transition:width .2s}
.modal-wrap{position:fixed;inset:0;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center;z-index:100}
.modal{background:var(--panel);border:1px solid var(--line);border-radius:12px;max-width:520px;width:90%;padding:18px 20px;box-shadow:0 14px 44px rgba(0,0,0,.55)}
.modal-title{font-size:16px;font-weight:600;margin-bottom:12px}
.modal-body{font-size:13px;color:var(--txt);white-space:normal;max-height:52vh;overflow:auto;line-height:1.55;word-break:break-word}
.modal-actions{display:flex;gap:10px;justify-content:flex-end;margin-top:18px}
</style></head><body>
<header><h1>Sonic Mighty 16K Revo &middot; Files</h1>
<span class="pill" id="statusPill">printer: checking&hellip;</span><span class="sp"></span>
<span class="pill" id="cntPill"></span></header>
<main>
  <div class="bar roots">
    <b class="muted">Go to:</b>
    <button class="q" onclick="go('/media/emmc/')">Internal (emmc)</button>
    <button class="q" onclick="go('/media/emmc0/')">Internal (emmc0)</button>
    <button class="q" onclick="go('/media/')">/media</button>
    <button class="q" onclick="go('/mnt/')">USB (/mnt)</button>
    <button class="q" onclick="go('/')">root /</button>
  </div>
  <div class="upzone" id="upzone">
    <input type="file" id="fileInput" accept=".ctb" style="display:none">
    <span id="upText">Drag a <b>.ctb</b> file here, or <a id="browseLink">click to browse</a> &mdash; uploads to <b>Internal</b> storage</span>
    <div class="upbar" id="upbar" style="display:none"><div class="upfill" id="upfill"></div></div>
    <div id="upStatus" class="muted" style="display:none;margin-top:6px"></div>
  </div>
  <div class="crumbs" id="crumbs"></div>
  <div class="bar">
    <button onclick="reload()">&#8635; Refresh</button>
    <button id="upBtn" onclick="up()">&#8593; Up</button>
    <button class="danger" id="delBtn" disabled onclick="delSel()">&#128465; Delete selected</button>
    <span class="muted" id="selInfo"></span>
  </div>
  <div id="msg"></div>
  <table><thead><tr><th class="chk"><input type="checkbox" id="all" onchange="toggleAll(this)"></th>
    <th>Name</th><th class="size">Size</th><th class="date">Modified</th><th>Actions</th></tr></thead>
    <tbody id="tb"><tr><td colspan="5" class="empty">loading&hellip;</td></tr></tbody></table>
  <p class="muted" style="margin-top:16px;font-size:12px">The <b>Print</b> button starts a physical print and is only enabled when the printer is <b>idle</b> (it is greyed out and the server refuses the request while a print is running). Click an <b>Internal</b> file's name to <b>rename</b> it (the file is copied to the new name then the original is deleted; idle only). Delete is allowed only under <b>/media</b> and <b>/mnt</b>, and is disabled while printing. Status above updates automatically and is read-only &mdash; it sends nothing to the printer.</p>
</main>
<div id="modalWrap" class="modal-wrap" style="display:none">
  <div class="modal">
    <div class="modal-title" id="modalTitle"></div>
    <div class="modal-body" id="modalBody"></div>
    <div class="modal-actions" id="modalActions"></div>
  </div>
</div>
<script>
let cur="/media/emmc/";
const $=s=>document.querySelector(s);
function fmt(b){if(b==null||b<0)return"";const u=["B","KB","MB","GB"];let i=0,n=+b;while(n>=1024&&i<3){n/=1024;i++}return n.toFixed(n<10&&i>0?1:0)+" "+u[i]}
function dt(t){if(!t||t<0)return"";const d=new Date(t*1000);return d.toLocaleString()}
function msg(t,cls){const m=$("#msg");m.textContent=t;m.className=cls||"";}
function crumbs(){const c=$("#crumbs");const parts=cur.split("/").filter(Boolean);let acc="/";let h=`<a onclick="go('/')">/</a> `;for(const p of parts){acc+=p+"/";const a=acc;h+=`<a onclick="go('${a}')">${p}</a>/ `;}c.innerHTML=h;}
function go(p){cur=p.endsWith("/")?p:p+"/";reload({nav:true});}
function up(){if(cur==="/")return;const p=cur.replace(/[^/]+\/$/,"");go(p||"/");}
// fetch the listing with retries; returns an array, or null on total failure.
async function loadList(retries){
  if(retries==null)retries=3;
  for(let i=0;i<=retries;i++){
    try{
      const r=await fetch("/api/list?path="+encodeURIComponent(cur));
      const j=await r.json();
      if(!j.error) return Array.isArray(j.entries)?j.entries:(j.entries?Object.values(j.entries):[]);
    }catch(e){}
    if(i<retries) await new Promise(s=>setTimeout(s,600));
  }
  return null;
}
// nav=true (changing directory): show a loading placeholder.
// otherwise (refresh / after an action): keep the current rows on screen and only
// swap them once fresh data is in hand -> no blank flash, ever.
async function reload(opts){
  opts=opts||{};
  crumbs();
  if(opts.nav){ $("#all").checked=false; $("#tb").innerHTML=`<tr><td colspan="5" class="empty">loading ${cur}&hellip;</td></tr>`; }
  const list=await loadList(opts.retries);
  if(list===null){ if(opts.nav) $("#tb").innerHTML=`<tr><td colspan="5" class="empty">could not read printer listing (try Refresh)</td></tr>`; return; }
  render(list);
}
function render(list){
  list.sort((a,b)=>(b.isDir-a.isDir)||a.name.localeCompare(b.name));
  const canDel=cur.startsWith("/media/")||cur.startsWith("/mnt/");
  const tb=$("#tb");tb.innerHTML="";
  if(!list.length){tb.innerHTML=`<tr><td colspan="5" class="empty">empty</td></tr>`;}
  let files=0,dirs=0;
  for(const e of list){
    e.isDir?dirs++:files++;
    const tr=document.createElement("tr");if(e.isDir)tr.className="dir";
    const chk=(!e.isDir&&canDel)?`<input type="checkbox" class="rc" data-path="${e.path}" data-name="${e.name.replace(/"/g,'&quot;')}" onchange="upd()">`:"";
    const dl=e.isDir?"":`<a class="dl" href="/api/download?path=${encodeURIComponent(e.path)}">download</a>`;
    const printable=(!e.isDir)&&(cur.startsWith("/media/emmc/")||cur.startsWith("/mnt/"));
    const pb=printable?`<button class="print" data-print>&#9654; Print</button>`:"";
    tr.innerHTML=`<td class="chk">${chk}</td>
      <td class="name">${e.isDir?"&#128193; ":"&#128196; "}${escapeHtml(e.name)}</td>
      <td class="size">${e.isDir?"":fmt(e.size)}</td><td class="date">${dt(e.mtime)}</td><td class="act">${dl}${pb}</td>`;
    if(e.isDir)tr.querySelector("td.name").onclick=()=>go(e.path);
    else if(cur.startsWith("/media/emmc/")){ // internal files: click name to rename
      const nt=tr.querySelector("td.name");nt.classList.add("ren");nt.title="Click to rename";nt.onclick=()=>renameFile(e.path,e.name);
    }
    const pbtn=tr.querySelector("button.print"); if(pbtn){ pbtn.onclick=()=>printFile(e.path,e.name); }
    tb.appendChild(tr);
  }
  $("#cntPill").textContent=`${dirs} folders, ${files} files`;
  if(!canDel)msg("Delete is disabled here (only /media and /mnt allow deletion). Browsing/downloading still work.","warn");
  applyState();
}
function escapeHtml(s){return s.replace(/[&<>]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;"}[c]));}
// ---- in-app modal dialogs (replace browser confirm/alert) ----
function showModal(title,bodyHtml,buttons){
  $("#modalTitle").textContent=title;
  $("#modalBody").innerHTML=bodyHtml;
  const act=$("#modalActions");act.innerHTML="";
  buttons.forEach(b=>{const btn=document.createElement("button");btn.innerHTML=b.label;if(b.cls)btn.className=b.cls;btn.onclick=()=>{closeModal();if(b.onClick)b.onClick();};act.appendChild(btn);});
  $("#modalWrap").style.display="flex";
}
function closeModal(){$("#modalWrap").style.display="none";$("#modalActions").innerHTML="";}
function confirmModal(title,bodyHtml,okLabel,danger){return new Promise(res=>{showModal(title,bodyHtml,[{label:"Cancel",onClick:()=>res(false)},{label:okLabel||"OK",cls:danger?"danger":"primary",onClick:()=>res(true)}]);});}
function infoModal(title,bodyHtml){return new Promise(res=>{showModal(title,bodyHtml,[{label:"OK",cls:"primary",onClick:()=>res(true)}]);});}
function bulletList(items){return items.map(n=>"&bull; "+escapeHtml(n)).join("<br>");}
function toggleAll(cb){document.querySelectorAll(".rc").forEach(c=>c.checked=cb.checked);upd();}
function upd(){const s=[...document.querySelectorAll(".rc")].filter(c=>c.checked);$("#selInfo").textContent=s.length?`${s.length} selected`:"";$("#delBtn").disabled=!s.length||PRINTER.state==='printing';}
let PRINTER={state:'unknown'};
function shortName(n){if(!n)return"";return n.length>44?n.slice(0,42)+"...":n;}
function applyState(){
  const idle=PRINTER.state==='idle';
  document.querySelectorAll("button.print").forEach(b=>{b.disabled=!idle;b.title=idle?"Start printing this file":("Disabled - printer is "+PRINTER.state);});
  upd();
}
let statusFails=0;
async function pollStatus(){
  const p=$("#statusPill");
  try{
    const r=await fetch("/api/status");const j=await r.json();
    statusFails=0;PRINTER=j;
    if(j.state==='printing'){p.className="pill st-printing";p.innerHTML=`&#128295; PRINTING &mdash; ${escapeHtml(shortName(j.filename))} &middot; layer ${j.current}/${j.total} (${j.percent}%)`;}
    else if(j.state==='idle'){p.className="pill st-idle";p.textContent="Printer: idle";}
    else{p.className="pill st-unknown";p.textContent="Printer: "+j.state;}
  }catch(e){
    // debounce: keep the last known state through a brief blip (e.g. during a delete),
    // only degrade after several consecutive failures.
    statusFails++;
    if(statusFails>=3){PRINTER={state:'unknown'};p.className="pill st-unknown";p.textContent="Printer: status error";}
  }
  applyState();
}
async function printFile(path,name){
  if(PRINTER.state!=='idle'){await infoModal("Printer busy","The printer is <b>"+PRINTER.state+"</b> right now &mdash; a print can only be started when it is idle.");return;}
  const body=`This will <b>start a physical print immediately</b>.<br><br>Make sure the build plate is clean and mounted and the vat has resin.<br><br><b>File:</b> ${escapeHtml(name)}`;
  if(!await confirmModal("Start print?",body,"&#9654; Start print",false))return;
  msg("starting print...","warn");
  try{
    const r=await fetch("/api/print",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({path})});
    const j=await r.json();
    if(j.ok){msg("Print started: "+j.filename,"ok");}
    else if(j.blocked){msg("Blocked: printer is "+j.state+". Print NOT started.","err");}
    else{msg("Print not started"+(j.ack!=null?" (ack="+j.ack+")":"")+": "+(j.error||""),"err");}
  }catch(e){msg("print request failed: "+e.message,"err");}
  setTimeout(pollStatus,1500);
}
// ---- rename (copy-under-new-name + delete original; Internal files only) ----
function renameFile(path,name){
  if(PRINTER.state!=='idle'){infoModal("Printer busy","Rename copies the file, which can only run when the printer is <b>idle</b> (it is currently <b>"+PRINTER.state+"</b>).");return;}
  const body=`Rename this file on the printer's Internal storage.<br><br>`+
    `<span class="muted">There is no native rename, so the file is <b>copied</b> to the new name and the original is then deleted &mdash; this can take a moment for large files.</span><br><br>`+
    `<input id="renInput" type="text" spellcheck="false" value="${name.replace(/"/g,'&quot;')}" `+
    `style="width:100%;padding:8px 10px;border-radius:7px;border:1px solid var(--line);background:var(--panel2);color:var(--txt);font:inherit">`;
  showModal("Rename file",body,[
    {label:"Cancel"},
    {label:"Rename",cls:"primary",onClick:()=>doRename(path,name)}
  ]);
  setTimeout(()=>{const i=$("#renInput");if(!i)return;i.focus();const d=name.lastIndexOf(".");i.setSelectionRange(0,d>0?d:name.length);
    i.addEventListener("keydown",ev=>{if(ev.key==="Enter"){ev.preventDefault();const p=path,n=name;closeModal();doRename(p,n,i.value);}});},30);
}
async function doRename(path,oldName,typed){
  // when invoked from the button, closeModal() has already run but modalBody isn't
  // cleared, so #renInput is still readable; Enter passes the value in directly.
  const inp=$("#renInput");
  const newName=(typed!=null?typed:(inp?inp.value:"")).trim();
  if(!newName||newName===oldName)return;
  if(/[\\/]/.test(newName)){await infoModal("Invalid name","The name can't contain slashes.");return;}
  if(/\.ctb$/i.test(oldName)&&!/\.ctb$/i.test(newName)){
    if(!await confirmModal("Change file type?","The new name doesn't end in <b>.ctb</b>, which may make it unprintable.<br><br>Rename anyway?","Rename",false))return;
  }
  msg("renaming - copying "+escapeHtml(oldName)+" ...","warn");
  try{
    const r=await fetch("/api/rename",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({path,newName})});
    const j=await r.json();
    if(j.ok){
      msg("");
      cur="/media/emmc/";await reload({nav:true});
      await infoModal("Rename complete","Renamed to <b>"+escapeHtml(j.newName)+"</b>."+(j.oldRemoved?"":"<br><br><b>Note:</b> the original could not be removed and may still be present."));
    }else if(j.blocked){msg("Blocked: printer is "+j.state+". Nothing was changed.","err");}
    else{msg("Rename failed: "+(j.error||""),"err");}
  }catch(e){msg("rename request failed: "+e.message,"err");}
}
async function delSel(){
  const s=[...document.querySelectorAll(".rc")].filter(c=>c.checked);
  if(!s.length)return;
  const paths=s.map(c=>c.dataset.path),names=s.map(c=>c.dataset.name);
  const cbody=`Permanently delete <b>${paths.length}</b> file(s) from the printer? This cannot be undone.<br><br>`+bulletList(names);
  if(!await confirmModal("Delete files?",cbody,"&#128465; Delete",true))return;
  $("#delBtn").disabled=true;msg("deleting&hellip;","warn");
  let okc=0,failLines=[];
  try{
    const r=await fetch("/api/delete",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({paths})});
    const j=await r.json();
    const verified=j.results.filter(x=>x.verified);okc=verified.length;
    // optimistically remove deleted rows immediately -> no blank flash while we reconcile
    const delset=new Set(verified.map(x=>x.path));
    document.querySelectorAll(".rc").forEach(cb=>{if(delset.has(cb.dataset.path)){const tr=cb.closest("tr");if(tr)tr.remove();}});
    failLines=j.results.filter(x=>!x.verified).map(f=>`${f.path} (ack=${f.ack}, after=${f.after}${f.error?", "+f.error:""})`);
  }catch(e){failLines=["request failed: "+e.message];}
  msg("");
  // silent reload keeps the (already-pruned) rows on screen and swaps to the fresh
  // list only once the printer's listing recovers -> never shows an empty table.
  await reload({retries:6});
  let rb=`Deleted <b>${okc}</b> file(s).`;
  if(failLines.length)rb+=`<br><br><b>Not removed:</b><br>`+bulletList(failLines);
  await infoModal(failLines.length?"Delete finished with errors":"Delete complete",rb);
}
// ---- upload (chunked, with progress + drag/drop) ----
function genUuid(){let s="";for(let i=0;i<32;i++)s+=Math.floor(Math.random()*16).toString(16);return s;}
function initUpload(){
  const z=$("#upzone"),fi=$("#fileInput");
  z.onclick=()=>fi.click();
  fi.onchange=()=>{const f=fi.files[0];fi.value="";if(f)uploadFile(f);};
  ["dragenter","dragover"].forEach(ev=>z.addEventListener(ev,e=>{e.preventDefault();e.stopPropagation();z.classList.add("drag");}));
  ["dragleave","dragend"].forEach(ev=>z.addEventListener(ev,e=>{e.preventDefault();e.stopPropagation();z.classList.remove("drag");}));
  z.addEventListener("drop",e=>{e.preventDefault();e.stopPropagation();z.classList.remove("drag");const f=e.dataTransfer.files&&e.dataTransfer.files[0];if(f)uploadFile(f);});
}
async function uploadFile(file){
  if(PRINTER.state==='printing'){await infoModal("Printer busy","Can't upload while a print is running. Wait until the printer is idle.");return;}
  if(!/\.ctb$/i.test(file.name)){ if(!await confirmModal("Not a .ctb file","This doesn't look like a sliced <b>.ctb</b> file:<br><br>&bull; "+escapeHtml(file.name)+"<br><br>Upload it anyway?","Upload",false))return; }
  const total=file.size,uuid=genUuid(),name=file.name,CH=1048576;
  const z=$("#upzone"),bar=$("#upbar"),fill=$("#upfill"),st=$("#upStatus");
  z.style.pointerEvents="none";bar.style.display="block";st.style.display="block";fill.style.width="0%";
  st.textContent="Uploading "+name+" ...";
  try{
    for(let off=0;off<total;off+=CH){
      const chunk=await file.slice(off,Math.min(off+CH,total)).arrayBuffer();
      const q=`?name=${encodeURIComponent(name)}&uuid=${uuid}&offset=${off}&total=${total}`;
      const r=await fetch("/api/uploadchunk"+q,{method:"POST",headers:{"Content-Type":"application/octet-stream"},body:chunk});
      const j=await r.json();
      if(!j.ok)throw new Error(j.error||("printer rejected the file (code "+(j.code||j.httpcode)+")"));
      const done=Math.min(off+CH,total);
      fill.style.width=(100*done/total).toFixed(1)+"%";
      st.textContent=`Uploading ${name} - ${fmt(done)} / ${fmt(total)} (${Math.round(100*done/total)}%)`;
    }
    st.textContent="Finalizing ...";
    cur="/media/emmc/";await reload({nav:true});
    await infoModal("Upload complete",escapeHtml(name)+" was uploaded to <b>Internal</b> storage.");
  }catch(e){
    await infoModal("Upload failed","Could not upload "+escapeHtml(name)+":<br><br>"+escapeHtml(e.message));
  }finally{
    z.style.pointerEvents="";bar.style.display="none";st.style.display="none";fill.style.width="0%";
  }
}
go(cur);
initUpload();
pollStatus();
setInterval(pollStatus,3000);
</script></body></html>
'@

$listener = New-Object System.Net.HttpListener
$prefix = "http://127.0.0.1:$LocalPort/"
$listener.Prefixes.Add($prefix)
try { $listener.Start() } catch { Write-Host "Could not start local server on $prefix`n$($_.Exception.Message)" -ForegroundColor Red; Write-Host "Try a different -LocalPort." ; exit 1 }
Write-Host "==================================================================" -ForegroundColor Green
Write-Host " Revo File Manager running:  $prefix" -ForegroundColor Green
Write-Host " Talking to printer:         $PBASE" -ForegroundColor Green
Write-Host " Press Ctrl+C here to stop." -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
if (-not $NoBrowser) { try { Start-Process $prefix } catch {} }

$LOG = Join-Path $PSScriptRoot "revo_server.log"
function Log([string]$m){ try { ("{0}  {1}" -f (Get-Date -Format "HH:mm:ss"), $m) | Out-File -FilePath $LOG -Append -Encoding utf8 } catch {} }
function Send-Bytes($resp,[byte[]]$b,[string]$ctype,[int]$code=200){
  try { $resp.StatusCode=$code; $resp.ContentType=$ctype; $resp.ContentLength64=$b.Length; $resp.OutputStream.Write($b,0,$b.Length) } catch { Log "write error: $($_.Exception.Message)" }
}
function Send-Json($resp,$obj,[int]$code=200){ Send-Bytes $resp ([Text.Encoding]::UTF8.GetBytes(($obj|ConvertTo-Json -Depth 8 -Compress))) "application/json; charset=utf-8" $code }

# Stray errors while serving must never terminate the accept loop.
$ErrorActionPreference = "Continue"
Log "server started on $prefix -> $PBASE"

# ---------- background printer-status monitor ----------
# One long-lived, RECEIVE-ONLY connection maintained on a separate thread.
# It updates $STATE continuously so /api/status is instant and never blocks the
# web server. It sends NOTHING to the printer, so it cannot interrupt a print.
$STATE = [hashtable]::Synchronized(@{ state='unknown'; filename=''; current=0; total=0; percent=0; ts=0 })
$monitorScript = {
  param($st,$ip,$port)
  $fail = 0   # debounce: only report 'unreachable' after several consecutive misses,
              # so a brief blip (e.g. during a delete) doesn't flip the status pill.
  $silent = 0        # consecutive cycles with NO status push while we believe a print is active
  $IDLE_CONFIRM = 3  # require this many silent cycles before flipping printing -> idle
  while ($true) {
    try {
      $cts = New-Object System.Threading.CancellationTokenSource
      $ws  = New-Object System.Net.WebSockets.ClientWebSocket
      $ct  = $ws.ConnectAsync([Uri]("ws://{0}:{1}/websocket" -f $ip,$port),$cts.Token)
      if (-not $ct.Wait(3000) -or $ws.State -ne 'Open') {
        $fail++; if ($fail -ge 3) { $st.state='unreachable' }; try{$ws.Abort()}catch{}; Start-Sleep -Milliseconds 1500; continue
      }
      $buf = New-Object byte[] 131072
      $seg = New-Object System.ArraySegment[byte] (,$buf)
      $pending = $ws.ReceiveAsync($seg,$cts.Token)
      $deadline = [DateTime]::UtcNow.AddMilliseconds(6000)
      $sawStatus=$false; $ns=$null; $fn=''; $cur=0; $tot=0; $pct=0
      while ([DateTime]::UtcNow -lt $deadline -and $ws.State -eq 'Open') {
        if (-not $pending.Wait(200)) { continue }
        try { $r = $pending.Result } catch { break }
        if ($r.MessageType -eq 'Close') { break }
        $txt = [Text.Encoding]::UTF8.GetString($buf,0,$r.Count)
        if ($txt -like '*sdcp/status*') {
          $sawStatus=$true
          try {
            $o=$txt|ConvertFrom-Json; $cs=$o.Status.CurrentStatus[0]; $pi=$o.Status.PrintInfo
            if ($cs -eq 1) { $ns='printing'; $fn=$pi.Filename; $cur=[int]$pi.CurrentLayer; $tot=[int]$pi.TotalLayer; if($tot -gt 0){$pct=[math]::Round(100.0*$cur/$tot)} }
            else { $ns='idle' }
          } catch {}
          break
        }
        $seg = New-Object System.ArraySegment[byte] (,$buf); $pending = $ws.ReceiveAsync($seg,$cts.Token)
      }
      try{$ws.Abort()}catch{}; try{$ws.Dispose()}catch{}
      $fail = 0   # the connection itself worked this cycle
      $st.ts=[int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
      if ($sawStatus -and $ns -eq 'printing') {
        # live print push: trust it immediately and refresh the layer details
        $silent = 0
        $st.state='printing'; $st.filename=$fn; $st.current=$cur; $st.total=$tot; $st.percent=$pct
      }
      elseif ($sawStatus -and $ns -eq 'idle') {
        # printer explicitly reported a non-printing status -> genuinely idle
        $silent = 0
        $st.state='idle'; $st.filename=''; $st.current=0; $st.total=0; $st.percent=0
      }
      else {
        # NO status push this cycle. The firmware streams status ONLY while printing,
        # but a push can land just outside our listen window, so a single silent cycle
        # is ambiguous - it was flipping the pill printing<->idle mid-print. Only flip an
        # active print to idle after several consecutive silent cycles (hysteresis).
        if ($st.state -eq 'printing') {
          $silent++
          if ($silent -ge $IDLE_CONFIRM) {
            $silent = 0
            $st.state='idle'; $st.filename=''; $st.current=0; $st.total=0; $st.percent=0
          }
          # else: hold the last known printing state + layer info untouched
        } else {
          # was idle/unknown and still silent -> idle
          $silent = 0
          $st.state='idle'; $st.filename=''; $st.current=0; $st.total=0; $st.percent=0
        }
      }
    } catch { $fail++; if ($fail -ge 3) { $st.state='unreachable' } }
    Start-Sleep -Milliseconds 800
  }
}
$monRS = [runspacefactory]::CreateRunspace(); $monRS.Open()
$monPS = [powershell]::Create(); $monPS.Runspace = $monRS
[void]$monPS.AddScript($monitorScript).AddArgument($STATE).AddArgument($PrinterIp).AddArgument($PrinterPort)
[void]$monPS.BeginInvoke()

while ($true) {
  if (-not $listener.IsListening) { break }
  try { $ctx = $listener.GetContext() }
  catch { Log "GetContext error: $($_.Exception.Message)"; if (-not $listener.IsListening) { break }; continue }
  $req = $ctx.Request; $resp = $ctx.Response
  try {
    $route = $req.Url.AbsolutePath
    Log "$($req.HttpMethod) $($req.Url.PathAndQuery)"
    if ($route -eq "/" ) {
      Send-Bytes $resp ([Text.Encoding]::UTF8.GetBytes($html)) "text/html; charset=utf-8"
    }
    elseif ($route -eq "/favicon.ico") { $resp.StatusCode = 204 }
    elseif ($route -eq "/api/list") {
      $path = $req.QueryString["path"]; if (-not $path) { $path = "/" }
      if (-not $path.EndsWith("/")) { $path += "/" }
      $res = Printer-Request "GET" $path
      if ($res.code -ne 200) { Send-Json $resp @{ error = "printer returned $($res.code) for $path" } }
      else {
        $htmlDir = [Text.Encoding]::UTF8.GetString($res.bytes)
        $entries = @(Parse-Listing $htmlDir $path)
        Send-Json $resp @{ path=$path; entries=$entries; count=$entries.Count }
      }
    }
    elseif ($route -eq "/api/uploadchunk" -and $req.HttpMethod -eq "POST") {
      # one 1MB chunk from the browser -> forwarded to the printer's SDCP upload endpoint
      $q = $req.QueryString
      $name = $q["name"]; $uuid = $q["uuid"]; $offset = [long]$q["offset"]; $total = [long]$q["total"]
      $mem = New-Object System.IO.MemoryStream; $req.InputStream.CopyTo($mem); $chunk = $mem.ToArray()
      $fields = [ordered]@{ "S-File-MD5"=""; "Check"="0"; "Offset"="$offset"; "Uuid"=$uuid; "TotalSize"="$total" }
      $pr = Post-Multipart "$PBASE/uploadFile/upload" $fields "File" $name $chunk
      $ok = $false; $code = ""
      try { $o = $pr.body | ConvertFrom-Json; $ok = [bool]$o.success; $code = "$($o.code)" } catch {}
      Log "UPLOAD $name off=$offset/$total len=$($chunk.Length) -> http=$($pr.code) success=$ok code=$code"
      $errTxt = $null; if (-not $ok) { $errTxt = "printer response: " + $pr.body }
      Send-Json $resp @{ ok=$ok; code=$code; httpcode=$pr.code; error=$errTxt }
    }
    elseif ($route -eq "/api/download") {
      $path = $req.QueryString["path"]
      $res = Printer-Request "GET" $path 120000
      if ($res.code -ne 200) { Send-Json $resp @{ error="printer $($res.code)" } 502 }
      else {
        $name = [System.Uri]::UnescapeDataString(($path -split '/')[-1])
        $resp.AddHeader("Content-Disposition","attachment; filename=`"$name`"")
        Send-Bytes $resp $res.bytes "application/octet-stream"
      }
    }
    elseif ($route -eq "/api/delete" -and $req.HttpMethod -eq "POST") {
      $body = (New-Object IO.StreamReader($req.InputStream)).ReadToEnd()
      $paths = @((ConvertFrom-Json $body).paths)
      # map browser paths -> SDCP paths (/media/emmc -> /local, /mnt -> /usb)
      $sdcpList = @(); $map = @{}
      foreach ($p in $paths) {
        $dec  = [System.Uri]::UnescapeDataString($p)
        $name = [System.Uri]::UnescapeDataString(($p -split '/')[-1])
        $s = $null
        if ($dec -like '/media/emmc/*') { $s = "/local/$name" } elseif ($dec -like '/mnt/*') { $s = "/usb/$name" }
        $map[$p] = $s; if ($s) { $sdcpList += $s }
      }
      $delAck = $null; $delErr = $null
      if ($sdcpList.Count) { $dr = Send-DeleteFiles $sdcpList; $delAck = $dr.ack; $delErr = $dr.error }
      $results = @()
      foreach ($p in $paths) {
        $s = $map[$p]
        if (-not $s) { $results += @{ path=$p; verified=$false; error="Only internal /media/emmc and USB /mnt files can be deleted (SDCP has no path for this location)." }; continue }
        $after = (Printer-Request "HEAD" $p).code   # verify via HTTP: 404 = gone
        Log "DELETE(sdcp) $s ack=$delAck after=$after"
        $results += @{ path=$p; sdcp=$s; ack=$delAck; after=$after; verified=($after -eq 404) }
      }
      Send-Json $resp @{ results=@($results); ack=$delAck; err=$delErr }
    }
    elseif ($route -eq "/api/status") {
      # instant read of the background monitor's shared state (never blocks)
      Send-Json $resp @{ state=$STATE.state; filename=$STATE.filename; current=$STATE.current; total=$STATE.total; percent=$STATE.percent }
    }
    elseif ($route -eq "/api/print" -and $req.HttpMethod -eq "POST") {
      $body = (New-Object IO.StreamReader($req.InputStream)).ReadToEnd()
      $path = (ConvertFrom-Json $body).path
      # SAFETY GATE: refuse unless the monitor reports the printer is idle
      $pstate = $STATE.state
      if ($pstate -ne 'idle') {
        Log "PRINT blocked: printer state=$pstate for $path"
        Send-Json $resp @{ ok=$false; blocked=$true; state=$pstate; error="Printer is $pstate - refusing to start a print." }
      } else {
        $dec  = [System.Uri]::UnescapeDataString($path)
        $name = [System.Uri]::UnescapeDataString(($path -split '/')[-1])
        $sdcp = $null
        if ($dec -like '/media/emmc/*') { $sdcp = "/local/$name" }
        elseif ($dec -like '/mnt/*')     { $sdcp = "/usb/$name" }
        if (-not $sdcp) { Send-Json $resp @{ ok=$false; error="Not a printable location (only internal /media/emmc and USB /mnt)." } }
        else {
          Log "PRINT start (idle-verified): $sdcp"
          $r = Send-StartPrint $sdcp
          Log "PRINT result ack=$($r.ack) ok=$($r.ok) err=$($r.error)"
          Send-Json $resp @{ ok=$r.ok; ack=$r.ack; error=$r.error; filename=$sdcp }
        }
      }
    }
    elseif ($route -eq "/api/rename" -and $req.HttpMethod -eq "POST") {
      # SDCP has NO rename command, so rename = copy-under-new-name then delete original.
      # Re-upload only ever lands in /local, so this is Internal (emmc) only.
      $body = (New-Object IO.StreamReader($req.InputStream)).ReadToEnd()
      $rq = ConvertFrom-Json $body
      $oldPath = $rq.path; $newName = "$($rq.newName)".Trim()
      # SAFETY GATE: copy+delete must never run mid-print
      $pstate = $STATE.state
      if ($pstate -ne 'idle') {
        Log "RENAME blocked: printer state=$pstate for $oldPath"
        Send-Json $resp @{ ok=$false; blocked=$true; state=$pstate; error="Printer is $pstate - refusing to rename." }
      } else {
        $decOld  = [System.Uri]::UnescapeDataString($oldPath)
        $oldName = [System.Uri]::UnescapeDataString(($oldPath -split '/')[-1])
        if ($decOld -notlike '/media/emmc/*') {
          Send-Json $resp @{ ok=$false; error="Rename is only supported for Internal (emmc) files." }
        } elseif ([string]::IsNullOrWhiteSpace($newName) -or $newName -match '[\\/]' -or $newName -eq '..' -or $newName -eq '.') {
          Send-Json $resp @{ ok=$false; error="Invalid file name." }
        } elseif ($newName -eq $oldName) {
          Send-Json $resp @{ ok=$false; error="The new name is the same as the current name." }
        } else {
          # same directory, new (encoded) path for HTTP existence checks
          $dirEnc  = $oldPath.Substring(0, $oldPath.LastIndexOf('/') + 1)
          $newPathEnc = $dirEnc + [System.Uri]::EscapeDataString($newName)
          if ((Printer-Request "HEAD" $newPathEnc).code -eq 200) {
            Send-Json $resp @{ ok=$false; error="A file named '$newName' already exists here." }
          } else {
            $src = Printer-Request "GET" $oldPath 300000
            if ($src.code -ne 200) {
              Send-Json $resp @{ ok=$false; error="Could not read the source file (printer $($src.code))." }
            } else {
              $bytes = $src.bytes; $total = $bytes.Length; $uuid = [guid]::NewGuid().ToString("N")
              $CH = 1048576; $ok = $true; $errTxt = $null
              for ($off = 0; $off -lt $total; $off += $CH) {
                $len = [Math]::Min($CH, $total - $off)
                $chunk = New-Object byte[] $len
                [Array]::Copy($bytes, [long]$off, $chunk, 0, $len)
                $fields = [ordered]@{ "S-File-MD5"=""; "Check"="0"; "Offset"="$off"; "Uuid"=$uuid; "TotalSize"="$total" }
                $pr = Post-Multipart "$PBASE/uploadFile/upload" $fields "File" $newName $chunk
                $cok = $false; try { $o = $pr.body | ConvertFrom-Json; $cok = [bool]$o.success } catch {}
                if (-not $cok) { $ok = $false; $errTxt = "upload failed at offset $off (printer: $($pr.body))"; break }
              }
              if (-not $ok) {
                Log "RENAME copy failed $oldName -> $newName : $errTxt"
                Send-Json $resp @{ ok=$false; error=$errTxt }
              } elseif ((Printer-Request "HEAD" $newPathEnc).code -ne 200) {
                Send-Json $resp @{ ok=$false; error="Copy did not verify - the new file was not found after upload. Original left untouched." }
              } else {
                # new copy verified present -> remove the original via SDCP Cmd 259
                $dr = Send-DeleteFiles @("/local/$oldName")
                $delAfter = (Printer-Request "HEAD" $oldPath).code   # 404 = gone
                Log "RENAME $oldName -> $newName (ack=$($dr.ack) oldAfter=$delAfter)"
                Send-Json $resp @{ ok=$true; newName=$newName; oldRemoved=($delAfter -eq 404); ack=$dr.ack }
              }
            }
          }
        }
      }
    }
    else { Send-Json $resp @{ error="not found" } 404 }
  } catch {
    Log "handler error on $($req.Url.PathAndQuery): $($_.Exception.Message)"
    try { Send-Json $resp @{ error=$_.Exception.Message } 500 } catch {}
  } finally {
    try { $resp.OutputStream.Close() } catch {}
    try { $resp.Close() } catch {}
  }
}
