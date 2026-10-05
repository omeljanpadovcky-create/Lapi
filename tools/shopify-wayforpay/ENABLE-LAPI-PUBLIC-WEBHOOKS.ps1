$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== LAPI: public HTTPS webhooks for n8n ===" -ForegroundColor Cyan
Write-Host ""

# 1) Find/start n8n
$containers = @(docker ps -a --format "{{.Names}}")
$n8n = $containers | Where-Object { $_ -eq "n8n" } | Select-Object -First 1
if (-not $n8n) {
    $n8n = $containers | Where-Object { $_ -match "n8n" } | Select-Object -First 1
}
if (-not $n8n) {
    throw "n8n Docker container not found."
}

if (@(docker ps --format "{{.Names}}") -notcontains $n8n) {
    docker start $n8n | Out-Null
    Start-Sleep -Seconds 4
}

# 2) Download cloudflared from Cloudflare's official GitHub release if needed
$toolDir = Join-Path $HOME ".lapi-tools"
New-Item -ItemType Directory -Path $toolDir -Force | Out-Null
$cloudflared = Join-Path $toolDir "cloudflared.exe"

if (-not (Test-Path $cloudflared)) {
    Write-Host "Downloading cloudflared..." -ForegroundColor Cyan
    Invoke-WebRequest "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" -OutFile $cloudflared
}

# 3) Stop only a previous tunnel started by this LAPI script
$pidFile = Join-Path $toolDir "lapi-cloudflared.pid"
if (Test-Path $pidFile) {
    $oldPid = Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($oldPid -match '^\d+$') {
        Stop-Process -Id ([int]$oldPid) -Force -ErrorAction SilentlyContinue
    }
}

$logFile = Join-Path $toolDir "lapi-cloudflared.log"
Remove-Item $logFile -Force -ErrorAction SilentlyContinue

Write-Host "Starting temporary Cloudflare HTTPS tunnel..." -ForegroundColor Cyan
$cf = Start-Process -FilePath $cloudflared -ArgumentList @("tunnel","--url","http://localhost:5678") -RedirectStandardError $logFile -RedirectStandardOutput (Join-Path $toolDir "lapi-cloudflared-out.log") -PassThru -WindowStyle Hidden
Set-Content -Path $pidFile -Value $cf.Id -Encoding ASCII

