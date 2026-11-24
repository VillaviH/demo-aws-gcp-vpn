#!/bin/bash
#
# demo-menu.sh - menu interactivo para la demo en vivo:
#   DynamoDB (AWS) -> VPN site-to-site AWS<->GCP -> SQL Server (GCP)
#
# Uso:
#   export AWS_PROFILE=<tu-perfil> AWS_DEFAULT_REGION=us-east-1
#   ./scripts/demo-menu.sh            (menu interactivo)
#   ./scripts/demo-menu.sh 1|2|3|4|5  (ejecuta una opcion y termina)
#
# Variables opcionales: TABLE_NAME, FUNCTION_NAME, MAX_WAIT (segundos, default 60),
#                       LAST_ID_FILE (default /tmp/demo-last-id)
#
# SQL Server se consulta invocando la Lambda dentro de la VPC ({"action":"count"}),
# igual que verify-sql.sh y demo-live.sh. No se imprime ninguna credencial ni ARN.
set -uo pipefail

TABLE_NAME="${TABLE_NAME:-demo-merchants-table}"
FUNCTION_NAME="${FUNCTION_NAME:-demo-dynamodb-sqlserver-sync}"
MAX_WAIT="${MAX_WAIT:-60}"
LAST_ID_FILE="${LAST_ID_FILE:-/tmp/demo-last-id}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_PAGER=""

# Colores ANSI
R=$'\033[0m'; B=$'\033[1m'; RED=$'\033[31m'; GRN=$'\033[32m'
YEL=$'\033[33m'; CYN=$'\033[36m'; DIM=$'\033[2m'

RESP_FILE="$(mktemp)"
trap 'rm -f "$RESP_FILE"' EXIT

# ---------------------------------------------------------------- utilidades
fail() { printf '%s\n' "${RED}${B}✖ $*${R}" >&2; }

check_deps() {
  local missing=0 dep
  for dep in aws jq; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      fail "Falta '$dep'. Instalalo (por ejemplo: brew install $dep) y vuelve a intentar."
      missing=1
    fi
  done
  return "$missing"
}

check_credentials() {
  if aws sts get-caller-identity >/dev/null 2>&1; then
    return 0
  fi
  if [ -z "${AWS_PROFILE:-}" ]; then
    fail "No hay credenciales de AWS. Exporta tu perfil antes de correr el menu:"
    printf '   export AWS_PROFILE=<tu-perfil> AWS_DEFAULT_REGION=us-east-1\n' >&2
  else
    fail "No se pudo autenticar con AWS (sesion vencida o perfil invalido). Revisa tu login."
  fi
  return 1
}

banner() {
  clear
  printf '%s\n' "${CYN}${B}╔══════════════════════════════════════════════════════════╗"
  printf '%s\n' "║   DEMO: DynamoDB -> VPN AWS<->GCP -> SQL Server          ║"
  printf '%s\n' "╚══════════════════════════════════════════════════════════╝${R}"
  echo
}

pause() {
  [ "$INTERACTIVE" = "1" ] || return 0
  echo
  read -r -p "${DIM}Presiona Enter para volver al menu...${R} " _
}

# ----------------------------------------------------- conteos (globales)
DDB_COUNT=""
SQL_COUNT=""

get_ddb_count() {
  local total=0 out n token=""
  while :; do
    if [ -z "$token" ]; then
      out=$(aws dynamodb scan --table-name "$TABLE_NAME" --select COUNT --output json 2>/dev/null)
    else
      out=$(aws dynamodb scan --table-name "$TABLE_NAME" --select COUNT --output json \
        --starting-token "$token" 2>/dev/null)
    fi || return 1
    n=$(printf '%s' "$out" | jq -r '.Count // empty' 2>/dev/null) || return 1
    [ -n "$n" ] || return 1
    total=$((total + n))
    token=$(printf '%s' "$out" | jq -r '.NextToken // empty' 2>/dev/null)
    [ -n "$token" ] || break
  done
  DDB_COUNT="$total"
}

