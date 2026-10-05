#!/bin/bash
# Installs a packaged build in ~/Applications by default. M4IX_INSTALL_DIR
# selects another Applications folder. Previous installations are retained.
# Takes the build's .app path; without one, the newest in outputs/.
# build-and-package.sh --install runs this after packaging. Run it by hand to go back
# to an earlier build.

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
APP_NAME='m4ix.CLI'
INSTALL_DIR="${M4IX_INSTALL_DIR:-$HOME/Applications}"
BACKUPS_DIR="${M4IX_INSTALL_BACKUPS_DIR:-$HOME/Library/Caches/m4ix.cli/install-backups}"
[[ "$INSTALL_DIR" == /* && "$BACKUPS_DIR" == /* ]] || { printf 'Installation and backup folders must be absolute paths.\n' >&2; exit 1; }
TARGET="$INSTALL_DIR/$APP_NAME.app"

SOURCE=${1:-}
if [[ -z "$SOURCE" ]]; then
    SOURCE=$(ls -td "$PROJECT_DIR/outputs/$APP_NAME "*.app 2>/dev/null | head -1)
fi
[[ -n "$SOURCE" && -x "$SOURCE/Contents/MacOS/PrivateCLIHost" ]] || {
    printf 'No packaged build to install: %s\n' "${SOURCE:-outputs/ is empty}" >&2
    exit 1
}
codesign --verify --strict "$SOURCE"
[[ $(plutil -extract CFBundleIdentifier raw "$SOURCE/Contents/Info.plist") == com.maxblomqvist.privateclis ]] || exit 1

# Swap by rename, never by copying into the installed bundle: macOS kills a
# running app whose signed executable changes in place, while a renamed and
# deleted file stays readable to the process that has it open.
mkdir -p "$INSTALL_DIR"
STAGE=$(mktemp -d "$INSTALL_DIR/.$APP_NAME-install.XXXXXXXX")
trap 'rm -rf "$STAGE"' EXIT
if ! ditto "$SOURCE" "$STAGE/$APP_NAME.app"; then
    # Some command hosts can copy content but cannot preserve extended metadata.
    rm -rf "$STAGE/$APP_NAME.app"
    python3 - "$SOURCE" "$STAGE/$APP_NAME.app" <<'PY'
import os
import shutil
import stat
import sys
def copy_content(source, destination):
    shutil.copyfile(source, destination)
    os.chmod(destination, stat.S_IMODE(os.stat(source).st_mode))
    return destination
shutil.copytree(sys.argv[1], sys.argv[2], symlinks=True, copy_function=copy_content)
PY
fi
codesign --verify --strict "$STAGE/$APP_NAME.app"
BACKUP=''
if [[ -e "$TARGET" ]]; then
    [[ -d "$TARGET" && ! -L "$TARGET" ]] || { printf 'Installation target is not an app folder: %s\n' "$TARGET" >&2; exit 1; }
    codesign --verify --strict "$TARGET"
    mkdir -p "$BACKUPS_DIR"
    BACKUP=$(mktemp -d "$BACKUPS_DIR/manual-install.XXXXXXXX")
    mv "$TARGET" "$BACKUP/$APP_NAME.app"
fi
if ! mv "$STAGE/$APP_NAME.app" "$TARGET"; then
    if [[ -n "$BACKUP" ]]; then mv "$BACKUP/$APP_NAME.app" "$TARGET"; fi
    exit 1
fi

VERSION=$(plutil -extract CFBundleShortVersionString raw "$TARGET/Contents/Info.plist")
printf 'Installed: %s %s\n' "$TARGET" "$VERSION"
if [[ -n "$BACKUP" ]]; then printf 'Previous app: %s\n' "$BACKUP/$APP_NAME.app"; fi
printf 'Quit the running app, then open "%s" to load %s.\n' "$TARGET" "$VERSION"
