#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Full Xcode supplies the test runner frameworks missing from some CLT installations.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == *CommandLineTools* && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift test -j 4 "$@"
