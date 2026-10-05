
$ErrorActionPreference = "Stop"

$ShopSubdomain = "i084rv-1z"
$ShopDomain = "$ShopSubdomain.myshopify.com"
$ClientId = "86a44d146a34902d79abbea8736d5576"
$CredentialId = "lapi-shopify-oauth2"
$CredentialName = "LAPI Shopify OAuth2"

Write-Host ""
Write-Host "=== FIX LAPI n8n Shopify credential ===" -ForegroundColor Cyan
Write-Host ""

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker command not found. Start Docker Desktop first."
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
    docker start $n8nContainer | Out-Null
    Start-Sleep -Seconds 4
}

Write-Host "n8n container: $n8nContainer" -ForegroundColor Green
Write-Host ""

$secure = Read-Host "Paste Shopify Client secret here (hidden; stays on this PC)" -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)

try {
    $ClientSecret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)

    $credential = @(
        [ordered]@{
            id = $CredentialId
            name = $CredentialName
            type = "shopifyOAuth2Api"
            data = [ordered]@{
                shopSubdomain = $ShopSubdomain
                grantType = "authorizationCode"
                clientId = $ClientId
                clientSecret = $ClientSecret
                authUrl = "https://$ShopDomain/admin/oauth/authorize"
                accessTokenUrl = "https://$ShopDomain/admin/oauth/access_token"
                scope = "write_orders read_orders write_products read_products"
                authQueryParameters = ""
                authentication = "body"
            }
        }
    )

    $tempCredential = Join-Path $env:TEMP "lapi-shopify-oauth2-credential.json"

    # IMPORTANT: -InputObject preserves the outer [] even when there is only one credential.
    $credentialJson = ConvertTo-Json -InputObject $credential -Depth 20
    [IO.File]::WriteAllText(
        $tempCredential,
        $credentialJson,
        (New-Object System.Text.UTF8Encoding($false))
    )

    Write-Host "Importing Shopify OAuth credential into n8n..." -ForegroundColor Cyan
    docker cp $tempCredential "$($n8nContainer):/tmp/lapi-shopify-oauth2-credential.json" | Out-Null
    docker exec $n8nContainer n8n import:credentials --input=/tmp/lapi-shopify-oauth2-credential.json

    if ($LASTEXITCODE -ne 0) {
        throw "n8n credential import failed."
    }

    Write-Host "Credential imported." -ForegroundColor Green

    Remove-Item $tempCredential -Force -ErrorAction SilentlyContinue
    docker exec $n8nContainer sh -lc "rm -f /tmp/lapi-shopify-oauth2-credential.json" | Out-Null

    Write-Host ""
    Write-Host "Linking credential to LAPI Shopify Trigger..." -ForegroundColor Cyan

    docker exec $n8nContainer n8n export:workflow --all --output=/tmp/lapi-all-workflows.json --pretty | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Credential is ready, but workflows could not be exported for auto-linking." -ForegroundColor Yellow
    }
    else {
        $tempAll = Join-Path $env:TEMP "lapi-all-workflows.json"
        docker cp "$($n8nContainer):/tmp/lapi-all-workflows.json" $tempAll | Out-Null
        $all = Get-Content $tempAll -Raw | ConvertFrom-Json
        $matched = @()

        foreach ($wf in @($all)) {
            $changed = $false

            foreach ($node in @($wf.nodes)) {
                if ($node.type -eq "n8n-nodes-base.shopifyTrigger" -and
                    ($wf.name -match "LAPI|WayForPay" -or $node.name -match "Shopify")) {

                    $node.parameters.authentication = "oAuth2"

                    if (-not $node.PSObject.Properties["credentials"]) {
                        $node | Add-Member -NotePropertyName credentials -NotePropertyValue ([pscustomobject]@{})
                    }

                    $node.credentials | Add-Member -Force -NotePropertyName shopifyOAuth2Api -NotePropertyValue ([pscustomobject]@{
                        id = $CredentialId
                        name = $CredentialName
                    })

                    $changed = $true
                }
            }

            if ($changed) {
                $matched += $wf
            }
        }

        if ($matched.Count -gt 0) {
            $tempWorkflow = Join-Path $env:TEMP "lapi-patched-workflow.json"
            $workflowJson = ConvertTo-Json -InputObject $matched -Depth 100
            [IO.File]::WriteAllText(
                $tempWorkflow,
                $workflowJson,
                (New-Object System.Text.UTF8Encoding($false))
            )

            docker cp $tempWorkflow "$($n8nContainer):/tmp/lapi-patched-workflow.json" | Out-Null
            docker exec $n8nContainer n8n import:workflow --input=/tmp/lapi-patched-workflow.json

            if ($LASTEXITCODE -eq 0) {
                Write-Host "Workflow linked to Shopify OAuth credential." -ForegroundColor Green
            }
            else {
                Write-Host "Credential imported, but workflow auto-linking failed. We can link it in the UI." -ForegroundColor Yellow
            }

            Remove-Item $tempWorkflow -Force -ErrorAction SilentlyContinue
            docker exec $n8nContainer sh -lc "rm -f /tmp/lapi-patched-workflow.json" | Out-Null
        }
        else {
            Write-Host "Credential imported, but no matching Shopify Trigger was found." -ForegroundColor Yellow
        }

        Remove-Item $tempAll -Force -ErrorAction SilentlyContinue
        docker exec $n8nContainer sh -lc "rm -f /tmp/lapi-all-workflows.json" | Out-Null
    }
}
finally {
    if ($ptr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
    Remove-Variable ClientSecret -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=== DONE ===" -ForegroundColor Green
Write-Host "Opening n8n Credentials..."
Start-Process "http://localhost:5678/home/credentials"
