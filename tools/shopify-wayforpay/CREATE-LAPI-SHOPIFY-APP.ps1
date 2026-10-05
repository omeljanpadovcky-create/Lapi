$ErrorActionPreference = "Stop"

$OrgId   = "218929384"
$AppName = "LAPI n8n WayForPay"
$Stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$Project = Join-Path $env:USERPROFILE "Desktop\LAPI-Shopify-n8n-$Stamp"

Write-Host ""
Write-Host "=== LAPI Shopify app setup ===" -ForegroundColor Cyan
Write-Host "Organization: $OrgId"
Write-Host "Project:      $Project"
Write-Host ""

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-Host "Node.js/npm not found." -ForegroundColor Yellow
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "Installing Node.js LTS with winget..." -ForegroundColor Yellow
        winget install --id OpenJS.NodeJS.LTS -e --accept-package-agreements --accept-source-agreements
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("Path","User")
    } else {
        Write-Host "Install Node.js LTS first, then run this file again." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
}

Write-Host "Installing/updating Shopify CLI..." -ForegroundColor Cyan
npm install -g @shopify/cli@latest

Write-Host ""
Write-Host "Creating Shopify app. If a browser opens, log in with the Shopify account that owns the store." -ForegroundColor Yellow
shopify app init `
  --name "$AppName" `
  --organization-id "$OrgId" `
  --template none `
  --path "$Project"

if (-not (Test-Path $Project)) {
    throw "Shopify CLI did not create the project folder."
}

$toml = Join-Path $Project "shopify.app.toml"
if (-not (Test-Path $toml)) {
    throw "shopify.app.toml was not created."
}

$content = Get-Content $toml -Raw

if ($content -match '(?m)^application_url\s*=') {
    $content = [regex]::Replace(
        $content,
        '(?m)^application_url\s*=.*$',
        'application_url = "https://shopify.dev/apps/default-app-home"'
    )
}

if ($content -match '(?m)^embedded\s*=') {
    $content = [regex]::Replace($content, '(?m)^embedded\s*=.*$', 'embedded = false')
}

if ($content -match '(?ms)\[access_scopes\].*?(?=\r?\n\[|\z)') {
    $content = [regex]::Replace(
        $content,
        '(?ms)\[access_scopes\].*?(?=\r?\n\[|\z)',
        "[access_scopes]`r`nscopes = `"read_orders,write_orders,read_products`"`r`n"
    )
} else {
    $content += "`r`n[access_scopes]`r`nscopes = `"read_orders,write_orders,read_products`"`r`n"
}

if ($content -notmatch '(?m)^\[auth\]') {
    $content += "`r`n[auth]`r`nredirect_urls = []`r`n"
}

Set-Content -Path $toml -Value $content -Encoding UTF8

Write-Host ""
Write-Host "Configured scopes:" -ForegroundColor Green
Write-Host "  read_orders"
Write-Host "  write_orders"
Write-Host "  read_products"

Write-Host ""
Write-Host "Deploying Shopify app configuration..." -ForegroundColor Cyan
shopify app deploy --allow-updates --path "$Project"

Write-Host ""
Write-Host "App environment:" -ForegroundColor Cyan
shopify app env show --path "$Project"

$appsUrl = "https://dev.shopify.com/dashboard/$OrgId/apps"
Write-Host ""
Write-Host "Opening Shopify Dev Dashboard..." -ForegroundColor Cyan
Start-Process $appsUrl

Write-Host ""
Write-Host "NEXT (only unavoidable manual approval):" -ForegroundColor Yellow
Write-Host "1. Open 'LAPI n8n WayForPay'."
Write-Host "2. Click Install app."
Write-Host "3. Select the store with domain: i084rv-1z.myshopify.com"
Write-Host "4. Approve Install."
Write-Host ""
Write-Host "After that, send me ONLY a screenshot of the app page." -ForegroundColor Green
Write-Host "Do NOT send Client Secret or any token in chat." -ForegroundColor Red
Write-Host ""
Read-Host "Press Enter to close"
