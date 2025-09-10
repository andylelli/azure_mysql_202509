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

# Azure (target app user password)
: "${MYSQL_APP_PASSWORD:?}"  # Azure MySQL app user's password

# ========= Optional / defaults =========
MAINTENANCE_MODE="${MAINTENANCE_MODE:-true}"

# Azure MySQL target (your known values)
AZ_MYSQL_SERVER_NAME="${AZ_MYSQL_SERVER_NAME:-fest-db}"
AZ_MYSQL_HOST="${AZ_MYSQL_HOST:-${AZ_MYSQL_SERVER_NAME}.mysql.database.azure.com}"
AZ_MYSQL_DB="${AZ_MYSQL_DB:-laravel}"                # <-- target DB name
AZ_MYSQL_USER="${AZ_MYSQL_USER:-appuser}"            # <-- Flexible Server: no @server suffix

# ========= Helpers / cleanup =========
cleanup() {
  set +e
  echo "🧹 Cleaning up..."
  # Remove temp firewall rule if we created it
  if [[ -n "${FW_CREATED:-}" ]]; then
    az mysql flexible-server firewall-rule delete \
      -g "$AZURE_RG" -n "$AZ_MYSQL_SERVER_NAME" \
      --rule-name gha-runner --yes >/dev/null 2>&1 || true
  fi
  # Remove temp key file
  rm -f cw_ssh_key >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "🌐 Allowing this runner IP to reach Azure MySQL..."
RUNNER_IP="$(curl -fsS https://api.ipify.org)"
az mysql flexible-server firewall-rule create \
  -g "$AZURE_RG" -n "$AZ_MYSQL_SERVER_NAME" \
  --rule-name gha-runner \
  --start-ip-address "$RUNNER_IP" \
  --end-ip-address "$RUNNER_IP" >/dev/null
FW_CREATED=1

echo "🔑 Preparing SSH key..."
umask 077
printf '%s\n' "$CW_SSH_KEY" > cw_ssh_key
chmod 600 cw_ssh_key

echo "🔎 Ensuring 'mysqldump' exists on Cloudways..."
ssh -i cw_ssh_key -o StrictHostKeyChecking=no -o ServerAliveInterval=30 \
  "${CW_SSH_USER}@${CW_SSH_HOST}" "command -v mysqldump >/dev/null" \
  || { echo "❌ 'mysqldump' not found on the server"; exit 1; }

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

echo "📥 Dumping database '${CW_DB_NAME}' from Cloudways over SSH..."
# NOTE: dump the schema/data only (NO 'CREATE DATABASE'/'USE') so we can import into target DB
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
| sed -E 's/DEFINER=`[^`]+`@`[^`]+`/DEFINER=CURRENT_USER/g' \
| gzip -c > dump.sql.gz

echo "🧽 Cleaning temp my.cnf on Cloudways..."
ssh -i cw_ssh_key -o StrictHostKeyChecking=no -o ServerAliveInterval=30 \
  "${CW_SSH_USER}@${CW_SSH_HOST}" "rm -f \"\$HOME/.my_cw.cnf\""

ls -lh dump.sql.gz

echo "🔍 Testing Azure MySQL login as ${AZ_MYSQL_USER}..."
mysql --host="$AZ_MYSQL_HOST" \
      --user="$AZ_MYSQL_USER" \
      --password="$MYSQL_APP_PASSWORD" \
      --ssl-mode=REQUIRED \
      -e "SELECT CURRENT_USER(), USER();"

echo "📤 Ensuring target DB '${AZ_MYSQL_DB}' exists, then importing over TLS..."
# Ensure target DB exists
mysql --host="$AZ_MYSQL_HOST" \
      --user="$AZ_MYSQL_USER" \
      --password="$MYSQL_APP_PASSWORD" \
      --ssl-mode=REQUIRED \
      -e "CREATE DATABASE IF NOT EXISTS \`$AZ_MYSQL_DB\`;"


# Import dump INTO the target DB
zcat dump.sql.gz | mysql \
  --host="$AZ_MYSQL_HOST" \
  --user="$AZ_MYSQL_USER" \
  --password="$MYSQL_APP_PASSWORD" \
  --ssl-mode=REQUIRED \
  -D "$AZ_MYSQL_DB"

# Optional: maintenance mode around artisan
if [[ "$MAINTENANCE_MODE" == "true" ]]; then
  echo "🛠️  Putting app in maintenance mode..."
  script -q -c "az containerapp exec --resource-group \"$AZURE_RG\" --name \"$ACA_NAME\" --command 'php artisan down --render=errors::503 || true'" /dev/null
fi

echo "🧭 Running Laravel migrations + cache warmup in Container App..."
script -q -c "az containerapp exec --resource-group \"$AZURE_RG\" --name \"$ACA_NAME\" --command 'php artisan migrate --force'" /dev/null
script -q -c "az containerapp exec --resource-group \"$AZURE_RG\" --name \"$ACA_NAME\" --command 'php artisan config:clear'" /dev/null
script -q -c "az containerapp exec --resource-group \"$AZURE_RG\" --name \"$ACA_NAME\" --command 'php artisan cache:clear'" /dev/null
script -q -c "az containerapp exec --resource-group \"$AZURE_RG\" --name \"$ACA_NAME\" --command 'php artisan route:cache'" /dev/null
script -q -c "az containerapp exec --resource-group \"$AZURE_RG\" --name \"$ACA_NAME\" --command 'php artisan event:cache'" /dev/null

if [[ "$MAINTENANCE_MODE" == "true" ]]; then
  echo "✅ Bringing app back up..."
  script -q -c "az containerapp exec --resource-group \"$AZURE_RG\" --name \"$ACA_NAME\" --command 'php artisan up || true'" /dev/null
fi

echo "🎉 Migration completed successfully."
