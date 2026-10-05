$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== LAPI Shopify test order ===" -ForegroundColor Cyan

$ShopDomain = "i084rv-1z.myshopify.com"
$CredentialName = "LAPI Shopify Access Token"

$containers = @(docker ps -a --format "{{.Names}}")
$n8n = $containers | Where-Object { $_ -eq "n8n" } | Select-Object -First 1
if (-not $n8n) { throw "Docker container named n8n was not found." }

if (@(docker ps --format "{{.Names}}") -notcontains $n8n) {
    docker start $n8n | Out-Null
    Start-Sleep -Seconds 4
}

$tmpInContainer = "/tmp/lapi-test-order-creds.json"
$tmpLocal = Join-Path $env:TEMP ("lapi-test-order-creds-" + [guid]::NewGuid().ToString("N") + ".json")

try {
    docker exec $n8n n8n export:credentials --all --decrypted --output=$tmpInContainer | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not export local n8n credentials." }

    docker cp "$($n8n):$tmpInContainer" $tmpLocal | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not copy temporary credentials file." }

    $all = @(Get-Content $tmpLocal -Raw | ConvertFrom-Json)
    $cred = $all | Where-Object { $_.name -eq $CredentialName -and $_.type -eq "shopifyAccessTokenApi" } | Select-Object -First 1
    if (-not $cred) { throw "Credential LAPI Shopify Access Token was not found." }

    $token = [string]$cred.data.accessToken
    $subdomain = [string]$cred.data.shopSubdomain

    if (-not $token) { throw "Shopify access token is empty." }
    if ($subdomain) { $ShopDomain = $subdomain + ".myshopify.com" }

    $query = @"
mutation CreateLapiWayForPayTest($order: OrderCreateOrderInput!, $options: OrderCreateOptionsInput) {
  orderCreate(order: $order, options: $options) {
    order {
      id
      name
      displayFinancialStatus
      paymentGatewayNames
      test
      totalPriceSet {
        shopMoney {
          amount
          currencyCode
        }
      }
    }
    userErrors {
      field
      message
      code
    }
  }
}
"@

    $variables = @{
        order = @{
            currency = "USD"
            financialStatus = "PENDING"
            test = $true
            tags = @("LAPI_TEST","WAYFORPAY_TEST")
            note = "Automated test order for LAPI Shopify -> n8n -> WayForPay workflow"
            lineItems = @(
                @{
                    title = "LAPI WayForPay Test Item"
                    quantity = 1
                    requiresShipping = $false
                    taxable = $false
                    priceSet = @{
                        shopMoney = @{
                            amount = "1.00"
                            currencyCode = "USD"
                        }
                    }
                }
            )
            transactions = @(
                @{
                    amountSet = @{
                        shopMoney = @{
                            amount = "1.00"
                            currencyCode = "USD"
                        }
                    }
                    gateway = "WayForPay"
                    kind = "SALE"
                    status = "PENDING"
                    test = $true
                }
            )
        }
        options = @{
            inventoryBehaviour = "BYPASS"
            sendReceipt = $false
            sendFulfillmentReceipt = $false
        }
    }

    $body = @{
        query = $query
        variables = $variables
    } | ConvertTo-Json -Depth 20

    $headers = @{
        "X-Shopify-Access-Token" = $token
        "Content-Type" = "application/json"
    }

    Write-Host ("Creating a 1.00 USD PENDING test order on " + $ShopDomain + "...") -ForegroundColor Cyan

    $result = Invoke-RestMethod -Method Post -Uri ("https://" + $ShopDomain + "/admin/api/2026-10/graphql.json") -Headers $headers -Body $body -ContentType "application/json"

    if ($result.errors) {
        Write-Host ""
        Write-Host "SHOPIFY GRAPHQL ERROR:" -ForegroundColor Red
        $result.errors | ConvertTo-Json -Depth 10 | Write-Host
        throw "Shopify rejected the orderCreate request."
    }

    $payload = $result.data.orderCreate

    if ($payload.userErrors -and @($payload.userErrors).Count -gt 0) {
        Write-Host ""
        Write-Host "SHOPIFY USER ERROR:" -ForegroundColor Red
        $payload.userErrors | ConvertTo-Json -Depth 10 | Write-Host
        throw "Shopify returned an orderCreate user error."
    }

    if (-not $payload.order) { throw "Shopify returned no order." }

    $order = $payload.order

    Write-Host ""
    Write-Host "=== ORDER CREATED ===" -ForegroundColor Green
    Write-Host ("Order: " + $order.name)
    Write-Host ("ID: " + $order.id)
    Write-Host ("Financial status: " + $order.displayFinancialStatus)
    Write-Host ("Payment gateways: " + (@($order.paymentGatewayNames) -join ", "))
    Write-Host ("Test order: " + $order.test)
    Write-Host ("Total: " + $order.totalPriceSet.shopMoney.amount + " " + $order.totalPriceSet.shopMoney.currencyCode)
    Write-Host ""
    Write-Host "Now open n8n -> Executions. A Shopify Order Created execution should appear within a few seconds." -ForegroundColor Yellow
}
finally {
    Remove-Item $tmpLocal -Force -ErrorAction SilentlyContinue
    docker exec -u 0 $n8n sh -lc "rm -f $tmpInContainer" 2>$null | Out-Null
}
