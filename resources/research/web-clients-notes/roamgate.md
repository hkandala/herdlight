# Roamgate (powerfooI/roamgate, a.k.a. herdr-studio / herdr-gui): research notes

Clone: `/tmp/herdr-research/roamgate` @ `4476392 Release 0.8.0`. Bun + TypeScript bridge (`server/`), React 19 + Vite
PWA (`web/`), plus `herdr-plugin.toml` (herdr plugin that starts/stops the service). About 190k LOC, roughly half of it tests.
Supports Herdr protocols 14–20 (0.7.0–0.8.2) and the **0.9.x stable "endpoint generation 1"** on `herdr-client.sock`.
Key docs: `docs/ARCHITECTURE.md`, `docs/DEPLOYMENT.md`, `docs/HISTORY.md`, `FEATURES.md`.

## 1. Server/bridge architecture & transport

```
Browser (React PWA) --same-origin HTTPS + one WebSocket /ws--> Bridge (Bun, single binary)
Bridge --node:net--> herdr.sock (NDJSON control)  +  herdr-client.sock (bincode binary "endpoint"/thin-client)
```
- The bridge exists because browsers can't open unix sockets. It also owns auth, SSH runtimes, git/file ops, Web Push,
  an embedded pi-based assistant ("Ranger"), and self-update.
- **Control socket client** `server/src/bridge/herdr-client.ts`: *one request per connection* (herdr reads a line, replies
  with a line, then closes). Envelope: `{"id","method","params"}\n` → `{"id","result"}` | `{"id","error":{code,message}}`.
  Subscriptions use one long-lived connection: `{"id":"sub","method":"events.subscribe","params":{"subscriptions":[{"type":"workspace.created"},…]}}`,
  then each event arrives as `{ "event": "<name>", "data": {..., "type": ...} }`. Max line 1 MiB, 8 s timeouts.
- **Browser↔bridge WS** (`server/src/index.ts:1468,1536`): JSON RPC `{id, method, params, connection_id, connection_generation}`
  → `{id,result}|{id,error}`; events are `{event:…}` tagged with connection identity. On open the server sends
  `{hello:true, bridge_protocol_version:2, default_connection_id, capabilities:{connection_id, file_reveal, embedded_assistant, herdr_task_notifications,…}}`.
  Most herdr methods are **passed straight through** (`connections/rpc-routing.ts`). `bridge.*`/`connections.*` are bridge-global.
- WS uses permessage-deflate only for terminal messages ≥1 KiB, with per-connection context (they cite WebKit compat).
  Backpressure (`bridge/websocket-send.ts`): limit 8 MiB. Full-repaint terminal frames carry a *coalesce key*, so under
  backpressure only the newest frame per terminal is kept and it is flushed on `drain`.
- **Auth** (`server/src/http/auth.ts`): a token or password is always required, even on loopback. The token is a
  64-hex secret in `~/.config/roamgate/auth-token`, or `ROAMGATE_PASSWORD`. A `?token=` URL param is exchanged for an
  HMAC-SHA256 signed cookie (`HttpOnly; SameSite=Lax`). Login has rate limits. Optional TLS via `ROAMGATE_TLS_CERT/KEY`.
- **Tunnels**: no built-in public tunnel. Docs recommend loopback plus your own reverse proxy, Tailscale, or SSH. For
  remote *herdr hosts*, see §6.
- Reconnect model: when a subscription is acked, the bridge emits a synthetic `session.resync_required` event and the
  browser re-snapshots (`workspace.list`/`pane.list`/`pane.layout`). An event that arrives during a refresh queues
  another refresh. ARCHITECTURE: "This reconciles missed changes, not an atomic or replayable event log."

## 2. Herdr socket methods / events used

Control socket (`herdr.sock`), from grepping server and web:
- Topology: `workspace.list|get|create|rename|close|focus|move`, `tab.list|create|rename|close|focus|move`,
  `pane.list|get|layout|split|resize|zoom|swap|close|focus_direction|process_info`, `popup.close`,
  `worktree.list|create|open|remove`, `ping`, `server.agent_manifests`, `integration.list`, `plugin.action.invoke`.
