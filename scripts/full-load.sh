#!/bin/bash
#
# full-load.sh - full load DynamoDB -> SQL Server invocando la Lambda en bucle
# con el checkpoint (start_key) hasta que last_evaluated_key sea null.
#
# Uso:
#   ./scripts/full-load.sh --dry-run   (valida, NO escribe en SQL Server)
#   ./scripts/full-load.sh             (escritura real)
#
# Requisitos: aws cli con credenciales del usuario y jq.
# Variable opcional: FUNCTION_NAME (default: demo-dynamodb-sqlserver-sync)

set -euo pipefail

FUNCTION_NAME="${FUNCTION_NAME:-demo-dynamodb-sqlserver-sync}"

command -v aws >/dev/null 2>&1 || { echo "Error: se requiere 'aws' cli." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: se requiere 'jq'." >&2; exit 1; }

DRY_RUN=false
if [ "${1:-}" == "--dry-run" ]; then
  DRY_RUN=true
  echo "Modo DRY-RUN: se valida todo, no se escribe nada en SQL Server."
else
  echo "Modo REAL: se escribira en SQL Server."
fi

RESP_FILE="$(mktemp)"
trap 'rm -f "$RESP_FILE"' EXIT

START_KEY="null"
PAGINA=0
TOTAL_MIGRADOS=0
TOTAL_PARCIALES=0
TOTAL_ERRORES=0

while true; do
  PAGINA=$((PAGINA + 1))
  PAYLOAD=$(jq -cn --argjson dry "$DRY_RUN" --argjson key "$START_KEY" \
    '{full_scan: true, dry_run: $dry} + (if $key == null then {} else {start_key: $key} end)')

  aws lambda invoke --function-name "$FUNCTION_NAME" \
    --payload "$PAYLOAD" --cli-binary-format raw-in-base64-out "$RESP_FILE" >/dev/null

  if jq -e '.errorMessage' "$RESP_FILE" >/dev/null 2>&1; then
    echo "Error de la Lambda: $(jq -r '.errorMessage' "$RESP_FILE")" >&2
    exit 1
  fi

  BODY=$(jq -r '.body' "$RESP_FILE")
  MIGRADOS=$(echo "$BODY" | jq -r '.resumen.migrados // 0')
  PARCIALES=$(echo "$BODY" | jq -r '.resumen.parciales // 0')
  ERRORES=$(echo "$BODY" | jq -r '.resumen.errores // 0')
  echo "Invocacion $PAGINA: migrados=$MIGRADOS parciales=$PARCIALES errores=$ERRORES"

  TOTAL_MIGRADOS=$((TOTAL_MIGRADOS + MIGRADOS))
  TOTAL_PARCIALES=$((TOTAL_PARCIALES + PARCIALES))
  TOTAL_ERRORES=$((TOTAL_ERRORES + ERRORES))

  START_KEY=$(echo "$BODY" | jq -c '.last_evaluated_key')
  if [ "$START_KEY" == "null" ]; then
    echo ""
    echo "Full load completo en $PAGINA invocaciones."
    echo "Totales -> migrados: $TOTAL_MIGRADOS | parciales: $TOTAL_PARCIALES | errores: $TOTAL_ERRORES"
    if [ "$TOTAL_ERRORES" -gt 0 ]; then
      echo "Hay $TOTAL_ERRORES registro(s) con error. Revisar el detalle en la tabla de control (demo-sync-control)." >&2
      exit 2
    fi
    break
  fi
  sleep 1
done
