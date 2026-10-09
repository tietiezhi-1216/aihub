#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
temporary="$(mktemp -d)"
server_pid=""
cleanup() {
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$temporary"
}
trap cleanup EXIT
python3 scripts/mock-provider.py --port-file "$temporary/port" >"$temporary/server.log" 2>&1 &
server_pid=$!
for _ in {1..100}; do
    if [[ -s "$temporary/port" ]]; then break; fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
        echo "Mock provider failed to start: $temporary/server.log" >&2
        exit 1
    fi
    sleep 0.05
done
if [[ ! -s "$temporary/port" ]]; then echo "Mock provider startup timed out" >&2; exit 1; fi
read -r port < "$temporary/port" || true
result=0
AIHUB_TEST_SERVER_URL="http://127.0.0.1:$port" ./scripts/test.sh --filter "TransportIntegrationTests|SDKLoopbackTests" || result=$?
if [[ "$result" -ne 0 ]]; then
    cp "$temporary/server.log" .build/mock-provider-last-error.log
    echo "Mock server diagnostics: .build/mock-provider-last-error.log" >&2
fi
exit "$result"
