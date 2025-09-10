#!/usr/bin/env bash
set -euo pipefail

# ========= Required env (fail fast) =========
: "${AZURE_RG:?}"            # e.g. laravel-rg
: "${ACA_NAME:?}"            # e.g. laravel-aca

# Cloudways (source)
: "${CW_DB_NAME:?}"          # e.g. gthewnsykf (source DB)
: "${CW_DB_USER:?}"          # e.g. gthewnsykf
: "${CW_DB_PASSWORD:?}"      # Cloudways DB password
: "${CW_SSH_HOST:?}"         # Cloudways server public IP
: "${CW_SSH_USER:?}"         # Cloudways master SSH username
: "${CW_SSH_KEY:?}"          # Private key PEM (GitHub secret)

# Azure (target)
: "${MYSQL_APP_PASSWORD:?}"  # Azure MySQL app user's password

# ========= Optional / defaults =========
MAINTENANCE_MODE="${MAINTENANCE_MODE:-true}"

# Azure MySQL target (your known values)
AZ_MYSQL_SERVER_NAME="${AZ_MYSQL_SERVER_NAME:-fest-db}"
AZ_MYSQL_HOST="${AZ_MYSQL_HOST:-${AZ_MYSQL_SERVER_NAME}.mysql.database.azure.com}"
AZ_MYSQL_DB="${AZ_MYSQL_DB:-laravel}"         # target DB name used by Laravel
AZ_MYSQL_USER="${AZ_MYSQL_USER:-appuser}"     # Flexible Server: no @server suffix

