#!/usr/bin/env bash
set -euo pipefail

# ==== Required env (fail fast if missing) ====
: "${AZURE_RG:?}"
: "${ACA_NAME:?}"
: "${CW_DB_NAME:?}"
: "${CW_DB_USER:?}"
: "${CW_DB_PASSWORD:?}"
: "${CW_SSH_HOST:?}"
: "${CW_SSH_USER:?}"
: "${CW_SSH_KEY:?}"
: "${MYSQL_APP_PASSWORD:?}"

# ==== Optional / defaults ====
MAINTENANCE_MODE="${MAINTENANCE_MODE:-true}"

# Azure MySQL target (your known values)
AZ_MYSQL_HOST="${AZ_MYSQL_HOST:-fest-db.mysql.database.azure.com}"
AZ_MYSQL_DB="${AZ_MYSQL_DB:-laravel}"
AZ_MYSQL_USER="${AZ_MYSQL_USER:-appuser@fest-db}"
AZ_MYSQL_SERVER_NAME="${AZ_MYSQL_SERVER_NAME:-fest-db}"  # for firewall rule mgmt

# ==== Helpers ====
cleanup() {
  set +e
  echo "🧹 Cleaning up..."
  if [[ -n "${FW_CREATED:-}" ]]; then
    az mysql flexible-server firewall-rule delete \
      -g "$AZURE_RG" -n "$AZ_MYSQL_SERVER_NAME" \
      --rule-name gha-runner --yes >/dev/null 2>&1 || true
  fi
  if [[ -n "${SSH_PID:-}" ]]; then
    kill "$SSH_PID" >/dev/null 2>&1 || true
  fi
  rm -f cw_ssh_key >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ==== Create temporary Azure MySQL firewall rule for this runner ====
echo "🌐 Allowing this runner IP to reach Azure MySQL..."
RUNNER_IP="$(curl -fsS https://api.ipify.org)"
az mysql flexible-server firewall-rule create \
  -g "$AZURE_RG" -n "$AZ_MYSQL_SERVER_NAME" \
  --rule-name gha-runner \
  --start-ip-address "$RUNNER_IP" \
  --end-ip-address "$RUNNER_IP" >/dev/null
FW_CREATED=1

# ==== SSH tunnel to Cloudways (3307 -> 127.0.0.1:3306) ====
echo "🔑 Establishing SSH tunnel to Cloudways @ ${CW_SSH_HOST} ..."
umask 077
echo "$CW_SSH_KEY" > cw_ssh_key
chmod 600 cw_ssh_key
ssh -i cw_ssh_key -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -N \
  -L 3307:127.0.0.1:3306 "${CW_SSH_USER}@${CW_SSH_HOST}" &
SSH_PID=$!
# Wait briefly and verify local port
sleep 1
ss -lnt | grep -q ":3307" || { echo "❌ SSH tunnel failed"; exit 1; }
echo "✅ Tunnel active on 127.0.0.1:3307"

# ==== Dump from Cloudways via tunnel ====
echo "📥 Dumping database '${CW_DB_NAME}' from Cloudways..."
mysqldump \
  --host=127.0.0.1 --port=3307 \
  --user="${CW_DB_USER}" --password="${CW_DB_PASSWORD}" \
  --databases "${CW_DB_NAME}" \
  --single-transaction --quick --lock-tables=0 \
  --routines --triggers --events \
  --hex-blob --default-character-set=utf8mb4 \
  --set-gtid-purged=OFF --column-statistics=0 --no-tablespaces \
  --skip-comments \
| sed -E 's/DEFINER=`[^`]+`@`[^`]+`/DEFINER=CURRENT_USER/g' \
| gzip -c > dump.sql.gz
ls -lh dump.sql.gz

# ==== Import into Azure MySQL (TLS) ====
echo "📤 Importing into Azure MySQL (${AZ_MYSQL_HOST})..."
mysql --host="$AZ_MYSQL_HOST" --user="$AZ_MYSQL_USER" \
  --password="$MYSQL_APP_PASSWORD" --ssl-mode=REQUIRED \
  -e "CREATE DATABASE IF NOT EXISTS \`${AZ_MYSQL_DB}\`;"

zcat dump.sql.gz | mysql \
  --host="$AZ_MYSQL_HOST" \
  --user="$AZ_MYSQL_USER" \
  --password="$MYSQL_APP_PASSWORD" \
  --ssl-mode=REQUIRED

# ==== (Optional) Laravel maintenance mode ====
if [[ "$MAINTENANCE_MODE" == "true" ]]; then
  echo "🛠️  Putting app in maintenance mode..."
  script -q -c "az containerapp exec --resource-group \"$AZURE_RG\" --name \"$ACA_NAME\" --command 'php artisan down --render=errors::503 || true'" /dev/null
fi

# ==== Run Laravel migrations + cache warmup ====
echo "🧭 Running Laravel migrations and cache warmup..."
script -q -c "az containerapp exec --resource-group \"$AZURE_RG_
