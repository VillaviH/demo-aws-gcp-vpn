"""Replica comercios ficticios de DynamoDB hacia SQL Server (simulado en GCP).

La configuracion llega por variables de entorno y Secrets Manager. La tabla
origen es de solo lectura y cada resultado se registra en la tabla de control.

Modos de uso (se eligen con el "event" de cada invocacion):

  Full load por Scan paginado:
    {"full_scan": true}                          -> primera pagina
    {"full_scan": true, "dry_run": true}         -> solo valida, no abre conexion
    {"full_scan": true, "start_key": {...}}      -> continua desde el checkpoint
                                                    (usar "last_evaluated_key" de la
                                                    invocacion anterior)
    {"full_scan": true, "page_size": 25}         -> tamano de pagina pedido

  Streams (Event Source Mapping de DynamoDB Streams, NEW_IMAGE):
    {"Records": [...]}   -> INSERT/MODIFY hacen MERGE, REMOVE se ignora.
                            Los fallos por record se devuelven en batchItemFailures.

  Acciones de demo (verificacion en vivo, sin abrir puertos adicionales):
    {"action": "ping"}                           -> @@SERVERNAME y @@VERSION de SQL Server
    {"action": "count"}                          -> COUNT(*) de la tabla destino
    {"action": "count", "merchant_id": "M-001"}  -> ademas devuelve esa fila

Corte por tiempo: antes de procesar cada item se revisa el tiempo restante. Si
queda menos de TIME_SAFETY_MARGIN_MS se detiene y se devuelve como
"last_evaluated_key" la clave del ULTIMO item procesado (ExclusiveStartKey es
exclusivo: devolver la clave del item pendiente lo saltaria). Siempre se
procesa al menos un item por invocacion para garantizar progreso.
"""

import json
import logging
import os
import re
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any

import boto3
import pymssql
from boto3.dynamodb.types import TypeDeserializer

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

# ---------------------------------------------------------------------------
# Configuracion via variables de entorno
# ---------------------------------------------------------------------------
SOURCE_TABLE_NAME = os.environ["SOURCE_TABLE_NAME"]
SQLSERVER_SECRET_ARN = os.environ["SQLSERVER_SECRET_ARN"]
SQLSERVER_TARGET_TABLE = os.environ["SQLSERVER_TARGET_TABLE"]
CONTROL_TABLE_NAME = os.environ.get("CONTROL_TABLE_NAME", "")
APP_ENV = os.environ.get("APP_ENV", "unknown")
DEFAULT_SCAN_PAGE_SIZE = int(os.environ.get("SCAN_PAGE_SIZE", "25"))
TIME_SAFETY_MARGIN_MS = int(os.environ.get("TIME_SAFETY_MARGIN_MS", "15000"))

PROGRESS_KEY = "__FULL_LOAD_PROGRESS__"
PARTITION_KEY = "merchant_id"

EXPECTED_FIELDS = [
    "merchant_id", "business_name", "contact_name", "email", "phone",
    "city", "category", "status", "credit_limit", "created_at",
]

_dynamodb = boto3.resource("dynamodb")
_secrets_client = boto3.client("secretsmanager")

_sqlserver_creds_cache: dict[str, Any] | None = None

if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*", SQLSERVER_TARGET_TABLE):
    raise ValueError("SQLSERVER_TARGET_TABLE debe tener el formato esquema.tabla")


def _get_sqlserver_credentials() -> dict[str, Any]:
    """Obtiene host/usuario/password/db de Secrets Manager (cache en memoria del contenedor)."""
    global _sqlserver_creds_cache
    if _sqlserver_creds_cache is not None:
        return _sqlserver_creds_cache

    response = _secrets_client.get_secret_value(SecretId=SQLSERVER_SECRET_ARN)
    secret = json.loads(response["SecretString"])

    required_keys = {"host", "port", "user", "password", "database"}
    missing = required_keys - secret.keys()
    if missing:
        raise ValueError(f"Faltan claves en el secreto de SQL Server: {missing}")

    _sqlserver_creds_cache = secret
    return secret


def _connect() -> Any:
    """Abre una conexion pymssql con las credenciales del secreto."""
    creds = _get_sqlserver_credentials()
    return pymssql.connect(
        server=creds["host"],
        port=str(creds.get("port", 1433)),
        user=creds["user"],
        password=creds["password"],
        database=creds["database"],
        timeout=30,
        login_timeout=30,
    )


def _decimal_to_native(value: Any) -> Any:
    """DynamoDB devuelve numeros como Decimal; se convierten a int/float."""
    if isinstance(value, Decimal):
        return int(value) if value % 1 == 0 else float(value)
    return value


