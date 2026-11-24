#!/usr/bin/env python3
"""Carga comercios ficticios (Faker, seed fija) en la tabla DynamoDB del demo.

Usa solo las credenciales del entorno o del perfil del usuario (boto3 las
resuelve); nunca se leen ni se guardan en el repositorio.

Ejemplo:
    python scripts/seed_dynamodb.py --count 150 --region us-east-1
"""

import argparse
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import boto3
from faker import Faker

CATEGORIES = ["Restaurante", "Farmacia", "Supermercado", "Ropa", "Tecnologia", "Ferreteria", "Libreria"]
STATUSES = ["ACTIVO", "ACTIVO", "ACTIVO", "SUSPENDIDO", "PENDIENTE"]


def count_arg(value: str) -> int:
    number = int(value)
    if not 100 <= number <= 200:
        raise argparse.ArgumentTypeError("--count debe estar entre 100 y 200")
    return number


def build_items(count: int, seed: int) -> list[dict]:
    fake = Faker("es_ES")
    Faker.seed(seed)
    fake.seed_instance(seed)
    base = datetime(2026, 1, 1, tzinfo=timezone.utc)

    items = []
    for i in range(1, count + 1):
        created = base + timedelta(minutes=fake.random_int(0, 60 * 24 * 300))
        items.append({
            "merchant_id": f"M-{i:04d}",
            "business_name": fake.company(),
            "contact_name": fake.name(),
            "email": fake.company_email(),
            "phone": fake.phone_number(),
            "city": fake.city(),
            "category": fake.random_element(CATEGORIES),
            "status": fake.random_element(STATUSES),
            "credit_limit": Decimal(fake.random_int(500, 50000)),
            "created_at": created.isoformat(),
        })
    return items


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--table", default="demo-merchants-table")
    parser.add_argument("--count", type=count_arg, default=150)
    parser.add_argument("--region", default=None)
    parser.add_argument("--seed", type=int, default=2026)
    args = parser.parse_args()

    table = boto3.resource("dynamodb", region_name=args.region).Table(args.table)
    items = build_items(args.count, args.seed)

    with table.batch_writer() as batch:
        for item in items:
            batch.put_item(Item=item)

    print(f"Se escribieron {len(items)} comercios en {args.table}")


if __name__ == "__main__":
    main()
