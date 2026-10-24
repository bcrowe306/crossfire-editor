#!/usr/bin/env bash
# The profiling harness: runs the editor's profiling scenarios (tests/profile/*.script) in a
# Spall build, headless, and reports where each frame's time goes (the engine's
# tools/spall_report). Runs without a person and without being disturbed:
#   - no window: SDL's offscreen video driver (Vulkan through VK_EXT_headless_surface, on the real
#     GPU), the dummy audio driver, a fixed --window-size; no focus taken, no input from the
#     desktop, nothing resized by the window manager;
#   - its own copy of the project each run (the demo or the UI fixture as committed: `git
#     archive HEAD`, so uncommitted edits to them don't change the numbers), its own settings file
#     and XDG_DATA_HOME (the editor's data folder, a game's saves);
#   - every frame drawn and uncapped (SKALD_BENCH_FRAMES, SKALD_BENCH_UNCAP), on pinned CPUs
#     (taskset), several runs, the median run's report kept.
#
#   tools/profile.sh [options] [scenario...]       (default: every scenario)
#     --runs <n>          runs per scenario (default 3; the run with the median frame is kept)
#     --cpus <list>       taskset's CPU list (default 2-5; "" for none)
#     --size <w>x<h>      window size (default 1680x1000; a scenario's "# window:" line wins)
#     --no-build          use the last build (build/profile/crossfire-editor)
#     --auto              build with SPALL_AUTO (every procedure: slow, for finding hot spots)
#     --save-baseline     keep the results as the baseline (build/profile/baseline/)
#     --compare           compare the results with the baseline; exit 1 if a scenario's median
#                         or mean frame got slower by more than --threshold percent (default 5)
#     --threshold <pct>
#
# Results: build/profile/results/<scenario>.txt (the report) and .json, the median run's trace
# build/profile/results/<scenario>.spall (open it in Spall: https://gravitymoth.com/spall/), and a
# summary. Everything under build/profile/ is scratch (gitignored).
#
# Environment: ENGINE_DIR (default ../odin_sdl_engine), ODIN (default odin).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
ENGINE_DIR=${ENGINE_DIR:-../odin_sdl_engine}
ODIN=${ODIN:-odin}
OUT=$ROOT/build/profile
RUNS=3
CPUS=2-5
SIZE=1680x1000
BUILD=1
AUTO=0
SAVE=0
COMPARE=0
THRESHOLD=5
SCENARIOS=()

while [[ $# -gt 0 ]]; do
	case $1 in
		--runs) RUNS=$2; shift 2 ;;
		--cpus) CPUS=$2; shift 2 ;;
		--size) SIZE=$2; shift 2 ;;
		--no-build) BUILD=0; shift ;;
		--auto) AUTO=1; shift ;;
		--save-baseline) SAVE=1; shift ;;
		--compare) COMPARE=1; shift ;;
		--threshold) THRESHOLD=$2; shift 2 ;;
		-h|--help) sed -n '2,32p' "$0"; exit 0 ;;
		-*) echo "profile.sh: unknown option $1" >&2; exit 2 ;;
		*) SCENARIOS+=("$1"); shift ;;
	esac
