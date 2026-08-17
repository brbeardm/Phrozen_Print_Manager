param([string]$Ip = "192.168.1.187", [int]$Seconds = 20)
$cts = New-Object System.Threading.CancellationTokenSource
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$uri = [System.Uri]("ws://{0}:3030/websocket" -f $Ip)
Write-Host "Connecting $uri ..." -ForegroundColor Yellow
$ws.ConnectAsync($uri, $cts.Token).Wait()
Write-Host "CONNECTED. Passively listening $Seconds s (sending nothing)..." -ForegroundColor Yellow

$deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
$buf = New-Object byte[] 131072
$seg = New-Object System.ArraySegment[byte] (,$buf)
$pending = $ws.ReceiveAsync($seg, $cts.Token)
$sb = New-Object System.Text.StringBuilder
$n = 0
while ([DateTime]::UtcNow -lt $deadline -and $ws.State -eq 'Open') {
  if (-not $pending.Wait(250)) { continue }
  try { $r = $pending.Result } catch { Write-Host "RECV ERR: $($_.Exception.InnerException.Message) State=$($ws.State)" -ForegroundColor Red; break }
  if ($r.MessageType -eq 'Close') { Write-Host "CLOSE from printer: $($ws.CloseStatus) '$($ws.CloseStatusDescription)'" -ForegroundColor Red; break }
  if ($r.MessageType -eq 'Binary') { Write-Host ("BINARY frame, $($r.Count) bytes") -ForegroundColor DarkYellow }
  [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buf,0,$r.Count))
  if ($r.EndOfMessage) {
    $n++
    $t = [DateTime]::Now.ToString("HH:mm:ss.fff")
    Write-Host ("[$t] #$n <<< " + $sb.ToString()) -ForegroundColor Green
    $sb = New-Object System.Text.StringBuilder
  }
  $seg = New-Object System.ArraySegment[byte] (,$buf)
  $pending = $ws.ReceiveAsync($seg, $cts.Token)
}
Write-Host "Total messages: $n  FinalState=$($ws.State)" -ForegroundColor Yellow
try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,"bye",$cts.Token).Wait(1000) | Out-Null } catch {}
