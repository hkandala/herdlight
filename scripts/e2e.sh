#!/usr/bin/env bash
# Run a command (the UI tests) against two throwaway herdr sessions and the e2e helper, and remove
# the sessions after, even when the command fails.
# Usage: scripts/e2e.sh <command>...
set -euo pipefail
cd "$(dirname "$0")/.."
# Inside a herdr pane these point at the user's own session; keep them out of herdr and the helper.
unset "${!HERDR_@}"

id=$(openssl rand -hex 3)
one=hl-e2e-$id-a
two=hl-e2e-$id-b
# Each trap only after its session is up: a failed `up` must not remove a session it did not make.
scripts/herdr-session.sh up "$one"
trap 'scripts/herdr-session.sh down "$one"' EXIT
scripts/herdr-session.sh up "$two"
trap 'scripts/herdr-session.sh down "$one" || true; scripts/herdr-session.sh down "$two"' EXIT

# The sandboxed test runner cannot reach herdr; the helper serves it on localhost while the tests run.
python3 scripts/e2e-helper.py "$one" "$two" -- "$@"
