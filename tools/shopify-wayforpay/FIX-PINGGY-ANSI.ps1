$ErrorActionPreference = "Stop"

$WorkflowId = "tENsj9N2NIiRitQR"

Write-Host ""
Write-Host "=== LAPI: fix Pinggy URL ===" -ForegroundColor Cyan

$raw = (docker exec n8n printenv WEBHOOK_URL | Out-String).Trim()
if (-not $raw) { throw "WEBHOOK_URL is empty inside n8n." }

# Strip real ANSI escape sequences and literal leftovers such as [39m
$clean = [regex]::Replace($raw, [char]27 + "\[[0-9;]*m", "")
$clean = [regex]::Replace($clean, "\[[0-9;]*m", "")
$clean = $clean.Trim().TrimEnd("/")

Write-Host ("Current WEBHOOK_URL: " + $raw) -ForegroundColor DarkGray
Write-Host ("Clean WEBHOOK_URL:   " + $clean) -ForegroundColor Green

if ($clean -notmatch "^https://[A-Za-z0-9.-]+$") {
    throw "Cleaned URL still looks invalid: $clean"
}

$inspect = (docker inspect n8n | ConvertFrom-Json)[0]
$image = $inspect.Config.Image
$backup = "n8n-before-clean-url-" + (Get-Date -Format "yyyyMMdd-HHmmss")
$args = @("run","-d","--name","n8n")

if ($inspect.HostConfig.RestartPolicy.Name -and $inspect.HostConfig.RestartPolicy.Name -ne "no") {
    $args += @("--restart",$inspect.HostConfig.RestartPolicy.Name)
}
if ($inspect.Config.User) { $args += @("--user",$inspect.Config.User) }

foreach ($prop in $inspect.HostConfig.PortBindings.PSObject.Properties) {
    $containerPort = ($prop.Name -split "/")[0]
    foreach ($binding in @($prop.Value)) {
        if ($binding -and $binding.HostPort) {
            if ($binding.HostIp -and $binding.HostIp -ne "0.0.0.0" -and $binding.HostIp -ne "::") {
                $args += @("-p", ($binding.HostIp + ":" + $binding.HostPort + ":" + $containerPort))
            } else {
                $args += @("-p", ($binding.HostPort + ":" + $containerPort))
            }
        }
    }
}

foreach ($m in @($inspect.Mounts)) {
    if ($m.Type -eq "volume") { $source = $m.Name } else { $source = $m.Source }
    if ($source -and $m.Destination) {
        $spec = $source + ":" + $m.Destination
        if (-not $m.RW) { $spec += ":ro" }
        $args += @("-v",$spec)
    }
}

foreach ($e in @($inspect.Config.Env)) {
    if ($e -match "^(WEBHOOK_URL|N8N_WEBHOOK_URL|N8N_PROXY_HOPS)=") { continue }
    $args += @("-e",$e)
}
$args += @("-e",("WEBHOOK_URL=" + $clean + "/"))
$args += @("-e","N8N_PROXY_HOPS=1")

$networkMode = $inspect.HostConfig.NetworkMode
if ($networkMode -and $networkMode -notin @("default","bridge")) { $args += @("--network",$networkMode) }
$args += $image

Write-Host "Restarting n8n with clean URL..." -ForegroundColor Cyan
docker stop n8n | Out-Null
docker rename n8n $backup

try {
    & docker @args | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker run failed" }
    $ok = $false
    for ($i=0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 1
        try {
            $h = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:5678/healthz" -TimeoutSec 3
            if ($h.StatusCode -eq 200) { $ok = $true; break }
        } catch {}
    }
    if (-not $ok) { throw "n8n did not become healthy" }
} catch {
    docker rm -f n8n 2>$null | Out-Null
    docker rename $backup n8n
    docker start n8n | Out-Null
    throw
}

try {
    docker exec n8n n8n unpublish:workflow --id=$WorkflowId | Out-Null
    Start-Sleep -Seconds 2
    docker exec n8n n8n publish:workflow --id=$WorkflowId | Out-Null
} catch {
    Write-Host "Open the workflow and toggle Published once." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== READY ===" -ForegroundColor Green
Write-Host ("Production callback: " + $clean + "/webhook/wayforpay-callback")
Write-Host ("Backup container: " + $backup) -ForegroundColor DarkGray

Start-Process ("http://localhost:5678/workflow/" + $WorkflowId)
