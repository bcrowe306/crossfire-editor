#!/usr/bin/env bash
# Runs UI test scripts (tests/ui/*.script) with the editor, several at once, and reports each
# script's result and time. The Taskfile's test:ui tasks call it (run from the editor's folder).
#
# Usage: tools/ui_tests.sh [options] <editor executable> [scripts...]   (no scripts: all of them)
#   --jobs N        scripts at once (default: half the CPUs, at least 1; JOBS= in the Taskfile)
#   --size WxH      the window's size in logical pixels (--window-size); headless runs only
#   --name NAME     the run's folder: build/ui_tests/NAME (default: ui)
#   --visible       open real windows on the desktop (one script at a time) instead of headless
#
# Headless (the default): each editor runs on SDL's offscreen video driver (Vulkan through
# VK_EXT_headless_surface, on the GPU) and the dummy audio driver, so no window appears, nothing
# resizes or throttles it, and the clipboard is the editor's own. A game started by Play inherits
# both drivers. Each script gets its own folder, build/ui_tests/NAME/<script>/: a fresh copy of
# tests/fixtures/ui_project (ui_project), of tests/ui/settings.ini (settings.ini, beside which
# the editor keeps its recent projects) and its log (log.txt). A passing script's project copy is
# deleted; a failing one's is kept with its log. Play's and Export's build folders are per project
# folder (build/players/<name>-<hash>, ...), so they're per script too, and stay between runs.
#
# Scripts run longest first (the times of the last run, build/ui_tests/NAME/times.txt), so a long
# one doesn't start last. Exits 1 if any script failed.
set -u

jobs=""
size=""
name="ui"
visible=0
while [[ $# -gt 0 ]]; do
	case "$1" in
		--jobs) jobs=$2; shift 2 ;;
		--size) size=$2; shift 2 ;;
		--name) name=$2; shift 2 ;;
		--visible) visible=1; shift ;;
		-*) echo "ui_tests.sh: unknown option $1" >&2; exit 2 ;;
		*) break ;;
	esac