$publicUrl = $null
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 1
    if (Test-Path $logFile) {
        $log = Get-Content $logFile -Raw -ErrorAction SilentlyContinue
        $matches = [regex]::Matches($log, 'https://[a-z0-9-]+\.trycloudflare\.com')
        $candidate = @(
            $matches |
            ForEach-Object { $_.Value.TrimEnd("/") } |
            Where-Object {
                $_ -ne "https://api.trycloudflare.com" -and
                $_ -match '^https://[a-z0-9-]{8,}\.trycloudflare\.com
    }
    if ($cf.HasExited) {
        break
    }
}

if (-not $publicUrl) {
    Write-Host ""
    Write-Host "cloudflared log:" -ForegroundColor Yellow
    if (Test-Path $logFile) { Get-Content $logFile -Tail 40 }
    throw "Could not obtain a trycloudflare.com URL."
}

Write-Host ""
Write-Host "Public URL: $publicUrl" -ForegroundColor Green

# 4) Verify tunnel can reach n8n before touching the container
try {
    $health = Invoke-WebRequest -UseBasicParsing -Uri ($publicUrl + "/healthz") -TimeoutSec 20
    Write-Host "Tunnel health check: HTTP $($health.StatusCode)" -ForegroundColor Green
}
catch {
    throw "The public tunnel started, but it cannot reach n8n on localhost:5678."
}

# 5) Recreate n8n with N8N_WEBHOOK_URL while preserving image, mounts, ports and n8n-related env
$inspect = (docker inspect $n8n | ConvertFrom-Json)[0]
$image = $inspect.Config.Image
$backup = "n8n-before-public-" + (Get-Date -Format "yyyyMMdd-HHmmss")

$runArgs = @("run","-d","--name","n8n")

# Preserve restart policy
if ($inspect.HostConfig.RestartPolicy.Name -and $inspect.HostConfig.RestartPolicy.Name -ne "no") {
    $runArgs += @("--restart",$inspect.HostConfig.RestartPolicy.Name)
}

# Preserve user if explicitly set
if ($inspect.Config.User) {
    $runArgs += @("--user",$inspect.Config.User)
}

# Preserve port bindings
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

# Preserve mounts
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

# Preserve useful existing env vars, but replace webhook/proxy values
$preservePrefixes = @("N8N_","DB_","QUEUE_","EXECUTIONS_","GENERIC_TIMEZONE=","TZ=","NODE_FUNCTION_","N8N_ENCRYPTION_KEY=")
foreach ($e in @($inspect.Config.Env)) {
    if ($e -match '^(N8N_WEBHOOK_URL|WEBHOOK_URL|N8N_PROXY_HOPS)=') { continue }

    $keep = $false
    foreach ($prefix in $preservePrefixes) {
        if ($e.StartsWith($prefix)) { $keep = $true; break }
    }
    if ($keep) {
        $runArgs += @("-e",$e)
    }
}

$runArgs += @("-e",("N8N_WEBHOOK_URL=" + $publicUrl + "/"))
$runArgs += @("-e","N8N_PROXY_HOPS=1")

# Preserve custom network mode if it is not the normal Docker bridge/default
$networkMode = $inspect.HostConfig.NetworkMode
if ($networkMode -and $networkMode -notin @("default","bridge")) {
    $runArgs += @("--network",$networkMode)
}

$runArgs += $image

Write-Host ""
Write-Host "Restarting n8n with the public webhook URL..." -ForegroundColor Cyan

docker stop $n8n | Out-Null
docker rename $n8n $backup

try {
    & docker @runArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker run failed." }

    $ready = $false
    for ($i = 0; $i -lt 45; $i++) {
        Start-Sleep -Seconds 1
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:5678/healthz" -TimeoutSec 3
            if ($r.StatusCode -eq 200) { $ready = $true; break }
        } catch {}
    }

    if (-not $ready) {
        throw "New n8n container did not become healthy."
    }
}
catch {
    Write-Host "n8n restart failed. Rolling back..." -ForegroundColor Red
    docker rm -f n8n 2>$null | Out-Null
    docker rename $backup n8n
    docker start n8n | Out-Null
    throw
}

Write-Host "n8n is healthy with N8N_WEBHOOK_URL=$publicUrl/" -ForegroundColor Green

# 6) Find the LAPI Shopify/WayForPay workflow, update callback origin, then republish
docker exec n8n n8n export:workflow --all --output=/tmp/lapi-public-workflows.json --pretty | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Could not export workflows."
}

$tmpAll = Join-Path $env:TEMP "lapi-public-workflows.json"
docker cp "n8n:/tmp/lapi-public-workflows.json" $tmpAll | Out-Null
$all = Get-Content $tmpAll -Raw | ConvertFrom-Json

$targets = @(
    @($all) | Where-Object {
        $_.name -match "LAPI" -and
        $_.name -match "WayForPay" -and
        @($_.nodes | Where-Object { $_.type -eq "n8n-nodes-base.shopifyTrigger" }).Count -gt 0
    }
)

if ($targets.Count -eq 0) {
    throw "Could not find the LAPI Shopify/WayForPay workflow."
}

foreach ($wf in $targets) {
    $callbackNode = @($wf.nodes | Where-Object { $_.type -eq "n8n-nodes-base.webhook" -and $_.name -match "WayForPay.*Callback" }) | Select-Object -First 1
    $callbackPath = "wayforpay-callback"

    if ($callbackNode -and $callbackNode.parameters -and $callbackNode.parameters.path) {
        $callbackPath = [string]$callbackNode.parameters.path
    }

    $callbackUrl = $publicUrl + "/webhook/" + $callbackPath.TrimStart("/")

    foreach ($node in @($wf.nodes)) {
        if (-not $node.parameters) { continue }

        # Patch common config-code patterns
        if ($node.parameters.PSObject.Properties["jsCode"] -and $node.parameters.jsCode) {
            $code = [string]$node.parameters.jsCode
            $code = $code.Replace("https://YOUR-PUBLIC-N8N-DOMAIN",$publicUrl)
            $code = $code.Replace("http://YOUR-PUBLIC-N8N-DOMAIN",$publicUrl)
            $code = $code.Replace("http://localhost:5678",$publicUrl)

            $code = [regex]::Replace(
                $code,
                '(WAYFORPAY_CALLBACK_URL\s*:\s*[''"])[^''"]+([''"])',
                ('$1' + $callbackUrl + '$2')
            )

            $node.parameters.jsCode = $code
        }

        # Patch plain string parameter values recursively at the top level
        foreach ($p in @($node.parameters.PSObject.Properties)) {
            if ($p.Value -is [string]) {
                $v = [string]$p.Value
                $v = $v.Replace("https://YOUR-PUBLIC-N8N-DOMAIN",$publicUrl)
                $v = $v.Replace("http://YOUR-PUBLIC-N8N-DOMAIN",$publicUrl)
                $v = $v.Replace("http://localhost:5678",$publicUrl)
                $p.Value = $v
            }
        }
    }

    Write-Host "WayForPay callback: $callbackUrl" -ForegroundColor Green

    # Unpublish first so trigger webhooks are re-created with the new public base URL
    if ($wf.id) {
        docker exec n8n n8n unpublish:workflow --id=$($wf.id) | Out-Null
    }
}

