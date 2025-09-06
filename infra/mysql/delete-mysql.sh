#!/usr/bin/env bash
set -euo pipefail
RG="${RG:-laravel-rg}"
SERVER="${SERVER:-fest-db}"
az mysql flexible-server delete -g "$RG" -n "$SERVER" --yes --force
