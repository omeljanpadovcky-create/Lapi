$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== CONTINUE LAPI Shopify setup ===" -ForegroundColor Cyan

$roots = @(
  "$HOME\Downloads",
  "$HOME\Desktop",
  "$HOME"
) | Where-Object { Test-Path $_ }

$toml = $null
foreach ($root in $roots) {
    $match = Get-ChildItem $root -Filter "shopify.app.toml" -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($match) {
        $toml = $match.FullName
        break
    }
}

if (-not $toml) {
    throw "Cannot find shopify.app.toml. Run 'shopify app init' first."
}

$Project = Split-Path $toml -Parent

Write-Host "Found project:" -ForegroundColor Green
Write-Host "  $Project"
Write-Host ""

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

Write-Host "Scopes configured:" -ForegroundColor Green
Write-Host "  read_orders"
Write-Host "  write_orders"
Write-Host "  read_products"
Write-Host ""

Push-Location $Project
try {
    Write-Host "Deploying app config..." -ForegroundColor Cyan
    shopify app deploy --allow-updates

    Write-Host ""
    Write-Host "App environment:" -ForegroundColor Cyan
    shopify app env show
}
finally {
    Pop-Location
}

$appsUrl = "https://dev.shopify.com/dashboard/218929384/apps"
Start-Process $appsUrl

Write-Host ""
Write-Host "DONE." -ForegroundColor Green
Write-Host "Shopify Dev Dashboard opened."
Write-Host "Open 'LAPI n8n WayForPay' and install/approve it on i084rv-1z.myshopify.com."
Write-Host "Do NOT paste Client Secret or tokens into chat."
Write-Host ""
Read-Host "Press Enter to close"
