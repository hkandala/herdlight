# herdr-world (IvoryHeart/herdr-world) — research notes

Repo: /tmp/herdr-research/herdr-world (HEAD 15a129c). Bun + TypeScript server (`server/src`), React + Vite +
xterm.js PWA (`web/src`), pixi.js for the "Office" pixel-art view. Forked from `powerfooI/roamgate` (UPSTREAM.md).
Targets Herdr 0.9.0, **terminal protocol 22, endpoint generation 1** (also legacy protocols 14–20).
Huge repo (~290k lines incl. tests/specs); the terminal-protocol code under `server/src/bridge/` is the useful part.

Checked against the live local herdr 0.9.3 (read-only `ping`):
```json
{"id":"1","result":{"type":"pong","version":"0.9.3","protocol":22,
 "capabilities":{"live_handoff":true,"detached_server_daemon":true,"endpoint_protocol_generation":1,
 "surface_interest":true,"health_check":true,"ssh_agent_registration":true}}}
```

---------------------------------------------------------------------------------------------------
## 1. Server/bridge architecture & transport

```
Browser (React PWA, xterm.js) ──HTTPS/WS JSON──▶ herdr-world (Bun.serve, one process)
                                                  ├─ per "connection" (host) runtime:
                                                  │   HerdrClient  → herdr.sock         (NDJSON control API)
                                                  │   ThinClient / EndpointClient → herdr-client.sock (bincode render protocol)
                                                  │   ssh -N -L tunnel (remote hosts only)
                                                  └─ web-push, file/git/session-history helpers
```
- `server/src/index.ts` `Bun.serve({port, hostname, tls, fetch, websocket})`. Routes: `/ws` (one WebSocket per
  browser, all traffic), `/api/login|logout|health|herdr-info|herdr/status|herdr/setup|update/*|upload-image|
  file/*|agent-session/*|notifications/push`, `/health(z)`, static files.
- **No SSE.** Everything live goes over one WS with JSON envelopes. Requests: `{id, method, params,
  connection_id?, connection_generation?}`. Pushes are wrapped by `serializeConnectionEnvelope`:
  `{connection_id, connection_generation, ...message}` (`connections/protocol.ts`).
- Method routing (`connections/rpc-routing.ts`): `bridge.*`, `connections.*`, `world.*` are bridge-global;
  `terminal.*` handled by the terminal bridge; a few intercepted (`settings.*`, `worktree.create|open|remove`);
  **everything else is passed straight to `herdr.call(method, params)`** on that host's socket (index.ts ~L1359).
  So the browser speaks herdr's own API (`pane.list`, `pane.split`, `tab.create`, …) through the proxy.
- Auth (`http/auth.ts`, `config/auth-token.ts`): auth required when bound to non-localhost. Password login or
  URL login token (`?token=` → cookie), 64-hex token stored at `~/.config/herdr-world/auth-token` (0600).
  HttpOnly SameSite=Lax cookie. Same-origin "browser admission" check (Origin/Host vs `publicOrigin`).
  Logout closes that session's WSs (code 4001) and revokes its push subscriptions.
- Backpressure (`bridge/websocket-send.ts`): if `ws.getBufferedAmount() > 8 MiB` → close slow socket.
  Full-repaint frames carry a `coalesceKey` so only the newest pending frame per terminal is held.
- Tunnels: no relay/cloud; remote hosts via OpenSSH socket forwarding (§6). Exposure to phone = user's own
  TLS/reverse proxy/Tailscale (docs/DEPLOYMENT.md).

## 2. Herdr socket methods / protocols used

### 2a. Control socket `~/.config/herdr/herdr.sock` (or `sessions/<name>/herdr.sock`) — NDJSON
`bridge/herdr-client.ts`:
- **One request per connection**: connect → write `{"id","method","params"}\n` → read one line
  `{"id","result"}` | `{"id","error":{"code","message"}}` → socket closes. Max line 1 MiB, timeout 8 s.
