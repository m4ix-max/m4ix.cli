#!/bin/bash
set -euo pipefail
umask 077
[[ $# -ge 3 && $# -le 4 ]] || { printf 'Usage: app-update.sh source.app target.app data-root [waiting-pid]\n' >&2; exit 1; }
source_app=$1
target_app=$2
data_root=$3
wait_pid=${4:-}
[[ "$source_app" == /* && "$target_app" == /* && "$data_root" == /* ]] || exit 1
if [[ -n "$wait_pid" ]]; then
    [[ "$wait_pid" =~ ^[0-9]+$ && "$wait_pid" -gt 1 ]] || exit 1
    while kill -0 "$wait_pid" 2>/dev/null; do sleep 1; done
fi
validate_app() {
    [[ -x "$1/Contents/MacOS/PrivateCLIHost" ]] || return 1
    [[ $(/usr/bin/plutil -extract CFBundleIdentifier raw "$1/Contents/Info.plist") == com.maxblomqvist.privateclis ]] || return 1
    /usr/bin/codesign --verify --strict "$1"
}
validate_app "$source_app"
parent_dir=$(dirname -- "$target_app")
stage_dir=$(mktemp -d "$parent_dir/.m4ix-update.XXXXXXXX")
trap 'rm -rf "$stage_dir"' EXIT
/usr/bin/ditto "$source_app" "$stage_dir/new.app"
validate_app "$stage_dir/new.app"
if [[ -e "$target_app" ]]; then
    validate_app "$target_app"
    version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$target_app/Contents/Info.plist")
    build=$(/usr/bin/plutil -extract CFBundleVersion raw "$target_app/Contents/Info.plist")
    [[ "$version" =~ ^[0-9.]+$ && "$build" =~ ^[0-9]+$ ]] || exit 1
    mkdir -p "$data_root/updates/versions"
    backup_dir=$(mktemp -d "$data_root/updates/versions/$version-$build.XXXXXXXX")
    /usr/bin/ditto "$target_app" "$backup_dir/m4ix.CLI.app"
    validate_app "$backup_dir/m4ix.CLI.app"
    mv "$target_app" "$stage_dir/previous.app"
fi
if ! mv "$stage_dir/new.app" "$target_app"; then
    if [[ -d "$stage_dir/previous.app" ]]; then mv "$stage_dir/previous.app" "$target_app"; fi
    exit 1
fi
printf 'Installed: %s\n' "$target_app"