def _flatten_item(item: dict[str, Any]) -> dict[str, Any]:
    """Deja solo los campos esperados, tolerando faltantes (None)."""
    return {field: _decimal_to_native(item.get(field)) for field in EXPECTED_FIELDS}


def _validate_item(flat: dict[str, Any]) -> tuple[str, list[str]]:
    """
    Estado de migracion de un registro:
      - MIGRADO: tiene merchant_id y todos los campos.
      - PARCIAL: tiene merchant_id pero falta algun otro campo.
      - ERROR: sin merchant_id.
    Devuelve (estado, campos_faltantes).
    """
    if not flat.get(PARTITION_KEY):
        return "ERROR", ["merchant_id (clave primaria ausente)"]

    faltantes = [f for f in EXPECTED_FIELDS if flat.get(f) in (None, "")]
    if faltantes:
        return "PARCIAL", faltantes
    return "MIGRADO", []


def _read_items_by_scan(
    start_key: dict[str, Any] | None, page_size: int
) -> tuple[list[dict[str, Any]], dict[str, Any] | None]:
    """Lee una pagina de la tabla via Scan. Devuelve (items, LastEvaluatedKey nativa)."""
    table = _dynamodb.Table(SOURCE_TABLE_NAME)
    scan_kwargs: dict[str, Any] = {"Limit": page_size}
    if start_key:
        scan_kwargs["ExclusiveStartKey"] = start_key

    response = table.scan(**scan_kwargs)
    return response.get("Items", []), response.get("LastEvaluatedKey")


def _remaining_ms(context: Any) -> int:
    """Milisegundos restantes antes del timeout. Sin contexto real, nunca corta."""
    getter = getattr(context, "get_remaining_time_in_millis", None)
    if getter is None:
        return TIME_SAFETY_MARGIN_MS + 1
    return getter()


def _upsert_sqlserver(conn: Any, flat: dict[str, Any]) -> None:
    """MERGE idempotente de un registro en la tabla destino."""
    columns = list(EXPECTED_FIELDS)
    values = [flat[f] for f in columns]

    set_clause = ", ".join(f"target.{c} = source.{c}" for c in columns if c != PARTITION_KEY)
    insert_columns = ", ".join(columns)
    insert_values = ", ".join(f"source.{c}" for c in columns)
    placeholders = ", ".join("%s" for _ in columns)

    merge_sql = f"""
        MERGE {SQLSERVER_TARGET_TABLE} AS target
        USING (SELECT {placeholders}) AS source ({insert_columns})
        ON target.{PARTITION_KEY} = source.{PARTITION_KEY}
        WHEN MATCHED THEN
            UPDATE SET {set_clause}
        WHEN NOT MATCHED THEN
            INSERT ({insert_columns}) VALUES ({insert_values});
    """

    logger.info("MERGE hacia %s | merchant_id=%s", SQLSERVER_TARGET_TABLE, flat.get(PARTITION_KEY))

    cursor = conn.cursor()
    try:
        cursor.execute(merge_sql, tuple(values))
        conn.commit()
    finally:
        cursor.close()


def _record_control_result(merchant_id: str, estado: str, detalle: str) -> None:
    """Registra el resultado por registro en la tabla de control (si esta configurada)."""
    if not CONTROL_TABLE_NAME:
        return

    _dynamodb.Table(CONTROL_TABLE_NAME).put_item(
        Item={
            "merchant_id": merchant_id,
            "estado": estado,
            "detalle": detalle,
            "ejecutado_en": datetime.now(timezone.utc).isoformat(),
            "ambiente": APP_ENV,
            "origen": SOURCE_TABLE_NAME,
        }
    )


def _record_progress(
    pagina_completa: bool,
    procesados: int,
    resumen: dict[str, int],
    last_evaluated_key: dict[str, Any] | None,
) -> None:
    """Guarda el progreso de esta invocacion bajo la clave fija __FULL_LOAD_PROGRESS__."""
    if not CONTROL_TABLE_NAME:
        return

    _dynamodb.Table(CONTROL_TABLE_NAME).put_item(
        Item={
            "merchant_id": PROGRESS_KEY,
            "estado": "PAGINA_COMPLETA" if pagina_completa else "PAGINA_CORTADA_POR_TIEMPO",
            "detalle": json.dumps({
                "procesados_esta_invocacion": procesados,
                "resumen_esta_invocacion": resumen,
                "last_evaluated_key": last_evaluated_key,
            }),
            "ejecutado_en": datetime.now(timezone.utc).isoformat(),
            "ambiente": APP_ENV,
            "origen": SOURCE_TABLE_NAME,
        }
    )


