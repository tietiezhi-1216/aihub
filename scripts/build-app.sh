#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
    echo "Usage: $0 [debug|release]" >&2
    exit 1
fi
# Reject invalid release metadata before invoking the compiler or changing the app.
if [[ -n "${APP_VERSION:-}" && ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "APP_VERSION must be a version such as 0.1.0" >&2
    exit 1
fi
if [[ -n "${APP_BUILD_NUMBER:-}" && ! "$APP_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "APP_BUILD_NUMBER must contain only digits" >&2
    exit 1
fi
jobs="${SWIFT_BUILD_JOBS:-4}"
[[ "$jobs" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]] || { echo "SWIFT_BUILD_JOBS must be 1...32" >&2; exit 1; }
swift build -c "$configuration" -j "$jobs"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
app="$PWD/dist/AIHub.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# Replace the executable atomically; never truncate an inode used by a running
# app, which can invalidate its mapped code and lose an unsaved editor draft.
staged_binary="$(mktemp "$app/Contents/MacOS/.AIHub-XXXXXX")"
cp "$bin_dir/AIHub" "$staged_binary"
chmod 755 "$staged_binary"
mv -f "$staged_binary" "$app/Contents/MacOS/AIHub"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -n "${APP_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$app/Contents/Info.plist"
fi
if [[ -n "${APP_BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD_NUMBER" "$app/Contents/Info.plist"
fi
cp Resources/ThirdPartyNotices.txt "$app/Contents/Resources/ThirdPartyNotices.txt"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
swift scripts/generate-icon.swift "$temporary/AIHub.iconset"
iconutil -c icns "$temporary/AIHub.iconset" -o "$app/Contents/Resources/AppIcon.icns"
identity="${CODE_SIGN_IDENTITY:--}"
codesign --force --sign "$identity" --identifier app.aihub.mac \
    --options runtime --entitlements Resources/AIHub.entitlements "$app"
codesign --verify --strict "$app"
echo "Built: $app"
echo "Launch: open \"$app\""
