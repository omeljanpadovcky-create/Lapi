$ErrorActionPreference = "Stop"

$PublicUrl = "https://lmvgt-185-17-127-229.free.pinggy.net"
$WorkflowId = "tENsj9N2NIiRitQR"

Write-Host ""
Write-Host "=== LAPI: apply Pinggy webhook URL to n8n ===" -ForegroundColor Cyan
Write-Host ("Public URL: " + $PublicUrl) -ForegroundColor Green

# Check local n8n and public tunnel before changing anything
try {
    $local = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:5678/healthz" -TimeoutSec 10
    Write-Host ("Local n8n: HTTP " + $local.StatusCode) -ForegroundColor Green
}
catch {
    throw "n8n is not reachable at http://127.0.0.1:5678"
}

try {
    $headers = @{
        "X-Pinggy-No-Screen" = "1"
        "User-Agent" = "lapi-webhook-check/1.0"
    }
    $remote = Invoke-WebRequest -UseBasicParsing -Uri ($PublicUrl + "/healthz") -Headers $headers -TimeoutSec 20
    Write-Host ("Pinggy tunnel: HTTP " + $remote.StatusCode) -ForegroundColor Green
}
catch {
    Write-Host "Pinggy browser screening may block PowerShell's default request, but the tunnel can still work for webhooks." -ForegroundColor Yellow
    Write-Host "Retrying with curl and the Pinggy no-screen header..." -ForegroundColor Cyan
    $status = & curl.exe -sS -o NUL -w "%{http_code}" -H "X-Pinggy-No-Screen: 1" -A "lapi-webhook-check/1.0" ($PublicUrl + "/healthz")
    if ($LASTEXITCODE -ne 0 -or $status -ne "200") {
        throw ("Pinggy tunnel check failed. HTTP status: " + $status + ". Keep the Pinggy window open.")
    }
    Write-Host ("Pinggy tunnel: HTTP " + $status) -ForegroundColor Green
}

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

# Port bindings
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

# Mounts / persistent n8n data
foreach ($m in @($inspect.Mounts)) {
    if ($m.Type -eq "volume") {
        $source = $m.Name
    } else {
        $source = $m.Source
    }

    if ($source -and $m.Destination) {
        $mountSpec = $source + ":" + $m.Destination
        if (-not $m.RW) { $mountSpec += ":ro" }
        $runArgs += @("-v",$mountSpec)
    }
}

# Preserve only n8n-related/custom environment values; replace WEBHOOK_URL
$prefixes = @(
    "N8N_",
    "DB_",
    "QUEUE_",
    "EXECUTIONS_",
    "GENERIC_TIMEZONE=",
    "TZ=",
    "NODE_FUNCTION_"
)

foreach ($e in @($inspect.Config.Env)) {
    if ($e -match "^(WEBHOOK_URL|N8N_WEBHOOK_URL|N8N_PROXY_HOPS)=") { continue }

    $keep = $false
    foreach ($prefix in $prefixes) {
        if ($e.StartsWith($prefix)) {
            $keep = $true
            break
        }
    }

    if ($keep) {
        $runArgs += @("-e",$e)
    }
}

# Correct n8n variables for reverse proxy/public webhook URLs
$runArgs += @("-e",("WEBHOOK_URL=" + $PublicUrl + "/"))
$runArgs += @("-e","N8N_PROXY_HOPS=1")

# Preserve custom Docker network if used
$networkMode = $inspect.HostConfig.NetworkMode
if ($networkMode -and $networkMode -notin @("default","bridge")) {
    $runArgs += @("--network",$networkMode)
}

$runArgs += $image

Write-Host ""
Write-Host "Recreating n8n with WEBHOOK_URL..." -ForegroundColor Cyan

docker stop n8n | Out-Null
docker rename n8n $backup

try {
    & docker @runArgs | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "docker run failed"
    }

    $ready = $false
    for ($i = 0; $i -lt 45; $i++) {
        Start-Sleep -Seconds 1
        try {
            $h = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:5678/healthz" -TimeoutSec 3
            if ($h.StatusCode -eq 200) {
                $ready = $true
                break
            }
        } catch {}
    }

    if (-not $ready) {
        throw "New n8n container did not become healthy"
    }
}
catch {
    Write-Host "Restart failed. Rolling back old container..." -ForegroundColor Red
    docker rm -f n8n 2>$null | Out-Null
    docker rename $backup n8n
    docker start n8n | Out-Null
    throw
}

Write-Host "n8n restarted successfully." -ForegroundColor Green

# Re-register trigger webhooks using the new public URL
Write-Host "Re-registering Shopify trigger webhook..." -ForegroundColor Cyan
docker exec n8n n8n unpublish:workflow --id=$WorkflowId | Out-Null
Start-Sleep -Seconds 2
docker exec n8n n8n publish:workflow --id=$WorkflowId
if ($LASTEXITCODE -ne 0) {
    Write-Host "Automatic publish failed. Open the workflow and click Publish once." -ForegroundColor Yellow
}

# Verify environment inside container
$envCheck = docker exec n8n printenv WEBHOOK_URL
Write-Host ("WEBHOOK_URL inside n8n: " + $envCheck) -ForegroundColor Green

Write-Host ""
Write-Host "=== READY ===" -ForegroundColor Green
Write-Host ("WayForPay production callback should now be: " + $PublicUrl + "/webhook/wayforpay-callback")
Write-Host "Open the WayForPay Callback node and check Production URL." -ForegroundColor Cyan
Write-Host ""
Write-Host ("Backup container kept as: " + $backup) -ForegroundColor DarkGray

Start-Process "http://localhost:5678/workflow/$WorkflowId"
