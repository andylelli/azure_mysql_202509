#!/usr/bin/env bash
set -euo pipefail

# --- Inputs (override via env or workflow) ---
RG="${RG:-laravel-rg}"
LOC="${LOC:-uksouth}"
SERVER="${SERVER:-fest-db}"                     # unique, lowercase, 3-63 chars
MYSQL_VERSION="${MYSQL_VERSION:-8.0}"
SKU_NAME="${SKU_NAME:-Standard_D2ds_v5}"        # GP default; pass Standard_B1ms for Burstable
TIER="${TIER:-}"                                # Burstable | GeneralPurpose | BusinessCritical (auto-inferred if empty)
STORAGE_GB="${STORAGE_GB:-20}"                  # min 20; can only increase later
BACKUP_DAYS="${BACKUP_DAYS:-7}"                 # 1-35
MAINT_POLICY="${MAINT_POLICY:-system}"          # kept for future use
DB_NAME="${DB_NAME:-laravel}"
APP_USER="${APP_USER:-appuser}"
ADMIN_USER="${ADMIN_USER:-mysqladmin}"          # Azure forms login as 'mysqladmin' (not mysqladmin@server in CLI)
ADMIN_IP="${ADMIN_IP:-}"                        # e.g. your workstation public IP (optional)

# App/Env
APP_NAME="${APP_NAME:-laravel-aca}"
ENV_NAME="${ENV_NAME:-laravel-env}"

# --- Secrets (required) ---
: "${MYSQL_ADMIN_PASSWORD:?Missing MYSQL_ADMIN_PASSWORD}"
: "${MYSQL_APP_PASSWORD:?Missing MYSQL_APP_PASSWORD}"

# --- Infer TIER from SKU if not provided ---
if [[ -z "${TIER}" ]]; then
  case "$SKU_NAME" in
    Standard_B*) TIER="Burstable" ;;
    Standard_D*|GP*) TIER="GeneralPurpose" ;;
    Standard_E*|BC*) TIER="BusinessCritical" ;;
    *) TIER="Burstable" ;;  # safe default
  esac
fi
echo "==> Effective tier: $TIER, SKU: $SKU_NAME"

echo "==> Ensure server exists (or create)"
if ! az mysql flexible-server show -g "$RG" -n "$SERVER" >/dev/null 2>&1; then
  az mysql flexible-server create \
    --resource-group "$RG" --name "$SERVER" --location "$LOC" \
    --admin-user "$ADMIN_USER" --admin-password "$MYSQL_ADMIN_PASSWORD" \
    --version "$MYSQL_VERSION" \
    --tier "$TIER" --sku-name "$SKU_NAME" \
    --storage-size "$STORAGE_GB" \
    --backup-retention "$BACKUP_DAYS" \
    --public-access None \
    --yes
fi

echo "==> Enforce TLS"
az mysql flexible-server parameter set -g "$RG" -s "$SERVER" \
  --name require_secure_transport --value ON >/dev/null

echo "==> Allow Container Apps Environment outbound IPs"
ENV_ID=$(az containerapp env show -g "$RG" -n "$ENV_NAME" --query id -o tsv)
readarray -t ACA_IPS < <(az rest --method get --uri "https://management.azure.com${ENV_ID}?api-version=2025-01-01" \
  --query "properties.outboundIpAddresses[]" -o tsv)
i=0
for ip in "${ACA_IPS[@]}"; do
  az mysql flexible-server firewall-rule create -g "$RG" -s "$SERVER" \
    --name "aca-${i}" --start-ip-address "$ip" --end-ip-address "$ip" >/dev/null || true
  i=$((i+1))
done

if [[ -n "${ADMIN_IP}" ]]; then
  az mysql flexible-server firewall-rule create -g "$RG" -s "$SERVER" \
    --name "admin-ip" --start-ip-address "$ADMIN_IP" --end-ip-address "$ADMIN_IP" >/dev/null || true
fi

echo "==> Create DB and least-privileged app user"
az mysql flexible-server db create -g "$RG" -s "$SERVER" -d "$DB_NAME" >/dev/null || true

# (Exactly like your original execute section)
SQL="
CREATE USER IF NOT EXISTS '${APP_USER}'@'%' IDENTIFIED BY '${MYSQL_APP_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${APP_USER}'@'%';
FLUSH PRIVILEGES;
"
az mysql flexible-server execute -g "$RG" -s "$SERVER" \
  --admin-user "$ADMIN_USER" --admin-password "$MYSQL_ADMIN_PASSWORD" \
  --querytext "$SQL" >/dev/null

echo "==> Wire Container App secrets + env"
HOST=$(az mysql flexible-server show -g "$RG" -n "$SERVER" --query fullyQualifiedDomainName -o tsv)

az containerapp secret set -g "$RG" -n "$APP_NAME" --secrets \
  db-host="$HOST" db-database="$DB_NAME" db-username="$APP_USER" db-password="$MYSQL_APP_PASSWORD" >/dev/null

az containerapp update -g "$RG" -n "$APP_NAME" --set-env-vars \
  DB_CONNECTION=mysql \
  DB_HOST=secretref:db-host \
  DB_DATABASE=secretref:db-database \
  DB_USERNAME=secretref:db-username \
  DB_PASSWORD=secretref:db-password \
  DB_PORT=3306 DB_SOCKET= \
  LOG_CHANNEL=stderr LOG_LEVEL=info >/dev/null

echo "==> Done. Host: $HOST"
