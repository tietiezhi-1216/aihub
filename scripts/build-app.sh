#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
    echo "Usage: $0 [debug|release]" >&2
    exit 1
fi
swift build -c "$configuration"
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