$tmpPatched = Join-Path $env:TEMP "lapi-public-patched.json"
$json = ConvertTo-Json -InputObject $targets -Depth 100
[IO.File]::WriteAllText($tmpPatched,$json,(New-Object System.Text.UTF8Encoding($false)))

docker cp $tmpPatched "n8n:/tmp/lapi-public-patched.json" | Out-Null
docker exec n8n n8n import:workflow --input=/tmp/lapi-public-patched.json
if ($LASTEXITCODE -ne 0) {
    throw "Workflow import failed."
}

foreach ($wf in $targets) {
    if ($wf.id) {
        docker exec n8n n8n publish:workflow --id=$($wf.id)
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Publish failed for workflow $($wf.name). Open it and press Publish once." -ForegroundColor Yellow
        }
    }
}

# 7) Save addresses for the user
$infoFile = Join-Path $HOME "Desktop\LAPI-N8N-PUBLIC.txt"
$callback = $null
foreach ($wf in $targets) {
    $callbackNode = @($wf.nodes | Where-Object { $_.type -eq "n8n-nodes-base.webhook" -and $_.name -match "WayForPay.*Callback" }) | Select-Object -First 1
    $pathValue = "wayforpay-callback"
    if ($callbackNode -and $callbackNode.parameters.path) { $pathValue = [string]$callbackNode.parameters.path }
    $callback = $publicUrl + "/webhook/" + $pathValue.TrimStart("/")
    break
}

@(
    "LAPI n8n public URL: $publicUrl"
    "WayForPay callback: $callback"
    "Cloudflared PID: $($cf.Id)"
    "Backup Docker container: $backup"
) | Set-Content -Path $infoFile -Encoding UTF8

Remove-Item $tmpAll -Force -ErrorAction SilentlyContinue
Remove-Item $tmpPatched -Force -ErrorAction SilentlyContinue
docker exec -u 0 n8n sh -lc "rm -f /tmp/lapi-public-workflows.json /tmp/lapi-public-patched.json" 2>$null | Out-Null

Write-Host ""
Write-Host "=== READY ===" -ForegroundColor Green
Write-Host "Public n8n: $publicUrl"
Write-Host "WayForPay callback: $callback"
Write-Host ""
Write-Host "IMPORTANT: this trycloudflare.com URL is temporary. Keep this PC, Docker and cloudflared running while testing." -ForegroundColor Yellow
Write-Host "Saved: $infoFile"
Write-Host ""

Start-Process "http://localhost:5678/home/workflows"

            } |
            Select-Object -Unique
        ) | Select-Object -Last 1

        if ($candidate) {
            $publicUrl = $candidate
            break
        }
    }
    if ($cf.HasExited) {
        break
    }
}

if (-not $publicUrl) {
    Write-Host ""
    Write-Host "cloudflared log:" -ForegroundColor Yellow
    if (Test-Path $logFile) { Get-Content $logFile -Tail 40 }
    throw "Could not obtain a trycloudflare.com URL."
}

Write-Host ""
Write-Host "Public URL: $publicUrl" -ForegroundColor Green

# 4) Verify tunnel can reach n8n before touching the container
try {
    $health = Invoke-WebRequest -UseBasicParsing -Uri ($publicUrl + "/healthz") -TimeoutSec 20
    Write-Host "Tunnel health check: HTTP $($health.StatusCode)" -ForegroundColor Green
}
catch {
    throw "The public tunnel started, but it cannot reach n8n on localhost:5678."
}

