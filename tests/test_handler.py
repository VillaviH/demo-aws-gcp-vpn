"""Tests del handler Lambda, sin red: boto3 y pymssql se stubbean en sys.modules."""

import importlib.util
import json
import os
import sys
import types
from decimal import Decimal
from pathlib import Path
from unittest.mock import MagicMock

import pytest

HANDLER_PATH = Path(__file__).resolve().parent.parent / "lambda" / "handler.py"

FULL_ITEM = {
    "merchant_id": "M-0001",
    "business_name": "Comercio Uno",
    "contact_name": "Ana",
    "email": "ana@example.com",
    "phone": "123",
    "city": "Quito",
    "category": "Ropa",
    "status": "ACTIVO",
    "credit_limit": Decimal("1000"),
    "created_at": "2026-01-01T00:00:00+00:00",
}


class FakeContext:
    def __init__(self, remaining):
        self._remaining = list(remaining)

    def get_remaining_time_in_millis(self):
        return self._remaining.pop(0) if len(self._remaining) > 1 else self._remaining[0]


class TypeDeserializerStub:
    """Deserializador minimo: soporta S y N."""

    def deserialize(self, value):
        if "S" in value:
            return value["S"]
        if "N" in value:
            return Decimal(value["N"])
        raise ValueError(f"tipo no soportado: {value}")