- Agents: `agent.list`, `agent.get {target: pane_id}`. `agent.list` items (verified against local 0.9.3):
  `{terminal_id, agent:"claude", agent_status:"idle|working|blocked|done", agent_session:{source:"herdr:claude", agent, kind:"id"|"path", value}, workspace_id, tab_id, pane_id, cwd, foreground_cwd, state_change_seq, completion_seq, revision, terminal_title, …}`.
- Input: `pane.send_input {pane_id, text, keys:["enter"]}` (Composer: herdr adds bracketed paste only if the PTY enabled
  it; `\n`→`\r` first, `web/src/terminalPaste.ts`), `pane.send_text {pane_id,text}`, `pane.send_keys {pane_id, keys:["ctrl+c"]}`.
- Read: `pane.read {pane_id, source:"recent", lines:120, format:"text", strip_ansi:true}` → `{read:{pane_id,workspace_id,tab_id,text,revision,truncated}}`
  (used only by the Ranger assistant's tool, with a 25 s timeout because herdr may restore an idle agent's viewport).
- Links: `pane.link.resolve` (0.9.1, returns visible regions; they never call `pane.link.activate`, which can run plugin handlers).
- Layout reply: `pane.layout {pane_id}` → `{layout:{workspace_id, tab_id, zoomed, area:Rect, focused_pane_id, panes:[{pane_id,focused,rect}], splits:[{id,direction:"right"|"down",ratio,rect}]}}`;
  `pane.resize {pane_id,direction,amount}` → `{resize:{layout}}`.
- Static subscription (`connections/runtime.ts:73`): `workspace.{created,updated,renamed,closed,focused,moved,reordered}`,
  `tab.{created,closed,renamed,focused}`, `pane.{created,closed,focused,moved,exited,agent_detected}`, `layout.updated`,
  `worktree.{created,opened,removed}`.
- **Gotcha**: `pane.agent_status_changed` is only delivered via *parameterized per-pane* subscriptions
  `{type:"pane.agent_status_changed", pane_id}`. `connections/agent-status-subscription.ts` keeps a second subscription
  socket for all panes with an `agent`. It rebuilds that subscription on membership events (`pane_agent_detected`,
  `pane_closed`, …, debounced 300 ms) and re-polls `pane.list` every 30 s.
- CLI is used only for `herdr integration status` (version fallback) and setup/bootstrap (`server/src/herdr/cli.ts`).

## 3. Live terminal streaming (the most interesting part)

They do **not** read raw PTY bytes and they do **not** poll `pane.read`. Each viewed terminal is a **herdr client
shell** on `herdr-client.sock`. Herdr renders the cells server-side and pushes them; the bridge re-encodes them as ANSI
for xterm.js.
- Framing (`bridge/bincode.ts`): `u32 LE length` + bincode-2 standard payload (varints: <251 is 1 byte; 0xfb/0xfc/0xfd
  mark u16/u32/u64; strings and vecs are length-prefixed; enums are varint tags).
