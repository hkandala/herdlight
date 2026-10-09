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
# Listed but stopped, for "Show stopped".
three=hl-e2e-$id-c
# Made by the app's New Session.
four=hl-e2e-$id-d
# A session joins the cleanup only once it is up: a failed `up` must not remove a session it did not make.
made=("$four")
trap 'for s in "${made[@]}"; do scripts/herdr-session.sh down "$s" || true; done' EXIT
for s in "$one" "$two" "$three"; do
    scripts/herdr-session.sh up "$s"
    made+=("$s")
done
herdr session stop "$three" >/dev/null

# The sandboxed test runner cannot reach herdr; the helper serves it on localhost while the tests run.
python3 scripts/e2e-helper.py "$one" "$two" "$three" "$four" -- "$@"
