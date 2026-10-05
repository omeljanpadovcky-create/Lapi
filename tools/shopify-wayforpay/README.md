# LAPI Shopify / WayForPay setup

This folder contains the setup script for the Shopify app used by the n8n + WayForPay integration.

## Fastest Windows PowerShell install

Open **PowerShell** and paste:

```powershell
$u="https://raw.githubusercontent.com/omeljanpadovcky-create/Lapi/main/tools/shopify-wayforpay/CREATE-LAPI-SHOPIFY-APP.ps1"; $f="$HOME\Downloads\CREATE-LAPI-SHOPIFY-APP.ps1"; Invoke-WebRequest $u -OutFile $f; Set-ExecutionPolicy -Scope Process Bypass -Force; & $f
```

The script:
- installs/updates Shopify CLI;
- creates the app **LAPI n8n WayForPay**;
- configures `read_orders`, `write_orders`, `read_products`;
- deploys the app config;
- opens the Shopify Dev Dashboard.

Shopify can still require you to log in and approve **Install app**. Do not commit Shopify or WayForPay secrets to this repository.
