
$ErrorActionPreference = "Stop"

$ShopSubdomain = "i084rv-1z"
$ShopDomain = "$ShopSubdomain.myshopify.com"
$ClientId = "86a44d146a34902d79abbea8736d5576"
$RedirectUrl = "http://localhost:5678/rest/oauth2-credential/callback"
$CredentialId = "lapi-shopify-oauth2"
$CredentialName = "LAPI Shopify OAuth2"

Write-Host ""
Write-Host "=== LAPI Shopify -> n8n AUTO SETUP ===" -ForegroundColor Cyan
Write-Host "Shop:      $ShopDomain"
Write-Host "Redirect:  $RedirectUrl"
Write-Host ""

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker command not found. Start Docker Desktop first."
}

if (-not (Get-Command shopify -ErrorAction SilentlyContinue)) {
    Write-Host "Shopify CLI not found. Installing..." -ForegroundColor Yellow
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        throw "npm is not installed. Install Node.js LTS first."
    }
    npm install -g @shopify/cli@latest
}

$containers = @(docker ps -a --format "{{.Names}}")
$n8nContainer = $containers | Where-Object { $_ -eq "n8n" } | Select-Object -First 1
if (-not $n8nContainer) {
    $n8nContainer = $containers | Where-Object { $_ -match "n8n" } | Select-Object -First 1
}
if (-not $n8nContainer) {
    throw "n8n Docker container was not found."
}

$running = @(docker ps --format "{{.Names}}")
if ($running -notcontains $n8nContainer) {
    Write-Host "Starting n8n container: $n8nContainer" -ForegroundColor Yellow
    docker start $n8nContainer | Out-Null
    Start-Sleep -Seconds 4
}

Write-Host "n8n container: $n8nContainer" -ForegroundColor Green

$searchRoots = @("$HOME\Desktop", "$HOME\Downloads") | Where-Object { Test-Path $_ }
$tomlFile = $null

foreach ($root in $searchRoots) {
    $candidate = Get-ChildItem $root -Filter "shopify.app.toml" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "lapi-n8n-way-for-pay|LAPI-Shopify-n8n" } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($candidate) {
        $tomlFile = $candidate.FullName
        break
    }
}

if (-not $tomlFile) {
    $candidate = Get-ChildItem "$HOME" -Filter "shopify.app.toml" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($candidate) { $tomlFile = $candidate.FullName }
}

if (-not $tomlFile) {
    throw "shopify.app.toml was not found."
}

$projectDir = Split-Path $tomlFile -Parent
Write-Host "Shopify project: $projectDir" -ForegroundColor Green

$toml = [IO.File]::ReadAllText($tomlFile).TrimStart([char]0xFEFF)

