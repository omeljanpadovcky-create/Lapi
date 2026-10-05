$ErrorActionPreference = "Stop"

$Shop = "i084rv-1z.myshopify.com"
$ClientId = "86a44d146a34902d79abbea8736d5576"

Write-Host ""
Write-Host "=== LAPI Shopify auth test ===" -ForegroundColor Cyan
Write-Host "Shop: $Shop"
Write-Host "Client ID: $ClientId"
Write-Host ""

$secure = Read-Host "Paste Shopify Client secret here (it will stay hidden)" -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)

try {
    $ClientSecret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)

    $tokenResponse = Invoke-RestMethod -Method Post -Uri "https://$Shop/admin/oauth/access_token" -ContentType "application/x-www-form-urlencoded" -Body @{
        grant_type = "client_credentials"
        client_id = $ClientId
        client_secret = $ClientSecret
    }

    if (-not $tokenResponse.access_token) {
        throw "Shopify did not return an access token."
    }

    Write-Host ""
    Write-Host "Access token received successfully." -ForegroundColor Green
    Write-Host "Expires in: $($tokenResponse.expires_in) seconds"

    $headers = @{
        "X-Shopify-Access-Token" = $tokenResponse.access_token
        "Content-Type" = "application/json"
    }

    $body = @{
        query = "query { shop { name myshopifyDomain } }"
    } | ConvertTo-Json -Compress

    $result = Invoke-RestMethod -Method Post -Uri "https://$Shop/admin/api/2026-10/graphql.json" -Headers $headers -Body $body

    if ($result.errors) {
        throw ($result.errors | ConvertTo-Json -Depth 10)
    }

    Write-Host ""
    Write-Host "SUCCESS: Shopify Admin API works." -ForegroundColor Green
    Write-Host "Store name: $($result.data.shop.name)"
    Write-Host "Domain:     $($result.data.shop.myshopifyDomain)"
    Write-Host ""
    Write-Host "The token was not saved to disk." -ForegroundColor DarkGray
}
finally {
    if ($ptr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
    Remove-Variable ClientSecret -ErrorAction SilentlyContinue
}

Read-Host "Press Enter to close"