# 5) Recreate n8n with N8N_WEBHOOK_URL while preserving image, mounts, ports and n8n-related env
$inspect = (docker inspect $n8n | ConvertFrom-Json)[0]
$image = $inspect.Config.Image
$backup = "n8n-before-public-" + (Get-Date -Format "yyyyMMdd-HHmmss")

$runArgs = @("run","-d","--name","n8n")

# Preserve restart policy
if ($inspect.HostConfig.RestartPolicy.Name -and $inspect.HostConfig.RestartPolicy.Name -ne "no") {
    $runArgs += @("--restart",$inspect.HostConfig.RestartPolicy.Name)
}

# Preserve user if explicitly set
if ($inspect.Config.User) {
    $runArgs += @("--user",$inspect.Config.User)
}

# Preserve port bindings
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

# Preserve mounts
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

# Preserve useful existing env vars, but replace webhook/proxy values
$preservePrefixes = @("N8N_","DB_","QUEUE_","EXECUTIONS_","GENERIC_TIMEZONE=","TZ=","NODE_FUNCTION_","N8N_ENCRYPTION_KEY=")
foreach ($e in @($inspect.Config.Env)) {
    if ($e -match '^(N8N_WEBHOOK_URL|WEBHOOK_URL|N8N_PROXY_HOPS)=') { continue }

    $keep = $false
    foreach ($prefix in $preservePrefixes) {
        if ($e.StartsWith($prefix)) { $keep = $true; break }
    }
    if ($keep) {
        $runArgs += @("-e",$e)
    }
}

$runArgs += @("-e",("N8N_WEBHOOK_URL=" + $publicUrl + "/"))
$runArgs += @("-e","N8N_PROXY_HOPS=1")

# Preserve custom network mode if it is not the normal Docker bridge/default
$networkMode = $inspect.HostConfig.NetworkMode
if ($networkMode -and $networkMode -notin @("default","bridge")) {
    $runArgs += @("--network",$networkMode)
}

$runArgs += $image

Write-Host ""
Write-Host "Restarting n8n with the public webhook URL..." -ForegroundColor Cyan

docker stop $n8n | Out-Null
docker rename $n8n $backup

try {
    & docker @runArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker run failed." }

    $ready = $false
    for ($i = 0; $i -lt 45; $i++) {
        Start-Sleep -Seconds 1
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:5678/healthz" -TimeoutSec 3
            if ($r.StatusCode -eq 200) { $ready = $true; break }
        } catch {}
    }

    if (-not $ready) {
        throw "New n8n container did not become healthy."
    }
}
catch {
    Write-Host "n8n restart failed. Rolling back..." -ForegroundColor Red
    docker rm -f n8n 2>$null | Out-Null
    docker rename $backup n8n
    docker start n8n | Out-Null
    throw
}

Write-Host "n8n is healthy with N8N_WEBHOOK_URL=$publicUrl/" -ForegroundColor Green

# 6) Find the LAPI Shopify/WayForPay workflow, update callback origin, then republish
docker exec n8n n8n export:workflow --all --output=/tmp/lapi-public-workflows.json --pretty | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Could not export workflows."
}

$tmpAll = Join-Path $env:TEMP "lapi-public-workflows.json"
docker cp "n8n:/tmp/lapi-public-workflows.json" $tmpAll | Out-Null
$all = Get-Content $tmpAll -Raw | ConvertFrom-Json

$targets = @(
    @($all) | Where-Object {
        $_.name -match "LAPI" -and
        $_.name -match "WayForPay" -and
        @($_.nodes | Where-Object { $_.type -eq "n8n-nodes-base.shopifyTrigger" }).Count -gt 0
    }
)

if ($targets.Count -eq 0) {
    throw "Could not find the LAPI Shopify/WayForPay workflow."
}

