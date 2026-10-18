#!/usr/bin/env bash
# Runs one remote-control smoke script against a fresh editor_demo:
#   tools/run_smoke.sh <script.edctl> <fixture> [extra demo flags...]
# `$SHOTS` in the script is replaced with the screenshot directory
# ($VISUAL_DIR/<script name>, default test_output/visual/<script name>).
# The fixture is copied to a scratch main.odin (repo files are never
# edited), the demo is launched with the control hook in --control-only
# mode (real keyboard/mouse ignored, window never takes focus), the script
# is replayed with edctl, and the app is quit. Exit 0 = every check passed.
# Needs `task build build:edctl` (and `task ols:build` for LSP scripts).
set -euo pipefail
cd "$(dirname "$0")/.."

SCRIPT="$1"
FIXTURE="$2"
shift 2
PORT="${PORT:-7799}"
NAME="$(basename "$SCRIPT" .edctl)"

# A dot in the directory name on purpose: regression cover for paths OLS
# once appeared to choke on (the real culprit was the /tmp symlink).
WORK="$(mktemp -d "/tmp/odin_editor_${NAME}.XXXXXX")"
if [ -d "$FIXTURE" ]; then
	# Multi-file fixture: every NAME.odin.txt becomes NAME.odin; main.odin opens.
	for f in "$FIXTURE"/*.odin.txt; do
		cp "$f" "$WORK/$(basename "$f" .txt)"
	done
else
	cp "$FIXTURE" "$WORK/main.odin"
fi

SHOTS="$PWD/${VISUAL_DIR:-test_output/visual}/$NAME"
rm -rf "$SHOTS"
mkdir -p "$SHOTS"

# Settings go to a scratch config dir, and keymap imports read fixtures —
# never the user's real config or Zed/VSCode keymaps.
./example/editor_demo --control "$PORT" --control-only \
	--config-dir "$WORK/config" \
	--zed-keymap example/assets/keymaps/zed_keymap.json \
	--vscode-keymap example/assets/keymaps/vscode_keybindings.json \
	"$@" "$WORK/main.odin" >"$WORK/demo.log" 2>&1 &
APP=$!
trap 'kill "$APP" 2>/dev/null || true' EXIT

status=0
sed "s|\$SHOTS|$SHOTS|g" "$SCRIPT" | ./tools/edctl/edctl --port "$PORT" --retry 15 -q || status=$?
./tools/edctl/edctl --port "$PORT" -q quit >/dev/null 2>&1 || true
wait "$APP" 2>/dev/null || true

if [ "$status" -eq 0 ]; then
	echo "$NAME: PASS"
else
	echo "$NAME: FAIL (app log: $WORK/demo.log)" >&2
fi
exit "$status"
