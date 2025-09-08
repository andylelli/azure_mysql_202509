#!/usr/bin/env bash
set -euo pipefail

# Resource context
RG="${RG:-laravel-rg}"
SERVER="${SERVER:-fest-db}"
LOC="${LOC:-uksouth}"

# Target (defaults to what your provision script uses)
TIER="${TIER:-Burstable}"
TARGET_SKU="${TARGET_SKU:-}"   # leave empty to auto-pick B1ms or the smallest Burstable available

# --- Helper: choose a small Burstable SKU in this region (prefer B1ms) ---
pick_burstable_sku() {
  # List Burstable SKUs in region
  local skus
  skus=$(az mysql flexible-server list-skus -l "$LOC" \
          --query "[?tier=='Burstable'].name" -o tsv | tr -s '\n' ' ')
  # Prefer B1ms, then B1s, then B2s; otherwise first Burstable returned
  for s in $skus; do [[ "$s" == *"Standard_B1ms"* ]] && echo "$s" && return; done
  for s in $skus; do [[ "$s" == *"Standard_B1s"*  ]] && echo "$s" && return; done
  for s in $skus; do [[ "$s" == *"Standard_B2s"*  ]] && echo "$s" && return; done
  for s in $skus; do echo "$s" && return; done
  return 1
}

# Resolve TARGET_SKU if not provided
if [[ -z "$TARGET_SKU" ]]; then
  echo "Auto-selecting a Burstable SKU in $LOC (preferring Standard_B1ms)..."
  TARGET_SKU="$(pick_burstable_sku)"
  [[ -z "$TARGET_SKU" ]] && { echo "ERROR: No Burstable SKUs available in $LOC"; exit 2; }
fi

echo "==> Scaling DOWN MySQL Flexible Server"
CUR_SKU=$(az mysql flexible-server show -g "$RG" -n "$SERVER" --query "sku.name" -o tsv)
CUR_TIER=$(az mysql flexible-server show -g "$RG" -n "$SERVER" --query "sku.tier" -o tsv)
CUR_STATE=$(az mysql flexible-server show -g "$RG" -n "$SERVER" --query "state" -o tsv)
echo "   Current: tier=$CUR_TIER sku=$CUR_SKU state=$CUR_STATE"
echo "   Target : tier=$TIER sku=$TARGET_SKU"

if [[ "$CUR_SKU" == "$TARGET_SKU" && "$CUR_TIER" == "$TIER" ]]; then
  echo "   No change needed."; exit 0
fi

# Perform scale (causes a brief restart)
az mysql flexible-server update \
  -g "$RG" -n "$SERVER" \
  --tier "$TIER" \
  --sku-name "$TARGET_SKU" >/dev/null

echo "==> Waiting for server to be Ready after scale"
for i in {1..60}; do
  STATE=$(az mysql flexible-server show -g "$RG" -n "$SERVER" --query "state" -o tsv)
  [[ "$STATE" == "Ready" ]] && { echo "   Ready."; break; }
  echo "   state=$STATE ... retry $i/60"; sleep 10
done

echo "Scaled down to $TIER $TARGET_SKU"
