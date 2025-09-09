#!/usr/bin/env bash
set -euo pipefail

RG="${RG:-laravel-rg}"
SERVER="${SERVER:-fest-db}"

echo "==> Deleting MySQL Flexible Server: $SERVER (resource group: $RG)"
az mysql flexible-server delete \
  --resource-group "$RG" \
  --name "$SERVER" \
  --yes

echo "   Delete requested. This may take a few minutes."