# invoca la Lambda con el payload $1 y deja el body JSON en LAMBDA_BODY
LAMBDA_BODY=""
invoke_lambda() {
  LAMBDA_BODY=""
  aws lambda invoke --function-name "$FUNCTION_NAME" --payload "$1" \
    --cli-binary-format raw-in-base64-out "$RESP_FILE" >/dev/null 2>&1 || return 1
  jq -e '.errorMessage' "$RESP_FILE" >/dev/null 2>&1 && return 1
  LAMBDA_BODY=$(jq -r '.body // empty' "$RESP_FILE" 2>/dev/null)
  [ -n "$LAMBDA_BODY" ]
}

get_sql_count() {
  invoke_lambda '{"action":"count"}' || return 1
  SQL_COUNT=$(printf '%s' "$LAMBDA_BODY" | jq -r '.count // empty' 2>/dev/null)
  [ -n "$SQL_COUNT" ]
}

# ------------------------------------------------------------- opciones
opt_ddb() {
  printf '%s\n' "${YEL}⏳ Contando registros en DynamoDB...${R}"
  if get_ddb_count; then
    printf '\n   %s\n' "${B}${GRN}☁  DynamoDB (AWS): ${DDB_COUNT} registros${R}"
  else
    fail "No se pudo leer DynamoDB. Revisa tu sesion de AWS y la region."
    return 1
  fi
}

opt_sql() {
  printf '%s\n' "${YEL}⏳ Consultando SQL Server (GCP) via Lambda y VPN...${R}"
  if get_sql_count; then
    printf '\n   %s\n' "${B}${GRN}🗄  SQL Server (GCP): ${SQL_COUNT} registros${R}"
  else
    fail "No se pudo consultar SQL Server (la Lambda no respondio o la VPN esta caida)."
    return 1
  fi
}

opt_compare() {
  printf '%s\n' "${YEL}⏳ Consultando ambos lados...${R}"
  get_ddb_count || { fail "No se pudo leer DynamoDB."; return 1; }
  get_sql_count || { fail "No se pudo consultar SQL Server (Lambda/VPN)."; return 1; }
  echo
  printf '   %s\n' "${B}☁  DynamoDB (AWS)   : ${DDB_COUNT}${R}"
  printf '   %s\n' "${B}🗄  SQL Server (GCP) : ${SQL_COUNT}${R}"
  echo
  if [ "$DDB_COUNT" -eq "$SQL_COUNT" ]; then
    printf '   %s\n' "${GRN}${B}✔ OK: los conteos coinciden (${DDB_COUNT} = ${SQL_COUNT})${R}"
  else
    local diff=$((DDB_COUNT - SQL_COUNT))
    [ "$diff" -lt 0 ] && diff=$((-diff))
    printf '   %s\n' "${RED}${B}✖ DIFERENCIA: faltan ${diff} registros por replicar${R}"
  fi
}

opt_create() {
  local id now_h epoch item
  id="DEMO-LIVE-$(date +%H%M%S)"
  now_h="$(date +%H:%M:%S)"
  epoch="$(date +%s)"
  item=$(jq -cn --arg id "$id" --arg now "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" '{
      merchant_id: {S: $id},
      business_name: {S: "Cafeteria El Mirador"},
      contact_name: {S: "Lucia Paredes"},
      email: {S: "contacto@example.com"},
      phone: {S: "+593 99 123 4567"},
      city: {S: "Guayaquil"},
      category: {S: "Restaurante"},
      status: {S: "ACTIVO"},
      credit_limit: {N: "7500"},
      created_at: {S: $now}
    }')
  printf '%s\n' "${YEL}⏳ Insertando registro en DynamoDB...${R}"
  if ! aws dynamodb put-item --table-name "$TABLE_NAME" --item "$item" >/dev/null 2>&1; then
    fail "No se pudo insertar en DynamoDB. Revisa tu sesion de AWS."
    return 1
  fi
  printf '%s\n%s\n' "$id" "$epoch" > "$LAST_ID_FILE"
  printf '\n   %s\n' "${GRN}${B}✔ Registro creado: ${id}${R}"
  printf '   %s\n' "🕒 Hora: ${now_h}"
  if get_ddb_count; then
    printf '   %s\n' "${B}☁  DynamoDB (AWS) ahora: ${DDB_COUNT} registros${R}"
  fi
  printf '\n   %s\n' "${DIM}Siguiente paso: opcion 5 para verlo llegar a SQL Server.${R}"
}