- Endpoint gen 1 (`bridge/endpoint-client.ts`): ClientMessage tags `ClientShellResize=12, ClientShellPaneInput=13,
  ClientShellEndpointRequest=15, EndpointControl=20`. ServerMessage tags `Welcome=0, Clipboard=5, PaneSurface=13,
  SemanticNotification=14, ClientShellError=15, EndpointResponseChunk=18, PaneSurfacePatch=19, EndpointControl=20`.
  `EndpointControl` = `(kind: string, json: string)`.
  ```js
  hello = {generation:1, cell_width_px:0, cell_height_px:0, surface_size:{cols,rows}, pixel_mouse:false,
    direct_graphics:false, endpoint_keybindings:false, mouse_capture:false, surface_active:true,
    surface_delta:true, surface_reuse:true, snapshot_codecs:["shell.snapshot.v1"], surface_codecs:["shell.surface.v1"],
    input_codecs:["shell.input.semantic.v1"], blob_codecs:["shell.blob.v1"]}   // sent as kind "endpoint.hello.v1"
  ```
  The welcome (`endpoint.welcome.v1`) carries `methods[]` and `capabilities[]` (`pane.focus`, `pane.scroll`,
  `tab.create`, `workspace.create`, `health_check`, `surface_delta`, `surface_reuse`…). Next comes a `shell.snapshot.v1`
  JSON with `boot_id` and `revision` (topology). Endpoint RPC goes over the same socket:
  `ClientShellEndpointRequest(boot_id, JSON{id,method,params})`, and the reply arrives as chunked JSON.
- Attach flow (`bridge/endpoint-terminal-session.ts`): connect with the **tab** surface size → `lookupPaneId(terminal_id)`
  via `pane.list` → `callEndpoint("pane.focus",{pane_id})`. This scopes *this shell's* surface to that pane's tab, and
  gives per-client tab navigation. Then it waits for a surface that contains the pane.
- Surface = the whole tab: a cell grid (`CellData {symbol, fg, bg, modifier(ratatui bits), skip, hyperlink?}`, packed
  colors `0x00=indexed16 / 0x01=256 / 0x02RRGGBB`), plus `panes[] {pane_id, content_revision, rect, inner_rect,
  scroll{offset_from_bottom,max_offset_from_bottom,viewport_rows}, focused, mouse_reporting, alt_screen…}`, cursor,
  hyperlinks table, and an optional popup. Updates come as full `PaneSurface`, `PaneSurfacePatch`, or JSON-control
  `endpoint.surface-delta.v1` (base64 bincode against `base_revision`) / `endpoint.surface-reuse.v1`. Any revision
  mismatch closes the socket and reattaches for a fresh full frame.
- The bridge **crops `inner_rect` per pane** and `frameToAnsi()` (`bridge/frame-to-ansi.ts`) does a *full repaint*
  every time: `ESC[H ESC[2J ESC[?7l`, SGR runs, OSC 8 links, cursor shape `ESC[n q`. Source comment: "ponytail: full
  repaint per frame, no diffing. A 100x30 frame is ~20-60KB". Browser message:
  `{terminal:{terminal_id, width, height, full, link_frame?, mouse_reporting?, history?, bytes:<base64 ANSI>}}` → `xterm.write`.
  Identical repaints are skipped, using the `link_frame` identity.
- Renderer: `@xterm/xterm 6.1 beta` + fit, unicode-graphemes and clipboard addons. Kitty graphics are dropped.
- **Input** (`bridge/vt-input-classifier.ts`): the browser sends xterm's VT bytes as `terminal.input {data: base64}`. The
  bridge *classifies* them into semantic events and sends `ClientShellPaneInput(pane_id, [Key{code,char,mods,…} | TextCommit(text) | Mouse{kind,button,Cell(col,row),mods,lines}])`.
  Herdr then re-encodes for the target app's actual keyboard mode. They use basic CSI-u to disambiguate Ctrl+/ vs Ctrl+_, modified Enter, etc.
- Scroll: PageUp/PageDown are sent as semantic keys (herdr routes them by PTY mode). Explicit history uses endpoint
  `pane.scroll`, coalesced against `scroll.offset_from_bottom` feedback.
- Resize: `ClientShellResize(0,0,cols,rows,false)` with the tab size. **Pitfall**: "size follows Herdr's last-interacting
  client", so a phone and a desktop viewing the same tab fight over geometry.
- Legacy (<0.9, `bridge/thin-client.ts`): `Hello/AttachTerminal` on the same socket, "takeover" semantics (can kick
  another owner). Variant indices change between protocol versions, so they hard-code tables per protocol and reject
  unknown protocols (21, >22).
