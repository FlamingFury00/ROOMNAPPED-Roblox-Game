#!/usr/bin/env bash
# Shared tool lookup: prefer rokit-installed tools on PATH, fall back to the container toolchain.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$PATH:/opt/rbxtools/bin:$HOME/.rokit/bin"
DEFS_DIR="${DEFS_DIR:-$ROOT/build/defs}"
mkdir -p "$DEFS_DIR"
if [ ! -f "$DEFS_DIR/globalTypes.d.luau" ]; then
	if [ -f /opt/rbxtools/defs/globalTypes.d.luau ]; then
		cp /opt/rbxtools/defs/globalTypes.d.luau "$DEFS_DIR/globalTypes.d.luau"
	else
		curl -sSfL -o "$DEFS_DIR/globalTypes.d.luau" \
			https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau
	fi
fi
