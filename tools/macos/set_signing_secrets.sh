#!/usr/bin/env bash
# Stores the macOS signing and notarization credentials from a .env file as GitHub Actions
# secrets (gh secret set), for CI's Developer ID signing and notarization.
#
#   tools/macos/set_signing_secrets.sh [--dry-run] [<env file>]   (default: .env at the root)
#
# The file's format is tools/macos/signing.env.example's. Files (.p12, .p8) are sent as their
# content (the certificate base64-encoded); every value goes to gh on stdin, so none appears in
# the process list or the output. GITHUB_REPO picks another repository.
#
# Secrets set: MACOS_CERTIFICATE (base64 .p12), MACOS_CERTIFICATE_PASSWORD, APPLE_TEAM_ID,
# APPLE_API_KEY (the .p8's text), APPLE_API_KEY_ID, APPLE_API_ISSUER_ID.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
dry=false
[[ "${1:-}" == --dry-run ]] && { dry=true; shift; }
envFile=${1:-$root/.env}
repo=${GITHUB_REPO:-bcrowe306/crossfire-editor}
[[ -f "$envFile" ]] || { echo "No $envFile: copy tools/macos/signing.env.example there and fill it in" >&2; exit 1; }

# KEY=value lines, read as text (not sourced: a password may hold $ or quotes)
declare -A env
while IFS= read -r line || [[ -n "$line" ]]; do
	line=${line%$'\r'}
	[[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
	[[ "$line" == *=* ]] || { echo "Not KEY=value: a line of $envFile" >&2; exit 1; }
	key=${line%%=*}
	key=${key//[[:space:]]/}
	value=${line#*=}
	# One pair of surrounding quotes is dropped
	if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then value=${BASH_REMATCH[1]}; fi
	env[$key]=$value
done < "$envFile"

missing=()
for key in MACOS_CERTIFICATE_P12 MACOS_CERTIFICATE_PASSWORD APPLE_TEAM_ID APPLE_API_KEY_P8 APPLE_API_KEY_ID APPLE_API_ISSUER_ID; do
	[[ -n "${env[$key]:-}" ]] || missing+=("$key")
done
((${#missing[@]} == 0)) || { echo "Empty in $envFile: ${missing[*]}" >&2; exit 1; }
p12=${env[MACOS_CERTIFICATE_P12]/#\~/$HOME}
p8=${env[APPLE_API_KEY_P8]/#\~/$HOME}
[[ -f "$p12" ]] || { echo "No certificate at MACOS_CERTIFICATE_P12's path" >&2; exit 1; }
[[ -f "$p8" ]] || { echo "No API key at APPLE_API_KEY_P8's path" >&2; exit 1; }
grep -q "BEGIN PRIVATE KEY" "$p8" || { echo "APPLE_API_KEY_P8 isn't a .p8 key file" >&2; exit 1; }
# The password must open the certificate (openssl 3 needs -legacy for older .p12 files)
if command -v openssl > /dev/null; then
	opened=false
	for legacy in "" -legacy; do
		openssl pkcs12 $legacy -in "$p12" -nokeys -passin fd:3 3<<< "${env[MACOS_CERTIFICATE_PASSWORD]}" > /dev/null 2>&1 && { opened=true; break; }
	done
	$opened || { echo "MACOS_CERTIFICATE_PASSWORD doesn't open the certificate" >&2; exit 1; }
fi

set_secret() { # <name>; the value on stdin
	if $dry; then
		cat > /dev/null
		echo "would set $1"
	else
		gh secret set "$1" -R "$repo" > /dev/null
		echo "set $1"
	fi
}
$dry || gh auth status > /dev/null 2>&1 || { echo "gh isn't logged in: gh auth login" >&2; exit 1; }
echo "Secrets for $repo:"
base64 < "$p12" | tr -d '\n' | set_secret MACOS_CERTIFICATE
printf '%s' "${env[MACOS_CERTIFICATE_PASSWORD]}" | set_secret MACOS_CERTIFICATE_PASSWORD
printf '%s' "${env[APPLE_TEAM_ID]}" | set_secret APPLE_TEAM_ID
set_secret APPLE_API_KEY < "$p8"
printf '%s' "${env[APPLE_API_KEY_ID]}" | set_secret APPLE_API_KEY_ID
printf '%s' "${env[APPLE_API_ISSUER_ID]}" | set_secret APPLE_API_ISSUER_ID