- Sharing: one shell per terminal_id is shared by all browser viewers (`SharedTerminalSession.viewers`). Each viewer
  gets the frame clipped to its own cols/rows.

## 4. Layout model

- Herdr is the source of truth. `pane.layout` returns **flat rects** (cells) plus `splits[]`. The web app positions
  `.pane-layout-cell` absolutely, using percentages of `area` (`web/src/App.tsx:~1210`). It does not build its own
  split tree. Zoomed or single-pane tabs render one full `TerminalView`.
- Layout cache per tab (`web/src/tabLayout.ts`) avoids a blank frame on tab switch. It is reused only if the pane set matches.
- Mobile: multi-pane tabs become a **one-pane-at-a-time switcher** with ‹ › buttons and a "Pane 2 / 3" label.
- Ops: split right/down, `pane.resize` by direction and amount, drag handle to `pane.swap`, `tab.move` reorder (0.7.2+),
  "Move pane" menu, Zen mode.
- Navigation is browser-local in endpoint mode (each shell has its own focused tab). Same-tab pane focus is still shared
  across clients.

## 5. "Chat" view / agent history

- This is **not** a chat UI that replaces the terminal. "Agent History" is a read-only side drawer, and input stays terminal-based.
- Data source: transcript files on disk, **not** screen parsing. `agent.get {target:pane_id}` → `agent.agent_session`
  `{kind:"id"|"path", value}` → resolve the file (`server/src/agent/session-resolver.ts`):
  codex `~/.codex/sessions/**/*<id>*.jsonl`, claude `~/.claude/projects/**/<id>.jsonl`, pi `$PI_CODING_AGENT_DIR` or
  `~/.pi/agent/sessions/...`, plus kimi/grok/muse/agy. For grok/agy/muse without an id they fall back to cwd matching.
  Over SSH they read files remotely (`session-file-access.ts`).
- Per-agent projections normalize to entries (user/agent/tool call/output/error). There is also ATIF/raw export and
  token usage (`agent/session-messages.ts`, `session-trajectory.ts`, `token-usage.ts`).
- Protocol `agent_history.get {history_version:2, cursor:{epoch,revision}}` → `snapshot {entries}` | `delta {base_revision,
  upserts, removed, order?}`. The window is the last 200 entries. Each change still does a full JSONL re-read on the
  server, with a cache of 16 sessions and 32 MiB. **Browser polls every 4 s while the drawer is open and visible**
  (`docs/HISTORY.md`).
- `agent.list` gets an extra `last_activity_at` from the session-file mtime (1.5 s budget), which is used for "idle"
  ordering.
- Input: the mobile **Composer** (textarea with IME, dictation, images, multiline) sends `pane.send_input {pane_id, text, keys: submit?["enter"]:[]}`.
  "Insert" doesn't execute and "Send" adds Enter. Drafts are in memory only, keyed `[connId, generation, paneId]`
  ("input can contain secrets", so never localStorage). A slash-command picker uses **static catalogs** per agent.
  Image paste or file drop uploads the file to the pane's host temp dir and inserts the quoted path.
- Approvals / permission prompts: **no dedicated detection or answer UI**. They rely on herdr `agent_status ==
  "blocked"` / `SemanticNotification needs_attention`. The user answers in the terminal or with shortcut keys.

## 6. Multi-host

- `ConnectionManager` with independent `ConnectionRuntime`s (`connections/manager.ts`, `runtime.ts`). Profiles live in
  `~/.config/roamgate/connections.json`. Each is local (socket paths) or SSH (`ssh_destination` = alias or `user@host`).
- SSH = one supervised OpenSSH process **forwarding both unix sockets** to a private temp dir (`bridge/ssh-command.ts`):
  `ssh -o BatchMode=yes -o StrictHostKeyChecking=yes … -o ExitOnForwardFailure=yes -o ServerAliveInterval=20
  -o StreamLocalBindUnlink=yes -o StreamLocalBindMask=0177 -N -L <local>/herdr.sock:<remoteHOME>/.config/herdr/herdr.sock -L …herdr-client.sock -- host`.
  Readiness = control `ping` + render handshake. 6 retries with backoff capped at 30 s. Auth/host-key errors are not
  retried. Git, file and transcript ops run as `ssh host <cmd>` on the remote.
