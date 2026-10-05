#!/bin/bash

set -euo pipefail
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
OUTPUT_DIR="${M4IX_OUTPUT_DIR:-$PROJECT_DIR/outputs}"
APP_NAME='m4ix.CLI'
source "$SCRIPT_DIR/version.env"
INSTALL_BUILD=false
PRODUCTION_BUILD=false
case "${1:-}" in
    --install) INSTALL_BUILD=true ;;
    --production) PRODUCTION_BUILD=true ;;
    --help) printf 'Usage: bash Packaging/build-and-package.sh [--install|--production]\n'; exit 0 ;;
    '') ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
esac
[[ $# -le 1 ]] || { printf 'Too many arguments\n' >&2; exit 1; }
[[ "$OUTPUT_DIR" == /* ]] || { printf 'M4IX_OUTPUT_DIR must be an absolute path.\n' >&2; exit 1; }
if [[ "$PRODUCTION_BUILD" == true ]]; then
    [[ "${M4IX_SIGNING_IDENTITY:-}" == 'Developer ID Application: '* ]] || {
        printf 'Production packaging requires M4IX_SIGNING_IDENTITY (Developer ID Application).\n' >&2; exit 1;
    }
    [[ -n "${M4IX_NOTARY_PROFILE:-}" ]] || {
        printf 'Production packaging requires M4IX_NOTARY_PROFILE (notarytool keychain profile).\n' >&2; exit 1;
    }
fi
EXECUTABLE='PrivateCLIHost'
APP_PATH="$OUTPUT_DIR/$APP_NAME $APP_VERSION.app"
ZIP_PATH="$OUTPUT_DIR/$APP_NAME $APP_VERSION.zip"
LAUNCHER="$PROJECT_DIR/Resources/agent-launcher.sh"

[[ -f "$PROJECT_DIR/Package.swift" ]] || {
    printf 'Missing Swift package: %s\n' "$PROJECT_DIR/Package.swift" >&2
    exit 1
}
[[ -f "$LAUNCHER" ]] || {
    printf 'Missing CLI launcher: %s\n' "$LAUNCHER" >&2
    exit 1
}

# SwiftPM's nested macOS sandbox cannot initialize inside some agent hosts.
# The app build still runs under the invoking process's filesystem sandbox.
swift build --disable-sandbox --package-path "$PROJECT_DIR" -c release --product "$EXECUTABLE"
BIN_DIR=$(swift build --disable-sandbox --package-path "$PROJECT_DIR" -c release --show-bin-path)
BUILT_EXECUTABLE="$BIN_DIR/$EXECUTABLE"
[[ -x "$BUILT_EXECUTABLE" ]] || {
    printf 'Missing compiled executable: %s\n' "$BUILT_EXECUTABLE" >&2
    exit 1
}

LICENSE_SOURCE=''
for candidate in \
    "$PROJECT_DIR/.build/checkouts/SwiftTerm/LICENSE" \
    "$PROJECT_DIR/.build/checkouts/swiftterm/LICENSE"; do
    if [[ -f "$candidate" ]]; then
        LICENSE_SOURCE="$candidate"
        break
    fi
done
[[ -n "$LICENSE_SOURCE" ]] || {
    printf 'SwiftTerm license was not found in the local source or SwiftPM checkout.\n' >&2
    exit 1
}

mkdir -p "$OUTPUT_DIR"
[[ ! -e "$APP_PATH" && ! -L "$APP_PATH" && ! -e "$ZIP_PATH" ]] || {
    printf 'Release output already exists; bump the version before packaging again: %s\n' "$APP_PATH" >&2
    exit 1
}
STAGING_DIR=$(mktemp -d "$OUTPUT_DIR/.m4ix-cli.XXXXXXXX")
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/$APP_NAME $APP_VERSION.app"
MACOS_DIR="$STAGED_APP/Contents/MacOS"
RESOURCES_DIR="$STAGED_APP/Contents/Resources"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR/Licenses" "$RESOURCES_DIR/Fonts"
install -m 755 "$BUILT_EXECUTABLE" "$MACOS_DIR/$EXECUTABLE"
install -m 755 "$LAUNCHER" "$RESOURCES_DIR/agent-launcher.sh"
install -m 644 "$LICENSE_SOURCE" "$RESOURCES_DIR/Licenses/SwiftTerm-LICENSE.txt"
install -m 644 "$PROJECT_DIR/LICENSE" "$RESOURCES_DIR/Licenses/m4ix.CLI-LICENSE.txt"
for face in Newsreader ChivoMono; do
    install -m 644 "$PROJECT_DIR/Resources/Fonts/$face.ttf" "$RESOURCES_DIR/Fonts/$face.ttf"
    install -m 644 "$PROJECT_DIR/Resources/Fonts/$face-OFL.txt" "$RESOURCES_DIR/Licenses/$face-OFL.txt"
done

# Preserve any SwiftPM resource bundles in the app's standard resource directory.
for resource_bundle in "$BIN_DIR"/*.bundle; do
    [[ -d "$resource_bundle" ]] || continue
    bundle_name=$(basename "$resource_bundle")
    ditto "$resource_bundle" "$RESOURCES_DIR/$bundle_name"
done

cat > "$STAGED_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>m4ix.CLI</string>
    <key>CFBundleExecutable</key><string>PrivateCLIHost</string>
    <key>CFBundleIdentifier</key><string>com.maxblomqvist.privateclis</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>m4ix.CLI</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>VERSION</string>
    <key>CFBundleVersion</key><string>BUILD</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>m4ix.CLI listens only while you dictate a message. Speech is transcribed on this Mac.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>Dictated messages are transcribed on this Mac.</string>
</dict>
</plist>
PLIST

plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$STAGED_APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$APP_BUILD" "$STAGED_APP/Contents/Info.plist"
SOURCE_REVISION=$(git -C "$PROJECT_DIR" rev-parse --verify HEAD 2>/dev/null || true)
if [[ "$SOURCE_REVISION" =~ ^[0-9a-f]{40}$ ]]; then
    plutil -insert M4IXSourceRevision -string "$SOURCE_REVISION" "$STAGED_APP/Contents/Info.plist"
    SOURCE_DIRTY=false
    if [[ -n $(git -C "$PROJECT_DIR" status --porcelain) ]]; then SOURCE_DIRTY=true; fi
    plutil -insert M4IXSourceDirty -bool "$SOURCE_DIRTY" "$STAGED_APP/Contents/Info.plist"
fi

ICONSET="$STAGING_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
swift "$SCRIPT_DIR/generate-icon.swift" "$ICONSET/icon_512x512@2x.png"
for spec in \
    '16 icon_16x16.png' \
    '32 icon_16x16@2x.png' \
    '32 icon_32x32.png' \
    '64 icon_32x32@2x.png' \
    '128 icon_128x128.png' \
    '256 icon_128x128@2x.png' \
    '256 icon_256x256.png' \
    '512 icon_256x256@2x.png' \
    '512 icon_512x512.png'; do
    read -r size name <<< "$spec"
    sips -s format png -z "$size" "$size" \
        "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/$name" >/dev/null
done
if ! iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/AppIcon.icns"; then
    # iconutil fails in some nested command sandboxes. PNG-backed ICNS is
    # still valid, so pack the generated iconset with the standard library.
    python3 "$SCRIPT_DIR/make-icns.py" "$ICONSET" "$RESOURCES_DIR/AppIcon.icns"
    printf 'Packed the generated iconset without iconutil.\n'
fi

plutil -lint "$STAGED_APP/Contents/Info.plist"
if [[ "$PRODUCTION_BUILD" == true ]]; then
    # The hardened runtime blocks the microphone unless the entitlement asks for it.
    codesign --force --sign "$M4IX_SIGNING_IDENTITY" --options runtime --timestamp \
        --entitlements "$SCRIPT_DIR/m4ix.CLI.entitlements" "$STAGED_APP"
else
    codesign --force --sign - --timestamp=none "$STAGED_APP"
fi
codesign --verify --strict --verbose=2 "$STAGED_APP"

STAGED_ZIP="$STAGING_DIR/$APP_NAME.zip"
ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP" "$STAGED_ZIP"
if [[ "$PRODUCTION_BUILD" == true ]]; then
    xcrun notarytool submit "$STAGED_ZIP" --keychain-profile "$M4IX_NOTARY_PROFILE" --wait
    xcrun stapler staple "$STAGED_APP"
    xcrun stapler validate "$STAGED_APP"
    spctl --assess --type execute --verbose=2 "$STAGED_APP"
    rm "$STAGED_ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP" "$STAGED_ZIP"
fi
mv "$STAGED_APP" "$APP_PATH"
mv "$STAGED_ZIP" "$ZIP_PATH"
(cd "$OUTPUT_DIR" && shasum -a 256 "$APP_NAME $APP_VERSION.zip" > "$APP_NAME $APP_VERSION.zip.sha256")

printf 'App: %s\nArchive: %s\n' "$APP_PATH" "$ZIP_PATH"

if [[ "$INSTALL_BUILD" == true ]]; then
    "$SCRIPT_DIR/install.sh" "$APP_PATH"
else
    printf 'To install: bash Packaging/install.sh "%s"\n' "$APP_PATH"
fi
