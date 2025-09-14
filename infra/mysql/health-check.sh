
# MYSQL_APP_PASSWORD='YreW99gV4j'

# --- Set once ---
RG="laravel-rg"
SERVER="fest-db"
DB_NAME="laravel"
APP_USER="appuser"
MYSQL_APP_PASSWORD="${MYSQL_APP_PASSWORD:?Set MYSQL_APP_PASSWORD in your environment first}"

# Resolve FQDN
HOST=$(az mysql flexible-server show -g "$RG" -n "$SERVER" --query fullyQualifiedDomainName -o tsv)

echo "== Server state / FQDN / Public access =="
az mysql flexible-server show -g "$RG" -n "$SERVER" \
  --query "{state:state, fqdn:fullyQualifiedDomainName, public:publicNetworkAccess}" -o table

echo -e "\n== TLS required? =="
az mysql flexible-server parameter show -g "$RG" -s "$SERVER" \
  --name require_secure_transport --query "{name:name, value:value}" -o table

echo -e "\n== Firewall rules (including Cloudways / Workbench / ACA) =="
az mysql flexible-server firewall-rule list -g "$RG" --name "$SERVER" \
  --query "[].{name:name,start:startIpAddress,end:endIpAddress}" -o table

echo -e "\n== Databases on server =="
az mysql flexible-server db list -g "$RG" --server-name "$SERVER" \
  --query "[].name" -o table

echo -e "\n== App user visibility test (non-interactive) =="
MYSQL_PWD="$MYSQL_APP_PASSWORD" mysql -h "$HOST" -u "$APP_USER" \
  --ssl-ca=/home/master/applications/gthewnsykf/public_html/certs/azure-mysql-ca-bundle.pem \
  -e "SHOW DATABASES LIKE '${DB_NAME}';"