- Every RPC, event and frame carries `connection_id + connection_generation`. Stale generations are rejected, so a
  reconnected host can't receive input meant for the old one. The browser lets you pick one active connection at a
  time (ConnectionSwitcher).
- Instance title suffix (`Roamgate · Work`) to distinguish multiple bridges as PWAs.

## 7. Mobile UX tricks

- Floating, draggable **2×8 shortcut grid** plus up to 4 side buttons. It snaps to the nearer edge, and its position is
  saved per browser. Defaults: `C-c C-d C-R A-Up ▲ PgUp / Esc Tab Enter Bksp ◀ ▼ ▶ PgDn`
  (`web/src/mobileTerminalShortcuts.ts:311`). It is user-customizable, with a US-keyboard picker for Ctrl/Alt/Shift + key.
- Input dock with a **Composer / Direct** mode toggle. Direct means a terminal tap opens the OS keyboard. By default,
  touching the terminal only scrolls and reads, with no keyboard popup. Swiping in the terminal scrolls even while the dock is open.
- Controls clamp to `visualViewport` above the keyboard, and the keyboard lift is transient (not saved).
- Long-press for selection (Copy / Add comment / link actions). Selection *freezes the displayed frame* until it is
  cleared. Long-press on a link → explicit "Open link" or "File actions".
- Voice: only via OS dictation in the Composer textarea (nothing custom).
- Layout: Automatic/Mobile/Desktop, with a 768 px breakpoint and a `?layout=` override.

## 8. Push notifications

- Web Push with VAPID (`server/src/notifications/web-push.ts`). Keys and subscriptions are in
  `~/.config/roamgate/web-push.json`. There is a provider allowlist (Apple, FCM, Mozilla, WNS), 10 s deadline,
  4 concurrent sends, a 256-item memory queue, TTL 5 min, no durable replay, and 404/410 prunes.
  The Service Worker is `web/public/task-notifications-sw.js`. iOS needs a Home Screen PWA (16.4+).
- Trigger (default `ROAMGATE_NOTIFICATION_SOURCE=herdr`): one **passive endpoint shell per runtime** (`surface_active:false`).
  Herdr never makes it foreground, but delivers `SemanticNotification` (tag 14) *after applying herdr's own policy*:
  `{kind: needs_attention|finished|update_installed|custom, title, body?, sound: done|request?, agent?, workspace_id?, tab_id?, pane_id?}`
  (`bridge/semantic-notification.ts`). Mapping: finished→completed, needs_attention→blocked, custom→by sound.
  Only this shell decodes tag 14, so the number of open viewers doesn't multiply alerts. `herdr notification show` also reaches it.
- Fallback `status` source: the bridge's own `working→blocked` and `working→done/idle` transition tracker from the
  per-pane status subscriptions. Startup snapshots are silent.

## 9. Persistence

- Bridge (`~/.config/roamgate/`, or `%APPDATA%\roamgate`): `auth-token`, `connections.json` (profiles),
  `settings.json` (per-connection terminal transport codecs, worktree hooks, auto-sync), `web-push.json`,
  `assistant/{auth.json, models.json, state.json, sessions/<uuid>.json, durable/<uuid>/execution.sqlite, tasks.sqlite}`,
  and the upload temp dirs (swept after 24 h). Repo-level `roamgate.json` holds worktree hooks.
- Git dir: a transient `roamgate-last-step-capture/` for "Last step" snapshots, which capture checkout state at
  agent active/idle boundaries so you can diff what one agent turn changed.
- Browser: localStorage (namespaced) for appearance, layout, shortcuts, pins, collapsed groups, agent order and mobile
  control position. Composer drafts stay in memory only. Herdr owns everything topological. Tab pins rely on herdr tab
  IDs surviving restarts.

