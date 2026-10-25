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
#     (taskset), several runs, reported together (their frames pooled: the viewport renders on a
#     timer, so frames with and without a scene render alternate, and one run's median jumps).
#
#   tools/profile.sh [options] [scenario...]       (default: every scenario)
#     --runs <n>          runs per scenario (default 4: an even count balances --compare's ABBA
#                         order; reported together)
#     --cpus <list>       taskset's CPU list (default 2-5; "" for none)
#     --clock <wall|cpu>  the trace's clock (default wall): cpu is each thread's CPU time, which
#                         leaves out time the thread was descheduled (other programs' load), its
#                         GPU waits and sleeps: for comparing CPU work on a busy machine
#     --wait-quiet <s>    before each run, wait up to that long (default 300; 0: don't) for the
#                         machine's CPU use to drop under --quiet-busy percent (default 20): a
#                         compile or another program sharing the CPUs slows a run by 10-60%
#     --size <w>x<h>      window size (default 1680x1000; a scenario's "# window:" line wins)
#     --no-build          use the last build (build/profile/crossfire-editor)
#     --auto              build with SPALL_AUTO (every procedure: slow, for finding hot spots)
#     --save-baseline     keep the results and this build as the baseline (build/profile/baseline/)
#     --compare           compare with the baseline: the kept baseline build runs right before each
#                         of this build's runs (interleaved, so the machine's drift hits both), else
#                         the kept results; exit 1 if a scenario's mean frame got slower by more
#                         than --threshold percent (default 5)
#     --threshold <pct>
#
# Results: build/profile/results/<scenario>.txt (the report over all runs) and .json, the median run's trace
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
RUNS=4
CPUS=2-5
CLOCK=wall
WAIT_QUIET=300
QUIET_BUSY=20
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
		--clock) CLOCK=$2; shift 2 ;;
		--wait-quiet) WAIT_QUIET=$2; shift 2 ;;
		--quiet-busy) QUIET_BUSY=$2; shift 2 ;;
		--size) SIZE=$2; shift 2 ;;
		--no-build) BUILD=0; shift ;;
		--auto) AUTO=1; shift ;;
		--save-baseline) SAVE=1; shift ;;
		--compare) COMPARE=1; shift ;;
		--threshold) THRESHOLD=$2; shift 2 ;;
		-h|--help) sed -n '2,44p' "$0"; exit 0 ;;
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

# The machine's CPU use (percent of all CPUs) over one second, from /proc/stat
cpuBusy() {
	local a b
	read -r -a a < <(grep '^cpu ' /proc/stat)
	sleep 1
	read -r -a b < <(grep '^cpu ' /proc/stat)
	local idle=$(( (b[4] + b[5]) - (a[4] + a[5]) ))
	local total=0 i
	for i in 1 2 3 4 5 6 7 8; do total=$(( total + b[i] - a[i] )); done
	(( total > 0 )) || { echo 0; return; }
	echo $(( 100 * (total - idle) / total ))
}

# Waits (at most $WAIT_QUIET seconds) until the machine's CPU use is under $QUIET_BUSY percent,
# so a run doesn't share the CPUs with other work; says when it gave up
waitQuiet() {
	(( WAIT_QUIET > 0 )) || return 0
	local waited=0 busy
	while :; do
		busy=$(cpuBusy)
		(( busy < QUIET_BUSY )) && return 0
		if (( waited >= WAIT_QUIET )); then
			echo "  (the machine stayed busy: ${busy}% of its CPUs in use; running anyway)"
			return 0
		fi
		(( waited == 0 )) && echo "  waiting for the machine to be quiet (${busy}% of its CPUs in use)..."
		sleep 4
		waited=$(( waited + 5 ))
	done
}

status=0
summary=()
BASE_EDITOR=$OUT/baseline/crossfire-editor
interleave=0
[[ $COMPARE -eq 1 && -x $BASE_EDITOR ]] && interleave=1

