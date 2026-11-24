#!/bin/bash
#
# demo-live.sh - demo en vivo de replicacion por DynamoDB Streams.
#
# Uso:
#   ./scripts/demo-live.sh insert                 (crea un comercio DEMO-<timestamp>)
#   ./scripts/demo-live.sh update <merchant_id> [status] [credit_limit]
#
# Requiere enable_streams_sync=true. Espera ~5 s y consulta la fila en SQL Server
# via Lambda ({"action":"count"}) y el registro en la tabla de control.
#
# Variables opcionales: TABLE_NAME, CONTROL_TABLE, FUNCTION_NAME, WAIT_SECONDS

set -euo pipefail

TABLE_NAME="${TABLE_NAME:-demo-merchants-table}"
CONTROL_TABLE="${CONTROL_TABLE:-demo-sync-control}"
FUNCTION_NAME="${FUNCTION_NAME:-demo-dynamodb-sqlserver-sync}"
WAIT_SECONDS="${WAIT_SECONDS:-5}"

command -v aws >/dev/null 2>&1 || { echo "Error: se requiere 'aws' cli." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: se requiere 'jq'." >&2; exit 1; }

MODE="${1:-}"
case "$MODE" in
  insert)
    MERCHANT_ID="DEMO-$(date +%s)"
    NOW="$(date -u +%Y-%m-%dT%H:%M:%S+00:00)"
    echo "INSERT en DynamoDB: $MERCHANT_ID"
    aws dynamodb put-item --table-name "$TABLE_NAME" --item "$(jq -cn \
      --arg id "$MERCHANT_ID" --arg now "$NOW" '{
        merchant_id: {S: $id},
        business_name: {S: "Comercio Demo en Vivo"},
        contact_name: {S: "Ana Demo"},
        email: {S: "ana@example.com"},
        phone: {S: "+593 99 000 0000"},
        city: {S: "Quito"},
        category: {S: "Tecnologia"},
        status: {S: "ACTIVO"},
        credit_limit: {N: "1000"},
        created_at: {S: $now}
      }')"
    ;;
  update)
    MERCHANT_ID="${2:-}"
    [ -n "$MERCHANT_ID" ] || { echo "Uso: $0 update <merchant_id> [status] [credit_limit]" >&2; exit 1; }
    STATUS="${3:-SUSPENDIDO}"
    CREDIT="${4:-2500}"
    echo "UPDATE en DynamoDB: $MERCHANT_ID -> status=$STATUS credit_limit=$CREDIT"
    aws dynamodb update-item --table-name "$TABLE_NAME" \
      --key "$(jq -cn --arg id "$MERCHANT_ID" '{merchant_id: {S: $id}}')" \
      --update-expression "SET #s = :s, credit_limit = :c" \
      --expression-attribute-names '{"#s":"status"}' \
      --expression-attribute-values "$(jq -cn --arg s "$STATUS" --arg c "$CREDIT" '{":s": {S: $s}, ":c": {N: $c}}')"
    ;;
  *)
    echo "Uso: $0 insert | update <merchant_id> [status] [credit_limit]" >&2
    exit 1
    ;;
esac

echo "Esperando ${WAIT_SECONDS}s a que el stream replique..."
sleep "$WAIT_SECONDS"

RESP_FILE="$(mktemp)"
trap 'rm -f "$RESP_FILE"' EXIT

echo "Fila en SQL Server:"
aws lambda invoke --function-name "$FUNCTION_NAME" \
  --payload "$(jq -cn --arg id "$MERCHANT_ID" '{action: "count", merchant_id: $id}')" \
  --cli-binary-format raw-in-base64-out "$RESP_FILE" >/dev/null
jq -r '.body // .' "$RESP_FILE" | jq .

echo "Registro en la tabla de control:"
aws dynamodb get-item --table-name "$CONTROL_TABLE" \
  --key "$(jq -cn --arg id "$MERCHANT_ID" '{merchant_id: {S: $id}}')" | jq .Item
