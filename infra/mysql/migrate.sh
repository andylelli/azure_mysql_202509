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

# Migration behavior:
#   drop_recreate  -> drop ALL target objects and import full dump
#   no_overwrite   -> do NOT modify existing tables; only create+fill missing tables
# Default is SAFE: no_overwrite
MIGRATION_MODE="${MIGRATION_MODE:-no_overwrite}"

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

# ---- Guard MIGRATION_MODE ----
case "$MIGRATION_MODE" in
  drop_recreate|no_overwrite) ;;
  *) echo "❌ MIGRATION_MODE must be one of: drop_recreate | no_overwrite"; exit 2;;
esac

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
# IMPORTANT: unquoted heredoc so local ${CW_DB_USER}/${CW_DB_PASSWORD} expand BEFORE sending to remote.
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

# ---- Sanity check Azure MySQL auth, and ensure target DB exists ----
echo "🔍 Testing Azure MySQL login as ${AZ_MYSQL_USER}..."
mysql --host="$AZ_MYSQL_HOST" \
      --user="$AZ_MYSQL_USER" \
      --password="$MYSQL_APP_PASSWORD" \
      --ssl-mode=REQUIRED \
      -e "SELECT CURRENT_USER(), USER();"

echo "📤 Ensuring target DB '${AZ_MYSQL_DB}' exists..."
mysql --host="$AZ_MYSQL_HOST" \
      --user="$AZ_MYSQL_USER" \
      --password="$MYSQL_APP_PASSWORD" \
      --ssl-mode=REQUIRED \
      -e "CREATE DATABASE IF NOT EXISTS \`$AZ_MYSQL_DB\`;"

# ---- Make the dump (choice depends on MIGRATION_MODE) ----
if [[ "$MIGRATION_MODE" == "drop_recreate" ]]; then
  echo "📥 Dumping FULL database '${CW_DB_NAME}' from Cloudways (includes routines/triggers/events)..."
  ssh -i cw_ssh_key -o StrictHostKeyChecking=no -o ServerAliveInterval=30 \
    "${CW_SSH_USER}@${CW_SSH_HOST}" "
      set -euo pipefail
      mysqldump \
        --defaults-extra-file=\$HOME/.my_cw.cnf \
        ${CW_DB_NAME} \
        --single-transaction --quick --lock-tables=0 \
        --routines --triggers --events \
        --hex-blob \
        --add-drop-table \
        --no-tablespaces \
        --skip-comments
    " \
  | sed -E 's/DEFINER=\`[^`]+\`@\`[^`]+\`/DEFINER=CURRENT_USER/g' \
  | gzip -c > dump.sql.gz
else
  echo "📋 Resolving missing tables to migrate (no overwrite of existing tables)..."
  # List source tables
  ssh -i cw_ssh_key -o StrictHostKeyChecking=no -o ServerAliveInterval=30 \
    "${CW_SSH_USER}@${CW_SSH_HOST}" "
      mysql --defaults-extra-file=\$HOME/.my_cw.cnf -N -e \"
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema='${CW_DB_NAME}' AND table_type='BASE TABLE'
        ORDER BY 1;
      \"
    " > /tmp/src_tables.txt

  # List target tables
  mysql --host="$AZ_MYSQL_HOST" \
        --user="$AZ_MYSQL_USER" \
        --password="$MYSQL_APP_PASSWORD" \
        --ssl-mode=REQUIRED \
        -N -e "
          SELECT table_name
          FROM information_schema.tables
          WHERE table_schema='${AZ_MYSQL_DB}' AND table_type='BASE TABLE'
          ORDER BY 1;
        " > /tmp/tgt_tables.txt

  sort -u /tmp/src_tables.txt -o /tmp/src_tables.txt
  sort -u /tmp/tgt_tables.txt -o /tmp/tgt_tables.txt

  # Compute missing = in source but not in target
  comm -23 /tmp/src_tables.txt /tmp/tgt_tables.txt > /tmp/missing_tables.txt
  MISSING_COUNT=$(wc -l < /tmp/missing_tables.txt | tr -d '[:space:]' || echo 0)

  if [[ "$MISSING_COUNT" == "0" ]]; then
    echo "✅ No missing tables to import. Skipping dump/import."
    : > dump.sql.gz  # empty placeholder so later steps don't fail
  else
    echo "🧾 Will import $MISSING_COUNT table(s):"
    sed 's/^/   - /' /tmp/missing_tables.txt
    # Build a space-separated table list
    TABLE_LIST=$(tr '\n' ' ' < /tmp/missing_tables.txt | xargs echo || true)

    echo "📥 Dumping ONLY missing tables (no routines/triggers/events)..."
    ssh -i cw_ssh_key -o StrictHostKeyChecking=no -o ServerAliveInterval=30 \
      "${CW_SSH_USER}@${CW_SSH_HOST}" "
        set -euo pipefail
        mysqldump \
          --defaults-extra-file=\$HOME/.my_cw.cnf \
          ${CW_DB_NAME} ${TABLE_LIST} \
          --single-transaction --quick --lock-tables=0 \
          --hex-blob \
          --no-tablespaces \
          --skip-comments
      " \
    | sed -E 's/DEFINER=\`[^`]+\`@\`[^`]+\`/DEFINER=CURRENT_USER/g' \
    | gzip -c > dump.sql.gz
  fi