- **Subscriptions are long-lived**: `{"id":"sub","method":"events.subscribe","params":{"subscriptions":[{"type":"…"},…]}}`
  → ack `{"id":"sub","result":…}` → events `{"event":"<name>","data":{"type":"<name>",…}}` per line.
- Default subscription set (`connections/runtime.ts` DEFAULT_EVENTS):
  `workspace.created|updated|renamed|closed|focused|moved|reordered`, `tab.created|closed|renamed|focused`,
  `pane.created|updated|closed|focused|moved|exited|agent_detected`, `layout.updated`,
  `worktree.created|opened|removed`. After every ack they emit a synthetic `session.resync_required` and the
  browser re-snapshots (closes the missed-event gap). Retry every 2 s on close.
- Agent status is a **parameterized subscription per pane**:
  `{"type":"pane.agent_status_changed","pane_id":"w4:pDE"}`. `connections/agent-status-subscription.ts`
  lists agent panes (`pane.list`), subscribes to all, and **tears down/rebuilds the subscription when pane
  membership changes** (membership events + fallback poll). Pitfall: the subscribe fails if a pane closes mid-way.
- Methods seen (server + web): `ping` (→ `{version, protocol, capabilities}`), `workspace.list|get|create|focus|
  close|rename|move`, `tab.list|create|focus|close|rename|next|previous`, `pane.list|get|layout|read|split|
  resize|zoom|close|focus|focus_direction|scroll|send_input|send_keys|send_text|report_metadata`,
  `agent.list|get`, `integration.list`, `worktree.create|open|remove`, `events.subscribe`.
  "World snapshot" per host = parallel `workspace.list`, `tab.list`, `pane.list`, `agent.list` (world/snapshot.ts:702).
- Shapes used (`web/src/types.ts`; pane verified live):
  ```json
  pane: {"pane_id":"w4:pDE","terminal_id":"term_65d4…","workspace_id":"w4","tab_id":"w4:t7N","focused":false,
         "cwd":"…","foreground_cwd":"…","agent":"codex","terminal_title":"…","agent_status":"idle",
         "scroll":{"offset_from_bottom":0,"max_offset_from_bottom":0,"viewport_rows":58},"revision":1,
         "agent_session"?:{"source","agent","kind":"id|path","value"}, "tokens"?:{…}}
  pane.layout → {"layout":{"workspace_id","tab_id","zoomed","area":Rect,"focused_pane_id",
                 "panes":[{"pane_id","focused","rect"}],"splits":[{"id","direction":"right|down","ratio","rect"}]}}
  pane.read {pane_id, source:"visible", strip_ansi:true} → {pane_id,…,source,format,text,revision,truncated}
  pane.split {target_pane_id, direction:"right|down", focus:bool} → {pane:{pane_id,…}}
  pane.resize {pane_id, direction:"left|right|up|down", amount} → {resize:{layout}}
  pane.send_input {pane_id, text, keys:["enter"]}   // herdr adds bracketed paste only if PTY enabled it
  pane.report_metadata {pane_id, source:"herdr-world:task-summary", tokens:{task_summary:"…",…}, ttl_ms}
  agent.get {target: pane_id} → {agent:{agent, agent_session:{kind,value,…}, …}}
  ```

### 2b. Render socket `~/.config/herdr/herdr-client.sock` — bincode, length-prefixed
Framing: `u32 LE length + payload`; payload = bincode 2 `config::standard()` (varint ints: <251 one byte,
0xfb+u16, 0xfc+u32, 0xfd+u64; strings/vecs length-prefixed; Option = u8 tag; enum = varint variant index).
Codec: `bridge/bincode.ts` (136 lines — trivial to port to Swift). Max frame 32 MiB.

**Two backends**, chosen by `navigationMode()` (terminal-bridge.ts:146): protocol 22 + pane lookup available →
endpoint ("browser-local"), else legacy direct attach ("shared").

