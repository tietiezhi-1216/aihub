#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/dist/AIHub.app"
[[ -d "$app" ]] || { echo "Build the app first: ./scripts/build-app.sh" >&2; exit 1; }
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid application version" >&2; exit 1; }
architecture="$(uname -m)"
case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported architecture" >&2; exit 1 ;; esac
[[ "$(lipo -archs "$app/Contents/MacOS/AIHub")" == "$architecture" ]] || { echo "Binary architecture does not match this runner" >&2; exit 1; }
codesign --verify --strict "$app"
plutil -lint "$app/Contents/Info.plist"
name="AIHub-$version-$architecture"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
# Preserve the app's resources and signature. Never remove download quarantine
# or change system security settings as part of installation or packaging.
ditto -c -k --sequesterRsrc --keepParent "$app" "$PWD/dist/$name.zip"
ditto "$app" "$temporary/AIHub.app"
ln -s /Applications "$temporary/Applications"
hdiutil create -ov -format UDZO -fs HFS+ -volname AIHub \
    -srcfolder "$temporary" "$PWD/dist/$name.dmg"
(cd dist && shasum -a 256 "$name.zip" "$name.dmg" > "$name.sha256")
echo "Packaged: dist/$name.zip, dist/$name.dmg, dist/$name.sha256"
