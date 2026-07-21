#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REFERENCE_APP="$PROJECT_DIR/dist/ScreenWren.app"
REQUESTED_APP=${1:-}
LIVE_QA=${SCREENWREN_LIVE_QA:-0}

if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [ScreenWren.app]" >&2
    exit 64
fi

case "$LIVE_QA" in
    0|1) ;;
    *)
        echo "SCREENWREN_LIVE_QA must be 0 or 1" >&2
        exit 64
        ;;
esac

validate_bundle() {
    app_path=$1
    helper_app="$app_path/Contents/Library/LoginItems/ScreenWrenLoginItem.app"
    main_plist="$app_path/Contents/Info.plist"
    helper_plist="$helper_app/Contents/Info.plist"
    main_executable="$app_path/Contents/MacOS/ScreenWren"
    helper_executable="$helper_app/Contents/MacOS/ScreenWrenLoginItem"

    test -d "$app_path"
    test -d "$helper_app"
    test -x "$main_executable"
    test -x "$helper_executable"
    test -s "$app_path/Contents/Resources/ScreenWren.icns"
    plutil -lint "$main_plist" "$helper_plist" >/dev/null

    main_identifier=$(plutil -extract CFBundleIdentifier raw "$main_plist")
    helper_identifier=$(plutil -extract CFBundleIdentifier raw "$helper_plist")
    main_version=$(plutil -extract CFBundleShortVersionString raw "$main_plist")
    helper_version=$(plutil -extract CFBundleShortVersionString raw "$helper_plist")
    main_build=$(plutil -extract CFBundleVersion raw "$main_plist")
    helper_build=$(plutil -extract CFBundleVersion raw "$helper_plist")

    test "$(plutil -extract CFBundleExecutable raw "$main_plist")" = ScreenWren
    test "$(plutil -extract CFBundleExecutable raw "$helper_plist")" = ScreenWrenLoginItem
    test "$(plutil -extract CFBundlePackageType raw "$main_plist")" = APPL
    test "$(plutil -extract CFBundlePackageType raw "$helper_plist")" = APPL
    test "$(plutil -extract LSUIElement raw "$main_plist")" = true
    test "$(plutil -extract LSUIElement raw "$helper_plist")" = true
    test "$helper_identifier" = "$main_identifier.LoginItem"
    test "$helper_version" = "$main_version"
    test "$helper_build" = "$main_build"
    test "$(plutil -extract LSMinimumSystemVersion raw "$main_plist")" = 26.0
    test "$(plutil -extract LSMinimumSystemVersion raw "$helper_plist")" = 26.0

    lipo "$main_executable" -verify_arch arm64 x86_64
    lipo "$helper_executable" -verify_arch arm64 x86_64
    codesign --verify --strict --verbose=2 "$helper_app"
    codesign --verify --deep --strict --verbose=2 "$app_path"
    test "$(codesign -dv --verbose=4 "$app_path" 2>&1 | sed -n 's/^Identifier=//p')" = \
        "$main_identifier"
    test "$(codesign -dv --verbose=4 "$helper_app" 2>&1 | sed -n 's/^Identifier=//p')" = \
        "$helper_identifier"
    codesign -dv --verbose=4 "$app_path" 2>&1 | \
        grep -Eq '^CodeDirectory .*\(.*runtime.*\)'
    codesign -dv --verbose=4 "$helper_app" 2>&1 | \
        grep -Eq '^CodeDirectory .*\(.*runtime.*\)'
}

compare_bundle_contents() {
    expected_app=$1
    actual_app=$2
    comparison_dir=$(mktemp -d "${TMPDIR:-/tmp}/screenwren-compare.XXXXXX")
    expected_copy="$comparison_dir/expected/ScreenWren.app"
    actual_copy="$comparison_dir/actual/ScreenWren.app"

    trap 'rm -rf "$comparison_dir"' EXIT INT TERM
    mkdir -p "$comparison_dir/expected" "$comparison_dir/actual"
    ditto "$expected_app" "$expected_copy"
    ditto "$actual_app" "$actual_copy"

    # Signature timestamps can differ across otherwise identical Developer ID
    # builds. Compare complete unsigned copies after validating both originals.
    codesign --remove-signature "$expected_copy"
    codesign --remove-signature \
        "$expected_copy/Contents/Library/LoginItems/ScreenWrenLoginItem.app"
    codesign --remove-signature "$actual_copy"
    codesign --remove-signature \
        "$actual_copy/Contents/Library/LoginItems/ScreenWrenLoginItem.app"
    diff -qr "$expected_copy" "$actual_copy"

    rm -rf "$comparison_dir"
    trap - EXIT INT TERM
}

swift test --package-path "$PROJECT_DIR" --parallel
"$PROJECT_DIR/build-app.sh"

VERSION=$(plutil -extract CFBundleShortVersionString raw \
    "$REFERENCE_APP/Contents/Info.plist")
ARCHIVE_PATH="$PROJECT_DIR/dist/ScreenWren-$VERSION.zip"
test -s "$ARCHIVE_PATH"
unzip -tq "$ARCHIVE_PATH"

validate_bundle "$REFERENCE_APP"
APP_PATH=${REQUESTED_APP:-$REFERENCE_APP}
validate_bundle "$APP_PATH"

if [ "$APP_PATH" != "$REFERENCE_APP" ]; then
    compare_bundle_contents "$REFERENCE_APP" "$APP_PATH"
fi

# This check exits before starting NSApplication, so it never presents app UI.
"$APP_PATH/Contents/MacOS/ScreenWren" --self-check

if [ "$LIVE_QA" = 1 ]; then
    QA_DIR=$(mktemp -d "${TMPDIR:-/tmp}/screenwren-qa.XXXXXX")
    trap 'rm -rf "$QA_DIR"' EXIT INT TERM
    CAPTURE_PATH="$QA_DIR/region.png"
    open -n -W "$APP_PATH" --args --qa-capture "$CAPTURE_PATH"
    test -s "$CAPTURE_PATH"
    sips -g pixelWidth -g pixelHeight "$CAPTURE_PATH"
fi

echo "ScreenWren QA passed: $APP_PATH"
