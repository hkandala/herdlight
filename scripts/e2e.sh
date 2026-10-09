#!/usr/bin/env bash
# Run a command (the UI tests) against two throwaway herdr sessions and the e2e helper, and remove
# them after, even when the command fails.
# Usage: scripts/e2e.sh <command>...
set -euo pipefail
cd "$(dirname "$0")/.."

id=$(openssl rand -hex 3)
one=hl-e2e-$id-a
two=hl-e2e-$id-b
helper=
up_two=
cleanup() {
    if [ -n "$helper" ]; then kill "$helper" 2>/dev/null || true; fi
    scripts/herdr-session.sh down "$one" || true
    if [ -n "$up_two" ]; then scripts/herdr-session.sh down "$two" || true; fi
}
# The trap only after the first session is up: a failed `up` must not remove a session it did not make.
scripts/herdr-session.sh up "$one"
trap cleanup EXIT
scripts/herdr-session.sh up "$two"
up_two=1

# The sandboxed test runner cannot reach herdr; it asks this helper on localhost instead.
ports=$(mktemp)
python3 scripts/e2e-helper.py "$one" "$two" >"$ports" &
helper=$!
# Up to 30 s: the first python3 run on a fresh CI runner is slow.
for _ in $(seq 300); do
    [ -s "$ports" ] || ! kill -0 "$helper" 2>/dev/null && break
    sleep 0.1
done
port=$(head -n1 "$ports")
rm -f "$ports"
[ -n "$port" ] || { echo "the e2e helper did not start" >&2 && exit 1; }

# xcodebuild passes TEST_RUNNER_* to the tests without the prefix.
TEST_RUNNER_HL_SESSION=$one TEST_RUNNER_HL_SESSION2=$two TEST_RUNNER_HL_HELPER=http://127.0.0.1:$port "$@"
