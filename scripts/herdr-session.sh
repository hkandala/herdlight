#!/usr/bin/env bash
# Start or remove a throwaway headless herdr session.
# Usage: scripts/herdr-session.sh up|down <hl-e2e-*|hl-dev-*>
set -euo pipefail

usage="usage: $0 up|down <hl-e2e-*|hl-dev-*>"
cmd=${1:?$usage}
name=${2:?$usage}
case $name in
hl-e2e-* | hl-dev-*) ;;
*) echo "refusing '$name': only hl-e2e-* and hl-dev-* sessions are throwaway" >&2 && exit 2 ;;
esac
# Inside a herdr pane these point at the user's own session; keep them out of the server.
unset "${!HERDR_@}"

exists() {
    local list
    list=$(herdr session list --json) || exit 1
    grep -qF "\"name\":\"$name\"" <<<"$list"
}

case $cmd in
up)
    exists && echo "refusing '$name': it already exists" >&2 && exit 1
    log="${TMPDIR:-/tmp}/herdr-$name.log"
    nohup herdr --session "$name" server >"$log" 2>&1 &
    pid=$!
    for _ in $(seq 50); do
        herdr --session "$name" workspace list >/dev/null 2>&1 && exit 0
        sleep 0.1
    done
    kill "$pid" 2>/dev/null || true
    herdr session delete "$name" >/dev/null 2>&1 || true
    echo "herdr session '$name' did not start:" >&2 && cat "$log" >&2 && exit 1
    ;;
down)
    exists || exit 0
    herdr session stop "$name" >/dev/null 2>&1 || true
    for _ in $(seq 50); do
        herdr session delete "$name" >/dev/null 2>&1 && exit 0
        sleep 0.1
    done
    echo "herdr session '$name' did not stop" >&2 && exit 1
    ;;
*) echo "$usage" >&2 && exit 2 ;;
esac
