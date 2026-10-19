#!/usr/bin/env bash
# Installs the editor from its disk image the way a user would, then checks the installed app:
#   1. mounts the .dmg, copies the app out (ditto, like a Finder drag) into INSTALL_DIR, unmounts
#   2. checks the installed bundle (bundle.sh check: nothing linked outside it, signed)
#   3. runs UI test scripts with the installed editor, on a fresh copy of the test project; with
#      no Homebrew Vulkan, SDL or MoltenVK involved, so they pass only if the bundle has them
#
# Usage: tools/macos/verify.sh <dmg> [scripts...]   (run from the editor's folder; task macos:verify)
# Environment: INSTALL_DIR (default: a temporary folder, removed afterwards; the real
# /Applications is never touched unless you set it), UI=false to skip the UI scripts
set -euo pipefail
dmg=${1:?usage: verify.sh <dmg> [scripts...]}
shift
scripts=("$@")
[[ ${#scripts[@]} -gt 0 ]] || scripts=(tests/ui/smoke.script tests/ui/toolchain.script tests/ui/ldtk.script tests/ui/scripts.script)
editor=$(pwd)
work=$(mktemp -d -t odin_sdl_editor_verify)
mount="$work/mount"
install=${INSTALL_DIR:-$work/Applications}
cleanup() {
	hdiutil detach -quiet "$mount" 2> /dev/null || true
	[[ -z "${INSTALL_DIR:-}" ]] && rm -rf "$work"
}
trap cleanup EXIT

echo "== Installing from $dmg into $install"
mkdir -p "$mount" "$install"
hdiutil attach -nobrowse -readonly -noverify -mountpoint "$mount" "$dmg" > /dev/null
app_name=$(cd "$mount" && ls -d *.app | head -1)
[[ -n "$app_name" ]] || { echo "No .app in $dmg" >&2; exit 1; }
[[ -L "$mount/Applications" ]] || { echo "The disk image has no Applications link" >&2; exit 1; }
rm -rf "$install/$app_name"
ditto "$mount/$app_name" "$install/$app_name"
hdiutil detach -quiet "$mount"
app="$install/$app_name"

echo "== Checking the installed bundle"
APP="$app" "$editor/tools/macos/bundle.sh" check

if [[ "${UI:-true}" == false ]]; then
	echo "UI scripts skipped (UI=false)"
	exit 0
fi

echo "== UI scripts with the installed editor"
# Nothing from Homebrew may help: the bundle's own Vulkan, MoltenVK and libraries only
unset VK_ICD_FILENAMES VK_DRIVER_FILES DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH
# A real window: CI sets SDL's dummy video driver for its unit tests, which has no Vulkan
unset SDL_VIDEO_DRIVER
export GIT_AUTHOR_NAME="UI test" GIT_AUTHOR_EMAIL=ui-test@example.com GIT_COMMITTER_NAME="UI test" GIT_COMMITTER_EMAIL=ui-test@example.com
failed=0
for script in "${scripts[@]}"; do
	project="$work/ui_project"
	rm -rf "$project" "$work/ui_archive"
	cp -R tests/fixtures/ui_project "$project"
	cp tests/ui/settings.ini "$work/ui_settings.ini"
	if "$app/Contents/MacOS/odin_sdl_editor" "$project" --script "$editor/$script" --settings "$work/ui_settings.ini" > "$work/run.log" 2>&1; then
		grep "PASSED" "$work/run.log" || true
	else
		failed=$((failed + 1))
		grep -E "FAIL |FAILED|ERROR" "$work/run.log" | head -20 || tail -20 "$work/run.log"
	fi
done
if [[ $failed -gt 0 ]]; then
	echo "$failed UI script(s) failed with the installed app" >&2
	exit 1
fi
echo "The installed app passed ${#scripts[@]} UI script(s)"