def _deserialize_image(image: dict[str, Any], deserializer: TypeDeserializer) -> dict[str, Any]:
    """Convierte un NewImage de Streams ({"S": "..."}, ...) a dict Python nativo."""
    return {key: deserializer.deserialize(value) for key, value in image.items()}


def _action_ping() -> dict[str, Any]:
    """Abre una conexion y devuelve @@SERVERNAME y @@VERSION."""
    conn = _connect()
    try:
        cursor = conn.cursor()
        try:
            cursor.execute("SELECT @@SERVERNAME, @@VERSION")
            row = cursor.fetchone()
        finally:
            cursor.close()
    finally:
        conn.close()
    return {
        "statusCode": 200,
        "body": json.dumps({"servername": row[0], "version": row[1]}),
    }


def _action_count(merchant_id: str | None) -> dict[str, Any]:
    """COUNT(*) de la tabla destino y, opcionalmente, la fila de un merchant_id."""
    conn = _connect()
    try:
        cursor = conn.cursor()
        try:
            cursor.execute(f"SELECT COUNT(*) FROM {SQLSERVER_TARGET_TABLE}")
            total = int(cursor.fetchone()[0])
            body: dict[str, Any] = {"count": total}
            if merchant_id:
                columns = ", ".join(EXPECTED_FIELDS)
                cursor.execute(
                    f"SELECT {columns} FROM {SQLSERVER_TARGET_TABLE} WHERE {PARTITION_KEY} = %s",
                    (merchant_id,),
                )
                row = cursor.fetchone()
                body["row"] = (
                    {f: _decimal_to_native(v) for f, v in zip(EXPECTED_FIELDS, row)} if row else None
                )
        finally:
            cursor.close()
    finally:
        conn.close()
    return {"statusCode": 200, "body": json.dumps(body, default=str)}


