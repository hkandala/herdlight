# Phase 2: HerdrKit control plane

Goal: HerdrKit can find herdr, list sessions, call methods, stream events, pace snapshot
reads and rebuild split trees, tested against recorded JSON and a real throwaway session.

Read first: [talking-to-herdr](../../docs/content/docs/talking-to-herdr.mdx),
[layout](../../docs/content/docs/layout.mdx), [data](../../docs/content/docs/data.mdx),
`resources/research/herdr-core.md`, herdr-web `server/herdr.ts` and
`server/session-hub.ts`.

## Build

1. **`Exec`** (the design's one protocol) and **`ProcessExec`** (macOS): run argv, give
   back stdout as an async byte/line stream, a stdin writer, exit status and stderr.
   - Login-shell environment once at launch: `$SHELL -lic` with a unique marker, stdin from
     `/dev/null`, 3 s timeout, read `PATH`, `SSH_AUTH_SOCK`, `XDG_CONFIG_HOME`,
     `XDG_STATE_HOME`; fallback PATH from the design. Strip `HERDR_*` from children.
   - Children are killed by pid on cancel and on app quit.
   - Skip the SSH prefix and the base64 envelope: This Mac only. (`ponytail:` note.)
2. **Finding herdr**: resolve the binary path as the design says, check
   `remote-api-bridge --check` = `herdr-api-bridge-v1`, `ping` ≥ 0.9.3 (refuse older with a
   clear error).
3. **`HerdrClient`** for one session:
   - `call(method, params) async throws -> JSON result` via
     `herdr --session S remote-api-bridge`, one request per run, 10 s timeout that kills
     the process. herdr errors become a typed error with code and message.
   - `sessions()` from `herdr session list` (parse its output, or JSON if it has a flag).
   - `snapshot()` → lenient models: `Snapshot`, `Workspace`, `Tab`, `Pane`, `Agent`,
     `Layout` (only fields the app uses: ids, labels, numbers, order, `terminal_id`,
     agent status, `completion_seq`, layouts).
   - `events()` → one long-lived `events.subscribe` bridge run with the design's
     subscription list; each line is just "changed". Resubscribe when the agent pane set
     changes, on `events_lost`, `pane_not_found`, or the process ending.
   - **Snapshot pacing**: one read in flight, 100 ms debounce, 500 ms max wait, one
     trailing read, an immediate read on request. Exposed as an `AsyncStream<Snapshot>`.
   - 30 s `ping` keepalive marks the session live or not.
4. **Split tree**: `SplitNode` (`.leaf(paneID)` / `.split(direction, ratio, first, second)`)
   rebuilt from `layouts[]` per the design's 15-line algorithm; leaf count mismatch →
   `layout.export` fallback.
5. **Check `terminal session` resolution**: does `herdr --session S terminal session
   control <id>` attach to session S, or does it need `HERDR_SOCKET_PATH`? Record the
   answer in this file; phase 4 uses it.
6. **Fixtures**: record `session.snapshot` JSON from a throwaway session with 2
   workspaces, several tabs, nested right/down splits, plus `ping` and `session list`
   output. Put them in `Tests/HerdrKitTests/Fixtures/`.
7. **Tests** (Swift Testing):
   - Unit: decoding (including unknown fields), split-tree rebuild (nested, single pane,
     mismatch), pacing (debounce, max wait, single flight, trailing read) with a fake
     clock or short real delays.
   - Integration (skipped unless herdr is on PATH): start a throwaway session, `ping`,
     `snapshot`, create a tab with `focus:false`, see an event arrive and a new snapshot
     contain it; stop and delete the session.

## Done when

- `make test` passes locally and in CI (integration tests run in CI too, herdr is
  installed there).
- Reviewers approve. No app UI changes in this phase.

## Out of scope

Terminal streams (phase 4), SSH, iOS transport, writes beyond what tests need.

## Findings

- **`terminal session` resolution.** `herdr --session S terminal session control|observe <id>`
  attaches to session S. Checked on a throwaway session with `HERDR_SOCKET_PATH` and
  `HERDR_SESSION` pointing at sockets that do not exist: `--session` wins over both (frame,
  then `terminal.closed` `detached` on release, exit 0). Without `--session`, the CLI follows
  `HERDR_SOCKET_PATH` (`failed to connect … /tmp/nope-client.sock`). So phase 4 passes
  `--session S` like every other argv; no socket path needed. (herdr-web needed the variable
  only because it left out `--session`.)
- **`FileHandle.bytes` stalls.** Reading two child pipes at once with `FileHandle.bytes`
  (macOS 27) never delivers the second child's output: a `session.snapshot` bridge run while
  the events stream was open got no reply. `ProcessExec` reads pipes with
  `readabilityHandler` instead (comment in `Exec.swift`).
- **Argv.** `herdr --session S session list --json` and `herdr --session default
  remote-api-bridge --check` both work, so every argv carries `--session`. A bridge run
  against a session that is not running exits 1 with `failed to connect to remote Herdr API
  socket …` on stderr; `call` throws that text as `.failed`.
- **Errors on the events stream** come as `{"id","error":{code,message}}` lines
  (`pane_not_found` when a subscribed agent pane is unknown). Any error line or the stream
  ending reopens it after 1 s, through a fresh snapshot so the agent pane list is current.
- **Fixtures** come from `Tests/HerdrKitTests/Fixtures/record.sh` (throwaway session, known
  layout, two agents faked with `pane.report_agent`). The integration test runs in CI's
  `test-e2e` job, which has herdr; the `build` job only builds.