# One run of a scenario with a build: its trace and per-run report in runs/<scenario>/<tag>-<run>/;
# prints the run's median frame (empty when it failed)
runOne() {
	local scenario=$1 binary=$2 tag=$3 run=$4 size=$5 project=$6
	local dir=$OUT/runs/$scenario/$tag-$run
	rm -rf "$dir"
	mkdir -p "$dir/data"
	git archive HEAD "$project" | tar -x -C "$dir"
	cp tests/ui/settings.ini "$dir/settings.ini"
	if ! env SDL_VIDEO_DRIVER=offscreen SDL_AUDIO_DRIVER=dummy XDG_DATA_HOME="$dir/data" \
		SKALD_BENCH_UNCAP=1 SKALD_BENCH_FRAMES=1000000000 SPALL_TRACE="$dir/trace.spall" SPALL_CLOCK="$CLOCK" \
		timeout 600 "${pin[@]}" "$binary" "$dir/$project" --script "$ROOT/tests/profile/$scenario.script" \
		--settings "$dir/settings.ini" --window-size "$size" >"$dir/log.txt" 2>&1; then
		echo "[$scenario $tag $run] the script failed: $dir/log.txt" >&2
		grep -E "FAIL|fail" "$dir/log.txt" | head -5 >&2 || true
		return 1
	fi
	if ! "$REPORT" "$dir/trace.spall" -from=start -to=end -json="$dir/report.json" >"$dir/report.txt" 2>&1; then
		echo "[$scenario $tag $run] no report:" >&2; cat "$dir/report.txt" >&2; return 1
	fi
	grep -o '"p50_ms": *[0-9.e+-]*' "$dir/report.json" | head -1 | sed 's/.*: *//' | xargs printf '%.3f'
}

# A report's mean frame (ms), empty when it has none
meanOf() {
	[[ -f $1 ]] || return 0
	grep -o '"mean_ms": *[0-9.e+-]*' "$1" | head -1 | sed 's/.*: *//'
}

