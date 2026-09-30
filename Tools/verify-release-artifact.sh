#!/bin/bash
# Inspect the archive users will download, rather than the packaging directory.
set -euo pipefail
umask 077
[[ $# == 1 ]] || { printf 'Usage: bash Tools/verify-release-artifact.sh <production.zip>\n' >&2; exit 1; }
archive=$(cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1")
[[ -f "$archive" && -f "$archive.sha256" ]] || { printf 'Archive or checksum missing\n' >&2; exit 1; }
(cd -- "$(dirname -- "$archive")" && shasum -a 256 -c "$(basename -- "$archive").sha256")
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
ditto -x -k "$archive" "$scratch"
shopt -s nullglob
apps=("$scratch"/*.app)
[[ ${#apps[@]} == 1 ]] || { printf 'Expected one app in the archive\n' >&2; exit 1; }
app=${apps[0]}
plist="$app/Contents/Info.plist"
[[ $(plutil -extract CFBundleIdentifier raw "$plist") == com.maxblomqvist.privateclis ]] || { printf 'Unexpected app identifier\n' >&2; exit 1; }
codesign --verify --strict --verbose=2 "$app"
signature=$(codesign -d --verbose=4 "$app" 2>&1)
[[ "$signature" == *'Authority=Developer ID Application:'* && "$signature" == *'(runtime)'* ]] || {
    printf 'Release requires Developer ID signing and hardened runtime\n' >&2; exit 1;
}
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
printf 'Version: %s\nBuild: %s\n' "$(plutil -extract CFBundleShortVersionString raw "$plist")" "$(plutil -extract CFBundleVersion raw "$plist")"
lipo -archs "$app/Contents/MacOS/PrivateCLIHost"
printf 'Production archive verified\n'
