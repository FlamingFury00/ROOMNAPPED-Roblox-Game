#!/usr/bin/env bash
# Publish a place file to Roblox through Open Cloud (Place Publishing API).
#
#   ROBLOX_PLACE_ID=<place id> tools/publish.sh [place.rbxl] [Published|Saved]
#
# Defaults: release/ROOMNAPPED.rbxl, Published (live for players; Saved stores a version without publishing).
# The Open Cloud API key (permission: universe-places write on the experience) comes from ROBLOX_API_KEY, or
# from a network secret that adds the x-api-key header for apis.roblox.com. The universe id is looked up from
# the place id unless ROBLOX_UNIVERSE_ID is set. The key is never printed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FILE="${1:-release/ROOMNAPPED.rbxl}"
VERSION_TYPE="${2:-Published}"
PLACE="${ROBLOX_PLACE_ID:?set ROBLOX_PLACE_ID to the id of the place to publish to}"

if [[ ! "$PLACE" =~ ^[0-9]+$ ]]; then
	echo "ROBLOX_PLACE_ID must be a number" >&2
	exit 1
fi
if [[ ! -f "$FILE" ]]; then
	echo "no place file at $FILE" >&2
	exit 1
fi
if [[ "$VERSION_TYPE" != "Published" && "$VERSION_TYPE" != "Saved" ]]; then
	echo "version type must be Published or Saved" >&2
	exit 1
fi

UNIVERSE="${ROBLOX_UNIVERSE_ID:-}"
if [[ -z "$UNIVERSE" ]]; then
	UNIVERSE="$(curl -sS --fail --max-time 30 "https://apis.roblox.com/universes/v1/places/${PLACE}/universe" |
		python3 -I -c 'import json, sys; print(json.load(sys.stdin)["universeId"])')"
fi

ARGS=(-sS --max-time 300 -X POST -H "Content-Type: application/octet-stream" --data-binary "@${FILE}")
if [[ -n "${ROBLOX_API_KEY:-}" ]]; then
	ARGS+=(-H "x-api-key: ${ROBLOX_API_KEY}")
else
	echo "ROBLOX_API_KEY is not set: relying on a network secret for apis.roblox.com" >&2
fi

echo "Publishing $FILE ($(wc -c <"$FILE") bytes) to place $PLACE (universe $UNIVERSE) as $VERSION_TYPE"
BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT
CODE="$(curl "${ARGS[@]}" -o "$BODY" -w "%{http_code}" \
	"https://apis.roblox.com/universes/v1/${UNIVERSE}/places/${PLACE}/versions?versionType=${VERSION_TYPE}")"
cat "$BODY"
echo
if [[ "$CODE" != "200" ]]; then
	echo "Publish failed: HTTP $CODE" >&2
	exit 1
fi
echo "Done: the response above holds the new version number."
