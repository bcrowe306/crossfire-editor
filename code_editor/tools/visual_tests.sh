#!/usr/bin/env bash
# Visual UI test suite (`task test:visual`): replays every tools/*.edctl
# script against a fresh editor_demo through the remote-control hook
# (real SDL input, live OLS), failing on any `expect`/`wait` that doesn't
# hold, and saves the screenshots each script takes into
# test_output/visual/<script>/ plus an index.md gallery. Run it after every
# feature and look at the screenshots.
set -uo pipefail
cd "$(dirname "$0")/.."

if [ ! -x third_party/ols/ols ]; then
	echo "visual tests: third_party/ols/ols not found -- run 'task ols:build'" >&2
	exit 2
fi

OUT="${VISUAL_DIR:-test_output/visual}"
mkdir -p "$OUT"

# script : fixture : one-line description (shown in the gallery)
SUITES=(
	"lsp_smoke:example/assets/lsp_fixture.odin.txt:Completion popup and signature help against live OLS"
	"lsp_crash:example/assets/lsp_fixture.odin.txt:OLS is killed mid-session; the editor keeps working and restarts it"
	"mouse_smoke:example/assets/mouse_fixture.odin.txt:Mouse and cursor gestures, scrolling, tab stops"
	"diagnostics_smoke:example/assets/diag_fixture.odin.txt:Diagnostics: squiggles, gutter markers, tooltips, F8"
	"editing_smoke:example/assets/editing_fixture.odin.txt:Sticky visual column for Up/Down, word-sized undo of typing"
	"find_smoke:example/assets/mouse_fixture.odin.txt:Find/replace bar (case, whole word, regex), Ctrl/Cmd+D and select-all occurrences"
	"fonts_smoke:example/assets/fonts_fixture.odin.txt:Fallback fonts for emoji/CJK/symbols; wide characters on the cell grid"
	"completion_polish:example/assets/polish_fixture.odin.txt:Completion docs panel, snippets with tab stops, parameter hints, overload cycling"
	"mouse_extras:example/assets/lsp_fixture.odin.txt:LSP hover info, right-click context menu, drag-and-drop move/copy"
	"ui_tweaks:example/assets/ui_fixture.odin.txt:Ayu Dark syntax colours, scrollbars (drag/click), Ctrl/Cmd +/- zoom"
	"palette_smoke:example/assets/mouse_fixture.odin.txt:Command palette (Cmd/Ctrl+P): fuzzy search, shortcuts, MRU, run by key or click"
	"nav_smoke:example/assets/nav_fixture:Go to Definition, Peek, Find References, Cmd/Ctrl+click across files, Back"
	"windows_smoke:example/assets/lsp_fixture.odin.txt:Palette switches windows (find, keymap, theme, utilities); Utilities stops/starts/restarts OLS"
	"theme_smoke:example/assets/ui_fixture.odin.txt:Theme editor window: colour list, hex entry, RGBA sliders, live preview, presets"
	"keymap_smoke:example/assets/mouse_fixture.odin.txt:Line commands, Keymap Editor (filter, rebind, persist), import from Zed/VSCode"
	"diagnostics_extras:example/assets/problems_fixture:Diagnostic tags, quick fixes, edit-tracking squiggles, problems panel"
)

# SUITE=<name> runs just that script (the gallery then lists only it).
if [ -n "${SUITE:-}" ]; then
	filtered=()
	for entry in "${SUITES[@]}"; do
		[ "${entry%%:*}" = "$SUITE" ] && filtered+=("$entry")
	done
	if [ ${#filtered[@]} -eq 0 ]; then
		echo "visual tests: no suite named '$SUITE'" >&2
		exit 2
	fi
	SUITES=("${filtered[@]}")
fi

failed=0
results=()
for entry in "${SUITES[@]}"; do
	IFS=: read -r name fixture desc <<<"$entry"
	if ./tools/run_smoke.sh "tools/$name.edctl" "$fixture"; then
		results+=("$name:PASS:$desc")
	else
		results+=("$name:FAIL:$desc")
		failed=1
	fi
done

# One labelled contact sheet per suite, for reviewing a run at a glance.
for entry in "${SUITES[@]}"; do
	IFS=: read -r name _ _ <<<"$entry"
	./tools/contact_sheet/contact_sheet "$OUT/$name" >/dev/null || true
done

INDEX="$OUT/index.md"
{
	echo "# odin_editor visual UI tests"
	echo
	echo "Generated $(date '+%Y-%m-%d %H:%M') from \`task test:visual\` on $(git rev-parse --short HEAD 2>/dev/null || echo '?')."
	echo "Each screenshot is the real demo window, driven by real SDL events through the control hook."
	for r in "${results[@]}"; do
		IFS=: read -r name status desc <<<"$r"
		echo
		echo "## $name — $status"
		echo
		echo "$desc (\`tools/$name.edctl\`)"
		if [ -e "$OUT/$name/contact_sheet.png" ]; then
			echo
			echo "![$name contact sheet]($name/contact_sheet.png)"
		fi
		for img in "$OUT/$name"/[0-9]*.png; do
			[ -e "$img" ] || continue
			file="$(basename "$img")"
			caption="$(echo "${file%.png}" | sed -E 's/^[0-9]+_//; s/_/ /g')"
			echo
			echo "**$caption**"
			echo
			echo "![$caption]($name/$file)"
		done
	done
} >"$INDEX"

shots=$(find "$OUT" -name '*.png' | wc -l | tr -d ' ')
echo "visual tests: $shots images, gallery: $INDEX (contact sheets: $OUT/*/contact_sheet.png)"
exit "$failed"