(A) Legacy/direct terminal attach — `bridge/thin-client.ts`
- ClientMessage indices: Hello=0, Input=1, Resize=3, AttachTerminal=5, AttachScroll=6.
- Protocol-22 TerminalHello: `variant 0, varint protocol, cols, rows, cell_w_px=0, cell_h_px=0, bool pixel_mouse`.
- Server (v22): Welcome=0 `{varint version, varint encoding(=1 TerminalAnsi), Option<String> error}`,
  **Terminal=1 `{seq, width, height, bool full, bytes}` = raw ANSI bytes** for the terminal,
  ServerShutdown=3, Clipboard=5, MouseCapture=8 `{enabled, sgr_pixels}`, DirectTerminalKeyboardProtocol=16.
- `AttachTerminal {String terminal_id, bool takeover}` (they pass takeover=true); one attach per connection.
- Input = `Input {bytes}` raw VT bytes; scroll = `AttachScroll {source Wheel|PageKey(bytes), dir, lines, Option col,
  Option row, u8 mods}`.
- Pitfall: on v22 OSC 52 clipboard is only routed to endpoint shell clients, not direct attachments.

(B) Stable endpoint generation 1 — `bridge/endpoint-client.ts`, `endpoint-surface.ts`, `vt-input-classifier.ts`
- Hello is `EndpointControl`(variant 20) `{String kind="endpoint.hello.v1", String json}`:
  ```json
  {"generation":1,"cell_width_px":0,"cell_height_px":0,"surface_size":{"cols":C,"rows":R},
   "pixel_mouse":false,"direct_graphics":false,"endpoint_keybindings":false,"mouse_capture":false,
   "surface_active":true,"surface_delta":true,"surface_reuse":true,
   "snapshot_codecs":["shell.snapshot.v1"],"surface_codecs":["shell.surface.v1"],
   "input_codecs":["shell.input.semantic.v1"],"blob_codecs":["shell.blob.v1"]}
  ```
- Server replies `endpoint.welcome.v1` JSON `{generation, server_version, methods[], capabilities[], *_codec}`
  then `shell.snapshot.v1` JSON `{boot_id, revision, …}` (topology). Boot id change ⇒ reconnect.
- ClientMessage: ClientShellResize=12 `{cw_px,ch_px,cols,rows,pixel_mouse}`, ClientShellPaneInput=13,
  ClientShellEndpointRequest=15 `{String boot_id, String json {id,method,params}}`, EndpointControl=20.
- ServerMessage: Welcome=0 (means legacy server), Clipboard=5 (base64 string), PaneSurface=13,
  SemanticNotification=14, ClientShellError=15, EndpointResponseChunk=18 `{boot_id, request_id, bool final, bytes}`
  (concat chunks → JSON `{result|error}`), PaneSurfacePatch=19, EndpointControl=20.
  Named controls: `endpoint.surface-delta.v1`, `endpoint.surface-reuse.v1` (JSON/base64 deltas),
  `endpoint.health.ping.v1`/`pong.v1` (if capability `health_check`).
- Endpoint RPC methods used over this lane: `pane.focus {pane_id}`, `pane.scroll {pane_id, offset_from_bottom}`,
  `tab.create`, `workspace.create`, `pane.link.resolve|activate`. Must check `welcome.methods` before calling.
- PaneSurface = **server-rendered cell grid of the whole focused tab** (`FrameData {cells[{symbol, fg, bg,
  modifier, skip, hyperlink?}], width, height, cursor?{x,y,visible,shape}, hyperlinks[], graphics bytes}`)
  plus per-pane meta `{pane_id, content_revision, rect, inner_rect, scroll?, focused, mouse_reporting, …}` and
  optional popup frame. Colors packed: `0x00`+index (0=default) / `0x01`+256-color / `0x02RRGGBB`.
  Modifier = ratatui bits (+ underline style in bits 12–15).
