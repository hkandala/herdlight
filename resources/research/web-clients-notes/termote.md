# termote (lamngockhuong/termote) — research notes

Repo: /tmp/herdr-research/termote (HEAD 5ed54e8). One Go binary (`server/`, ~120k LOC incl. tests) +
React 19 PWA (`pwa/`, xterm.js 6). Backends: `tmux` or `herdr` (`TERMOTE_MUX=herdr`, `termote start --mux herdr`).
Written against **herdr 0.9.1, protocol 22** (`server/herdr_rpc.go: const herdrProtocol = 22`); a mismatch only
reports "degraded" health. Features gated on herdr version (`agent.start` ≥0.8.2, worktrees ≥0.9.2).

## 1. Server / bridge architecture & transport

- Go `net/http` server, runs on the herdr host and serves the PWA + a JSON REST API + one WebSocket.
  Middleware chain (`server/serve.go` `buildServer`): `hostGuard` (Host allowlist) → `securityHeaders` (CSP)
  → `writeGuard` (cross-site write check via `Sec-Fetch-Site`/Origin) → `basicAuth` → mux.
- **Auth**: one user/password (`TERMOTE_USER`/`TERMOTE_PASS`). HTML sign-in form for browsers, Basic auth
  for curl. Success → `termote_session` cookie (HttpOnly, SameSite=Strict, 24 h, max 256 sessions, LRU). Rate
  limit per IP (and per /64 for IPv6). With herdr, `--no-auth` is refused unless `TERMOTE_HERDR_ALLOW_NO_AUTH=true`
  ("herdr exposes every workspace").
