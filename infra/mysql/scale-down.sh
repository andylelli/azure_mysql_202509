#!/usr/bin/env bash
set -euo pipefail
RG="${RG:-laravel-rg}"
SERVER="${SERVER:-fest-db}"
DOWN_SKU="${DOWN_SKU:-Standard_B1ms}"  # Cheap off-season (Burstable)

echo "==> Scaling DOWN $SERVER to $DOWN_SKU"
az mysql flexible-server update -g "$RG" -n "$SERVER" --sku-name "$DOWN_SKU"
echo "Note: scaling causes a brief DB restart."