- Input = semantic events, not bytes: `ClientShellPaneInput {pane_id, [Key{code,char?,fn?,mods,…} |
  TextCommit{text} | Mouse{kind,button?,Cell{col,row},mods,lines} | Paste{text}]}`. Server-side
  `VtInputClassifier` converts xterm's VT bytes back into these (25 ms ESC flush to disambiguate Alt/Esc).
  No kitty keyboard, no pixel mouse.
- **Per-client tab focus**: `pane.focus` on an endpoint shell scopes *that shell's* surface to the pane's tab,
  so browser navigation doesn't move the herdr TUI's tab. Same-tab pane focus (cursor owner) is still shared.
- A passive role `surface_active:false` ("notifications" client) gets no surfaces but still receives
  SemanticNotification — used for push (§8).

## 3. Live terminal streaming

- **Not `pane.read` polling** for terminals. Real-time push over herdr-client.sock (above).
- Endpoint path: crop the tab surface to `pane.inner_rect` (`cropFrame`) → `frameToAnsi()`
  (`bridge/frame-to-ansi.ts`) = **full repaint per frame, no diffing** ("ponytail: … 100x30 frame ~20-60 KB"):
  `ESC[H ESC[2J ESC[?7l`, per row `ESC[y;1H`, SGR runs, OSC 8 links, trims trailing blanks, then cursor
  (`ESC[shape q`, `ESC[?25h/l`). Wide chars re-anchored with `ESC[colG` because xterm grapheme widths differ.
- Legacy path: herdr already sends ANSI bytes (`Terminal{full,bytes}`) → forwarded as-is.
- WS push to browser: `{terminal:{terminal_id,width,height,full,bytes:<base64 ANSI>,mouse_reporting?,link_frame?,history?}}`.
  Browser → bridge: `terminal.attach {terminal_id, cols, rows, surface_cols?, surface_rows?}`,
  `terminal.input {terminal_id, data:<base64>}`, `terminal.resize`, `terminal.scroll`, `terminal.focus`,
  `terminal.detach`, `terminal.link.resolve`, `terminal.relay_resize`, `terminal.watch_popup`.
- One herdr stream per terminal shared by all viewers (`sharedTerminals` map); per-viewer clip if a viewer is
  smaller. Last viewer leaves → stream closed.
- Sizing: pane dims are herdr's **shared layout dims**; browser passes the whole-tab surface size and the
  session converges with up to 3 corrective resizes (`fitSurface`, `SURFACE_FIT_MAX_ATTEMPTS=3`).
- Scrollback: `pane.scroll {offset_from_bottom}` with coalesced wheel intent; PageUp/Down sent as semantic keys.
- Renderer: **xterm.js** (`@xterm/xterm`, addon-fit, addon-unicode-graphemes, addon-clipboard). Bundled
  glyph-only Nerd Font (`web/src/assets/herdr-nerd-symbols.woff2`).
- Text selection freezes the displayed frame (keeps only latest full repaint) and catches up after;
  legacy incremental streams resume at a 1 MiB pending limit (TerminalView.tsx:1242).
- Screen polling exists only for **Desk cards**: `pane.read {source:"visible", strip_ansi:true}` every 4 s,
  max 16 panes, paused when `document.visibilityState==="hidden"` (`web/src/world/paneScreen.ts`).

## 4. Layout model

- Tree: host → workspace → tab → pane; agents attached to panes. Data from list calls + events; "Spaces" view is
  the classic terminal workspace; Office/Desk/Tree/Graph are visualizations of the same aggregate.
- Splits: `pane.layout` gives absolute `rect`s for panes and splits for the active tab. The browser renders each
  pane as an absolutely-positioned box at `rect` percentages, each with its own xterm instance
  (`web/src/TabTerminalPaneLayout.tsx`, `rectPercent`), with drag handles → `pane.resize {direction, amount}`.
  Split/zoom/close via `pane.split`, `pane.zoom`, `pane.close`. Layout is **owned by herdr**; app only projects it.