## 10. Clever bits & pitfalls

Clever / worth copying:
- **Use herdr's endpoint (client-shell) protocol, not `pane.read` polling**: push-based, server-rendered cells, deltas,
  per-client tab focus, scroll metadata, OSC 8 links, cursor. A native client can render `CellData` grids *directly*,
  with no ANSI round-trip (Roamgate re-encodes to ANSI only because xterm.js wants a byte stream).
- One shell per tab (not per pane) is enough: the surface already contains all panes of the tab with `inner_rect`, so
  you crop locally. Roamgate opens one per *terminal*, which is a guess-worthy inefficiency for multi-pane tabs.
- Passive `surface_active:false` shell = free, herdr-policy-correct notifications.
- Semantic input (`ClientShellPaneInput` key/text/mouse events) instead of raw bytes, so herdr picks the right encoding
  per app mode. `TextCommit` is ideal for IME and paste.
- `pane.send_input {text, keys:["enter"]}` for chat-style submit (herdr handles bracketed paste).
- Transcript discovery via `agent_session {kind:id|path}` from `agent.list` (herdr already provides the path for pi
  and the id for claude/codex).
- Generation-stamped connection identity on every message, to avoid sending input to a replaced host.
- Coalesce full-frame repaints under backpressure (keep the latest only).
- SSH forwarding of both unix sockets with `StreamLocalBindUnlink` (no remote agent install needed).

Pitfalls they hit:
- Herdr wire enums are **positional** and were renumbered across versions (0.8.2, 0.9.0). Pin to endpoint generation 1,
  validate codecs, and fail closed on unknown generations.
- Revision/baseline mismatches on deltas must trigger a reconnect and a full frame. Never keep stale output.
- Geometry is shared: last-interacting client wins the tab size. Phone and desktop on the same tab will thrash
  (no known fix; a guess: show a "resize to this device" action).
- `pane.agent_status_changed` needs per-pane subscriptions plus membership tracking.
- Control RPC is one connection per request, so don't try to pipeline on one socket.
- OSC 52 clipboard has no source-pane attribution in 0.9.0. They gate it to the browser that typed in the last 30 s.
- Selection on a constantly repainting grid: freeze presentation during selection.
- Transcript projection re-reads whole JSONL files (no byte cursor). That's fine at 4 s polling, but costly for huge
  sessions. A guess: tail by byte offset instead.
- Massive over-engineering (lease/generation checks everywhere, about 50% tests) is the cost of the web-bridge
  approach. A native app talking to the sockets directly (or over SSH-forwarded sockets) removes the bridge layer entirely.

## Lessons for our app

- Copy: talk directly to `herdr.sock` (NDJSON, one request per connection, plus one `events.subscribe` stream) and to
  `herdr-client.sock` endpoint gen 1 (bincode, `endpoint.hello.v1`, `pane.focus` to scope, PaneSurface/Patch/delta). In
  Swift, implement a small bincode varint reader and render the cell grid natively (CoreText/Metal grid), without
  xterm.js and without ANSI. iOS can't reach a unix socket, so use an SSH `-L` style forward (e.g. a Citadel/NIO-SSH
  streamlocal channel; guess, not verified) or a tiny relay.
- Copy: the passive notification shell to drive local notifications/APNs. Use `agent.list.agent_session` and the
  transcript JSONL for the chat view. Send input with `pane.send_input {text, keys:["enter"]}`. Draw layout from
  `pane.layout` rects. Mobile key bar defaults. In-memory drafts only.
- Avoid: re-encoding cells to ANSI, one shell per pane, polling `pane.read` for live view, building a bridge server, our
  own split-tree model, and our own approval detection (use `agent_status: blocked` / `needs_attention`).
- Watch: geometry contention between devices, enum renumbering across herdr versions (gate on welcome
  `methods`/`capabilities`), and per-pane status subscriptions.