done
if [[ ${#SCENARIOS[@]} -eq 0 ]]; then
	for f in tests/profile/*.script; do SCENARIOS+=("$(basename "$f" .script)"); done
fi

mkdir -p "$OUT/results" "$OUT/runs"
EDITOR=$OUT/crossfire-editor
REPORT=$OUT/spall_report

if [[ $BUILD -eq 1 ]]; then
	defines=(-define:SPALL=true)
	[[ $AUTO -eq 1 ]] && defines+=(-define:SPALL_AUTO=true)
	echo "Building the editor with ${defines[*]} (-o:speed)..."
	"$ODIN" build . -collection:gui=Skald "-collection:engine=$ENGINE_DIR" "-define:ENGINE_DIR=$ENGINE_DIR" \
		"${defines[@]}" -o:speed "-out:$EDITOR"
fi
if [[ ! -x $REPORT || $ENGINE_DIR/tools/spall_report/main.odin -nt $REPORT ]]; then
	"$ODIN" build "$ENGINE_DIR/tools/spall_report" -o:speed "-out:$REPORT"
fi
[[ -x $EDITOR ]] || { echo "profile.sh: no build at $EDITOR (run without --no-build)" >&2; exit 1; }

# Other work on the machine changes the numbers: say so
load=$(cut -d' ' -f1 /proc/loadavg)
cpus=$(nproc)
if awk -v l="$load" -v c="$cpus" 'BEGIN { exit !(l > c / 4) }'; then
	echo "Warning: load average $load on $cpus CPUs: other work may skew the numbers"
fi

pin=()
[[ -n $CPUS ]] && command -v taskset >/dev/null && pin=(taskset -c "$CPUS")

# A scenario's project, as committed: examples/demo_project unless its "# project:" line says
# "fixture" (tests/fixtures/ui_project)
projectOf() {
	local p
	p=$(sed -n 's/^# project: *//p' "tests/profile/$1.script" | head -1)
	[[ $p == fixture ]] && echo tests/fixtures/ui_project || echo examples/demo_project
}

status=0
summary=()
for scenario in "${SCENARIOS[@]}"; do
	script=tests/profile/$scenario.script
	[[ -f $script ]] || { echo "profile.sh: no scenario $script" >&2; status=1; continue; }
	size=$(sed -n 's/^# window: *//p' "$script" | head -1)
	size=${size:-$SIZE}
	project=$(projectOf "$scenario")
	medians=()
	for run in $(seq 1 "$RUNS"); do
		dir=$OUT/runs/$scenario/$run
		rm -rf "$dir"
		mkdir -p "$dir/data"
		git archive HEAD "$project" | tar -x -C "$dir"
		cp tests/ui/settings.ini "$dir/settings.ini"
		echo "[$scenario $run/$RUNS] running ($size)"
		if ! env SDL_VIDEO_DRIVER=offscreen SDL_AUDIO_DRIVER=dummy XDG_DATA_HOME="$dir/data" \
			SKALD_BENCH_UNCAP=1 SKALD_BENCH_FRAMES=1000000000 SPALL_TRACE="$dir/trace.spall" \
			timeout 600 "${pin[@]}" "$EDITOR" "$dir/$project" --script "$ROOT/$script" \
			--settings "$dir/settings.ini" --window-size "$size" >"$dir/log.txt" 2>&1; then
			echo "[$scenario $run/$RUNS] the script failed: $dir/log.txt"
			grep -E "FAIL|fail" "$dir/log.txt" | head -5 || true
			status=1
			continue
		fi
		if ! "$REPORT" "$dir/trace.spall" -from=start -to=end -json="$dir/report.json" >"$dir/report.txt" 2>&1; then
			echo "[$scenario $run/$RUNS] no report:"; cat "$dir/report.txt"; status=1; continue
		fi
		p50=$(grep -o '"p50_ms": *[0-9.e+-]*' "$dir/report.json" | head -1 | sed 's/.*: *//' | xargs printf '%.3f')
		medians+=("$p50 $run")
		echo "[$scenario $run/$RUNS] median frame $p50 ms"
	done
	[[ ${#medians[@]} -gt 0 ]] || continue
	# The run with the median frame time is the one kept
	kept=$(printf '%s\n' "${medians[@]}" | sort -g | awk -v n=${#medians[@]} 'NR == int((n + 1) / 2) { print $2 }')
	dir=$OUT/runs/$scenario/$kept
	cp "$dir/report.txt" "$OUT/results/$scenario.txt"
	cp "$dir/report.json" "$OUT/results/$scenario.json"
	cp "$dir/trace.spall" "$OUT/results/$scenario.spall"
	all=$(printf '%s\n' "${medians[@]}" | cut -d' ' -f1 | sort -g | tr '\n' ' ')
	summary+=("$(printf '%-12s kept run %s; median frame per run (ms): %s' "$scenario" "$kept" "$all")")
	if [[ $SAVE -eq 1 ]]; then
		mkdir -p "$OUT/baseline"
		cp "$OUT/results/$scenario.json" "$OUT/baseline/$scenario.json"
	fi
	if [[ $COMPARE -eq 1 ]]; then
		if [[ -f $OUT/baseline/$scenario.json ]]; then
			echo
			echo "=== $scenario: baseline -> now"
			"$REPORT" compare "$OUT/baseline/$scenario.json" "$OUT/results/$scenario.json" -threshold="$THRESHOLD" || status=1
		else
			echo "[$scenario] no baseline to compare with (--save-baseline)"
		fi
	fi
done

echo
echo "Summary (results in build/profile/results/):"
for line in "${summary[@]}"; do echo "  $line"; done
for scenario in "${SCENARIOS[@]}"; do
	[[ -f $OUT/results/$scenario.txt ]] && { echo; echo "=== $scenario"; sed -n '1,30p' "$OUT/results/$scenario.txt"; }
done
exit $status
