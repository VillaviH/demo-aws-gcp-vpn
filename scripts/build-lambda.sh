#!/bin/bash
#
# build-lambda.sh - arma build/lambda-package con handler.py y pymssql
# (wheel manylinux para Lambda Python 3.12 x86_64; pymssql 2.4.x
# publica la wheel como manylinux_2_28, compatible con AL2023). Requiere red para pip.
# Terraform zipea esa carpeta con archive_file.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$ROOT/build/lambda-package"

command -v python3 >/dev/null 2>&1 || { echo "Error: se requiere python3." >&2; exit 1; }

rm -rf "$PKG"
mkdir -p "$PKG"

if ! python3 -m pip install -r "$ROOT/lambda/requirements.txt" \
  --platform manylinux2014_x86_64 \
  --platform manylinux_2_28_x86_64 \
  --python-version 3.12 \
  --implementation cp \
  --only-binary=:all: \
  --target "$PKG" \
  --quiet; then
  echo "Error: pip no pudo obtener las wheels (manylinux2014/2_28 x86_64, cp312)." >&2
  echo "Revisa la conexion a internet y que la version de pymssql tenga wheel para cp312." >&2
  exit 1
fi

cp "$ROOT/lambda/handler.py" "$PKG/handler.py"
echo "Paquete listo en $PKG"
