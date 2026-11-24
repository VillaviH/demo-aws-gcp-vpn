#!/bin/bash
#
# check-vpn.sh - estado de los 2 tuneles (AWS) y de las sesiones BGP (GCP).
# Solo lectura.
#
# Variables opcionales: AWS_REGION, GCP_PROJECT, GCP_REGION, ROUTER_NAME
# Si no se definen GCP_PROJECT/GCP_REGION/ROUTER_NAME se omite la parte GCP
# con un aviso (consulta los nombres con "terraform output" o en la consola).

set -euo pipefail

command -v aws >/dev/null 2>&1 || { echo "Error: se requiere 'aws' cli." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: se requiere 'jq'." >&2; exit 1; }

REGION_ARGS=()
if [ -n "${AWS_REGION:-}" ]; then
  REGION_ARGS=(--region "$AWS_REGION")
fi

echo "== AWS: tuneles VPN (Project=demo-aws-gcp-vpn) =="
aws ec2 describe-vpn-connections "${REGION_ARGS[@]}" \
  --filters "Name=tag:Project,Values=demo-aws-gcp-vpn" "Name=state,Values=available,pending" \
  | jq -r '.VpnConnections[] | . as $c | .VgwTelemetry[] |
      "\($c.VpnConnectionId)  \(.OutsideIpAddress)  \(.Status)  \(.StatusMessage // "")"'

if [ -z "${GCP_PROJECT:-}" ] || [ -z "${GCP_REGION:-}" ]; then
  echo ""
  echo "Aviso: define GCP_PROJECT y GCP_REGION (y opcionalmente ROUTER_NAME) para ver la parte GCP."
  exit 0
fi

command -v gcloud >/dev/null 2>&1 || { echo "Error: se requiere 'gcloud'." >&2; exit 1; }

echo ""
echo "== GCP: tuneles VPN =="
gcloud compute vpn-tunnels list --project "$GCP_PROJECT" --regions "$GCP_REGION" \
  --format="table(name,status,detailedStatus)"

if [ -n "${ROUTER_NAME:-}" ]; then
  echo ""
  echo "== GCP: sesiones BGP del Cloud Router $ROUTER_NAME =="
  gcloud compute routers get-status "$ROUTER_NAME" --project "$GCP_PROJECT" --region "$GCP_REGION" \
    --format="table(result.bgpPeerStatus[].name,result.bgpPeerStatus[].status,result.bgpPeerStatus[].state)"
fi
