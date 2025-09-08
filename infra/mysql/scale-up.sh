#!/usr/bin/env bash
set -euo pipefail

RG="${RG:-laravel-rg}"
SERVER="${SERVER:-fest-db}"
LOC="${LOC:-uksouth}"
TIER="${TIER:-GeneralPurpose}"
# Allow override, else auto-pick
TARGET_SKU="${TARGET_SKU:-}"

pick_sku() {
  # List GP SKUs and pick 2 vCPU D-series. Prefer ads_v5 then ds_v4.
  # The JMESPath fields can vary; we match by name.
  local sku
  sku=$(az mysql flexible-server list-skus -l "$LOC" \
        --query "[?tier=='GeneralPurpose' && starts_with(name, 'Standard_D2')].name" -o tsv | tr -s '\n' ' ')
  # Try v5 (ads) first
  for s in $sku; do
    [[ "$s" == *"D2ads_v5"* ]] && echo "$s" && return
  done
  # Then v4 (ds)
  for s in $sku; do
    [[ "$s" == *"D2ds_v4"* ]] && echo "$s" && return
  done
  # Else first D2 GP we saw
  for s in $sku; do
    echo "$s" && return
  done
  return 1
}

if [[ -z "$TARGET_SKU" ]]; then
  echo "Auto-selecting a GP 2 vCPU SKU in $LOC..."
  TARGET_SKU="$(pick_sku)"
  [[ -z "$TARGET_SKU" ]] && { echo "No suitable GP D2 SKU found in $LOC"; exit 2; }
fi

echo "==> Scaling UP $SERVER to $TIER $TARGET_SKU"
CUR_SKU=$(az mysql flexible-server show -g "$RG" -n "$SERVER" --query "sku.name" -o tsv)
CUR_TIER=$(az mysql flexible-server show -g "$RG" -n "$SERVER" --query "sku.tier" -o tsv)

if [[ "$CUR_SKU" == "$TARGET_SKU" && "$CUR_TIER" == "$TIER" ]]; then
  echo "Already at $TIER $TARGET_SKU"; exit 0
fi

az mysql flexible-server update -g "$RG" -n "$SERVER" --tier "$TIER" --sku-name "$TARGET_SKU"

echo "Waiting for Ready..."
for i in {1..60}; do
  STATE=$(az mysql flexible-server show -g "$RG" -n "$SERVER" --query "state" -o tsv)
  [[ "$STATE" == "Ready" ]] && { echo "Ready."; break; }
  echo "state=$STATE retry $i/60"; sleep 10
done

echo "Scaled to $TIER $TARGET_SKU"