# The report over a build's runs (pooled), into results/<scenario><suffix>.json and .txt
pooledReport() {
	local scenario=$1 tag=$2 suffix=$3
	local traces=()
	for f in "$OUT/runs/$scenario/$tag"-*/trace.spall; do [[ -f $f ]] && traces+=("$f"); done
	[[ ${#traces[@]} -gt 0 ]] || return 1
	"$REPORT" "${traces[@]}" -from=start -to=end -json="$OUT/results/$scenario$suffix.json" >"$OUT/results/$scenario$suffix.txt" 2>&1
}

for scenario in "${SCENARIOS[@]}"; do
	script=tests/profile/$scenario.script
	[[ -f $script ]] || { echo "profile.sh: no scenario $script" >&2; status=1; continue; }
	size=$(sed -n 's/^# window: *//p' "$script" | head -1)
	size=${size:-$SIZE}
	project=$(projectOf "$scenario")
	# A failed run must not leave the last results looking like this one's
	rm -rf "$OUT/runs/$scenario" "$OUT/results/$scenario".*
	medians=()
	runBase() {
		waitQuiet
		echo "[$scenario $run/$RUNS] baseline build ($size)"
		local b
		b=$(runOne "$scenario" "$BASE_EDITOR" base "$run" "$size" "$project") || status=1
		[[ -n $b ]] && echo "[$scenario $run/$RUNS] baseline build: median frame $b ms"
	}
	for run in $(seq 1 "$RUNS"); do
		# Comparing with a kept baseline build: its runs and this build's alternate, in ABBA order (the
		# second of two runs in a row came out 3-11% faster, the same build both times: warm caches,
		# clocks already up), so the machine's drift and the order land on both alike
		[[ $interleave -eq 1 && $((run % 2)) -eq 1 ]] && runBase
		waitQuiet
		echo "[$scenario $run/$RUNS] running ($size)"
		if m=$(runOne "$scenario" "$EDITOR" new "$run" "$size" "$project"); then
			medians+=("$m $run")
			echo "[$scenario $run/$RUNS] median frame $m ms"
		else
			status=1
		fi
		[[ $interleave -eq 1 && $((run % 2)) -eq 0 ]] && runBase
	done
	[[ ${#medians[@]} -gt 0 ]] || continue
	# The report pools every run's frames and spans (steadier than any one run); the trace kept
	# for Spall's viewer is the run with the median frame
	pooledReport "$scenario" new "" || status=1
	kept=$(printf '%s\n' "${medians[@]}" | sort -g | awk -v n=${#medians[@]} 'NR == int((n + 1) / 2) { print $2 }')
	cp "$OUT/runs/$scenario/new-$kept/trace.spall" "$OUT/results/$scenario.spall"
	all=$(printf '%s\n' "${medians[@]}" | cut -d' ' -f1 | sort -g | tr '\n' ' ')
	pooled=$(grep -o '"mean_ms": *[0-9.e+-]*' "$OUT/results/$scenario.json" | head -1 | sed 's/.*: *//' | xargs printf '%.3f')
	summary+=("$(printf '%-12s mean frame %s ms over %s runs; median per run (ms): %s' "$scenario" "$pooled" "${#medians[@]}" "$all")")
	if [[ $SAVE -eq 1 ]]; then
		mkdir -p "$OUT/baseline"
		cp "$OUT/results/$scenario.json" "$OUT/baseline/$scenario.json"
	fi
	if [[ $COMPARE -eq 1 ]]; then
		before=$OUT/baseline/$scenario.json
		if [[ $interleave -eq 1 ]] && pooledReport "$scenario" base ".baseline"; then
			before=$OUT/results/$scenario.baseline.json
			echo
			echo "=== $scenario: baseline build -> this build (interleaved runs)"
		elif [[ -f $before ]]; then
			echo
			echo "=== $scenario: baseline results -> now (not interleaved: other work on the machine between them shows as a change)"
		else
			echo "[$scenario] no baseline to compare with (--save-baseline)"
			continue
		fi
		if [[ $interleave -eq 0 ]]; then
			"$REPORT" compare "$before" "$OUT/results/$scenario.json" -threshold="$THRESHOLD" || status=1
			continue
		fi
		# The pooled comparison shows where time moved; the verdict is the pairs': each ABBA pair's
		# mean frame, this build over the baseline, and the median of those ratios, which one run
		# disturbed by other work can't sway (a pooled mean can: one run at twice the others moved
		# a scenario by 16%)
		"$REPORT" compare "$before" "$OUT/results/$scenario.json" -threshold=1000 | sed '$d'
		ratios=()
		for n in $(seq 1 "$RUNS"); do
			bm=$(meanOf "$OUT/runs/$scenario/base-$n/report.json")
			nm=$(meanOf "$OUT/runs/$scenario/new-$n/report.json")
			[[ -n $bm && -n $nm ]] || continue
			ratios+=("$(awk -v a="$nm" -v b="$bm" 'BEGIN { printf "%.4f", a / b }')")
		done
		if [[ ${#ratios[@]} -eq 0 ]]; then
			echo "[$scenario] no complete pair to compare"; status=1; continue
		fi
		med=$(printf '%s\n' "${ratios[@]}" | sort -g | awk '{ v[NR] = $1 } END { print (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2 }')
		echo "Pairs (this build's mean frame over the baseline's, ABBA): ${ratios[*]}; median $med"
		if awk -v m="$med" -v t="$THRESHOLD" 'BEGIN { exit !(m > 1 + t / 100) }'; then
			echo "Slower: the median pair's mean frame grew by more than $THRESHOLD%"
			status=1
		else
			echo "Not slower than $THRESHOLD% (the median pair)"
		fi
	fi
done
# The build the results came from is the next comparisons' baseline
if [[ $SAVE -eq 1 ]]; then cp "$EDITOR" "$BASE_EDITOR"; fi

echo
echo "Summary (results in build/profile/results/):"
for line in "${summary[@]}"; do echo "  $line"; done
for scenario in "${SCENARIOS[@]}"; do
	[[ -f $OUT/results/$scenario.txt ]] && { echo; echo "=== $scenario"; sed -n '1,30p' "$OUT/results/$scenario.txt"; }
done
exit $status
