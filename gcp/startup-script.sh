#!/bin/bash
# Arranca SQL Server en Docker (Container-Optimized OS) y aplica init.sql. Idempotente.
set -euo pipefail

MD="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
md() { curl -fsS -H 'Metadata-Flavor: Google' "${MD}/$1"; }

SA_PASSWORD="$(md sa-password)"
APP_PASSWORD="$(md app-password)"
IMAGE="$(md mssql-image)"
DB="$(md mssql-database)"
APP_USER="$(md mssql-app-user)"

INIT_SQL=/var/mssql-init/init.sql
mkdir -p /var/mssql /var/mssql-init
md init-sql > "${INIT_SQL}"
# El contenedor corre como usuario mssql (uid 10001).
chown -R 10001:0 /var/mssql

if ! docker ps -a --format '{{.Names}}' | grep -qx sqlserver; then
  echo "Creando contenedor sqlserver (${IMAGE})"
  docker run -d --name sqlserver --restart unless-stopped \
    -e ACCEPT_EULA=Y -e MSSQL_PID=Developer -e MSSQL_SA_PASSWORD="${SA_PASSWORD}" \
    -p 1433:1433 -v /var/mssql:/var/opt/mssql \
    -v "${INIT_SQL}:/init.sql:ro" \
    "${IMAGE}" > /dev/null
else
  docker start sqlserver > /dev/null 2>&1 || true
fi

SQLCMD=/opt/mssql-tools18/bin/sqlcmd
echo "Esperando a SQL Server (hasta ~120 s)"
ready=0
for _ in $(seq 1 60); do
  if docker exec sqlserver "${SQLCMD}" -C -S localhost -U sa -P "${SA_PASSWORD}" -Q 'SELECT 1' > /dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
if [ "${ready}" -ne 1 ]; then
  echo "SQL Server no respondio a tiempo" >&2
  exit 1
fi

echo "Aplicando init.sql"
docker exec sqlserver "${SQLCMD}" -C -S localhost -U sa -P "${SA_PASSWORD}" -b \
  -i /init.sql -v DB="${DB}" APP_USER="${APP_USER}" APP_PASSWORD="${APP_PASSWORD}"
echo "SQL Server listo"