- **WebSocket** `GET /api/mux/stream?token=&pane=&cols=&rows=[&drive=1]` (`server/stream.go`, lib `coder/websocket`).
  The token comes from `POST /api/mux/stream-token`: **single-use, 30 s** (`newStreamTokenStore`), so the
  URL never holds a long-lived secret. Origin is checked against the allowlist. Max 8 streams server-wide;
  the oldest is evicted with close code **4001** ("do not auto-reconnect", so two devices don't loop).
  Ping every 15 s, drop after 15 s with no pong, 10 s write timeout.
  - binary frames both ways = terminal bytes (out) / raw input bytes (in)
  - text frames = JSON control: client→server `{"type":"resize","cols","rows"}`, `{"type":"drive","on":true}`;
    server→client `{"type":"size","cols","rows","driving":bool,"reason":"taken-over"|"failed"}`,
    `{"type":"exit","code":n}`, `{"type":"error","message":...}`.
- Everything else is plain REST polling (no SSE): `/api/mux/snapshot`, `/api/mux/tabs[/{id}]`,
  `/api/mux/panes/{id}` (DELETE), `/panes/{id}/keys`, `/panes/{id}/scroll`, `/panes/{id}/agent/{transcript,prompt,message,answer,start,commands}`,
  `/panes/{id}/files/{tree,content,raw,find,changes,diff,create,delete,restore}`, `/api/mux/uploads`,
  `/api/mux/push/{key,subscribe}`, plus group and worktree routes.
- **Tunnels**: no custom tunnel. Tailscale helper (`server/tailscale.go`) runs
  `tailscale serve --bg --https=<tsPort> http://127.0.0.1:<port>` (no sudo), and `tailscale serve --https=<p> off`.
  The CLI prints Tailscale / LAN / localhost URLs and a QR code (`rsc.io/qr`).
- **herdr plugin** (`herdr-plugin/herdr-plugin.toml`, min herdr 0.7.4): a `[[panes]]` popup
  (`placement="popup"`, `command=["sh","bin/termote.sh","panel"]`) shows the status, URLs and a QR code, and
  `[[actions]]` (`contexts=["pane","workspace"]`) run `termote url --herdr --open|--copy`, start/stop/restart.
  The deep link is built from env vars that herdr sets for plugin commands: `HERDR_WORKSPACE_ID`, `HERDR_TAB_ID`,
  `HERDR_PANE_ID` (`server/cli_url.go:175`) → `#/s/<group>/<tab>/<pane>`.

## 2. herdr socket methods / CLI used

Transport (`server/herdr_rpc.go`): Unix socket (`$HERDR_SOCKET_PATH`, otherwise `$XDG_CONFIG_HOME/herdr/…`;
a named pipe on Windows). NDJSON, **one request per connection** (except `events.subscribe`):
```json
→ {"id":"17","method":"pane.get","params":{"pane_id":"w1:p3"}}\n
← {"id":"17","result":{...}}   or   {"id":"17","error":{"code":"pane_not_found","message":"..."}}
```
Limits they found: requests ≥1 MiB are rejected (text chunks are 128 KiB, split on UTF-8 boundaries). Replies are
capped at 16 MiB (a busy `session.snapshot` is ~100 KiB). Error codes ending in `_not_found` are mapped to 400.

| method | params | used for |
|---|---|---|
| `ping` | – | `{version, protocol}` health and version gating |
| `session.snapshot` | – | the whole tree (cached, see below) |
| `events.subscribe` | `{"subscriptions":[{"type":"pane.created"},…,{"type":"pane.agent_status_changed","pane_id":"w1:p2"}]}` | cache invalidation and pane sizes |
| `pane.get` | `{pane_id}` | `agent`, `agent_status`, `agent_session{agent,kind:"id",value}`, `cwd`, `foreground_cwd`, `scroll{offset_from_bottom,max_offset_from_bottom}` |
| `pane.process_info` | `{pane_id}` | foreground process name and pids (≥0.9.3); "is idle shell" check |
| `pane.read` | `{pane_id, source:"visible", format:"ansi"}` → `{read:{text}}` | screen capture with SGR, used to parse agent dialogs |
| `pane.send_text` | `{pane_id, text}` | ALL input (keys, paste, wheel reports) as raw bytes |
| `pane.scroll` | `{pane_id, offset_from_bottom}` | scrollback (shared view) |
| `pane.close` | `{pane_id}` | |
| `tab.create` | `{workspace_id?, label?, focus:false}` → `{tab:{tab_id}}` | |
| `tab.close` / `tab.rename` | `{tab_id}` / `{tab_id,label}` | |
| `workspace.create` | `{label, cwd?, focus:false}` → `{workspace:{workspace_id}}` | |
| `workspace.close` / `workspace.rename` | `{workspace_id}` / `{workspace_id,label}` | |
| `worktree.list/create/open/remove` | `{workspace_id, branch, focus:false, …}` | |
| `agent.start` | `{pane_id, kind, name, args, timeout_ms}` | start claude/codex in an idle-shell pane |
| `agent.get` | `{target: pane_id or alias}` → `{agent:{agent,name,agent_status,launch_pending,interactive_ready}}` | start progress |

Event types subscribed (`mux_herdr.go:45`): `workspace.{created,updated,renamed,moved,reordered,closed,focused}`,
`tab.{created,closed,focused,renamed,moved}`, `pane.{created,closed,updated,focused,moved,exited,agent_detected}`,
`layout.updated`, `worktree.{created,opened,removed}` (only on herdr versions that know them: an unknown type makes
herdr **reject the whole subscription**), and per pane `pane.agent_status_changed` (this one needs a `pane_id`, so they
**resubscribe** when the pane set changes; bursts are debounced 200 ms). Event line shape: `{"event":"…","data":{"layout":{tab_id,focused_pane_id,panes:[{pane_id,rect:{x,y,width,height}}]}}}`.
Reconnect with backoff 250 ms→30 s. Any event just invalidates the snapshot cache (they never apply deltas). The cache
is also refetched after 30 s in case an event was missed. While the subscription is down, every request fetches fresh.

**CLI** (not socket) for streaming (`server/herdr_stream.go`):
```
herdr terminal session observe <pane> --cols C --rows R
herdr terminal session control <pane> --takeover --cols C --rows R
```
stdout is NDJSON: `{"type":"terminal.frame","bytes":"<base64>"}` and `{"type":"terminal.closed","reason":"…"}`
(reason `"terminal attach taken over"` = another client took control). For `control`, stdin takes
`{"type":"terminal.resize","cols":C,"rows":R}`; closing stdin gives the PTY back its desktop size.
Pane IDs are checked with `^w[0-9A-Za-z]+:p[0-9A-Za-z]+$`, so an ID can never be read as a `-flag`.

`session.snapshot` subset they read: `workspaces[{workspace_id,number,label,active_tab_id,worktree{repo_key,is_linked_worktree}}]`,
`tabs[{tab_id,workspace_id,number,label}]`, `panes[{pane_id,tab_id,terminal_title_stripped,agent,agent_status,cwd,foreground_cwd}]`,
`layouts[{tab_id,focused_pane_id,panes[{pane_id,rect}]}]`. Agent statuses: `idle|working|blocked|done|unknown`.

## 3. Live terminal streaming

- One herdr CLI child process per WS stream. Its frames are **rendered screen output from herdr, not raw PTY
  bytes**: "the first one of each process clears and redraws the whole screen" (comment in `herdr_stream.go`). The server
  just base64-decodes each frame and writes it into the WS as binary. No polling and no diffing on their side; herdr does it.
- Two modes:
  - **observe** (default): fixed at the pane's desktop size. When `layout.updated` changes the pane rect, the observer is
    **killed and restarted** at the new size (a size frame is sent first, so the client resizes before any bytes at the new size arrive).
  - **control/drive** (setting "Fit herdr pane to this device"): `control --takeover` at the client's size, which
    resizes the real PTY. Later resizes go through stdin. If another client takes over → back to observe with
    `reason:"taken-over"`. Mode switches are rate-limited to one per 500 ms.
- Renderer: **xterm.js 6 + addon-fit** (`pwa/src/components/terminal-view.tsx`). In observe mode the grid is fixed
  (server cols×rows). The font size is computed so the grid fits (`fitFontSize`), and "zoom" = ±1 px per step. A grid bigger
  than the screen pans with the finger.
- **No client scrollback**: observe only sends screen frames, so scroll goes to herdr's **shared** view through `pane.scroll`
  (read `pane.get` scroll first, then set an absolute offset, under a mutex). If `max_offset_from_bottom==0` and the pane is an agent
  (Claude fullscreen / alt screen), they send **SGR wheel reports** `\x1b[<64;x;yM` (up) / `65` (down), max 50, through send_text.
  Scrolling down past the limit sends Ctrl+End `\x1b[1;5F` to Claude ("jump to bottom").
- Input: WS binary → per-pane `paneWriter` queue → `pane.send_text`. They **serialize per pane** because
  concurrent send_text calls arrived out of order ("measured 59 of 300"). Input queued during an in-flight call is merged into the next call. Queue cap 1 MiB.

## 4. Layout model

- Flattened, not a split tree: Group=workspace, Tab=tab, Pane=pane. Panes inside a tab are **sorted top-left first by
  layout rect (y, then x)**. Rects are used only for ordering and for each pane's cols/rows.
- The UI shows **one pane at a time**: a sidebar of groups→tabs (`session-sidebar.tsx`), tabs (`session-tabs.tsx`), and a
  horizontal `PaneStrip` of buttons (status badge + label + command) when a tab has more than one pane.
- `SelectTab` returns `errUnsupported` on purpose: "switching tab on the PWA must not change what the desktop shows". Focus is
  client-side only (`Caps.ClientSideSelect`). Creating tabs/workspaces always passes `focus:false`.
- No pane split, resize or move from the UI (no `pane.split` call found). Close pane/tab/workspace, rename, create, and worktrees are supported.
- PWA polls `/api/mux/snapshot` every `pollInterval` s (setting, default **5 s**). The server answers from its event-invalidated cache, so polling is cheap.

## 5. Chat view

**Data source = the agent's own transcript JSONL, not screen parsing** (`server/agent.go`, `agent_claude.go`, `agent_codex.go`).
- herdr gives the session id: `pane.get` → `pane.agent_session {agent:"claude", kind:"id", value:<uuid>}`. They check
  `agent_session.agent == pane.agent` because herdr keeps a stale session after another agent replaces it.
- Claude: `$CLAUDE_CONFIG_DIR|~/.claude/projects/*/<id>.jsonl` (the path must resolve inside the dir).
- Codex: herdr's id may come from the app-server daemon (it can belong to another pane), so they **scan processes**
  for a Codex process that holds that rollout open (`agent_proc_codex.go`, `/proc` or `sysctl kern.proc.all`). Only a `--no-daemon` TUI is trusted.
- API `GET /panes/{id}/agent/transcript?cursor=|before=` → `{agent,sessionId,status,entries[],cursor,before,reset}`.
  Entry `{id,ts,role:user|assistant|summary|note,parts:[{kind:text|thinking|tool|image,text,tool,toolId,input,result,isError,orphan,clipped,detail{description,command,edits[{old,new}]}}]}`.
  Tail read: the window doubles from 256 KiB up to 8 MiB until 200 entries are found. Lines >2 MiB are clipped. **The cursor is an HMAC-signed `{session, byte offset, file inode}`**,
  so the client can only send back positions the server issued, and file rotation is detected (→ `reset:true`). Tool results are folded into their calls by toolId.
  The client polls every **1.5 s** while visible (backoff on errors). Server responses are cached 500 ms (`ttlCache`), so N clients cost one read.
- **Sending a message** (`POST /agent/message {text, cursor, images[]}`): rule "write only on positive evidence":
  1. the session id must still match the cursor's session (else `409 session_changed`)
  2. herdr status must be `idle|done` (they never queue into a working agent)
  3. `pane.read` ansi → parse: the input box must be **empty** (draft or dialog → 409 `input_not_ready`)
  4. bracketed paste `\x1b[200~…\x1b[201~` via one `pane.send_text`
  5. poll the screen (100 ms, up to 2 s) until the draft shows the text
  6. re-check the session, then send `\r` (Enter)
  7. poll until the box is cleared, else `502 delivered_not_submitted`.
  Images: uploaded first (`/api/mux/uploads`, 10 MB). Each file **path** is pasted alone and they wait for Claude to turn it into
  its `[Image #n]` token. If it fails, they clear the box with C-c only when it holds only their own paste.
- **Approvals/dialogs**: `GET /agent/prompt` captures the screen with `pane.read` and parses it with pure functions over SGR-tagged rows
  (`agent_claude_prompt.go`, `agent_codex_prompt.go`). Faint text = ghost suggestion, background = the selected tab, reverse video = Codex pointer.
  These parsers are checked against ~100 recorded screens in `server/testdata/{claude,codex}/screens/*.txt` (pinned versions 2.1.286/2.1.288, Codex 0.159/0.160).
  Card shape: `{promptId, kind:permission|select|multiselect|unsupported, title, body, options[], steps[], freeText{index,label}}`.
  Client poll: 1 s while `blocked|working`, 4 s otherwise.
  Answer `POST /agent/answer {promptId, choice}`: the promptId is single-use (60 s TTL) and bound to pane+session+screen signature.
  The dialog must still be on screen with the same signature, and status must be `blocked`. Then they send a digit key (or, for questions with
  previews: digit → wait for the pointer to move → Enter) and poll until the signature changes. Answered signatures are held 3 s, so a
  second device cannot answer the *next* dialog by mistake. Only these keys are allowed: `Enter Escape C-c Left Right Up Down 1-9`.
- Slash commands list (`agent_commands*.go`) is read from `~/.claude` commands, skills and `installed_plugins.json` + settings `enabledPlugins`.

## 6. Multi-host

None. One server = one host = one herdr socket. For another machine you run another termote and open its URL (each one is its own
PWA origin). Deep links are only `#/s/<ws>/<tab>/<pane>[?view=chat|files|…]` (`pwa/src/utils/deep-link.ts`).

## 7. Mobile UX

- Keyboard toolbar (`keyboard-toolbar.tsx`): Tab, Esc, sticky Ctrl/Shift modifiers, arrows, Bksp, PgUp/PgDn, Ins, Ctrl-combos
  (C D Z L A E B X K U W R P N), a ⚡ quick-actions menu (Clear, Cancel, Clear line, Exit), and a paste button (long-press paste does not work on iOS Safari).
- Gestures (`use-gestures.ts`, docs `usage/gestures.mdx`): swipe left = Ctrl+C, swipe right = Tab, vertical drag = scroll
  with momentum, long-press = paste, pinch = font size (6–24 px). There is a first-run gesture hint overlay. Haptics (`use-haptic.ts`).
- Command history dropdown (localStorage), `use-keyboard-visible`/`use-viewport` for the iOS on-screen keyboard, iPad window detection.
- No voice input found (grep for speech/voice: nothing).
- Swipeable sidebar items (`swipeable-session-item.tsx`) for close/rename.

## 8. Push notifications

- **Own Web Push implementation** (`server/webpush.go`: RFC 8291 aes128gcm + VAPID ES256, only Go stdlib crypto). Keys are stored in
  `<state>/push/vapid.json`, subscriptions in `subscriptions.json` (dir 0700, symlinks refused). Subscriptions are bound to the current credential "gen", so a password change drops them.
- Trigger (`push_watch.go`): the server polls its own cached snapshot **every 5 s** and computes per-pane agent status transitions:
  `→blocked` ⇒ "Agent needs you". `working→done|idle` ⇒ "Agent finished". The first sighting raises nothing. A pane that disappears is forgotten.
  The same rule is used in the PWA (`utils/agent-notify.ts`) for in-page notifications. Both are checked against `testdata/agent-transitions.json`.
- The payload holds **ids only** `{groupId,tabId,paneId,kind}`. The service worker (`pwa/public/notify-sw.js`) fetches
  `/api/mux/snapshot?peek=1` with the cookie to build the title and body, so no names go through Apple/Google push servers.
  Click → `postMessage({type:'termote-open',hash:'#/s/…'})` to an open window, or `openWindow`.
- Hardening: 4 sends in parallel, a 5 s timeout, per-push-service backoff (Retry-After / 1 min), and Topic (collapse key) derived from a key.

## 9. Persistence

- Server state: `$XDG_STATE_HOME/termote` (`~/.local/state/termote`): `termote.pid`, `termote.log`, `push/`, uploads dir, trash
  dir (deleted files can be restored). Config: `config.json` in the config dir (user/pass/port/etc.).
- In memory only: stream tokens, sessions (24 h, lost on restart), promptIds, transcript cursor HMAC key (a restart invalidates cursors → client reloads).
- PWA localStorage: settings (pollInterval, drive size, theme, UI style), font size, command history, collapsed groups/sidebar,
  **per-tab icon + description metadata** ("the mux only stores tab names"), last selection per backend, update-check cache.
- Nothing about herdr's layout is stored. herdr is the source of truth.

## 10. Clever things to copy / pitfalls

Clever:
- `herdr terminal session observe|control` gives a ready-made rendered stream with resize. There is no need to read the PTY yourself. A native client can
  run the same CLI over SSH, or (guess) speak the same stream over the socket if herdr exposes it.
- observe vs control/takeover split: watch at the desktop size without disturbing the desktop. Take over the size only when the user wants it. Handle `taken-over`.
- Announce the size before the bytes at that size. Restart the observer when the layout changes.
- Serialize `pane.send_text` per pane (herdr can reorder concurrent calls) and merge queued input into one call.
- Bracketed paste for chat input. Wait for the draft to show on screen before sending Enter. Re-check the session id and status right before Enter.
- Chat from the transcript JSONL keyed by herdr's `agent_session`. Use the screen only for dialogs/approvals. Bind answers to a screen signature.
- Scroll: use `pane.scroll` for the normal screen and SGR wheel reports for alt-screen agents.
- Push payload with ids only, and the client fetches the names. Transition rule shared between server and client, with a test vector file.
- Never change the desktop focus from the remote client (`focus:false`, no `tab.focus`).
- Event subscription only invalidates a cache. Use a TTL as a safety net. Resubscribe when the pane set changes (for per-pane `agent_status_changed`).

Pitfalls they hit:
- An unknown event type in `events.subscribe` makes herdr reject the whole subscription → gate subscriptions on the version.
- Requests ≥1 MiB are rejected → chunk text.
- herdr keeps a stale `agent_session` after the agent changes. For Codex, the session id can come from the daemon (another pane's).
- `agent.start` keeps `launch_pending` until its deadline, even when the command exits at once. `agent.get` clears an expired one.
- Screen parsers break with every Claude/Codex UI change → pinned recorded screens; anything not recognised = "unsupported", read-only.
- Observe has no client scrollback. A plain shell must not get wheel reports (it would echo them).
- Windows: process_info reports only known agents as foreground → walk the children.

## Lessons for our app

Copy:
1. Streaming: run `herdr terminal session observe <pane> --cols --rows` (and `control --takeover` for "fit to this device") and
   feed the frames into a terminal view (SwiftTerm or a Ghostty-based renderer). Over SSH for remote hosts (guess: simplest, no server to install).
2. Socket client: NDJSON, one request per connection, a long-lived `events.subscribe` that only invalidates a `session.snapshot` cache,
   rect-based pane order, version gating via `ping`.
3. Input: one serial queue per pane → `pane.send_text`, bracketed paste for chat, raw bytes from a key bar.
4. Chat view: tail the transcript JSONL located via `pane.get.agent_session`, with offset cursors. Approvals via `pane.read ansi` + a small parser
   with recorded screen fixtures; show unknown dialogs read-only and offer "open terminal".
5. Notifications from `pane.agent_status_changed` transitions (blocked / working→done). Locally that is native UNUserNotification. iOS remote push
   needs a relay (APNs), so (guess) start with the app in the foreground/background + local notifications only.
6. Never steal desktop focus. Use `focus:false` everywhere.

Avoid / do differently:
- Their one-pane-at-a-time UI and no split/resize. Our design needs split rects (the `layouts[].panes[].rect` is already in the snapshot) and `pane.*` move/resize methods.
- A web server + password auth + Tailscale serve stack is not needed for a native app. SSH (or a forwarded Unix socket) gives auth for free.
- Don't store per-tab metadata in the client (they store icons in localStorage). Our web-pane URL should live in herdr (pane title/label) as the brief says.
- Screen-parsing approvals is high-maintenance (~100 fixture screens). Keep it minimal and degrade to the terminal view.