foreach ($wf in $targets) {
    $callbackNode = @($wf.nodes | Where-Object { $_.type -eq "n8n-nodes-base.webhook" -and $_.name -match "WayForPay.*Callback" }) | Select-Object -First 1
    $callbackPath = "wayforpay-callback"

    if ($callbackNode -and $callbackNode.parameters -and $callbackNode.parameters.path) {
        $callbackPath = [string]$callbackNode.parameters.path
    }

    $callbackUrl = $publicUrl + "/webhook/" + $callbackPath.TrimStart("/")

    foreach ($node in @($wf.nodes)) {
        if (-not $node.parameters) { continue }

        # Patch common config-code patterns
        if ($node.parameters.PSObject.Properties["jsCode"] -and $node.parameters.jsCode) {
            $code = [string]$node.parameters.jsCode
            $code = $code.Replace("https://YOUR-PUBLIC-N8N-DOMAIN",$publicUrl)
            $code = $code.Replace("http://YOUR-PUBLIC-N8N-DOMAIN",$publicUrl)
            $code = $code.Replace("http://localhost:5678",$publicUrl)

            $code = [regex]::Replace(
                $code,
                '(WAYFORPAY_CALLBACK_URL\s*:\s*[''"])[^''"]+([''"])',
                ('$1' + $callbackUrl + '$2')
            )

            $node.parameters.jsCode = $code
        }

        # Patch plain string parameter values recursively at the top level
        foreach ($p in @($node.parameters.PSObject.Properties)) {
            if ($p.Value -is [string]) {
                $v = [string]$p.Value
                $v = $v.Replace("https://YOUR-PUBLIC-N8N-DOMAIN",$publicUrl)
                $v = $v.Replace("http://YOUR-PUBLIC-N8N-DOMAIN",$publicUrl)
                $v = $v.Replace("http://localhost:5678",$publicUrl)
                $p.Value = $v
            }
        }
    }

    Write-Host "WayForPay callback: $callbackUrl" -ForegroundColor Green

    # Unpublish first so trigger webhooks are re-created with the new public base URL
    if ($wf.id) {
        docker exec n8n n8n unpublish:workflow --id=$($wf.id) | Out-Null
    }
}

$tmpPatched = Join-Path $env:TEMP "lapi-public-patched.json"
$json = ConvertTo-Json -InputObject $targets -Depth 100
[IO.File]::WriteAllText($tmpPatched,$json,(New-Object System.Text.UTF8Encoding($false)))

docker cp $tmpPatched "n8n:/tmp/lapi-public-patched.json" | Out-Null
docker exec n8n n8n import:workflow --input=/tmp/lapi-public-patched.json
if ($LASTEXITCODE -ne 0) {
    throw "Workflow import failed."
}

foreach ($wf in $targets) {
    if ($wf.id) {
        docker exec n8n n8n publish:workflow --id=$($wf.id)
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Publish failed for workflow $($wf.name). Open it and press Publish once." -ForegroundColor Yellow
        }
    }
}

# 7) Save addresses for the user
$infoFile = Join-Path $HOME "Desktop\LAPI-N8N-PUBLIC.txt"
$callback = $null
foreach ($wf in $targets) {
    $callbackNode = @($wf.nodes | Where-Object { $_.type -eq "n8n-nodes-base.webhook" -and $_.name -match "WayForPay.*Callback" }) | Select-Object -First 1
    $pathValue = "wayforpay-callback"
    if ($callbackNode -and $callbackNode.parameters.path) { $pathValue = [string]$callbackNode.parameters.path }
    $callback = $publicUrl + "/webhook/" + $pathValue.TrimStart("/")
    break
}

@(
    "LAPI n8n public URL: $publicUrl"
    "WayForPay callback: $callback"
    "Cloudflared PID: $($cf.Id)"
    "Backup Docker container: $backup"
) | Set-Content -Path $infoFile -Encoding UTF8

Remove-Item $tmpAll -Force -ErrorAction SilentlyContinue
Remove-Item $tmpPatched -Force -ErrorAction SilentlyContinue
docker exec -u 0 n8n sh -lc "rm -f /tmp/lapi-public-workflows.json /tmp/lapi-public-patched.json" 2>$null | Out-Null

Write-Host ""
Write-Host "=== READY ===" -ForegroundColor Green
Write-Host "Public n8n: $publicUrl"
Write-Host "WayForPay callback: $callback"
Write-Host ""
Write-Host "IMPORTANT: this trycloudflare.com URL is temporary. Keep this PC, Docker and cloudflared running while testing." -ForegroundColor Yellow
Write-Host "Saved: $infoFile"
Write-Host ""

Start-Process "http://localhost:5678/home/workflows"
