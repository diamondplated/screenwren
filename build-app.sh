#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
DIST_DIR="$PROJECT_DIR/dist"
APP_PATH="$DIST_DIR/ScreenWren.app"
SIGNING_IDENTITY=${SCREENWREN_SIGNING_IDENTITY:--}

mkdir -p "$DIST_DIR"
STAGING_DIR=$(mktemp -d "$DIST_DIR/.screenwren-build.XXXXXX")
trap 'rm -rf "$STAGING_DIR"' EXIT INT TERM

build_architecture() {
    triple=$1
    scratch_path=$2

    swift build \
        --package-path "$PROJECT_DIR" \
        --scratch-path "$scratch_path" \
        --configuration release \
        --triple "$triple"
}

show_bin_path() {
    triple=$1
    scratch_path=$2

    swift build \
        --package-path "$PROJECT_DIR" \
        --scratch-path "$scratch_path" \
        --configuration release \
        --triple "$triple" \
        --show-bin-path
}

ARM_SCRATCH="$STAGING_DIR/build-arm64"
INTEL_SCRATCH="$STAGING_DIR/build-x86_64"

build_architecture arm64-apple-macosx26.0 "$ARM_SCRATCH"
build_architecture x86_64-apple-macosx26.0 "$INTEL_SCRATCH"

ARM_BIN_DIR=$(show_bin_path arm64-apple-macosx26.0 "$ARM_SCRATCH")
INTEL_BIN_DIR=$(show_bin_path x86_64-apple-macosx26.0 "$INTEL_SCRATCH")

for executable in ScreenWren ScreenWrenLoginItem; do
    test -x "$ARM_BIN_DIR/$executable"
    test -x "$INTEL_BIN_DIR/$executable"
done

STAGING_APP="$STAGING_DIR/ScreenWren.app"
HELPER_APP="$STAGING_APP/Contents/Library/LoginItems/ScreenWrenLoginItem.app"
MAIN_EXECUTABLE="$STAGING_APP/Contents/MacOS/ScreenWren"
HELPER_EXECUTABLE="$HELPER_APP/Contents/MacOS/ScreenWrenLoginItem"

mkdir -p \
    "$STAGING_APP/Contents/MacOS" \
    "$STAGING_APP/Contents/Resources" \
    "$HELPER_APP/Contents/MacOS"

lipo -create \
    "$ARM_BIN_DIR/ScreenWren" \
    "$INTEL_BIN_DIR/ScreenWren" \
    -output "$MAIN_EXECUTABLE"
lipo -create \
    "$ARM_BIN_DIR/ScreenWrenLoginItem" \
    "$INTEL_BIN_DIR/ScreenWrenLoginItem" \
    -output "$HELPER_EXECUTABLE"
chmod 755 "$MAIN_EXECUTABLE" "$HELPER_EXECUTABLE"

cp "$PROJECT_DIR/Info.plist" "$STAGING_APP/Contents/Info.plist"
cp "$PROJECT_DIR/LoginItem-Info.plist" "$HELPER_APP/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/ScreenWren.icns" \
    "$STAGING_APP/Contents/Resources/ScreenWren.icns"

MAIN_PLIST="$STAGING_APP/Contents/Info.plist"
HELPER_PLIST="$HELPER_APP/Contents/Info.plist"
plutil -lint "$MAIN_PLIST" "$HELPER_PLIST" >/dev/null

MAIN_IDENTIFIER=$(plutil -extract CFBundleIdentifier raw "$MAIN_PLIST")
HELPER_IDENTIFIER=$(plutil -extract CFBundleIdentifier raw "$HELPER_PLIST")
MAIN_VERSION=$(plutil -extract CFBundleShortVersionString raw "$MAIN_PLIST")
HELPER_VERSION=$(plutil -extract CFBundleShortVersionString raw "$HELPER_PLIST")
MAIN_BUILD=$(plutil -extract CFBundleVersion raw "$MAIN_PLIST")
HELPER_BUILD=$(plutil -extract CFBundleVersion raw "$HELPER_PLIST")

test "$(plutil -extract CFBundleExecutable raw "$MAIN_PLIST")" = ScreenWren
test "$(plutil -extract CFBundleExecutable raw "$HELPER_PLIST")" = ScreenWrenLoginItem
test "$(plutil -extract CFBundlePackageType raw "$MAIN_PLIST")" = APPL
test "$(plutil -extract CFBundlePackageType raw "$HELPER_PLIST")" = APPL
test "$(plutil -extract LSUIElement raw "$MAIN_PLIST")" = true
test "$(plutil -extract LSUIElement raw "$HELPER_PLIST")" = true
test "$HELPER_IDENTIFIER" = "$MAIN_IDENTIFIER.LoginItem"
test "$HELPER_VERSION" = "$MAIN_VERSION"
test "$HELPER_BUILD" = "$MAIN_BUILD"
test "$(plutil -extract LSMinimumSystemVersion raw "$MAIN_PLIST")" = 26.0
test "$(plutil -extract LSMinimumSystemVersion raw "$HELPER_PLIST")" = 26.0
lipo "$MAIN_EXECUTABLE" -verify_arch arm64 x86_64
lipo "$HELPER_EXECUTABLE" -verify_arch arm64 x86_64

sign_bundle() {
    bundle=$1

    if [ "$SIGNING_IDENTITY" = "-" ]; then
        codesign \
            --force \
            --options runtime \
            --sign - \
            --timestamp=none \
            "$bundle"
    else
        codesign \
            --force \
            --options runtime \
            --sign "$SIGNING_IDENTITY" \
            --timestamp \
            "$bundle"
    fi
}

# Nested code must be signed before the containing app bundle.
sign_bundle "$HELPER_APP"
sign_bundle "$STAGING_APP"
codesign --verify --strict --verbose=2 "$HELPER_APP"
codesign --verify --deep --strict --verbose=2 "$STAGING_APP"
test "$(codesign -dv --verbose=4 "$STAGING_APP" 2>&1 | sed -n 's/^Identifier=//p')" = \
    "$MAIN_IDENTIFIER"
test "$(codesign -dv --verbose=4 "$HELPER_APP" 2>&1 | sed -n 's/^Identifier=//p')" = \
    "$HELPER_IDENTIFIER"
codesign -dv --verbose=4 "$STAGING_APP" 2>&1 | \
    grep -Eq '^CodeDirectory .*\(.*runtime.*\)'
codesign -dv --verbose=4 "$HELPER_APP" 2>&1 | \
    grep -Eq '^CodeDirectory .*\(.*runtime.*\)'

case "$MAIN_VERSION" in
    *[!A-Za-z0-9._-]*)
        echo "Unsupported version for archive filename: $MAIN_VERSION" >&2
        exit 1
        ;;
esac

ARCHIVE_PATH="$DIST_DIR/ScreenWren-$MAIN_VERSION.zip"
STAGING_ARCHIVE="$STAGING_DIR/ScreenWren-$MAIN_VERSION.zip"

ditto -c -k --sequesterRsrc --keepParent "$STAGING_APP" "$STAGING_ARCHIVE"
rm -rf "$APP_PATH"
mv "$STAGING_APP" "$APP_PATH"
rm -f "$ARCHIVE_PATH"
mv "$STAGING_ARCHIVE" "$ARCHIVE_PATH"

echo "$APP_PATH"
echo "$ARCHIVE_PATH"
