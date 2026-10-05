$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== LAPI Cloudflare Tunnel ===" -ForegroundColor Cyan

$healthUrl = "http://127.0.0.1:5678/healthz"
try {
    $h = Invoke-WebRequest -UseBasicParsing -Uri $healthUrl -TimeoutSec 10
    Write-Host ("Local n8n OK: HTTP " + $h.StatusCode) -ForegroundColor Green
} catch {
    throw "n8n is not reachable at http://127.0.0.1:5678. Start n8n first."
}

$toolDir = Join-Path $HOME ".lapi-tools"
New-Item -ItemType Directory -Path $toolDir -Force | Out-Null
$cloudflared = Join-Path $toolDir "cloudflared.exe"

if (-not (Test-Path $cloudflared)) {
    Write-Host "Downloading cloudflared..." -ForegroundColor Cyan
    Invoke-WebRequest "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" -OutFile $cloudflared
}

$pidFile = Join-Path $toolDir "lapi-cloudflared.pid"
if (Test-Path $pidFile) {
    $oldPid = Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($oldPid -match "^\d+$") {
        Stop-Process -Id ([int]$oldPid) -Force -ErrorAction SilentlyContinue
    }
}

$outLog = Join-Path $toolDir "lapi-cloudflared-out.log"
$errLog = Join-Path $toolDir "lapi-cloudflared-err.log"
Remove-Item $outLog,$errLog -Force -ErrorAction SilentlyContinue

Write-Host "Starting HTTPS tunnel..." -ForegroundColor Cyan
$p = Start-Process -FilePath $cloudflared -ArgumentList @("tunnel","--no-autoupdate","--url","http://127.0.0.1:5678") -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru -WindowStyle Hidden
Set-Content -Path $pidFile -Value $p.Id -Encoding ASCII

$publicUrl = $null
for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep -Seconds 1
    $text = ""
    if (Test-Path $outLog) { $text += (Get-Content $outLog -Raw -ErrorAction SilentlyContinue) }
    if (Test-Path $errLog) { $text += "`n" + (Get-Content $errLog -Raw -ErrorAction SilentlyContinue) }

    $urls = @([regex]::Matches($text, "https://[a-zA-Z0-9-]+\.trycloudflare\.com") | ForEach-Object { $_.Value } | Where-Object { $_ -ne "https://api.trycloudflare.com" } | Select-Object -Unique)
    if ($urls.Count -gt 0) {
        $publicUrl = $urls[$urls.Count - 1].TrimEnd("/")
        break
    }

    if ($p.HasExited) { break }
}

if (-not $publicUrl) {
    Write-Host ""
    Write-Host "cloudflared output:" -ForegroundColor Yellow
    if (Test-Path $errLog) { Get-Content $errLog -Tail 50 }
    if (Test-Path $outLog) { Get-Content $outLog -Tail 50 }
    throw "No real trycloudflare.com tunnel URL was found."
}

Write-Host ""
Write-Host ("Public URL: " + $publicUrl) -ForegroundColor Green

try {
    $remote = Invoke-WebRequest -UseBasicParsing -Uri ($publicUrl + "/healthz") -TimeoutSec 20
    Write-Host ("Public tunnel OK: HTTP " + $remote.StatusCode) -ForegroundColor Green
} catch {
    Write-Host ""
    Write-Host ("Tunnel URL was created but health check failed: " + $publicUrl) -ForegroundColor Yellow
    throw
}

$infoFile = Join-Path $HOME "Desktop\LAPI-TUNNEL.txt"
@("Public n8n URL: " + $publicUrl, "PID: " + $p.Id) | Set-Content -Path $infoFile -Encoding UTF8

Write-Host ""
Write-Host "=== READY ===" -ForegroundColor Green
Write-Host ("Public n8n: " + $publicUrl)
Write-Host ("Saved: " + $infoFile)
Write-Host "Keep this PowerShell/Docker session and cloudflared process running while testing." -ForegroundColor Yellow
