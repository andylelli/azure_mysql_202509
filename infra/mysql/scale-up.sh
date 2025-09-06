#!/usr/bin/env bash
set -euo pipefail
RG="${RG:-laravel-rg}"
SERVER="${SERVER:-fest-db}"
UP_SKU="${UP_SKU:-Standard_D2ds_v5}"   # Festival size (GP 2 vCores class)

echo "==> Scaling UP $SERVER to $UP_SKU"
az mysql flexible-server update -g "$RG" -n "$SERVER" --sku-name "$UP_SKU"
echo "Note: scaling causes a brief DB restart."