# ========= Helpers / cleanup =========
cleanup() {
  set +e
  echo "🧹 Cleaning up..."
  if [[ -n "${ALLOW_ALL_AZURE:-}" ]]; then
    az mysql flexible-server firewall-rule delete \
      -g "$AZURE_RG" -n "$AZ_MYSQL_SERVER_NAME" \
      --rule-name AllowAllAzureIPs --yes >/dev/null 2>&1 || true
  fi
  if [[ -n "${FW_CREATED:-}" ]]; then
    az mysql flexible-server firewall-rule delete \
      -g "$AZURE_RG" -n "$AZ_MYSQL_SERVER_NAME" \
      --rule-name gha-runner --yes >/dev/null 2>&1 || true
  fi
  rm -f cw_ssh_key >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---- Allow this CI runner to reach Azure MySQL (for the import) ----
echo "🌐 Allowing this runner IP to reach Azure MySQL..."
RUNNER_IP="$(curl -fsS https://api.ipify.org)"
az mysql flexible-server firewall-rule create \
  -g "$AZURE_RG" -n "$AZ_MYSQL_SERVER_NAME" \
  --rule-name gha-runner \
  --start-ip-address "$RUNNER_IP" \
  --end-ip-address "$RUNNER_IP" >/dev/null
FW_CREATED=1

# ---- Prepare SSH key for Cloudways ----
echo "🔑 Preparing SSH key..."
umask 077
printf '%s\n' "$CW_SSH_KEY" > cw_ssh_key
chmod 600 cw_ssh_key

# ---- Ensure mysqldump exists on Cloudways ----
echo "🔎 Ensuring 'mysqldump' exists on Cloudways..."
ssh -i cw_ssh_key -o StrictHostKeyChecking=no -o ServerAliveInterval=30 \
  "${CW_SSH_USER}@${CW_SSH_HOST}" "command -v mysqldump >/dev/null" \
  || { echo "❌ 'mysqldump' not found on the server"; exit 1; }

# ---- Create a temp defaults file on Cloudways so password isn't in argv ----
echo "📝 Creating temporary my.cnf on Cloudways (hidden, strict perms)..."
ssh -i cw_ssh_key -o StrictHostKeyChecking=no -o ServerAliveInterval=30 \
  "${CW_SSH_USER}@${CW_SSH_HOST}" "bash -s" <<EOF
set -euo pipefail
umask 077
cat > "\$HOME/.my_cw.cnf" <<CFG
[client]
user=${CW_DB_USER}
password=${CW_DB_PASSWORD}
host=127.0.0.1
port=3306
default-character-set=utf8mb4
CFG
chmod 600 "\$HOME/.my_cw.cnf"
EOF

# ---- Dump the source DB schema+data (no CREATE DATABASE/USE) ----
echo "📥 Dumping database '${CW_DB_NAME}' from Cloudways over SSH..."
ssh -i cw_ssh_key -o StrictHostKeyChecking=no -o ServerAliveInterval=30 \
  "${CW_SSH_USER}@${CW_SSH_HOST}" "
    set -euo pipefail
    mysqldump \
      --defaults-extra-file=\$HOME/.my_cw.cnf \
      ${CW_DB_NAME} \
      --single-transaction --quick --lock-tables=0 \
      --routines --triggers --events \
      --hex-blob \
      --no-tablespaces \
      --skip-comments
  " \
| sed -E 's/DEFINER=\`[^`]+\`@\`[^`]+\`/DEFINER=CURRENT_USER/g' \
| gzip -c > dump.sql.gz

# ---- Remove the temp defaults file on Cloudways ----
echo "🧽 Cleaning temp my.cnf on Cloudways..."
ssh -i cw_ssh_key -o StrictHostKeyChecking=no -o ServerAliveInterval=30 \
  "${CW_SSH_USER}@${CW_SSH_HOST}" "rm -f \"\$HOME/.my_cw.cnf\""

ls -lh dump.sql.gz

# ---- Sanity check Azure MySQL auth, and ensure target DB exists ----
echo "🔍 Testing Azure MySQL login as ${AZ_MYSQL_USER}..."
mysql --host="$AZ_MYSQL_HOST" \
      --user="$AZ_MYSQL_USER" \
      --password="$MYSQL_APP_PASSWORD" \
      --ssl-mode=REQUIRED \
      -e "SELECT CURRENT_USER(), USER();"

echo "📤 Ensuring target DB '${AZ_MYSQL_DB}' exists, then importing over TLS..."
mysql --host="$AZ_MYSQL_HOST" \
      --user="$AZ_MYSQL_USER" \
      --password="$MYSQL_APP_PASSWORD" \
      --ssl-mode=REQUIRED \
      -e "CREATE DATABASE IF NOT EXISTS \`$AZ_MYSQL_DB\`;"

zcat dump.sql.gz | mysql \
  --host="$AZ_MYSQL_HOST" \
  --user="$AZ_MYSQL_USER" \
  --password="$MYSQL_APP_PASSWORD" \
  --ssl-mode=REQUIRED \
  -D "$AZ_MYSQL_DB"

# ---- Temporarily allow ALL Azure services (incl. Container Apps) ----
echo "🌐 Temporarily allowing all Azure services to reach Azure MySQL..."
az mysql flexible-server firewall-rule create \
  -g "$AZURE_RG" -n "$AZ_MYSQL_SERVER_NAME" \
  --rule-name AllowAllAzureIPs \
  --start-ip-address 0.0.0.0 \
  --end-ip-address 0.0.0.0 >/dev/null || true
ALLOW_ALL_AZURE=1

# ---- Laravel maintenance (optional), migrate, caches, bring up ----
if [[ "$MAINTENANCE_MODE" == "true" ]]; then
  echo "🛠️  Putting app in maintenance mode..."
  script -q -c "az containerapp exec \
    --resource-group \"$AZURE_RG\" \
    --name \"$ACA_NAME\" \
    --command \"sh -lc 'php artisan down --render=errors::503 || true'\"" /dev/null
fi

echo "🧭 Running Laravel migrations + cache warmup (and bringing app up if needed)..."
script -q -c "az containerapp exec \
  --resource-group \"$AZURE_RG\" \
  --name \"$ACA_NAME\" \
  --command \"sh -lc '
    php artisan migrate --force &&
    php artisan config:clear &&
    php artisan cache:clear &&
    php artisan route:cache &&
    php artisan event:cache &&
    ( [ \"$MAINTENANCE_MODE\" = \"true\" ] && php artisan up || true )
  '\"" /dev/null

echo '🎉 Migration completed successfully.'
