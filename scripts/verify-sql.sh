#!/bin/bash
#
# verify-sql.sh - verifica la conectividad Lambda -> SQL Server (por la VPN)
# con {"action":"ping"} y {"action":"count"}.
#
# Variable opcional: FUNCTION_NAME (default: demo-dynamodb-sqlserver-sync)

set -euo pipefail

FUNCTION_NAME="${FUNCTION_NAME:-demo-dynamodb-sqlserver-sync}"

command -v aws >/dev/null 2>&1 || { echo "Error: se requiere 'aws' cli." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: se requiere 'jq'." >&2; exit 1; }

RESP_FILE="$(mktemp)"
trap 'rm -f "$RESP_FILE"' EXIT

invoke() {
  aws lambda invoke --function-name "$FUNCTION_NAME" --payload "$1" \
    --cli-binary-format raw-in-base64-out "$RESP_FILE" >/dev/null
  if jq -e '.errorMessage' "$RESP_FILE" >/dev/null 2>&1; then
    echo "Error de la Lambda: $(jq -r '.errorMessage' "$RESP_FILE")" >&2
    exit 1
  fi
  jq -r '.body' "$RESP_FILE" | jq .
}

echo "== ping =="
invoke '{"action":"ping"}'
echo "== count =="
invoke '{"action":"count"}'