- Browser-local navigation (`web/src/browserNavigation.ts`): selected workspace/tab/pane kept per browser;
  snapshots supply topology only; stale layouts/results never overwrite newer selections.
- Herdr popups (plugin modal panes) are rendered over the active workspace (terminal not in any layout →
  streamed via legacy direct attach by terminal id).
- Recent pane switcher (Ctrl+Tab, 12 MRU panes) and fuzzy pane search (Alt+K).

## 5. "Chat" view

There is no live chat-transcript replacing the terminal. Two pieces:
- **Agent History** (read-only transcript): `agent.get {target: pane_id}` → `agent.agent_session
  {kind:"id"|"path", value}` → locate the agent's JSONL on disk (`agent/session-resolver.ts`):
  codex `~/.codex/sessions/**/*<id>*.jsonl`, claude `~/.claude/projects/**/<id>.jsonl`,
  pi `$PI_CODING_AGENT_DIR` or `~/.pi/agent/**/<id>.jsonl` / `*_<id>.jsonl`, plus kimi/grok/muse/antigravity.
  Parsed into ATIF-v1.7 trajectories (`agent/session-trajectory.ts`). Bridge method `agent_history.get`
  (`history_version:2`, cursor `{epoch,revision}` → `snapshot` or `delta {upserts, removed, order}`), window =
  last 200 conversation entries; browser polls every 4 s while open+visible (docs/HISTORY.md). Remote hosts:
  files read via `ssh host bash -lc '…'` with base64-encoded output.
- **Composer** (`web/src/terminalComposer.ts`, `components/TerminalComposer.tsx`): multiline textarea, IME,
  dictation, image paste → `POST /api/upload-image` saves on the host and inserts the quoted path.
  "Insert" = `pane.send_input {pane_id, text, keys:[]}`; "Send" = same with `keys:["enter"]` (exactly one Enter).
  Herdr decides bracketed-paste wrapping. Drafts kept in memory per connection/pane; warn on close.
- **Approvals/permission prompts**: no structured detection. Status comes from herdr (`agent_status`:
  working/blocked/done/idle via `pane.agent_status_changed` / `agent.list`) and SemanticNotification
  `needs_attention`. For blocked agents the Desk card shows the **bottom of the visible screen**
  (`questionFromScreen()` — strips box chars and agent footer chrome via regex) with fallback
  "Waiting for your answer in its terminal." Answering = open the terminal / composer. No one-tap
  approve buttons. "Turn receipts" (`agent/turn-receipt.ts`) show last user ask + last agent report from JSONL.

## 6. Multi-host

- "Connection profiles" = local or SSH, persisted in `~/.config/herdr-world/connections.json`
  (`connections/profiles.ts`): `{control_socket_path, client_socket_path}` or `{ssh_destination,
  remote_control_socket_path, remote_client_socket_path}`. Each has its own runtime, generation counter, event loop.
- SSH: one `ssh -N` process per host forwarding **both unix sockets** to local tmp sockets
  (`bridge/ssh-command.ts`):
  ```
  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ControlMaster=no … -o ExitOnForwardFailure=yes
      -o ServerAliveInterval=20 -o ServerAliveCountMax=3 -o StreamLocalBindUnlink=yes
      -o StreamLocalBindMask=0177 -N -L /tmp/herdr-world-<k>-control.sock:$HOME/.config/herdr/herdr.sock
      -L /tmp/herdr-world-<k>-client.sock:$HOME/.config/herdr/herdr-client.sock -- user@host
  ```
  Remote `$HOME` resolved first via `ssh host 'printf %s "$HOME"'`; then polls (100 ms, 8 s timeout) until the
  local sockets exist. After that, everything is identical to local (same NDJSON + bincode code).
