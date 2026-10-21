#!/usr/bin/env bash
# Export + render GUI scenarios in parallel (4 at a time).
#
#   tools/preview/render_all.sh scenario...      e.g. lobby explore phone:explore menu:Settings
#
# phone:<scenario> runs the scenario on a touch phone and renders its 750x311 safe area with Roblox's touch
# controls drawn in; any HUD element covering the thumbstick zone or the jump button is reported as a
# "touch overlap" warning. Everything else renders at 1920x1080. Output: tools/preview/out/gui_<scenario>.png
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source tools/env.sh
OUT=tools/preview/out
PLACE="${PLACE:-build/test.rbxl}"
mkdir -p $OUT
run_one() {
	s="$1"
	f=$(echo "$s" | tr ':' '_')
	lune run tools/preview/export_gui.luau "$PLACE" "$s" $OUT/gui_$f.json >$OUT/log_$f.txt 2>&1
	if [[ "$s" == phone:* ]]; then
		python3 tools/preview/render_gui.py $OUT/gui_$f.json $OUT/gui_$f.png --size 750x311 --inset 0 --touch >>$OUT/log_$f.txt 2>&1
	else
		python3 tools/preview/render_gui.py $OUT/gui_$f.json $OUT/gui_$f.png --size 1920x1080 >>$OUT/log_$f.txt 2>&1
	fi
	echo "done $s: $(grep -c WARNING $OUT/log_$f.txt) warnings; $(grep -h 'touch zones' $OUT/log_$f.txt) $(tail -1 $OUT/log_$f.txt)"
}
export -f run_one
export OUT PLACE
printf '%s\n' "$@" | xargs -P 4 -I{} bash -c 'run_one "$@"' _ {}
