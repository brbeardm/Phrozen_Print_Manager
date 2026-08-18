<#  Launcher for the Revo File Manager.
    Starts the local web server if it isn't already running, then opens Chrome
    (falls back to the default browser) at the app. Invoked by the "phrozen" command. #>
$ErrorActionPreference = "SilentlyContinue"
$port   = 8765
$url    = "http://127.0.0.1:$port"
$server = Join-Path $PSScriptRoot "revo_file_server.ps1"

function Test-Up {
  $c = New-Object Net.Sockets.TcpClient
  try { $r = $c.BeginConnect("127.0.0.1",$port,$null,$null); $ok = $r.AsyncWaitHandle.WaitOne(500) -and $c.Connected }
  catch { $ok = $false } finally { $c.Close() }
  return $ok
}

if (Test-Up) {
  Write-Host "Revo File Manager already running." -ForegroundColor Green
} else {
  Write-Host "Starting Revo File Manager..." -ForegroundColor Yellow
  # No -NoExit: if the server can't bind the port it self-closes instead of lingering
  # as a zombie. On success the listener loop keeps the (minimized) window open anyway.
  Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$server,'-NoBrowser' -WindowStyle Minimized
  for ($i=0; $i -lt 25; $i++) { Start-Sleep -Milliseconds 350; if (Test-Up) { break } }
  if (-not (Test-Up)) { Write-Host "Server did not start in time; try again in a moment." -ForegroundColor Red; exit 1 }
  Write-Host "Started." -ForegroundColor Green
}

# open Chrome if present, otherwise the default browser
$chrome = @(
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
  "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
  "$env:LocalAppData\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($chrome) { Start-Process $chrome $url } else { Start-Process $url }
Write-Host "Opened $url" -ForegroundColor Cyan

# one-time hint: the OBJ->STEP converter needs its Python venv installed
$venvPy = Join-Path $PSScriptRoot "files\.venv\Scripts\python.exe"
if (-not (Test-Path $venvPy)) {
  Write-Host "Note: the OBJ->STEP converter needs one-time setup - run setup_obj2step.ps1 (or double-click setup_obj2step.cmd)." -ForegroundColor Yellow
}