- Every request/push carries `connection_id` + `connection_generation`; stale generations are rejected so
  replies from a replaced connection never land in the UI. "All hosts" aggregate view by default.
- Windows: local only (no SSH forwarding).

## 7. Mobile UX tricks

- Installable PWA (`web/public/manifest.json`); mobile layout ≤ 768 px (configurable, `?layout=` override).
- Tap/swipe on terminal = read/scroll **without** popping the keyboard; explicit "Open device keyboard" button;
  light tap dismisses it without sending input.
- Floating key panel: configurable **2×8 shortcut grid + up to 4 side buttons** (`mobileTerminalShortcuts.ts`):
  Ctrl-A…Z subset, Esc, Tab, Enter, Shift/Alt-Enter, arrows, Home/End, PgUp/PgDn, Alt-arrows, half-page
  scroll, Paste (text or clipboard image → uploaded path). Defaults include `C-c`, `C-d`, `C-R`, `A-Up`, `▲`.
- Long-press word selection with drag handles → Copy / Add comment; frame freezes during selection.
- Composer with native dictation (voice = OS dictation only, no custom STT).
- Tabs sheet when the tab strip is hidden; one active window on mobile.

## 8. Push notifications

- Web Push with VAPID (`notifications/web-push.ts`, npm `web-push`). Keys auto-generated and stored with
  subscriptions in `~/.config/herdr-world/web-push.json` (0600, atomic rename). Sent with `TTL: 300,
  urgency: "high"`. Subscriptions bound to the login session (HMAC domain `herdr-world:web-push-session:v1`),
  revoked on logout. Service worker `web/public/task-notifications-sw.js`.
- Trigger source (default `herdr`): a **passive endpoint shell** per host (`surface_active:false`) receives
  `SemanticNotification {kind: needs_attention|finished|update_installed|custom, title, body?,
  sound?: done|request, agent?, workspace_id?, tab_id?, pane_id?}` — i.e. herdr's own toast policy, including
  `herdr notification show`. Mapped: finished→completed, needs_attention→blocked, custom→by sound.
  Fallback source `status`: World's own working→idle/done/blocked tracker from `pane.agent_status_changed`.
- Clicking a push focuses the pane if pane_id present.

## 9. Persistence

Server, `~/.config/herdr-world/` (Windows `%APPDATA%\herdr-world`): `auth-token`, `connections.json`
(host profiles), `settings.json` (GUI settings), `web-push.json` (VAPID + subscriptions), `summary.json`(?),
logs. Browser `localStorage`: appearance/themes, mobile shortcuts, layout prefs, hosts filter, inspector widths,
watchlist (`world/watchlistStore.ts`). Herdr itself owns all workspace/tab/pane/agent state. Task summaries are
pushed **into herdr** as pane metadata tokens (`pane.report_metadata`, TTL default 15 min, max 24 h), read back
from `pane.tokens` in `pane.list`.

## 10. Clever bits / pitfalls

Clever:
- Talks herdr's **render protocol directly** (herdr-client.sock) instead of scraping `pane.read`; real-time,
  per-pane, cheap. Whole bincode codec is ~140 lines.
