#!/usr/bin/env bash
# Re-pin OLS to a commit that builds with the installed Odin compiler.
#
#   tools/ols_repin.sh            check OLS_REF; if it no longer builds (or our
#                                 patches don't apply), find a commit that does
#   tools/ols_repin.sh --newest   move to the newest compatible commit even if
#                                 the current pin still works
#   tools/ols_repin.sh --check    only check the current pin (exit 1 if broken)
#
# OLS tracks Odin's development branch closely, so a compiler upgrade usually
# breaks the pinned commit. The search walks OLS master newest-first, limited
# to commits up to ~2 months after the compiler's release month (newer OLS
# needs a newer compiler), and picks the first commit that both applies
# patches/ols/*.patch and builds. Builds take ~2 s each and run in a scratch
# git worktree, so third_party/ols itself is untouched. On success the
# Taskfile's OLS_REF is updated; then run `task ols:build`.
set -uo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
OLS_DIR=third_party/ols
MAX_TRIES="${MAX_TRIES:-400}"

current_ref() { sed -n 's/^  OLS_REF: *//p' Taskfile.yml | head -1; }

if [ ! -d "$OLS_DIR/.git" ]; then
	echo "ols:repin: $OLS_DIR is not a clone -- run 'task ols:fetch' first" >&2
	exit 2
fi

WT="$(mktemp -d /tmp/ols_repin_XXXXXX)"
cleanup() {
	git -C "$OLS_DIR" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
	git -C "$OLS_DIR" worktree prune >/dev/null 2>&1 || true
}
trap cleanup EXIT
git -C "$OLS_DIR" worktree add --detach --quiet "$WT" HEAD

# try_commit <sha>: checkout, apply our patches, build. Exit status = result.
# A patch that no longer applies but reverse-applies is already upstream
# (the bug got fixed) and counts as satisfied; drop it from patches/ols then.
rejected_patch=0
rejected_build=0
try_commit() {
	git -C "$WT" checkout --quiet --force "$1" 2>/dev/null || return 1
	for p in patches/ols/*.patch; do
		[ -e "$p" ] || continue
		if git -C "$WT" apply --check "$PWD/$p" 2>/dev/null; then
			git -C "$WT" apply "$PWD/$p" || return 1
		elif git -C "$WT" apply --check -R "$PWD/$p" 2>/dev/null; then
			echo "ols:repin: note: ${1:0:12} already contains $(basename "$p") (fixed upstream)" >&2
		else
			rejected_patch=$((rejected_patch + 1))
			return 1
		fi
	done
	if ! odin build "$WT/src" -collection:src="$WT/src" -out:"$WT/ols_probe" >/dev/null 2>&1; then
		rejected_build=$((rejected_build + 1))
		return 1
	fi
}

CUR="$(current_ref)"
if [ "$MODE" != "--newest" ]; then
	if try_commit "$CUR"; then
		echo "ols:repin: current OLS_REF ${CUR:0:12} builds with $(odin version | awk '{print $3}') and takes our patches -- nothing to do"
		exit 0
	fi
	echo "ols:repin: current OLS_REF ${CUR:0:12} does not build (or patches don't apply) with this compiler"
	[ "$MODE" = "--check" ] && exit 1
fi

git -C "$OLS_DIR" fetch --quiet origin || echo "ols:repin: fetch failed, searching known commits only" >&2

# Compiler release month, e.g. "dev-2026-03:..." -> search up to 2026-05-01.
ver="$(odin version | sed -n 's/.*dev-\([0-9]\{4\}\)-\([0-9]\{2\}\).*/\1 \2/p')"
until_arg=()
if [ -n "$ver" ]; then
	read -r y m <<<"$ver"
	m=$((10#$m + 2)); if [ $m -gt 12 ]; then m=$((m - 12)); y=$((y + 1)); fi
	until_arg=(--until="$(printf '%04d-%02d-01' "$y" "$m")")
fi

tries=0
found=""
while read -r sha; do
	tries=$((tries + 1))
	[ $tries -gt "$MAX_TRIES" ] && break
	if try_commit "$sha"; then
		found="$sha"
		break
	fi
done < <(git -C "$OLS_DIR" log --first-parent --format=%H "${until_arg[@]}" origin/master 2>/dev/null || git -C "$OLS_DIR" log --first-parent --format=%H "${until_arg[@]}" HEAD)

if [ -z "$found" ]; then
	echo "ols:repin: no compatible commit in $((tries - 1)) candidates ($rejected_build failed to build, $rejected_patch rejected our patches)" >&2
	exit 1
fi
date="$(git -C "$OLS_DIR" log -1 --format=%cd --date=short "$found")"
if [ "$found" = "$CUR" ]; then
	echo "ols:repin: newest compatible commit is the current pin (${found:0:12}, $date)"
	exit 0
fi
sed -i.bak "s/^  OLS_REF: .*/  OLS_REF: $found/" Taskfile.yml && rm -f Taskfile.yml.bak
echo "ols:repin: OLS_REF -> ${found:0:12} ($date) after $tries tries ($rejected_build failed to build, $rejected_patch rejected our patches)"
if [ "$rejected_patch" -gt 0 ]; then
	echo "ols:repin: $rejected_patch newer commit(s) were skipped only because patches/ols/*.patch no longer apply;"
	echo "           refresh those patches against a newer commit to move further forward."
fi
echo "ols:repin: now run: task ols:build && task test:visual"