@pytest.fixture
def h(monkeypatch):
    """Importa lambda/handler.py con boto3/pymssql stubbeados y entorno fijo."""
    for key, val in {
        "SOURCE_TABLE_NAME": "src",
        "SQLSERVER_SECRET_ARN": "arn:secret",
        "SQLSERVER_TARGET_TABLE": "dbo.merchants",
        "CONTROL_TABLE_NAME": "control",
        "TIME_SAFETY_MARGIN_MS": "15000",
    }.items():
        monkeypatch.setenv(key, val)

    boto3 = types.ModuleType("boto3")
    boto3.resource = MagicMock()
    boto3.client = MagicMock()
    dyn_pkg = types.ModuleType("boto3.dynamodb")
    types_mod = types.ModuleType("boto3.dynamodb.types")
    types_mod.TypeDeserializer = TypeDeserializerStub
    pymssql = types.ModuleType("pymssql")
    pymssql.connect = MagicMock()

    monkeypatch.setitem(sys.modules, "boto3", boto3)
    monkeypatch.setitem(sys.modules, "boto3.dynamodb", dyn_pkg)
    monkeypatch.setitem(sys.modules, "boto3.dynamodb.types", types_mod)
    monkeypatch.setitem(sys.modules, "pymssql", pymssql)

    spec = importlib.util.spec_from_file_location("demo_handler", HANDLER_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    module._sqlserver_creds_cache = {
        "host": "10.10.1.5", "port": 1433, "user": "u", "password": "p", "database": "d",
    }
    module._record_control_result = MagicMock()
    module._record_progress = MagicMock()
    module.pymssql_mock = pymssql.connect
    return module


def stream_record(event_name, merchant_id="M-0001", seq="1", full=True):
    image = {
        "merchant_id": {"S": merchant_id},
        "business_name": {"S": "X"},
        "contact_name": {"S": "X"},
        "email": {"S": "x@example.com"},
        "phone": {"S": "1"},
        "city": {"S": "Quito"},
        "category": {"S": "Ropa"},
        "status": {"S": "ACTIVO"},
        "credit_limit": {"N": "10"},
        "created_at": {"S": "2026-01-01"},
    }
    if not full:
        image.pop("city")
    return {"eventName": event_name, "dynamodb": {"SequenceNumber": seq, "NewImage": image}}


def test_flatten_and_validate_migrado(h):
    flat = h._flatten_item({**FULL_ITEM, "extra": "ignorado"})
    assert list(flat) == h.EXPECTED_FIELDS
    assert flat["credit_limit"] == 1000 and isinstance(flat["credit_limit"], int)
    assert h._validate_item(flat) == ("MIGRADO", [])


def test_validate_parcial(h):
    item = {k: v for k, v in FULL_ITEM.items() if k != "city"}
    estado, faltantes = h._validate_item(h._flatten_item(item))
    assert estado == "PARCIAL" and faltantes == ["city"]


def test_validate_error_sin_merchant_id(h):
    item = {k: v for k, v in FULL_ITEM.items() if k != "merchant_id"}
    estado, _ = h._validate_item(h._flatten_item(item))
    assert estado == "ERROR"


def test_invalid_target_table_rejected(monkeypatch, h):
    monkeypatch.setenv("SQLSERVER_TARGET_TABLE", "dbo.merchants; DROP TABLE x")
    spec = importlib.util.spec_from_file_location("demo_handler_bad", HANDLER_PATH)
    module = importlib.util.module_from_spec(spec)
    with pytest.raises(ValueError):
        spec.loader.exec_module(module)


def test_streams_insert_modify_merge_and_remove_ignored(h):
    h.pymssql_mock.return_value = MagicMock()
    event = {"Records": [
        stream_record("INSERT", seq="1"),
        stream_record("MODIFY", seq="2"),
        stream_record("REMOVE", seq="3"),
    ]}
    result = h.handler(event, None)
    assert result == {"batchItemFailures": []}
    conn = h.pymssql_mock.return_value
    assert conn.cursor.return_value.execute.call_count == 2
    sql = conn.cursor.return_value.execute.call_args[0][0]
    assert "MERGE dbo.merchants" in sql and "%s" in sql


def test_streams_failed_record_isolated(h):
    conn = MagicMock()
    cursor = conn.cursor.return_value
    cursor.execute.side_effect = [None, RuntimeError("boom"), None]
    h.pymssql_mock.return_value = conn
    event = {"Records": [
        stream_record("INSERT", merchant_id="A", seq="1"),
        stream_record("INSERT", merchant_id="B", seq="2"),
        stream_record("INSERT", merchant_id="C", seq="3"),
    ]}
    result = h.handler(event, None)
    assert result == {"batchItemFailures": [{"itemIdentifier": "2"}]}
    assert cursor.execute.call_count == 3
    conn.rollback.assert_called_once()


def make_table(items, last_key=None):
    table = MagicMock()
    table.scan.return_value = {"Items": items, "LastEvaluatedKey": last_key}
    h_dyn = MagicMock()
    h_dyn.Table.return_value = table
    return h_dyn, table


def test_full_scan_dry_run_no_connection(h):
    native = {"merchant_id": "M-0002"}
    h._dynamodb, table = make_table([FULL_ITEM, {**FULL_ITEM, "merchant_id": "M-0002"}], native)
    body = json.loads(h.handler({"full_scan": True, "dry_run": True}, None)["body"])
    h.pymssql_mock.assert_not_called()
    assert body["last_evaluated_key"] == native
    assert body["resumen"]["migrados"] == 2 and body["dry_run"] is True
    table.scan.assert_called_once_with(Limit=h.DEFAULT_SCAN_PAGE_SIZE)


def test_full_scan_passes_start_key(h):
    h._dynamodb, table = make_table([], None)
    h.handler({"full_scan": True, "dry_run": True, "start_key": {"merchant_id": "M-0009"}, "page_size": 5}, None)
    table.scan.assert_called_once_with(Limit=5, ExclusiveStartKey={"merchant_id": "M-0009"})


def test_time_cutoff_returns_last_processed_item(h):
    """Regresion: el checkpoint es el ultimo item PROCESADO, no el pendiente."""
    items = [{**FULL_ITEM, "merchant_id": f"M-{i}"} for i in range(1, 5)]
    h._dynamodb, _ = make_table(items, {"merchant_id": "M-4"})
    # El 1er item se procesa sin consultar el tiempo; antes del 2do hay tiempo
    # de sobra; antes del 3ro ya esta por debajo del margen.
    ctx = FakeContext([60000, 1000])
    body = json.loads(h.handler({"full_scan": True, "dry_run": True}, ctx)["body"])
    assert body["cortado_por_tiempo"] is True
    assert body["procesados"] == 2
    assert body["last_evaluated_key"] == {"merchant_id": "M-2"}


def test_time_cutoff_always_processes_one_item(h):
    items = [{**FULL_ITEM, "merchant_id": f"M-{i}"} for i in range(1, 3)]
    h._dynamodb, _ = make_table(items, None)
    body = json.loads(h.handler({"full_scan": True, "dry_run": True}, FakeContext([100]))["body"])
    assert body["procesados"] == 1
    assert body["last_evaluated_key"] == {"merchant_id": "M-1"}


def test_action_ping(h):
    conn = MagicMock()
    conn.cursor.return_value.fetchone.return_value = ("SRV", "Microsoft SQL Server 2022")
    h.pymssql_mock.return_value = conn
    body = json.loads(h.handler({"action": "ping"}, None)["body"])
    assert body == {"servername": "SRV", "version": "Microsoft SQL Server 2022"}
    conn.close.assert_called_once()


def test_action_count_with_row(h):
    conn = MagicMock()
    cursor = conn.cursor.return_value
    row = tuple(FULL_ITEM[f] for f in h.EXPECTED_FIELDS)
    cursor.fetchone.side_effect = [(150,), row]
    h.pymssql_mock.return_value = conn
    body = json.loads(h.handler({"action": "count", "merchant_id": "M-0001"}, None)["body"])
    assert body["count"] == 150
    assert body["row"]["merchant_id"] == "M-0001"
    assert cursor.execute.call_args[0][1] == ("M-0001",)


def test_action_count_without_row(h):
    conn = MagicMock()
    conn.cursor.return_value.fetchone.return_value = (7,)
    h.pymssql_mock.return_value = conn
    body = json.loads(h.handler({"action": "count"}, None)["body"])
    assert body == {"count": 7}
