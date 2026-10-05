$ErrorActionPreference = "Stop"
Write-Host ""
Write-Host "=== LAPI Shopify test order ===" -ForegroundColor Cyan
$ShopDomain = "i084rv-1z.myshopify.com"
$CredentialName = "LAPI Shopify Access Token"
$n8n = "n8n"
if (@(docker ps -a --format "{{.Names}}") -notcontains $n8n) { throw "Docker container n8n was not found." }
if (@(docker ps --format "{{.Names}}") -notcontains $n8n) { docker start $n8n | Out-Null; Start-Sleep -Seconds 4 }
$tmpC = "/tmp/lapi-order-test-creds.json"
$tmpL = Join-Path $env:TEMP ("lapi-order-test-" + [guid]::NewGuid().ToString("N") + ".json")
try {
  docker exec $n8n n8n export:credentials --all --decrypted --output=$tmpC | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Could not export n8n credentials." }
  docker cp "$($n8n):$tmpC" $tmpL | Out-Null
  $items = @(Get-Content $tmpL -Raw | ConvertFrom-Json)
  $cred = $items | Where-Object { $_.name -eq $CredentialName -and $_.type -eq "shopifyAccessTokenApi" } | Select-Object -First 1
  if (-not $cred) { throw "LAPI Shopify Access Token credential not found." }
  $token = [string]$cred.data.accessToken
  $sub = [string]$cred.data.shopSubdomain
  if (-not $token) { throw "Shopify access token is empty." }
  if ($sub) { $ShopDomain = $sub + ".myshopify.com" }

  $query = @'
mutation CreateLapiWayForPayTest($order: OrderCreateOrderInput!, $options: OrderCreateOptionsInput) {
  orderCreate(order: $order, options: $options) {
    order { id name displayFinancialStatus paymentGatewayNames test totalPriceSet { shopMoney { amount currencyCode } } }
    userErrors { field message code }
  }
}
'@

  $variables = @{
    order = @{
      currency = "USD"
      financialStatus = "PENDING"
      test = $true
      tags = @("LAPI_TEST","WAYFORPAY_TEST")
      note = "Automated LAPI Shopify to n8n to WayForPay test order"
      lineItems = @(@{
        title = "LAPI WayForPay Test Item"
        quantity = 1
        requiresShipping = $false
        taxable = $false
        priceSet = @{ shopMoney = @{ amount = "1.00"; currencyCode = "USD" } }
      })
      transactions = @(@{
        amountSet = @{ shopMoney = @{ amount = "1.00"; currencyCode = "USD" } }
        gateway = "WayForPay"
        kind = "SALE"
        status = "PENDING"
        test = $true
      })
    }
    options = @{ inventoryBehaviour = "BYPASS"; sendReceipt = $false; sendFulfillmentReceipt = $false }
  }

  $payload = @{ query = $query; variables = $variables } | ConvertTo-Json -Depth 20
  $headers = @{ "X-Shopify-Access-Token" = $token }
  Write-Host ("Creating 1.00 USD PENDING test order on " + $ShopDomain + "...") -ForegroundColor Cyan
  $res = Invoke-RestMethod -Method Post -Uri ("https://" + $ShopDomain + "/admin/api/2026-10/graphql.json") -Headers $headers -Body $payload -ContentType "application/json"
  if ($res.errors) { $res.errors | ConvertTo-Json -Depth 10 | Write-Host; throw "Shopify GraphQL error." }
  if ($res.data.orderCreate.userErrors -and @($res.data.orderCreate.userErrors).Count -gt 0) { $res.data.orderCreate.userErrors | ConvertTo-Json -Depth 10 | Write-Host; throw "Shopify orderCreate user error." }
  $o = $res.data.orderCreate.order
  if (-not $o) { throw "Shopify returned no order." }
  Write-Host ""
  Write-Host "=== ORDER CREATED ===" -ForegroundColor Green
  Write-Host ("Order: " + $o.name)
  Write-Host ("Financial status: " + $o.displayFinancialStatus)
  Write-Host ("Payment gateways: " + (@($o.paymentGatewayNames) -join ", "))
  Write-Host ("Test order: " + $o.test)
  Write-Host ("Total: " + $o.totalPriceSet.shopMoney.amount + " " + $o.totalPriceSet.shopMoney.currencyCode)
  Write-Host ""
  Write-Host "Open n8n -> Executions and look for Shopify Order Created." -ForegroundColor Yellow
} finally {
  Remove-Item $tmpL -Force -ErrorAction SilentlyContinue
  docker exec -u 0 $n8n sh -lc "rm -f /tmp/lapi-order-test-creds.json" 2>$null | Out-Null
}