$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== Link LAPI Shopify Access Token to workflow ===" -ForegroundColor Cyan

$containers = @(docker ps -a --format "{{.Names}}")
$n8n = $containers | Where-Object { $_ -eq "n8n" } | Select-Object -First 1
if (-not $n8n) { $n8n = $containers | Where-Object { $_ -match "n8n" } | Select-Object -First 1 }
if (-not $n8n) { throw "n8n Docker container not found." }

if (@(docker ps --format "{{.Names}}") -notcontains $n8n) {
  docker start $n8n | Out-Null
  Start-Sleep -Seconds 4
}

$credId = "lapi-shopify-access-token"
$credName = "LAPI Shopify Access Token"
$shop = "i084rv-1z.myshopify.com"

docker exec $n8n n8n export:workflow --all --output=/tmp/lapi-all-workflows.json --pretty | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not export n8n workflows." }

$tmpAll = Join-Path $env:TEMP "lapi-all-workflows.json"
docker cp "$($n8n):/tmp/lapi-all-workflows.json" $tmpAll | Out-Null

$all = Get-Content $tmpAll -Raw | ConvertFrom-Json
$items = @($all)

$targets = @(
  $items | Where-Object { $_.name -like "*LAPI*Shopify*WayForPay*FULL*" }
)

if ($targets.Count -eq 0) {
  $targets = @(
    $items | Where-Object {
      $_.name -like "*LAPI*WayForPay*" -and
      (@($_.nodes | Where-Object { $_.type -eq "n8n-nodes-base.shopifyTrigger" }).Count -gt 0)
    }
  )
}

if ($targets.Count -eq 0) {
  throw "LAPI Shopify/WayForPay workflow was not found."
}

Write-Host "Found workflow(s):" -ForegroundColor Green
$targets | ForEach-Object { Write-Host ("  - " + $_.name + " [" + $_.id + "]") }

foreach ($wf in $targets) {
  foreach ($node in @($wf.nodes)) {

    if ($node.type -eq "n8n-nodes-base.shopifyTrigger") {
      if (-not $node.parameters) {
        $node | Add-Member -NotePropertyName parameters -NotePropertyValue ([pscustomobject]@{})
      }

      $node.parameters | Add-Member -Force -NotePropertyName authentication -NotePropertyValue "accessToken"

      if (-not $node.PSObject.Properties["credentials"]) {
        $node | Add-Member -NotePropertyName credentials -NotePropertyValue ([pscustomobject]@{})
      }

      $node.credentials | Add-Member -Force -NotePropertyName shopifyAccessTokenApi -NotePropertyValue ([pscustomobject]@{
        id = $credId
        name = $credName
      })

      if ($node.credentials.PSObject.Properties["shopifyOAuth2Api"]) {
        $node.credentials.PSObject.Properties.Remove("shopifyOAuth2Api")
      }

      Write-Host ("Linked Shopify Trigger: " + $node.name) -ForegroundColor Green
    }

    if ($node.type -eq "n8n-nodes-base.httpRequest" -and $node.name -match "Mark Order Paid|Shopify.*Paid") {
      if (-not $node.parameters) {
        $node | Add-Member -NotePropertyName parameters -NotePropertyValue ([pscustomobject]@{})
      }

      $node.parameters | Add-Member -Force -NotePropertyName authentication -NotePropertyValue "predefinedCredentialType"
      $node.parameters | Add-Member -Force -NotePropertyName nodeCredentialType -NotePropertyValue "shopifyAccessTokenApi"
      $node.parameters | Add-Member -Force -NotePropertyName url -NotePropertyValue ("https://" + $shop + "/admin/api/2026-10/graphql.json")

      if ($node.parameters.PSObject.Properties["headerParameters"] -and
          $node.parameters.headerParameters -and
          $node.parameters.headerParameters.PSObject.Properties["parameters"]) {

        $node.parameters.headerParameters.parameters = @(
          $node.parameters.headerParameters.parameters |
          Where-Object { $_.name -ne "X-Shopify-Access-Token" }
        )
      }

      if (-not $node.PSObject.Properties["credentials"]) {
        $node | Add-Member -NotePropertyName credentials -NotePropertyValue ([pscustomobject]@{})
      }

      $node.credentials | Add-Member -Force -NotePropertyName shopifyAccessTokenApi -NotePropertyValue ([pscustomobject]@{
        id = $credId
        name = $credName
      })

      if ($node.credentials.PSObject.Properties["shopifyOAuth2Api"]) {
        $node.credentials.PSObject.Properties.Remove("shopifyOAuth2Api")
      }

      Write-Host ("Linked Shopify API node: " + $node.name) -ForegroundColor Green
    }
  }
}

$tmpPatched = Join-Path $env:TEMP "lapi-patched-workflows.json"
$json = ConvertTo-Json -InputObject $targets -Depth 100
[IO.File]::WriteAllText($tmpPatched, $json, (New-Object System.Text.UTF8Encoding($false)))

docker cp $tmpPatched "$($n8n):/tmp/lapi-patched-workflows.json" | Out-Null
docker exec $n8n n8n import:workflow --input=/tmp/lapi-patched-workflows.json
if ($LASTEXITCODE -ne 0) { throw "Workflow import failed." }

foreach ($wf in $targets) {
  if ($wf.id) {
    docker exec $n8n n8n publish:workflow --id=$($wf.id)
    if ($LASTEXITCODE -ne 0) {
      Write-Host ("Publish failed for " + $wf.name + ". Open n8n and click Publish manually.") -ForegroundColor Yellow
    }
  }
}

Remove-Item $tmpAll -Force -ErrorAction SilentlyContinue
Remove-Item $tmpPatched -Force -ErrorAction SilentlyContinue

docker exec -u 0 $n8n sh -lc "rm -f /tmp/lapi-all-workflows.json /tmp/lapi-patched-workflows.json" | Out-Null

Write-Host ""
Write-Host "SUCCESS: Shopify token is linked to the LAPI workflow." -ForegroundColor Green
Write-Host "Opening workflow list..." -ForegroundColor Cyan
Start-Process "http://localhost:5678/home/workflows"
