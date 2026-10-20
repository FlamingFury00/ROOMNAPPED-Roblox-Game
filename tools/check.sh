#!/usr/bin/env bash
# Full verification: formatting, type analysis, place build and headless tests.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$ROOT"
echo "== StyLua"
stylua --check src tests tools
echo "== Sourcemap"
rojo sourcemap default.project.json -o sourcemap.json
echo "== luau-lsp analyze"
luau-lsp analyze \
	--definitions=@roblox="$DEFS_DIR/globalTypes.d.luau" \
	--sourcemap=sourcemap.json \
	--base-luaurc=.luaurc \
	--settings=tools/luau-lsp-settings.json \
	--no-flags-enabled \
	src
echo "== Build"
tools/build.sh build/test.rbxl >/dev/null
echo "== Tests"
lune run tests/run.luau build/test.rbxl "$@"