fi

# ---- Remove the temp defaults file on Cloudways ----
echo "🧽 Cleaning temp my.cnf on Cloudways..."
ssh -i cw_ssh_key -o StrictHostKeyChecking=no -o ServerAliveInterval=30 \
  "${CW_SSH_USER}@${CW_SSH_HOST}" "rm -f \"\$HOME/.my_cw.cnf\""

ls -lh dump.sql.gz || true

# ---- If drop_recreate, wipe target objects before import ----
if [[ "$MIGRATION_MODE" == "drop_recreate" ]]; then
  echo "🧨 Dropping ALL objects in target schema '${AZ_MYSQL_DB}' (tables, views, triggers, routines, events)..."
  # Generate DROP statements WITHOUT column headers, then execute them in the target DB.
  mysql --host="$AZ_MYSQL_HOST" \
        --user="$AZ_MYSQL_USER" \
        --password="$MYSQL_APP_PASSWORD" \
        --ssl-mode=REQUIRED \
        --skip-column-names --batch <<SQL \
  | mysql --host="$AZ_MYSQL_HOST" \
          --user="$AZ_MYSQL_USER" \
          --password="$MYSQL_APP_PASSWORD" \
          --ssl-mode=REQUIRED \
          "$AZ_MYSQL_DB"
SELECT 'SET FOREIGN_KEY_CHECKS=0;';
SELECT CONCAT('DROP VIEW IF EXISTS \`', table_name, '\`;')
  FROM information_schema.views
 WHERE table_schema='${AZ_MYSQL_DB}';
SELECT CONCAT('DROP TRIGGER IF EXISTS \`', trigger_name, '\`;')
  FROM information_schema.triggers
 WHERE trigger_schema='${AZ_MYSQL_DB}';
SELECT CONCAT('DROP ', routine_type, ' IF EXISTS \`', routine_name, '\`;')
  FROM information_schema.routines
 WHERE routine_schema='${AZ_MYSQL_DB}';
SELECT CONCAT('DROP EVENT IF EXISTS \`', event_name, '\`;')
  FROM information_schema.events
 WHERE event_schema='${AZ_MYSQL_DB}';
SELECT CONCAT('DROP TABLE IF EXISTS \`', table_name, '\`;')
  FROM information_schema.tables
 WHERE table_schema='${AZ_MYSQL_DB}' AND table_type='BASE TABLE';
SELECT 'SET FOREIGN_KEY_CHECKS=1;';
SQL
fi

# ---- Import (if we actually have content) ----
if [[ -s dump.sql.gz ]]; then
  echo "📦 Importing into '${AZ_MYSQL_DB}' over TLS..."
  zcat dump.sql.gz | mysql \
    --host="$AZ_MYSQL_HOST" \
    --user="$AZ_MYSQL_USER" \
    --password="$MYSQL_APP_PASSWORD" \
    --ssl-mode=REQUIRED \
    -D "$AZ_MYSQL_DB"
else
  echo "ℹ️ No import file content; nothing to load."
fi

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