def handler_streams(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """
    Procesa un batch de DynamoDB Streams. INSERT/MODIFY hacen MERGE; REMOVE se
    ignora. Cada record va en su propio try/except y los que fallan se reportan
    en batchItemFailures (ReportBatchItemFailures) sin tumbar el resto.
    """
    records = event.get("Records", [])
    logger.info("Streams: %d record(s) recibidos", len(records))

    deserializer = TypeDeserializer()
    resumen = {"migrados": 0, "parciales": 0, "errores": 0, "ignorados_remove": 0}
    batch_item_failures: list[dict[str, str]] = []
    conn: Any = None

    try:
        for record in records:
            event_name = record.get("eventName")
            sequence_number = record.get("dynamodb", {}).get("SequenceNumber")

            if event_name == "REMOVE":
                resumen["ignorados_remove"] += 1
                logger.info("Streams: REMOVE ignorado (SequenceNumber=%s)", sequence_number)
                continue

            if event_name not in ("INSERT", "MODIFY"):
                logger.warning("Streams: eventName desconocido '%s', se omite", event_name)
                continue

            flat: dict[str, Any] | None = None
            try:
                item = _deserialize_image(record["dynamodb"]["NewImage"], deserializer)
                flat = _flatten_item(item)
                estado, faltantes = _validate_item(flat)
                merchant_id = flat.get(PARTITION_KEY) or "DESCONOCIDO"

                if estado == "ERROR":
                    resumen["errores"] += 1
                    _record_control_result(merchant_id, estado, f"Campos invalidos: {faltantes}")
                    logger.error("Streams: registro invalido, no se migra: %s", faltantes)
                    continue

                if conn is None:
                    conn = _connect()

                _upsert_sqlserver(conn, flat)

                if estado == "PARCIAL":
                    resumen["parciales"] += 1
                    _record_control_result(merchant_id, estado, f"Campos faltantes: {faltantes}")
                else:
                    resumen["migrados"] += 1
                    _record_control_result(merchant_id, estado, "OK (via streams)")

            except Exception as exc:  # noqa: BLE001 - aislamiento por record
                if conn is not None:
                    try:
                        conn.rollback()
                    except Exception:  # noqa: BLE001
                        logger.warning("Streams: rollback fallo")
                resumen["errores"] += 1
                logger.exception(
                    "Streams: fallo al procesar record (eventName=%s, SequenceNumber=%s): %s",
                    event_name, sequence_number, exc,
                )
                if sequence_number:
                    batch_item_failures.append({"itemIdentifier": sequence_number})
    finally:
        if conn is not None:
            conn.close()

    logger.info("Streams: batch finalizado. Resumen: %s | fallos: %d", resumen, len(batch_item_failures))
    return {"batchItemFailures": batch_item_failures}


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """
    Punto de entrada. Despacha segun el evento:
      Records            -> handler_streams
      action ping/count  -> acciones de demo
      full_scan          -> full load paginado (dry_run, start_key, page_size)
    """
    event = event or {}
    if "Records" in event:
        return handler_streams(event, context)

    action = event.get("action")
    if action == "ping":
        return _action_ping()
    if action == "count":
        return _action_count(event.get("merchant_id"))
    if action:
        return {"statusCode": 400, "body": json.dumps({"error": f"action desconocida: {action}"})}

    dry_run = bool(event.get("dry_run", False))
    start_key = event.get("start_key")
    page_size = int(event.get("page_size", DEFAULT_SCAN_PAGE_SIZE))

    logger.info(
        "Full load. Tabla origen: %s | dry_run: %s | page_size: %s",
        SOURCE_TABLE_NAME, dry_run, page_size,
    )

    items, last_evaluated_key = _read_items_by_scan(start_key, page_size)
    resumen = {"migrados": 0, "parciales": 0, "errores": 0}

    if not items:
        return {
            "statusCode": 200,
            "body": json.dumps({
                "total_leidos": 0,
                "procesados": 0,
                "resumen": resumen,
                "dry_run": dry_run,
                "cortado_por_tiempo": False,
                "last_evaluated_key": last_evaluated_key,
            }),
        }

    conn = None
    if not dry_run:
        conn = _connect()

    procesados = 0
    cortado_por_tiempo = False
    ultimo_key: dict[str, Any] | None = start_key

    try:
        for item in items:
            # Guardia de tiempo ANTES de cada item, pero siempre se procesa al
            # menos uno para garantizar progreso. El checkpoint es la clave del
            # ultimo item procesado (ExclusiveStartKey es exclusivo).
            if procesados > 0 and _remaining_ms(context) < TIME_SAFETY_MARGIN_MS:
                last_evaluated_key = ultimo_key
                cortado_por_tiempo = True
                logger.warning(
                    "Cortando por margen de tiempo (%sms restantes). Checkpoint: %s. Procesados: %d/%d",
                    _remaining_ms(context), last_evaluated_key, procesados, len(items),
                )
                break

            flat = _flatten_item(item)
            estado, faltantes = _validate_item(flat)
            merchant_id = flat.get(PARTITION_KEY) or "DESCONOCIDO"
            if flat.get(PARTITION_KEY):
                ultimo_key = {PARTITION_KEY: flat[PARTITION_KEY]}

            if estado == "ERROR":
                resumen["errores"] += 1
                _record_control_result(merchant_id, estado, f"Campos invalidos: {faltantes}")
                procesados += 1
                continue

            if dry_run:
                if estado == "PARCIAL":
                    resumen["parciales"] += 1
                    _record_control_result(merchant_id, "PARCIAL_DRYRUN", f"Campos faltantes: {faltantes}")
                else:
                    resumen["migrados"] += 1
                    _record_control_result(merchant_id, "MIGRADO_DRYRUN", "OK (dry-run, no se escribio)")
                procesados += 1
                continue

            try:
                _upsert_sqlserver(conn, flat)
            except Exception as exc:  # noqa: BLE001
                conn.rollback()
                resumen["errores"] += 1
                _record_control_result(merchant_id, "ERROR", f"Fallo al escribir en SQL Server: {exc}")
                logger.exception("Fallo al escribir merchant_id %s en SQL Server", merchant_id)
                procesados += 1
                continue

            if estado == "PARCIAL":
                resumen["parciales"] += 1
                _record_control_result(merchant_id, estado, f"Campos faltantes: {faltantes}")
            else:
                resumen["migrados"] += 1
                _record_control_result(merchant_id, estado, "OK")
            procesados += 1
    finally:
        if conn is not None:
            conn.close()

    _record_progress(
        pagina_completa=not cortado_por_tiempo,
        procesados=procesados,
        resumen=resumen,
        last_evaluated_key=last_evaluated_key,
    )

    logger.info(
        "Full load: procesados %d/%d | %s | cortado_por_tiempo: %s | last_evaluated_key: %s",
        procesados, len(items), resumen, cortado_por_tiempo, last_evaluated_key,
    )
    return {
        "statusCode": 200,
        "body": json.dumps({
            "total_leidos": len(items),
            "procesados": procesados,
            "resumen": resumen,
            "dry_run": dry_run,
            "cortado_por_tiempo": cortado_por_tiempo,
            "last_evaluated_key": last_evaluated_key,
        }),
    }