opt_verify() {
  if [ ! -s "$LAST_ID_FILE" ]; then
    fail "Aun no hay un registro creado. Usa primero la opcion 4."
    return 1
  fi
  local id start now elapsed found=0 row
  id=$(sed -n 1p "$LAST_ID_FILE")
  start=$(sed -n 2p "$LAST_ID_FILE")
  case "$start" in ''|*[!0-9]*) start=$(date +%s) ;; esac
  printf '%s\n\n' "${YEL}🔎 Buscando ${B}${id}${R}${YEL} en SQL Server (GCP), maximo ${MAX_WAIT}s...${R}"
  while :; do
    now=$(date +%s); elapsed=$((now - start))
    if invoke_lambda "$(jq -cn --arg id "$id" '{action:"count", merchant_id:$id}')"; then
      row=$(printf '%s' "$LAMBDA_BODY" | jq -c '.row // empty' 2>/dev/null)
      if [ -n "$row" ] && [ "$row" != "null" ]; then found=1; break; fi
    fi
    if [ "$elapsed" -ge "$MAX_WAIT" ]; then break; fi
    printf '\r   %s' "${CYN}⏱  ${elapsed}s transcurridos desde la creacion...${R}   "
    sleep 1
  done
  printf '\r%60s\r' ""
  if [ "$found" -eq 1 ]; then
    now=$(date +%s); elapsed=$((now - start))
    printf '   %s\n\n' "${GRN}${B}✔ ENCONTRADO en SQL Server a los ${elapsed} segundos${R}"
    printf '%s' "$row" | jq -r '
      "   ID:        \(.merchant_id)",
      "   Negocio:   \(.business_name)",
      "   Contacto:  \(.contact_name)",
      "   Ciudad:    \(.city)",
      "   Categoria: \(.category)",
      "   Estado:    \(.status)",
      "   Credito:   \(.credit_limit)"'
    if get_sql_count; then
      printf '\n   %s\n' "${B}🗄  SQL Server (GCP) ahora: ${SQL_COUNT} registros${R}"
    fi
  else
    printf '   %s\n' "${RED}${B}✖ No aparecio en ${MAX_WAIT}s. Revisa el streams mapping y la DLQ.${R}"
    return 1
  fi
}

# ------------------------------------------------------------------ menu
run_option() {
  case "$1" in
    1) opt_ddb ;;
    2) opt_sql ;;
    3) opt_compare ;;
    4) opt_create ;;
    5) opt_verify ;;
    *) fail "Opcion no valida: $1"; return 1 ;;
  esac
}

show_menu() {
  banner
  printf '   %s\n' "${B}1)${R} Contar registros en DynamoDB (AWS)"
  printf '   %s\n' "${B}2)${R} Contar registros en SQL Server (GCP)"
  printf '   %s\n' "${B}3)${R} Comparar ambos"
  printf '   %s\n' "${B}4)${R} Crear un registro nuevo en DynamoDB"
  printf '   %s\n' "${B}5)${R} Verificar el ultimo registro en SQL Server"
  printf '   %s\n' "${B}0)${R} Salir"
  echo
}

main() {
  check_deps || exit 1
  check_credentials || exit 1

  if [ $# -ge 1 ]; then
    INTERACTIVE=0
    run_option "$1"
    exit $?
  fi

  INTERACTIVE=1
  local choice
  while :; do
    show_menu
    read -r -p "   Elige una opcion: " choice
    [ "$choice" = "0" ] && { echo; printf '%s\n' "👋 Hasta luego."; exit 0; }
    banner
    run_option "$choice"
    pause
  done
}

INTERACTIVE=1
main "$@"
