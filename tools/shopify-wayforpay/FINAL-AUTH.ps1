$ErrorActionPreference = "Stop"

$ShopSubdomain = "i084rv-1z"
$ShopDomain = "$ShopSubdomain.myshopify.com"
$ClientId = "86a44d146a34902d79abbea8736d5576"
$RedirectUrl = "http://localhost:8765/callback"
$Scopes = "read_orders,write_orders,read_products,write_products"
$CredentialId = "lapi-shopify-access-token"
$CredentialName = "LAPI Shopify Access Token"

Write-Host ""
Write-Host "=== LAPI Shopify final auth ===" -ForegroundColor Cyan

$containers = @(docker ps -a --format "{{.Names}}")
$n8n = $containers | Where-Object { $_ -eq "n8n" } | Select-Object -First 1
if (-not $n8n) { $n8n = $containers | Where-Object { $_ -match "n8n" } | Select-Object -First 1 }
if (-not $n8n) { throw "n8n Docker container not found." }
if (@(docker ps --format "{{.Names}}") -notcontains $n8n) { docker start $n8n | Out-Null; Start-Sleep -Seconds 4 }

$toml = Get-ChildItem "$HOME\Desktop" -Filter "shopify.app.toml" -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -match "lapi-n8n-way-for-pay|LAPI-Shopify-n8n" } |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
if (-not $toml) { throw "shopify.app.toml not found." }

$p = $toml.FullName
$c = [IO.File]::ReadAllText($p).TrimStart([char]0xFEFF)
$nl = [Environment]::NewLine
$auth = "[auth]" + $nl + 'redirect_urls = ["http://localhost:5678/rest/oauth2-credential/callback", "http://localhost:8765/callback"]' + $nl
if ($c -match '(?ms)\[auth\].*?(?=\r?\n\[|\z)') {
  $c = [regex]::Replace($c,'(?ms)\[auth\].*?(?=\r?\n\[|\z)',$auth)
} else {
  $c += $nl + $auth
}
[IO.File]::WriteAllText($p,$c,(New-Object System.Text.UTF8Encoding($false)))

Push-Location (Split-Path $p)
try {
  shopify app deploy --allow-updates
  if ($LASTEXITCODE -ne 0) { throw "Shopify deploy failed." }
} finally { Pop-Location }

$sec = Read-Host "Paste Shopify Client secret (hidden)" -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
$listener = $null
$client = $null

try {
  $ClientSecret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,8765)
  $listener.Start()

  $state = [Guid]::NewGuid().ToString("N")
  $authUrl = "https://$ShopDomain/admin/oauth/authorize?client_id=$ClientId&scope=$([Uri]::EscapeDataString($Scopes))&redirect_uri=$([Uri]::EscapeDataString($RedirectUrl))&state=$state"
  Start-Process $authUrl

  $task = $listener.AcceptTcpClientAsync()
  if (-not $task.Wait(180000)) { throw "Timed out waiting for Shopify authorization." }
  $client = $task.Result
  $stream = $client.GetStream()
  $reader = New-Object IO.StreamReader($stream,[Text.Encoding]::ASCII,$false,1024,$true)

  $requestLine = $reader.ReadLine()
  while ($true) {
    $line = $reader.ReadLine()
    if ($null -eq $line -or $line -eq "") { break }
  }

  $target = ($requestLine -split " ")[1]
  $uri = [Uri]("http://localhost:8765" + $target)
  $q = @{}
  foreach ($part in $uri.Query.TrimStart("?").Split("&")) {
    if (-not $part) { continue }
    $kv = $part.Split("=",2)
    $key = [Uri]::UnescapeDataString($kv[0])
    $value = if ($kv.Count -gt 1) { [Uri]::UnescapeDataString($kv[1]) } else { "" }
    $q[$key] = $value
  }

  if ($q["state"] -ne $state) { throw "OAuth state mismatch." }
  if (-not $q["code"]) { throw "No Shopify authorization code returned." }

  $tok = Invoke-RestMethod -Method Post -Uri "https://$ShopDomain/admin/oauth/access_token" -ContentType "application/x-www-form-urlencoded" -Body @{
    client_id = $ClientId
    client_secret = $ClientSecret
    code = $q["code"]
    expiring = "0"
  }
  if (-not $tok.access_token) { throw "No Shopify access token returned." }

  $AccessToken = $tok.access_token

  $credential = @([ordered]@{
    id = $CredentialId
    name = $CredentialName
    type = "shopifyAccessTokenApi"
    data = [ordered]@{
      shopSubdomain = $ShopSubdomain
      accessToken = $AccessToken
      appSecretKey = $ClientSecret
    }
  })

  $f = Join-Path $env:TEMP "lapi-shopify-access-token.json"
  [IO.File]::WriteAllText($f,(ConvertTo-Json -InputObject $credential -Depth 20),(New-Object System.Text.UTF8Encoding($false)))
  docker cp $f "$($n8n):/tmp/lapi-shopify-access-token.json" | Out-Null
  docker exec $n8n n8n import:credentials --input=/tmp/lapi-shopify-access-token.json
  if ($LASTEXITCODE -ne 0) { throw "n8n credential import failed." }

  $crlf = [char]13 + [char]10
  $html = "<html><body><h2>Shopify connected successfully.</h2><p>You can close this window.</p></body></html>"
  $bb = [Text.Encoding]::UTF8.GetBytes($html)
  $header = "HTTP/1.1 200 OK" + $crlf + "Content-Type: text/html; charset=utf-8" + $crlf + "Content-Length: " + $bb.Length + $crlf + "Connection: close" + $crlf + $crlf
  $hb = [Text.Encoding]::ASCII.GetBytes($header)
  $stream.Write($hb,0,$hb.Length)
  $stream.Write($bb,0,$bb.Length)
  $stream.Flush()

  Write-Host ""
  Write-Host "SUCCESS: LAPI Shopify Access Token imported to n8n." -ForegroundColor Green
  Start-Process "http://localhost:5678/home/credentials"
}
finally {
  if ($client) { try { $client.Close() } catch {} }
  if ($listener) { try { $listener.Stop() } catch {} }
  if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
  Remove-Variable ClientSecret -ErrorAction SilentlyContinue
  Remove-Variable AccessToken -ErrorAction SilentlyContinue
}
