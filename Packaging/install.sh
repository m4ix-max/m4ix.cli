#!/bin/bash
# Installs a packaged build as /Applications/m4ix.CLI.app, replacing the one
# there. Takes the build's .app path; without one, the newest in outputs/.
# build-and-package.sh --install runs this after packaging. Run it by hand to go back
# to an earlier build.

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
APP_NAME='m4ix.CLI'
TARGET="/Applications/$APP_NAME.app"

SOURCE=${1:-}
if [[ -z "$SOURCE" ]]; then
    SOURCE=$(ls -td "$PROJECT_DIR/outputs/$APP_NAME "*.app 2>/dev/null | head -1)
fi
[[ -n "$SOURCE" && -x "$SOURCE/Contents/MacOS/PrivateCLIHost" ]] || {
    printf 'No packaged build to install: %s\n' "${SOURCE:-outputs/ is empty}" >&2
    exit 1
}
codesign --verify --strict "$SOURCE"

# Swap by rename, never by copying into the installed bundle: macOS kills a
# running app whose signed executable changes in place, while a renamed and
# deleted file stays readable to the process that has it open.
STAGE=$(mktemp -d "/Applications/.$APP_NAME-install.XXXXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto "$SOURCE" "$STAGE/$APP_NAME.app"
if [[ -e "$TARGET" ]]; then
    mv "$TARGET" "$STAGE/previous.app"
fi
mv "$STAGE/$APP_NAME.app" "$TARGET"

VERSION=$(defaults read "$TARGET/Contents/Info.plist" CFBundleShortVersionString)
printf 'Installed: %s %s\n' "$TARGET" "$VERSION"
# pgrep misses the app from some sandboxed shells; ps does not. grep reads
# all of it, since an early exit would fail the pipeline under pipefail.
if ps -axo comm= | grep '/PrivateCLIHost$' >/dev/null; then
    printf 'The app is still running the previous build. Quit and reopen it to use %s.\n' "$VERSION"
fi
