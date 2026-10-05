$ErrorActionPreference = "Stop"

$WorkflowId = "tENsj9N2NIiRitQR"

Write-Host ""
Write-Host "=== LAPI Pinggy + n8n webhook V3 ===" -ForegroundColor Cyan

# 1) Check local n8n
try {
    $r = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:5678/healthz" -TimeoutSec 10
    Write-Host ("Local n8n OK: HTTP " + $r.StatusCode) -ForegroundColor Green
} catch {
    throw "n8n is not reachable on http://127.0.0.1:5678"
}

# 2) Start a fresh Pinggy tunnel in background and capture the fresh public URL
Write-Host "Starting a fresh Pinggy tunnel..." -ForegroundColor Cyan
$pinggyText = (& pinggy -l http://127.0.0.1:5678 --b --force 2>&1 | Out-String)
Write-Host $pinggyText

$urlMatches = [regex]::Matches($pinggyText, "https://[^\s]+")
$PublicUrl = $null
foreach ($m in $urlMatches) {
    $u = $m.Value.TrimEnd("/", ",", ";", ".")
    if ($u -match "pinggy") {
        $PublicUrl = $u
        break
    }
}

if (-not $PublicUrl) {
    throw "Pinggy started but no public HTTPS URL was found in its output."
}

Write-Host ("Fresh Pinggy URL: " + $PublicUrl) -ForegroundColor Green
Write-Host "Waiting 5 seconds for public DNS to settle..." -ForegroundColor DarkGray
Start-Sleep -Seconds 5

# 3) Find n8n container and remember its exact Docker settings
$containers = @(docker ps -a --format "{{.Names}}")
$n8n = $containers | Where-Object { $_ -eq "n8n" } | Select-Object -First 1
if (-not $n8n) { throw "Docker container named n8n was not found." }

$inspect = (docker inspect $n8n | ConvertFrom-Json)[0]
$image = $inspect.Config.Image
$backup = "n8n-before-pinggy-" + (Get-Date -Format "yyyyMMdd-HHmmss")
$runArgs = @("run","-d","--name","n8n")

# Restart policy
if ($inspect.HostConfig.RestartPolicy.Name -and $inspect.HostConfig.RestartPolicy.Name -ne "no") {
    $runArgs += @("--restart",$inspect.HostConfig.RestartPolicy.Name)
}

# User, if explicitly configured
if ($inspect.Config.User) {
    $runArgs += @("--user",$inspect.Config.User)
}

# Port mappings
foreach ($prop in $inspect.HostConfig.PortBindings.PSObject.Properties) {
    $containerPort = ($prop.Name -split "/")[0]
    foreach ($binding in @($prop.Value)) {
        if ($binding -and $binding.HostPort) {
            if ($binding.HostIp -and $binding.HostIp -ne "0.0.0.0" -and $binding.HostIp -ne "::") {
                $runArgs += @("-p", ($binding.HostIp + ":" + $binding.HostPort + ":" + $containerPort))
            } else {
                $runArgs += @("-p", ($binding.HostPort + ":" + $containerPort))
            }
        }
    }
}

# Volumes / bind mounts
foreach ($m in @($inspect.Mounts)) {
    if ($m.Type -eq "volume") { $source = $m.Name } else { $source = $m.Source }
    if ($source -and $m.Destination) {
        $mountSpec = $source + ":" + $m.Destination
        if (-not $m.RW) { $mountSpec += ":ro" }
        $runArgs += @("-v",$mountSpec)
    }
}

# Preserve every existing environment variable except the webhook/proxy values we are replacing
foreach ($e in @($inspect.Config.Env)) {
    if ($e -match "^(WEBHOOK_URL|N8N_WEBHOOK_URL|N8N_PROXY_HOPS)=") { continue }
    $runArgs += @("-e",$e)
}

$runArgs += @("-e",("WEBHOOK_URL=" + $PublicUrl + "/"))
$runArgs += @("-e","N8N_PROXY_HOPS=1")

# Preserve custom network
$networkMode = $inspect.HostConfig.NetworkMode
if ($networkMode -and $networkMode -notin @("default","bridge")) {
    $runArgs += @("--network",$networkMode)
}

$runArgs += $image

# 4) Replace the container, with automatic rollback on failure
Write-Host "Restarting n8n with the fresh public webhook URL..." -ForegroundColor Cyan
docker stop n8n | Out-Null
docker rename n8n $backup

try {
    & docker @runArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker run failed" }

    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 1
        try {
            $h = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:5678/healthz" -TimeoutSec 3
            if ($h.StatusCode -eq 200) { $ready = $true; break }
        } catch {}
    }

    if (-not $ready) { throw "New n8n container did not become healthy." }
} catch {
    Write-Host "Restart failed. Restoring the previous n8n container..." -ForegroundColor Red
    docker rm -f n8n 2>$null | Out-Null
    docker rename $backup n8n
    docker start n8n | Out-Null
    throw
}

Write-Host "n8n restarted successfully." -ForegroundColor Green

# 5) Re-register published trigger webhooks so Shopify receives the new public URL
Write-Host "Refreshing workflow publication..." -ForegroundColor Cyan
try {
    docker exec n8n n8n unpublish:workflow --id=$WorkflowId | Out-Null
    Start-Sleep -Seconds 2
    docker exec n8n n8n publish:workflow --id=$WorkflowId | Out-Null
} catch {
    Write-Host "Automatic re-publish was not available. Open the workflow and toggle Published once." -ForegroundColor Yellow
}

# 6) Verify the environment actually stored in n8n
$inside = docker exec n8n printenv WEBHOOK_URL
Write-Host ("WEBHOOK_URL inside n8n: " + $inside) -ForegroundColor Green

$info = Join-Path $HOME "Desktop\LAPI-N8N-PUBLIC.txt"
@(
    ("Public n8n: " + $PublicUrl),
    ("WayForPay callback: " + $PublicUrl + "/webhook/wayforpay-callback"),
    ("Backup Docker container: " + $backup)
) | Set-Content -Path $info -Encoding UTF8

Write-Host ""
Write-Host "=== READY ===" -ForegroundColor Green
Write-Host ("Public n8n: " + $PublicUrl)
Write-Host ("WayForPay callback: " + $PublicUrl + "/webhook/wayforpay-callback")
Write-Host ("Saved: " + $info)
Write-Host ""
Write-Host "Open WayForPay Callback -> Production URL. It should now use this Pinggy address." -ForegroundColor Cyan

Start-Process ("http://localhost:5678/workflow/" + $WorkflowId)
