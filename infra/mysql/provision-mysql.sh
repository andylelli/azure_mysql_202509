#!/usr/bin/env bash
set -euo pipefail

# --- Inputs (override via env or workflow) ---
RG="${RG:-laravel-rg}"
LOC="${LOC:-uksouth}"
SERVER="${SERVER:-fest-db}"

# Exact version string required by Azure; default to 8.4 (LTS).
MYSQL_VERSION="${MYSQL_VERSION:-8.4}"          # 8.4, 8.0.21, 5.7, or explicit 8.0.x

SKU_NAME="${SKU_NAME:-Standard_B1ms}"          # default Burstable
TIER="${TIER:-}"                                # Burstable | GeneralPurpose | BusinessCritical (auto-infer)
STORAGE_GB="${STORAGE_GB:-20}"
BACKUP_DAYS="${BACKUP_DAYS:-7}"
DB_NAME="${DB_NAME:-laravel}"
APP_USER="${APP_USER:-appuser}"
ADMIN_USER="${ADMIN_USER:-mysqladmin}"
ADMIN_IP="${ADMIN_IP:-}"                        # optional: your public IP (firewall)

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
  # NOTE: --public-access None = public connectivity method with no IPs allowed yet.
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

# Optional admin IP rule (your laptop/workstation)
if [[ -n "${ADMIN_IP}" ]]; then
  az mysql flexible-server firewall-rule create -g "$RG" -s "$SERVER" \
    --name "admin-ip" --start-ip-address "$ADMIN_IP" --end-ip-address "$ADMIN_IP" >/dev/null || true
fi

echo "==> Create DB (idempotent)"
az mysql flexible-server db create -g "$RG" -s "$SERVER" -d "$DB_NAME" >/dev/null || true

# --- Temporarily allow the GitHub runner IP for the SQL step, then retry until open ---
TEMP_RULE=""
cleanup() {
  if [[ -n "$TEMP_RULE" ]]; then
    az mysql flexible-server firewall-rule delete -g "$RG" -s "$SERVER" -n "$TEMP_RULE" --yes >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ -z "${ADMIN_IP}" ]]; then
  echo "==> Detect runner public IP for temporary firewall rule"
  MYIP="$(curl -fsS https://ifconfig.me 2>/dev/null || curl -fsS https://api.ipify.org 2>/dev/null || true)"
  if [[ -n "$MYIP" ]]; then
    TEMP_RULE="gha-$(date +%s)"
    echo "   Detected IP: $MYIP -> creating rule $TEMP_RULE"
    az mysql flexible-server firewall-rule create -g "$RG" -s "$SERVER" \
      --name "$TEMP_RULE" --start-ip-address "$MYIP" --end-ip-address "$MYIP" >/dev/null || true
  else
    echo "   Could not detect runner IP. If this step fails, re-run with 'admin_ip' input set."
  fi
fi

# Ensure CLI helper is available
az config set extension.use_dynamic_install=yes_without_prompt >/dev/null
az config set extension.dynamic_install_allow_preview=true >/dev/null

# Wait for firewall propagation and test connectivity
echo "==> Wait for firewall propagation & test connectivity"
for attempt in {1..18}; do
  if az mysql flexible-server connect \
       --name "$SERVER" -u "$ADMIN_USER" -p "$MYSQL_ADMIN_PASSWORD" \
       -d "$DB_NAME" --querytext "SELECT 1;" >/dev/null 2>&1; then
    echo "   Connectivity OK."
    break
  fi
  echo "   Attempt $attempt/18: waiting 10s..."
  sleep 10
done

echo "==> Create least-privileged app user (via SQL)"
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
