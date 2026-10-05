$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== LAPI Shopify token test inside n8n ===" -ForegroundColor Cyan

$containers = @(docker ps -a --format "{{.Names}}")
$n8n = $containers | Where-Object { $_ -eq "n8n" } | Select-Object -First 1
if (-not $n8n) { $n8n = $containers | Where-Object { $_ -match "n8n" } | Select-Object -First 1 }
if (-not $n8n) { throw "n8n Docker container not found." }

if (@(docker ps --format "{{.Names}}") -notcontains $n8n) {
  docker start $n8n | Out-Null
  Start-Sleep -Seconds 4
}

docker exec $n8n n8n export:credentials --all --decrypted --output=/tmp/lapi-cred-test.json | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not export credentials for local test." }

$js = @'
const fs = require("fs");
(async () => {
  const all = JSON.parse(fs.readFileSync("/tmp/lapi-cred-test.json", "utf8"));
  const c = all.find(x => x.name === "LAPI Shopify Access Token" && x.type === "shopifyAccessTokenApi");
  if (!c) {
    console.error("CREDENTIAL_NOT_FOUND");
    process.exit(2);
  }

  const shop = c.data.shopSubdomain + ".myshopify.com";
  const r = await fetch("https://" + shop + "/admin/api/2026-10/graphql.json", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Shopify-Access-Token": c.data.accessToken
    },
    body: JSON.stringify({ query: "query { shop { name myshopifyDomain } }" })
  });

  const text = await r.text();
  if (!r.ok) {
    console.error("HTTP_" + r.status);
    console.error(text);
    process.exit(3);
  }

  const j = JSON.parse(text);
  if (j.errors) {
    console.error("GRAPHQL_ERRORS");
    console.error(JSON.stringify(j.errors));
    process.exit(4);
  }

  console.log("SHOPIFY_GRAPHQL_OK");
  console.log("Store: " + j.data.shop.name);
  console.log("Domain: " + j.data.shop.myshopifyDomain);
})().catch(e => {
  console.error("TEST_ERROR");
  console.error(e && e.message ? e.message : String(e));
  process.exit(5);
});
'@

$tmpJs = Join-Path $env:TEMP "lapi-shopify-token-test.js"
[IO.File]::WriteAllText($tmpJs, $js, (New-Object System.Text.UTF8Encoding($false)))
docker cp $tmpJs "$($n8n):/tmp/lapi-shopify-token-test.js" | Out-Null

try {
  docker exec $n8n node /tmp/lapi-shopify-token-test.js
  $code = $LASTEXITCODE
}
finally {
  Remove-Item $tmpJs -Force -ErrorAction SilentlyContinue
  docker exec $n8n sh -lc "rm -f /tmp/lapi-shopify-token-test.js /tmp/lapi-cred-test.json" | Out-Null
}

if ($code -eq 0) {
  Write-Host ""
  Write-Host "SUCCESS: token is valid. The red n8n credential check is a false negative." -ForegroundColor Green
} else {
  Write-Host ""
  Write-Host "The real GraphQL test failed. Send me ONLY the error text above." -ForegroundColor Yellow
  exit $code
}