- Endpoint shells give **independent per-client tab navigation** without disturbing the herdr TUI.
- Passive endpoint shell = free, policy-correct notification stream (same as herdr's toasts).
- `pane.send_input {text, keys:["enter"]}` lets herdr handle bracketed paste/Enter encoding per PTY mode.
- `pane.report_metadata` tokens = a supported way to attach app data to a pane that every client can read.
- SSH = forward the two unix sockets; zero remote install beyond herdr itself.
- Resync after every subscription ack (`session.resync_required`) — simple, robust.
- Capability gating: only call endpoint methods present in `welcome.methods`; per-socket, never cached globally.

Pitfalls they hit:
- Protocol churn: ServerMessage indices shifted between protocols (Frame removed in v22; launch-mode enum
  renumbered in 0.8.2). They allowlist exact protocols (14–20, 22) and refuse others. Pin versions.
- Direct attach with `takeover=true` and endpoint resize both influence shared PTY/layout size; sizes need
  convergence loops; panes keep herdr's shared layout dims.
- Clipboard OSC 52 on v22: only to the foreground endpoint shell, no source pane attribution.
- `pane.agent_status_changed` needs per-pane subscriptions rebuilt on membership changes.
- One-request-per-connection RPC: each call = new unix socket connect (fine locally; over SSH forward it's
  still local socket → ssh channel).
- Endpoint surfaces have no soft-wrap info → link detection heuristics; xterm wide-char width mismatches.
- Generation/lease checks everywhere to avoid stale replies after reconnect (big source of complexity).

---------------------------------------------------------------------------------------------------
## Lessons for our app (native Swift macOS + iOS)

Copy:
1. **No bridge server on macOS**: connect straight to `herdr.sock` (NDJSON) and `herdr-client.sock` (bincode)
   with `Network.framework`/`NWConnection` unix endpoints. Port `bincode.ts` + the endpoint codecs to Swift.
2. Terminal: easiest is **legacy direct attach** (`TerminalHello` + `AttachTerminal{terminal_id}`) → raw ANSI
   `Terminal{bytes}` fed into SwiftTerm (or libghostty). Better long-term: endpoint shell per tab (one socket
   gives all panes of a tab with rects; per-client tab focus; semantic input). Either way no polling.
3. Layout: `pane.layout` rects/splits + `layout.updated` events; resize via `pane.resize`, zoom `pane.zoom`,
   move via `pane.moved`-related methods. Herdr owns layout — store nothing.
4. Chat view: `agent.get` → `agent_session` → read the agent's JSONL (claude/codex/pi paths above); send with
   `pane.send_input {pane_id, text, keys:["enter"]}`. Blocked prompt text: `pane.read {source:"visible",
   strip_ansi:true}` + the `questionFromScreen` regex trick, only when status is `blocked`.
5. Notifications: one passive endpoint shell per host (`surface_active:false`) → `SemanticNotification` →
   UNUserNotificationCenter on macOS. iOS background push needs APNs from something always-on (guess: a tiny
   relay on the host or the Mac app; Web Push/VAPID doesn't apply to native).
6. Web-page panes: `pane.report_metadata {pane_id, source:"<app>", tokens:{url:"…"}, ttl_ms}` appears as
   `pane.tokens` in `pane.list` for all clients. **Caveat (verified from their code): TTL is required and
   capped (max 24 h in their CLI; guess: herdr enforces a cap)** → would need periodic re-reporting, so the
   placeholder pane's command/title (e.g. `herdr pane run` of a tiny `web-placeholder <url>` process, or
   terminal title) may be more durable. Worth testing.
7. Multi-host: `ssh -N -L local.sock:remote/herdr.sock -L …client.sock` with the same options; on iOS there is
   no ssh binary → need an SSH library (e.g. swift-nio-ssh `direct-streamlocal@openssh.com` channels) or a
   host-side agent. Tag every request with a host generation to drop stale replies.
8. Mobile: keyboard-only-on-demand, configurable key grid, composer with dictation + image upload (upload =
   write file on host then insert path).

Avoid:
- Their scale: generations/leases/coalescing everywhere, 290k lines, many visualizations. Keep one terminal
  path, one chat path.
- Full repaint ANSI re-encoding if we can render cells directly: with the endpoint protocol we get a cell grid —
  draw it natively (CoreText/Metal) instead of grid→ANSI→terminal emulator.
- Hardcoding enum indices without a version check — gate on `ping.protocol` and
  `capabilities.endpoint_protocol_generation`, refuse unknown.
- Polling `pane.read` for live terminals.
