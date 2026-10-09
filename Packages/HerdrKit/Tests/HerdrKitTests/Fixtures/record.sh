#!/usr/bin/env bash
# Re-record the fixtures from a throwaway session with a known layout.
# Usage: Packages/HerdrKit/Tests/HerdrKitTests/Fixtures/record.sh
set -euo pipefail
cd "$(dirname "$0")"
unset "${!HERDR_@}"
session=hl-dev-fixtures-$(openssl rand -hex 3)
scripts=../../../../../scripts
"$scripts/herdr-session.sh" up "$session"
trap '"$scripts/herdr-session.sh" down "$session"' EXIT

call() { # method params → result
    printf '{"id":"1","method":"%s","params":%s}\n' "$1" "$2" | herdr --session "$session" remote-api-bridge
}

# w1 t1: p1 | (p2 / (p3 | p4)), w1 t2: one pane.
call workspace.create '{"label":"one","cwd":"/tmp","focus":false}' >/dev/null
call pane.split '{"target_pane_id":"w1:p1","direction":"right","ratio":0.6,"cwd":"/tmp","focus":false}' >/dev/null
call pane.split '{"target_pane_id":"w1:p2","direction":"down","cwd":"/tmp","focus":false}' >/dev/null
call pane.split '{"target_pane_id":"w1:p3","direction":"right","ratio":0.3,"cwd":"/tmp","focus":false}' >/dev/null
call tab.create '{"workspace_id":"w1","label":"second","cwd":"/tmp","focus":false}' >/dev/null
# w2 t1: (p1 | p3) / p2, w2 t2 and t3: one pane each.
call workspace.create '{"label":"two","cwd":"/tmp","focus":false}' >/dev/null
call pane.split '{"target_pane_id":"w2:p1","direction":"down","cwd":"/tmp","focus":false}' >/dev/null
call pane.split '{"target_pane_id":"w2:p1","direction":"right","cwd":"/tmp","focus":false}' >/dev/null
call tab.create '{"workspace_id":"w2","cwd":"/tmp","focus":false}' >/dev/null
call tab.create '{"workspace_id":"w2","cwd":"/tmp","focus":false}' >/dev/null
# An agent that finished once (completion_seq set) and one that is working (null).
report() { call pane.report_agent "{\"pane_id\":\"$1\",\"source\":\"user:fixtures\",\"agent\":\"pi\",\"state\":\"$2\"}" >/dev/null; }
report w1:p1 working
report w1:p1 idle
report w2:p2 working

call session.snapshot '{}' | jq . >snapshot.json
call ping '{}' | jq . >ping.json
call layout.export '{"tab_id":"w1:t1"}' | jq . >layout-export.json
herdr session list --json | jq --arg s "$session" '.sessions |= map(select(.name == $s or .name == "default"))' >session-list.json
