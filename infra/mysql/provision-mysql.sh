#!/usr/bin/env bash
set -euo pipefail

# --- Inputs (override via env or workflow) ---
RG="${RG:-laravel-rg}"
LOC="${LOC:-uksouth}"
SERVER="${SERVER:-fest-db}"                     # unique, lowercase, 3-63 chars

# Exact version string required by Azure; default to 8.4 (LTS).
MYSQL_VERSION="${MYSQL_VERSION:-8.4}"          # allowed: 8.4, 8.0.21, 5.7, or explicit 8.0.x

SKU_NAME="${SKU_NAME:-Standard_B1ms}"          # default Burstable so create never mismatches
TIER="${TIER:-}"                                # Burstable | GeneralPurpose | BusinessCritical (auto-infer if empty)
STORAGE_GB="${STORAGE_GB:-20}"                  # min 20; can only increase later
BACKUP_DAYS="${BACKUP_DAYS:-7}"                 # 1-35
DB_NAME="${DB_NAME:-laravel}"
APP_USER="${APP_USER:-appuser}"
ADMIN_USER="${ADMIN_USER:-mysqladmin}"          # Azure forms login as 'mysqladmin'
ADMIN_IP="${ADMIN_IP:-}"                        # optional: your public IP

# App/Env
APP_NAME="${APP_NAME:-laravel-aca}"
ENV_NAME="${ENV_NAME:-laravel-env}"

# --- Secrets (required) ---
: "${MYSQL_ADMIN_PASSWORD:?Missing MYSQL_ADMIN_PASSWORD}"
: "${MYSQL_APP_PASSWORD:?Missing MYSQL_APP_PASSWORD}"

# --- Normalize / validate version ---
case "$MYSQL_VERSION" in
  8|8.0) MYSQL_VERSION="8.0.21" ;;
  8.4|8.0.21|5.7) : ;;
  8.0.*) : ;;
  *) echo "Unsupported MYSQL_VERSION='$MYSQL_VERSION'. Use 8.4, 8.0.21, 5.7, or explicit 8.0.x"; exit 2 ;;
esac

# --- Infer TIER from SKU if not provided ---
if [[ -z "${TIER}" ]]; then
  case "$SKU_NAME" in
    Standard_B*) TIER="Burstable" ;;
    Standard_D*|GP*) TIER="GeneralPurpose" ;;
    Standard_E*|BC*) TIER="BusinessCritical" ;;
    *) TIER="Burstable" ;;
  esac
fi
echo "==> Effective tier: $TIER, SKU: $SKU_NAME, Version: $MYSQL_VERSION"

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

# Install preview helper non-interactively (safe if already set)
az config set extension.use_dynamic_install=yes_without_prompt >/dev/null
az config set extension.dynamic_install_allow_preview=true >/dev/null

# Execute SQL (FIXED: no --resource-group here)
SQL="
CREATE USER IF NOT EXISTS '${APP_USER}'@'%' IDENTIFIED BY '${MYSQL_APP_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${APP_USER}'@'%';
FLUSH PRIVILEGES;
"
az mysql flexible-server execute \
  --name "$SERVER" \
  --admin-user "$ADMIN_USER" \
  --admin-password "$MYSQL_ADMIN_PASSWORD" \
  --database-name "$DB_NAME" \
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