if ($toml -match '(?ms)\[access_scopes\].*?(?=\r?\n\[|\z)') {
    $toml = [regex]::Replace(
        $toml,
        '(?ms)\[access_scopes\].*?(?=\r?\n\[|\z)',
        "[access_scopes]`r`nscopes = `"read_orders,write_orders,read_products,write_products`"`r`n"
    )
} else {
    $toml += "`r`n[access_scopes]`r`nscopes = `"read_orders,write_orders,read_products,write_products`"`r`n"
}

if ($toml -match '(?ms)\[auth\].*?(?=\r?\n\[|\z)') {
    $toml = [regex]::Replace(
        $toml,
        '(?ms)\[auth\].*?(?=\r?\n\[|\z)',
        "[auth]`r`nredirect_urls = [`"$RedirectUrl`"]`r`n"
    )
} else {
    $toml += "`r`n[auth]`r`nredirect_urls = [`"$RedirectUrl`"]`r`n"
}

[IO.File]::WriteAllText($tomlFile, $toml, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "Deploying Shopify OAuth redirect + scopes..." -ForegroundColor Cyan
Push-Location $projectDir
try {
    shopify app deploy --allow-updates
    if ($LASTEXITCODE -ne 0) {
        throw "Shopify deploy failed."
    }
}
finally {
    Pop-Location
}

Write-Host ""
$secure = Read-Host "Paste Shopify Client secret here (hidden; stays on this PC)" -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)

try {
    $ClientSecret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)

    $credential = @(
        @{
            id = $CredentialId
            name = $CredentialName
            type = "shopifyOAuth2Api"
            data = @{
                shopSubdomain = $ShopSubdomain
                grantType = "authorizationCode"
                clientId = $ClientId
                clientSecret = $ClientSecret
                authUrl = "https://$ShopDomain/admin/oauth/authorize"
                accessTokenUrl = "https://$ShopDomain/admin/oauth/access_token"
                scope = "write_orders read_orders write_products read_products"
                authQueryParameters = "access_mode=value"
                authentication = "body"
            }
        }
    )

    $tempCredential = Join-Path $env:TEMP "lapi-shopify-oauth2-credential.json"
    $credentialJson = $credential | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($tempCredential, $credentialJson, (New-Object System.Text.UTF8Encoding($false)))

    docker cp $tempCredential "$($n8nContainer):/tmp/lapi-shopify-oauth2-credential.json" | Out-Null
    docker exec $n8nContainer n8n import:credentials --input=/tmp/lapi-shopify-oauth2-credential.json
    if ($LASTEXITCODE -ne 0) {
        throw "n8n credential import failed."
    }

    Remove-Item $tempCredential -Force -ErrorAction SilentlyContinue
    docker exec $n8nContainer sh -lc "rm -f /tmp/lapi-shopify-oauth2-credential.json" | Out-Null

    Write-Host ""
    Write-Host "Linking the credential to your existing LAPI workflow..." -ForegroundColor Cyan

    docker exec $n8nContainer n8n export:workflow --all --output=/tmp/lapi-all-workflows.json --pretty | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not export n8n workflows."
    }

    $tempAll = Join-Path $env:TEMP "lapi-all-workflows.json"
    docker cp "$($n8nContainer):/tmp/lapi-all-workflows.json" $tempAll | Out-Null
    $all = Get-Content $tempAll -Raw | ConvertFrom-Json
    $matched = @()

    foreach ($wf in @($all)) {
        $hasLapiShopifyNode = $false

        foreach ($node in @($wf.nodes)) {
            if ($node.type -eq "n8n-nodes-base.shopifyTrigger" -and ($wf.name -match "LAPI|WayForPay" -or $node.name -match "Shopify")) {
                $hasLapiShopifyNode = $true
                $node.parameters.authentication = "oAuth2"

                if (-not $node.PSObject.Properties["credentials"]) {
                    $node | Add-Member -NotePropertyName credentials -NotePropertyValue ([pscustomobject]@{})
                }

                $node.credentials | Add-Member -Force -NotePropertyName shopifyOAuth2Api -NotePropertyValue ([pscustomobject]@{
                    id = $CredentialId
                    name = $CredentialName
                })
            }
        }

        if ($hasLapiShopifyNode) {
            $matched += $wf
        }
    }

    if ($matched.Count -gt 0) {
        $tempWorkflow = Join-Path $env:TEMP "lapi-patched-workflow.json"
        $workflowJson = $matched | ConvertTo-Json -Depth 100
        [IO.File]::WriteAllText($tempWorkflow, $workflowJson, (New-Object System.Text.UTF8Encoding($false)))

        docker cp $tempWorkflow "$($n8nContainer):/tmp/lapi-patched-workflow.json" | Out-Null
        docker exec $n8nContainer n8n import:workflow --input=/tmp/lapi-patched-workflow.json

        if ($LASTEXITCODE -eq 0) {
            Write-Host "Workflow linked to LAPI Shopify OAuth2." -ForegroundColor Green
        } else {
            Write-Host "Credential is ready, but automatic workflow linking failed." -ForegroundColor Yellow
        }

        Remove-Item $tempWorkflow -Force -ErrorAction SilentlyContinue
        docker exec $n8nContainer sh -lc "rm -f /tmp/lapi-patched-workflow.json" | Out-Null
    } else {
        Write-Host "No matching LAPI Shopify Trigger was found. Credential is still ready." -ForegroundColor Yellow
    }

    Remove-Item $tempAll -Force -ErrorAction SilentlyContinue
    docker exec $n8nContainer sh -lc "rm -f /tmp/lapi-all-workflows.json" | Out-Null
}
finally {
    if ($ptr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
    Remove-Variable ClientSecret -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=== AUTOMATIC PART DONE ===" -ForegroundColor Green
Write-Host "n8n is opening now."
Write-Host ""
Write-Host "Only one Shopify authorization remains:"
Write-Host "Open 'LAPI Shopify OAuth2' -> Connect my account -> Approve."
Write-Host ""
Write-Host "Do not paste your Client secret into chat." -ForegroundColor Yellow

Start-Process "http://localhost:5678/home/credentials"