done
editor=${1:?usage: tools/ui_tests.sh [options] <editor executable> [scripts...]}
shift
scripts=("$@")
[[ ${#scripts[@]} -gt 0 ]] || scripts=(tests/ui/*.script)

if [[ -z "$jobs" || "$jobs" == "0" ]]; then
	cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
	jobs=$(( cpus / 2 ))
fi
(( jobs >= 1 )) || jobs=1
# Real windows share the desktop (a tiling window manager shrinks each for the others) and the
# system clipboard: one at a time
(( visible )) && jobs=1
(( jobs > ${#scripts[@]} )) && jobs=${#scripts[@]}

root="build/ui_tests/$name"
mkdir -p "$root"
root=$(cd "$root" && pwd)

# One run per folder at a time: a second one would delete the first's projects
lock="$root/.lock"
if [[ -f "$lock" ]] && kill -0 "$(cat "$lock")" 2>/dev/null; then
	echo "ui_tests.sh: another run (process $(cat "$lock")) is using $root; give this one another --name" >&2
	exit 2
fi
echo $$ > "$lock"
trap 'rm -f "$lock"' EXIT

# Milliseconds since some point (bash 5's EPOCHREALTIME; whole seconds with an older bash)
now_ms() {
	if [[ -n "${EPOCHREALTIME:-}" ]]; then
		local t=${EPOCHREALTIME/[.,]/}
		echo $(( t / 1000 ))
	else
		echo $(( $(date +%s) * 1000 ))
	fi
}

# Longest first, by the last run's times; scripts without one (new) first of all
times_file="$root/times.txt"
ordered=()
if [[ -f "$times_file" ]]; then
	while IFS= read -r script; do ordered+=("$script"); done < <(
		for script in "${scripts[@]}"; do
			ms=$(awk -v s="$script" '$2 == s { print $1 }' "$times_file")
			echo "${ms:-999999999} $script"
		done | sort -rn | cut -d' ' -f2-)
else
	ordered=("${scripts[@]}")
fi

# The editor kills a script after 300 s (SCRIPT_TIMEOUT); this catches a hang the driver can't
timeout_cmd=""
if command -v timeout > /dev/null; then timeout_cmd="timeout 420"
elif command -v gtimeout > /dev/null; then timeout_cmd="gtimeout 420"; fi

editor_abs=$(cd "$(dirname "$editor")" && pwd)/$(basename "$editor")
if [[ ! -x "$editor_abs" ]]; then
	echo "ui_tests.sh: no editor at $editor" >&2
	exit 2
fi

# Runs one script in its own folder; prints a line with its result as soon as it ends
run_one() {
	local script=$1
	local base
	base=$(basename "$script" .script)
	local dir="$root/$base"
	rm -rf "$dir"
	mkdir -p "$dir"
	cp -R tests/fixtures/ui_project "$dir/ui_project"
	cp tests/ui/settings.ini "$dir/settings.ini"
	local args=("$dir/ui_project" --script "$script" --settings "$dir/settings.ini")
	[[ -n "$size" && "$visible" == 0 ]] && args+=(--window-size "$size")
	local start end rc
	start=$(now_ms)
	if [[ "$visible" == 1 ]]; then
		$timeout_cmd "$editor_abs" "${args[@]}" > "$dir/log.txt" 2>&1
	else
		SDL_VIDEO_DRIVER=offscreen SDL_AUDIO_DRIVER=dummy $timeout_cmd "$editor_abs" "${args[@]}" > "$dir/log.txt" 2>&1
	fi
	rc=$?
	end=$(now_ms)
	local ms=$(( end - start ))
	echo "$rc $ms $script" > "$dir/result"
	local seconds
	seconds=$(awk -v ms="$ms" 'BEGIN { printf "%6.1f", ms / 1000 }')
	if [[ $rc == 0 ]]; then
		# The log stays; the project copy (and what the script made beside it) goes
		find "$dir" -mindepth 1 -maxdepth 1 ! -name log.txt ! -name result -exec rm -rf {} +
		echo "  ok    ${seconds} s  $base"
	else
		echo "  FAIL  ${seconds} s  $base  (exit $rc: $dir/log.txt)"
	fi
}
export -f run_one now_ms
export root size visible timeout_cmd editor_abs

mode="headless, ${size:-default size}"
(( visible )) && mode="visible windows"
echo "UI tests: ${#ordered[@]} script(s), $jobs at a time ($mode), in $root"
run_start=$(now_ms)
printf '%s\0' "${ordered[@]}" | xargs -0 -n 1 -P "$jobs" bash -c 'run_one "$1"' _
run_end=$(now_ms)

# Summary: each script's time, slowest first; the failures with their failed lines
failed=()
total=0
: > "$times_file.new"
for script in "${scripts[@]}"; do
	base=$(basename "$script" .script)
	result="$root/$base/result"
	if [[ ! -f "$result" ]]; then
		failed+=("$script")
		continue
	fi
	read -r rc ms _ < "$result"
	total=$(( total + ms ))
	echo "$ms $script" >> "$times_file.new"
	[[ $rc == 0 ]] || failed+=("$script")
done
# Keep the times of scripts this run didn't include (SCRIPT=)
[[ -f "$times_file" ]] && awk 'NR == FNR { seen[$2] = 1; next } !($2 in seen)' "$times_file.new" "$times_file" >> "$times_file.new"
mv "$times_file.new" "$times_file"

echo
echo "Slowest:"
for script in "${scripts[@]}"; do
	base=$(basename "$script" .script)
	[[ -f "$root/$base/result" ]] && awk -v b="$base" '{ printf "%8.1f s  %s\n", $2 / 1000, b }' "$root/$base/result"
done | sort -rn | head -8
wall=$(( run_end - run_start ))
awk -v w="$wall" -v t="$total" -v j="$jobs" -v n="${#scripts[@]}" -v f="${#failed[@]}" 'BEGIN {
	printf "\n%d script(s), %d failed: %.1f s wall, %.1f s of scripts, %d at a time\n", n, f, w / 1000, t / 1000, j }'

if [[ ${#failed[@]} -gt 0 ]]; then
	echo
	echo "Failed:"
	for script in "${failed[@]}"; do
		log="$root/$(basename "$script" .script)/log.txt"
		echo "  $script  ($log)"
		[[ -f "$log" ]] && grep -m 5 '^\[script\].* FAIL ' "$log" | sed 's/^/      /'
	done
	exit 1
fi
