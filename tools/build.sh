#!/usr/bin/env bash
# Build the ROOMNAPPED place file. Usage: tools/build.sh [output.rbxl]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$ROOT"
OUT="${1:-build/ROOMNAPPED.rbxl}"
mkdir -p "$(dirname "$OUT")"
rojo build default.project.json -o "$OUT"
echo "Built $OUT"
