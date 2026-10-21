#!/usr/bin/env bash
# Download the pinned toolchain (same versions as rokit.toml) into $1/bin (default: $HOME/rbxtools).
# Used by CI; locally `rokit install` does the same job.
set -euo pipefail
DEST="${1:-$HOME/rbxtools}"
mkdir -p "$DEST" && cd "$DEST"
dl() { curl -sSfL --retry 4 -o "$2" "$1"; unzip -o -q "$2" -d "${2%.zip}"; }
dl https://github.com/rojo-rbx/rojo/releases/download/v7.7.1/rojo-7.7.1-linux-x86_64.zip rojo.zip
dl https://github.com/lune-org/lune/releases/download/v0.11.0/lune-0.11.0-linux-x86_64.zip lune.zip
dl https://github.com/Kampfkarren/selene/releases/download/0.32.0/selene-0.32.0-linux.zip selene.zip
dl https://github.com/JohnnyMorganz/StyLua/releases/download/v2.6.0/stylua-linux-x86_64.zip stylua.zip
dl https://github.com/JohnnyMorganz/luau-lsp/releases/download/1.70.1/luau-lsp-linux-x86_64.zip luau-lsp.zip
mkdir -p bin
for b in rojo lune selene stylua luau-lsp; do
	find "./$b" -type f -name "$b" -exec cp {} bin/ \;
	chmod +x "bin/$b"
done
echo "$DEST/bin"
