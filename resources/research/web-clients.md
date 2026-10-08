# Web/PWA herdr clients and browser-pane plugins

Repos were cloned shallow into `/tmp/herdr-research/<name>` on 2026-10-08. None returned 404.
`powerfooI/roamgate` and `powerfooI/herdr-studio` are the same project under two names (same commit `4476392`, "Release 0.8.0").
`IvoryHeart/herdr-world` is a fork of roamgate.
Longer per-repo notes, with more file paths, are in `research/web-clients-notes/{collie,roamgate,herdr-world,termote}.md`.

Local herdr `ping` returned this (read-only call):
`{"version":"0.9.3","protocol":22,"capabilities":{"live_handoff":true,"detached_server_daemon":true,"endpoint_protocol_generation":1,"surface_interest":true,"health_check":true,"ssh_agent_registration":true}}`

---

## 0. Summary table

| | collie | roamgate / herdr-studio | herdr-world | herdr-webui (alecuba16) | termote | herdr-remote |
|---|---|---|---|---|---|---|
| Stack | Bun bridge + React PWA | Bun bridge + React PWA | Bun bridge (roamgate fork) + React + pixi | Rust Axum + vanilla JS | Go + React PWA | Python relay + PWA + Telegram + **SwiftUI Mac/iOS** |
| Browser ↔ bridge | HTTP polling only, ETag/304, gzip | one WS, JSON RPC passthrough | one WS, JSON RPC passthrough | HTTP + `/ws/events` + `/ws/terminal` | REST + one WS per stream | WS JSON |
| herdr access | `herdr.sock` NDJSON | `herdr.sock` + `herdr-client.sock` (bincode) | same as roamgate | `herdr.sock` + `herdr-client.sock` | `herdr.sock` + `herdr terminal session` CLI | `herdr` CLI subprocesses only |
| Live terminal | `pane.read recent/ansi` snapshots → own SGR→spans renderer | endpoint gen-1 cell surfaces → ANSI → xterm.js | same (+ legacy direct attach) | direct `AttachTerminal` ANSI frames → wterm/Ghostty | `herdr terminal session observe/control` NDJSON frames → xterm.js | `pane read --format ansi` every ~3 s → spans |
| Layout | flat, one pane at a time | `pane.layout` rects, absolute positioning | same | panels (tabs) | flat; panes ordered by rect | cards |
| Chat source | transcript files (claude/codex/pi/omp/opencode/…) | transcript files (read-only drawer) | transcript files (read-only drawer) | jcode store only | claude/codex JSONL | claude/pi/kimi JSONL |
| Approvals | screen grammars per harness + prompt binding | none (status only) | none (shows bottom of screen) | prompt cards from parsed screen | screen parsers + promptId bound to screen signature | screen parsers + prompt hash |
| Multi-host | "crew": a Collie on every host, lead merges | SSH `-L` forwards both sockets | same | none | none | SSH per call (ControlMaster) |
| Push | Web Push (VAPID), 30 s debounce, coalesce, retract | Web Push, source = passive endpoint shell `SemanticNotification` | same | browser Notification API only | own Web Push in Go stdlib, ids-only payload | Web Push + Telegram + Live Activity |

---

## 1. collie (AltanS/collie): mobile PWA, push alerts

**Architecture.** A long-lived Bun daemon per machine (systemd `--user` / launchd), *not* a plugin pane, so it survives herdr restarts.
The herdr plugin only adds `[[actions]]` that call `bin/collie start|stop|update`.
The browser talks to the bridge with **HTTP JSON polling only**. ADR 0073 rejects WebSocket and SSE on purpose.
- Reads: `GET /api/snapshot`, `/api/pane/:id?lines=N`, `/api/pane/:id/chat`, `/history`.
- Writes: `POST /api/pane/:id/{reply,keys,upload,close,rename,focus}`.
- Every read is ETag'd: 304 when unchanged, gzip otherwise.
- Front door: binds 127.0.0.1 behind `tailscale serve`. Funnel is forbidden.
- Device pairing: a one-time code is traded for a 256-bit bearer token. Only the token's SHA-256 is stored. There is also a Host allowlist and a JSONL audit log of writes.

**herdr API** (`bridge/mux/herdr/client.ts`; `HERDR_API.md` is a contract the author verified against live servers and is worth reading):
`session.snapshot` (falls back to `workspace.list`+`tab.list`+`pane.list` on `unknown variant`), `pane.read {pane_id, source: visible|recent|recent_unwrapped|detection, lines, format: text|ansi}`, `pane.send_text`, `pane.send_keys`, `pane.focus`, `pane.rename {pane_id,label|null}`, `pane.close`, `tab.create {workspace_id, focus:false}`, `tab.rename/close`, `workspace.create {cwd, focus:false}`, `worktree.list/create/open`, `events.subscribe`.
Facts the author verified:
- **One request per connection.** `id` must be a string. A request over 1 MiB gets no answer.
- `send_keys` grammar is `Up Down Left Right Tab Enter Escape Space Backspace F1..F12`, single characters, and chords like `ctrl+c`, `shift+tab`, `alt+Up`. **`PageUp/PageDown/Home/End/Delete/C-c` are rejected** with `invalid_key`.
- **`pane.read` with `recent`+`text` and `lines > viewport_rows` scrolls the operator's real terminal.** herdr harvests alt-screen agents through mouse-scroll; 400 lines took 13.8 s. Background polls must use `visible` or `ansi`.
- `revision` is always 0, a stub. `agent_session` can be stale, so check `agent_session.agent == pane.agent`. `pane.rename` emits no event. Tab order is array order (`tab.move` doesn't renumber).
- `pane.agent_status_changed` subscriptions **require `pane_id`**. One unknown subscription type rejects the whole subscribe.

**Streaming.** There is no terminal emulator (ADR 0008: "`pane.read` already returns herdr's rendered grid").
- The bridge polls `session.snapshot` every 1.5 s, relaxed to 12 s while the event stream is healthy. **Events only "poke" a debounced re-poll** and never change state directly.
- The browser polls at 300 ms bursts after a send, 1.5 s while hot, and 4–6 s when idle. It pauses while the tab is hidden.
- `pane.read recent ansi lines=200` is parsed by its own SGR parser (`web/src/lib/ansi.ts`) into React spans.
- When a URL is cut at the column edge, the bridge does one extra `recent_unwrapped` read to rebuild it.
- The author considered `herdr terminal session observe|control` and rejected it, because `control` resizes the shared PTY.

**Layout.** `layouts[]` is carried but intentionally unused. The phone shows one pane at a time, with space, tab and pane pill strips.
ADR 0063: a pane never moves when its status changes.

**Chat** (ADR 0082: chat is the *default* view for agent panes).
- Source: the agent's own transcript (`bridge/journal/`, claude/codex/pi/omp/opencode-sqlite/hermes/grok/muse), located via `pane.agent_session {kind:"id"|"path", value}`.
- It tails a bounded window (2 MB / 2000 entries) with cursors. Real sessions reached 186 MB.
- It falls back to the terminal mirror on *events* (blocked with no log yet, no session after the first turn), not on timers.
- **Approvals** come from per-harness pure grammars over styled lines (`web/src/lib/harness/<agent>/`, about 34 byte-exact fixtures). A dialog's footer must be the last non-blank line.
- Answering is `send_keys ["1"]` or `["2","Enter"]`. The **bridge re-reads the pane right before sending** and returns 409 if the dialog changed (`bridge/prompt-binding.ts`).
- **Free-text reply never sends a blind Enter** (issue #34: a blind Enter answered a permission dialog with "Yes"):
  1. Check the composer is ready.
  2. Clear it with `ctrl+k` + Backspace×N.
  3. `send_text`.
  4. Poll until the text shows on the `❯` line.
  5. Only then `send_keys ["Enter"]`.
- `send_text` doesn't add bracketed paste. Collie wraps replies over 800 characters in `ESC[200~…ESC[201~` itself, because macOS PTYs split writes into ~1 KB reads and 12,029 characters arrived as 787.
- Chunking is rejected: a `\n` at a chunk boundary would submit half a message.
- Attachments are uploaded, and the absolute path is typed into the message.

**Multi-host ("crew").** Every machine runs a full Collie. A lead merges peer snapshots over mTLS plus a crew secret (`CREW_PROTOCOL.md`, 3,159 lines). No herdr verb crosses machines. Keys are `(host, id)`.

**Mobile UX.**
- Composer textarea, so OS dictation works.
- Keys tray with Esc, arrows, digits, F-keys and Ctrl presets per agent from `keys.toml`; `danger=true` keys need two taps.
- A key *queue*: compose chords as chips and send them in one call.
- Quick replies, launchers and direct-typing mode. Left/right-hand mirroring, haptics, swipe-up switcher, zen mode.
- Optional STT provider seam.

**Push.** VAPID Web Push from status transitions (`bridge/notifications.ts`).
- **30 s debounce**: an agent that blocks and unblocks inside the window was handled at the desk, so no push goes out.
- One coalesced "N agents need you" summary. A `{type:"clear"}` push retracts it.
- `TTL 21600, topic "collie-herd", urgency high`. Apple rejects topics whose length ≡ 1 (mod 4). Titles go out as codes that the phone translates.

**Persisted:** `~/.local/state/collie/`: paired devices, push subscriptions, `activity.json` (a seen ledger, because herdr has no timestamps), snooze, audit log, uploads. Config lives in TOML files. Layout is never stored.

---

## 2. roamgate = herdr-studio (powerfooI): Bun bridge + React PWA

**Architecture.** The browser opens one same-origin WS `/ws`.
- Messages are JSON RPC `{id, method, params, connection_id, connection_generation}`. Most herdr methods are **passed straight through** to `herdr.sock`.
- The bridge also owns auth (token or password always required, HMAC cookie), SSH runtimes, git and files, Web Push, an embedded pi assistant, and self-update.
- Under backpressure (8 MiB), full-repaint frames carry a *coalesce key*, so only the newest frame per terminal is kept.

**herdr API.** `herdr.sock` is one-request-per-connection NDJSON.
- Methods used: `workspace.*`, `tab.*`, `pane.list|get|layout|split|resize|zoom|swap|close|focus_direction|process_info`, `agent.list|get`, `pane.send_input {pane_id, text, keys:["enter"]}` (herdr adds bracketed paste only if the PTY enabled it), `pane.send_text`, `pane.send_keys`, `pane.read`, `pane.link.resolve`, `worktree.*`, `plugin.action.invoke`, `server.agent_manifests`.
- `pane.layout` reply: `{layout:{workspace_id, tab_id, zoomed, area, focused_pane_id, panes:[{pane_id,focused,rect}], splits:[{id,direction,ratio,rect}]}}`.
- After every subscribe ack, the bridge emits a synthetic `session.resync_required` and the client re-snapshots. Per-pane `pane.agent_status_changed` is handled on a second subscription socket that is rebuilt (debounced 300 ms) when the set of agent panes changes.

**Streaming (the best part).** No `pane.read` polling and no raw PTY.
- Each viewed terminal is an **endpoint (client-shell) generation 1 connection on `herdr-client.sock`**.
- Framing: `u32 LE length` + bincode-2 `standard()` (varints; see `server/src/bridge/bincode.ts`, 136 lines).
- Hello is `EndpointControl`(tag 20) with kind `"endpoint.hello.v1"` and this JSON:
  ```json
  {"generation":1,"cell_width_px":0,"cell_height_px":0,"surface_size":{"cols":C,"rows":R},"pixel_mouse":false,
   "direct_graphics":false,"endpoint_keybindings":false,"mouse_capture":false,"surface_active":true,
   "surface_delta":true,"surface_reuse":true,"snapshot_codecs":["shell.snapshot.v1"],"surface_codecs":["shell.surface.v1"],
   "input_codecs":["shell.input.semantic.v1"],"blob_codecs":["shell.blob.v1"]}
  ```
- The server replies with `endpoint.welcome.v1` (`methods[]`, `capabilities[]`), then a `shell.snapshot.v1` (`boot_id`, `revision`).
- Endpoint RPC runs on the same socket: `ClientShellEndpointRequest(boot_id, json)` → chunked `EndpointResponseChunk`.
- To attach, the bridge calls `pane.focus {pane_id}` *on that shell*. This scopes only that shell's surface to the tab, so each client navigates tabs on its own.
- `PaneSurface` (tag 13) is the **server-rendered cell grid of the whole tab**:
  - `CellData {symbol, fg, bg, modifier, skip, hyperlink?}`, with colors packed as `0x00`+idx / `0x01`+256 / `0x02RRGGBB`.
  - Per-pane `{pane_id, content_revision, rect, inner_rect, scroll, focused, mouse_reporting, alt_screen}`, plus cursor and an optional popup.
  - Updates arrive as `PaneSurfacePatch` (tag 19) or `endpoint.surface-delta.v1`. A revision mismatch triggers a reconnect.
- The bridge crops each pane's `inner_rect` and `frameToAnsi()` does a full repaint (a 100×30 frame is about 20–60 KB) for xterm.js.
- Input is **semantic**: xterm VT bytes are classified back into `ClientShellPaneInput(pane_id,[Key|TextCommit|Mouse|Paste])`, and herdr re-encodes them for the app's keyboard mode.
- Pitfall: "size follows Herdr's last-interacting client", so a phone and a desktop on the same tab fight over geometry.
- Legacy servers (<0.9) use `Hello`/`AttachTerminal` with hard-coded enum tables per protocol, because variant indices were renumbered across versions.

**Layout.** Absolute positioning from `pane.layout` rects as percentages of `area`. Split, resize (`pane.resize {pane_id,direction,amount}`), swap by drag, and zen mode are supported. On mobile, one pane at a time with ‹ › buttons.

**Chat.** A read-only "Agent History" drawer.
- `agent.get {target:pane_id}` → `agent_session` → transcript (codex `~/.codex/sessions/**/*<id>*.jsonl`, claude `~/.claude/projects/**/<id>.jsonl`, pi `~/.pi/agent/sessions/...`, plus kimi/grok/muse).
- History protocol is snapshot/delta with a 200-entry window, polled every 4 s.
- The Composer sends `pane.send_input {text, keys: submit?["enter"]:[]}`. Drafts stay in memory only, because they can contain secrets.
- **No approval detection**: the UI uses `agent_status == blocked` and `needs_attention`.

**Multi-host.** One supervised `ssh -N` per host that **forwards both unix sockets**:
`-o BatchMode=yes -o StrictHostKeyChecking=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=20 -o StreamLocalBindUnlink=yes -o StreamLocalBindMask=0177 -L <tmp>/herdr.sock:<remoteHOME>/.config/herdr/herdr.sock -L <tmp>/herdr-client.sock:…`.
Every message carries `connection_id + generation`, so stale replies are dropped.

**Mobile UX.**
- Floating, draggable **2×8 shortcut grid** with defaults `C-c C-d C-R A-Up ▲ PgUp / Esc Tab Enter Bksp ◀ ▼ ▶ PgDn`.
- Composer/Direct toggle. Touching the terminal only scrolls; it never pops the keyboard.
- Long-press selection *freezes the frame*. Controls stay above `visualViewport`.

**Push.** Web Push.
- Source is **one passive endpoint shell per host (`surface_active:false`)** that receives herdr's own `SemanticNotification` (tag 14): `{kind: needs_attention|finished|update_installed|custom, title, body?, sound?, agent?, workspace_id?, tab_id?, pane_id?}`.
- This applies herdr's notification policy, and `herdr notification show` also arrives there.
- Fallback: the bridge's own status-transition tracker.

**Persisted:** `~/.config/roamgate/`: auth token, `connections.json`, settings, web-push. Browser localStorage holds UI prefs.

---

## 3. herdr-world (IvoryHeart): roamgate fork with "world" views

Same core as roamgate (`server/src/bridge/{herdr-client,thin-client,endpoint-client,bincode,frame-to-ansi}.ts`), plus Office/Desk/Graph visualisations (pixi.js) and an "All hosts" aggregate view.
Differences worth noting:
- It supports **both** terminal paths, chosen by `navigationMode()`.
  - Legacy direct attach, protocol 22: `TerminalHello` (variant 0) and `AttachTerminal {terminal_id, takeover:true}` (5) → `Terminal` (1) `{seq,width,height,full,bytes}` raw ANSI → straight to xterm.
  - Endpoint gen 1 is used when available.
- Desk cards poll `pane.read {source:"visible", strip_ansi:true}` every 4 s (max 16 panes, paused when the page is hidden). For blocked agents they show the bottom of the screen (`questionFromScreen()`).
- **It stores app data in herdr**: `pane.report_metadata {pane_id, source:"herdr-world:task-summary", tokens:{task_summary:"…"}, ttl_ms}`, read back from `pane.tokens` in `pane.list`. Their CLI caps the TTL at 24 h. Whether herdr has a default TTL or a cap is a guess (see §9).
- Popups (plugin modal panes) are not in any layout. They are rendered over the workspace via legacy attach by `terminal_id`.
- Persisted: `~/.config/herdr-world/{auth-token,connections.json,settings.json,web-push.json}`.

---

## 4. herdr-webui (alecuba16): Rust Axum, vanilla JS

**Architecture.** One binary: Axum server, embedded assets, and an optional **built-in PTY multiplexer** (`src/builtin_backend.rs`, 9k lines) that reimplements a herdr-shaped API.
"external-herdr" mode talks to real herdr ≥0.9.0.
- The browser uses `/api/*` with an `x-herdr-backend` header, plus `/ws/events` and `/ws/terminal` (backend chosen by `?backend=`, because browsers can't set WS headers).
- It also ships `herdr-webui-tui` (Ratatui) on top of a reusable `src/backend_client.rs`.

**herdr API used.** `session.snapshot`, `workspace.*`, `tab.*`, `pane.list|read|layout|close`, `agent.list`, `agent.start`, **`agent.prompt {pane_id,text}`**, `worktree.*`, `events.subscribe` (1 s→30 s retry).
- herdr refuses `agent.prompt` with `agent_blocked` / `empty_agent_prompt`. The webui maps `agent_blocked` to HTTP 409: "the agent is waiting for an answer in the terminal".
- The herdr skill says `agent prompt` honours the pane's bracketed-paste mode and sends text + Enter as one ordered submission.

**Streaming.** Direct attach on `herdr-client.sock` (`src/protocol.rs` mirrors herdr's `wire.rs`, "client protocol 22", **exact version match required**):
```rust
TerminalHello { version: 22, cols, rows, cell_width_px, cell_height_px, pixel_mouse }
AttachTerminal { terminal_id, takeover: true }        // also ObserveTerminal{target}, ControlTerminal{target,takeover}
← Welcome{version, encoding: TerminalAnsi, error}  ← Terminal(TerminalFrame{seq,width,height,full,bytes})
→ Input{data} / Resize{..} / AttachScroll{..} / Detach
← Notify, Clipboard (OSC 52), TerminalBell, MouseCapture, SemanticNotification
```
- `src/terminal_hub.rs` keeps **one backend attach per terminal**, fanned out to N WebSockets.
- It has an 8 MiB replay ring for late joiners and a 1.5 s teardown grace, and it drops stalled clients (close 4404) instead of blocking.
- Renderer: wterm bundle with a Ghostty (default) or wterm core.
- OSC 10/11 colour-query replies from the browser renderer are filtered out so they never reach the PTY.

**Chat.** Only jcode (`SUPPORTED_AGENTS = &["jcode"]`). It reads `~/.jcode/sessions` (snapshot `.json` plus `.journal.jsonl` replay).
- **Prompt cards** appear for blocked panes: the tail is parsed for numbered options and answered with `N`+Enter.
- The tail is **re-parsed right before sending**, so a stale card never fires.

**Notifications:** local only (Web Audio tone and the Notification API on blocked/done). **Multi-host:** none.
**Persisted:** localStorage, plus `webui-settings.json` (recent workspaces).

---

## 5. termote (lamngockhuong): Go server, xterm.js PWA

**Architecture.** Go `net/http`; middleware hostGuard → CSP → writeGuard → basicAuth (cookie session). The only tunnel is a Tailscale helper (`tailscale serve --bg`).
- WS `GET /api/mux/stream?token=&pane=&cols=&rows=[&drive=1]`.
- The token is **single-use and lives 30 s** (`POST /api/mux/stream-token`).
- Binary frames carry terminal bytes; text frames carry JSON control (`resize`, `drive`, `size{driving,reason:"taken-over"}`, `exit`).
- At most 8 streams; the oldest is evicted with code 4001 ("don't reconnect").
- Also ships a herdr plugin (popup pane with QR code, `[[actions]]` for URL/start/stop). It builds deep links from `HERDR_WORKSPACE_ID/TAB_ID/PANE_ID`.

**herdr API** (`server/herdr_rpc.go`, protocol 22).
- Methods: `ping`, `session.snapshot` (cached, invalidated by events, 30 s safety refetch), `pane.get`, `pane.process_info`, `pane.read {source:"visible",format:"ansi"}`, `pane.send_text`, `pane.scroll {pane_id, offset_from_bottom}`, `tab.*`, `workspace.*`, `worktree.*`, `agent.start {pane_id, kind, name, args, timeout_ms}`, `agent.get {target}`.
- Text is chunked at 128 KiB because requests ≥1 MiB are rejected.
- **Input is serialised per pane**: concurrent `send_text` calls arrived out of order (59 of 300 in their measurement).

**Streaming via the CLI**:
- `herdr terminal session observe <pane> --cols C --rows R` (read-only, desktop size).
- `herdr terminal session control <pane> --takeover --cols C --rows R` (resizes the real PTY; resize messages go in on stdin as `{"type":"terminal.resize",…}`).
- stdout is NDJSON: `{"type":"terminal.frame","bytes":"<base64>"}` and `{"type":"terminal.closed","reason":"terminal attach taken over"}`.
- Frames are herdr-rendered ANSI. The first frame is a full redraw.
- On `layout.updated` the observer is killed and restarted at the new size. The size is announced before any bytes at that size.
- Scroll uses shared `pane.scroll` on normal screens. On alt-screen agents it sends SGR wheel reports (`\e[<64;x;yM`).

**Layout.** Flat; panes are sorted by rect (y, x). The UI shows one pane at a time and never changes desktop focus (`focus:false`, `SelectTab` intentionally unsupported).

**Chat.** Claude and Codex JSONL, located via `pane.get.agent_session`.
- Codex needs a process scan, because the session id may belong to the app-server daemon.
- The cursor is an **HMAC-signed `{session, offset, inode}`**. The client polls every 1.5 s.
- Sending follows "write only on positive evidence":
  1. The session still matches the cursor.
  2. Status is idle or done.
  3. The input box is empty.
  4. Bracketed paste.
  5. Wait until the draft shows.
  6. Re-check the session.
  7. `\r`.
  8. Wait until the box clears.
- Approvals: SGR-aware parsers checked against about 100 recorded screens. Answers need a single-use `promptId` bound to pane+session+screen signature. Answered signatures are held for 3 s, so a second device can't answer the *next* dialog.

**Mobile UX.**
- Toolbar with sticky Ctrl/Shift, Ctrl-combos, a ⚡ quick-actions menu and a paste button.
- Gestures: swipe left = Ctrl+C, swipe right = Tab, drag = scroll with momentum, long-press = paste, pinch = font size.
- A first-run hint overlay.

**Push.** Its own RFC 8291 Web Push using only Go stdlib crypto.
- A 5 s poll of the cached snapshot detects `→blocked` and `working→done|idle`.
- **The payload carries ids only.** The service worker fetches names from the server, so no text passes through Apple or Google.

**Persisted:** `~/.local/state/termote` (push keys and subscriptions, uploads, trash), plus localStorage (including per-tab icons, "the mux only stores tab names").

---

## 6. herdr-remote (dcolinmorgan): Python relay, PWA, Telegram, **native SwiftUI Mac and iOS**

**Architecture.** `relay/herdr_relay.py` (asyncio websockets, `:8375`) serves the PWA and a WS JSON protocol.
- Clients: PWA, Telegram bot, TUI, **Herdi.app** (macOS menu bar plus a notch "Dynamic Island" panel, `herdi-mac/`), **Herdi iOS** (SwiftUI, Live Activity, widget, haptics, `herdi-ios/`), and herdi-win.
- Remote access is a `cloudflared` quick tunnel with a token, an Origin allowlist, mDNS, and a JSONL audit log.

**herdr access is CLI subprocesses only** (`_invoke_herdr`, :783): `pane list`, `pane read <id> --lines N --source visible|recent --format ansi`, `pane process-info`, `pane layout`, `pane focus --direction`, `pane send-text`, `pane send-keys`.
- It polls every 2 s.
- **Fast path**: a plugin `[[events]] on = "pane.agent_status_changed"` runs `on_event.py`, which reads `HERDR_PLUGIN_EVENT_JSON` / `HERDR_PLUGIN_CONTEXT_JSON` and sends a **UDP datagram to 127.0.0.1:8376**.
- The Mac app also has a "Direct (herdr CLI)" mode that shells out to `herdr pane list` itself (binary lookup: UserDefaults → `HERDR_BIN` → `which` → `/opt/homebrew/bin`, `~/.local/bin`).

**Multi-host.** `HERDR_REMOTES=host1,host2`. Every call becomes `ssh <ControlMaster opts> host HERDR_SESSION=… herdr …`. ControlMaster avoids 30 handshakes per minute.

**Terminal mirror.** `read_pane` with `format:'ansi', source:'recent'`, refreshed about every 3 s and reconciled per styled run (`web/js/mirror.js`).
The comments record a key fact: **agent TUIs run on the alternate screen, so herdr keeps no scrollback for them**. `recent` reads past the viewport cost about 31 ms per line and scroll the operator's terminal.

**Chat/history.** `relay/transcript.py` reads Claude, pi and kimi transcripts via `agent_session`. The uuid is regex-validated before it touches a path.
**Approvals** are screen-parsed (`detect_question`, `detect_approval_options`, `detect_checkbox_options`, `menu_cursor_row`…). Answers walk the menu with `send-keys Down…` + `Enter`, and a prompt hash rejects stale answers.

**Push.** Web Push (pywebpush) with `Topic: herdr-herd` and TTL 6 h (offline phones get only the latest), plus a "clear" push on unblock.
Telegram notifications can be replied to.
iOS uses local notifications and a Live Activity while connected. No APNs server was found (guess based on code size).

---

## 7. herdr-browser (ogulcancelik): renders Chromium inside a herdr pane

**Status: DEPRECATED** (HEAD `ab5c60b`). The successor is `zenbu-labs/terminal-browser` (Electron offscreen rendering → raw RGBA frame files → `pane.graphics.stream` `{"format":"rgba","file":{"path":…},"sequence":42,"revision":0}` with herdr acks).
The manifest was deleted at HEAD; the version below is from commit `be6888b`.

**How a browser pane is represented in herdr.** It is a **herdr plugin pane**: an ordinary terminal pane whose process is the plugin's viewer.
```toml
id = "official.browser"
[[panes]]
id = "browser"
title = "Browser"
placement = "split"
command = ["bun", "run", "src/viewer.ts"]
[[link_handlers]]
id = "localhost"
pattern = "^https?://(localhost|127\\.0\\.0\\.1|\\[::1\\])(:[0-9]+)?([/?#].*)?$"
action = "open-localhost"
```
It is opened like this (`src/herdr.ts`):
```
herdr plugin pane open --plugin official.browser --entrypoint browser --placement split|tab|zoomed|overlay
  [--direction right|down] [--target-pane P] --env HERDR_BROWSER_INITIAL_URL=<url> --env HERDR_BROWSER_VIEW_ID=<id> --focus|--no-focus
→ {"result":{"type":"plugin_pane_opened","plugin_pane":{"pane":{"pane_id":"…"}}}}
```
**The URL is stored only in the process environment** (`HERDR_BROWSER_INITIAL_URL`) and in the plugin daemon's own view registry (view_id ↔ pane_id ↔ url/title/tabs, `herdr-browser views`). **herdr's pane metadata does not record it.**
herdr injects these variables into the pane process: `HERDR_PANE_ID`, `HERDR_SOCKET_PATH`, `HERDR_BIN_PATH`, `HERDR_PLUGIN_ID`, `HERDR_PLUGIN_ENTRYPOINT_ID`, `HERDR_CELL_WIDTH_PX/HEIGHT_PX`.

**Rendering.**
- A Bun daemon owns Chromium over CDP.
- The viewer turns `Page.startScreencast` frames into PNG and sends them through herdr's graphics methods (`src/herdrGraphics.ts`):
  - `pane.graphics.info {pane_id}` → `{type:"pane_graphics_info", cell_width_px, cell_height_px}`
  - `pane.graphics.set {pane_id, format:"png", image_width, image_height, data_base64, placement:{viewport_col, viewport_row, grid_cols, grid_rows}}`
  - `pane.graphics.clear {pane_id}`
  - `pane.graphics.stream {pane_id}`: after the JSON ack, the socket carries `<json header {format,image_width,image_height,data_length,placement}>\n<png bytes>` frames.
- This needs `[experimental] kitty_graphics = true` in the herdr config.
- Terminal mouse, wheel and key input is mapped to CDP `Input.dispatch*`.
- A view-scoped **CDP gateway** (`cdp_http_url` / `browser_ws_url`) lets agents drive the visible browser with Playwright `connectOverCDP` or Chrome DevTools MCP.

## 8. herdr-plannotator (plannotator): "Herdr Browser panes"

Small glue code.
1. Plannotator's external-presenter hook runs `bin/herdr-plannotator-present` with one JSON request.
2. The helper runs `herdr plugin pane open --plugin official.browser --entrypoint browser --placement zoomed --target-pane <agent pane> --env HERDR_BROWSER_INITIAL_URL=<url> --focus` and parses the pane id.
3. **Readiness** is checked with `herdr pane wait-output <pane> --match <url origin> --source visible --timeout 5000`. The viewer draws its URL bar as text.
4. Close: `herdr plugin pane close <id>`, falling back to `herdr pane close`.

Capability check: `herdr plugin list --plugin official.browser --json` → `result.plugins[].{plugin_id, enabled, plugin_root}`. It then greps the installed `src/viewer.ts` for `HERDR_BROWSER_INITIAL_URL`, because the plugin version was never bumped.
Approvals stay inside the web page.

## 9. Test on local herdr 0.9.3: where can a placeholder pane hold a URL?

Test setup: one throwaway pane `w9:pH` that I created and then closed. Steps:
```
herdr pane split w9:p5 --direction down --no-focus --env HERDR_WEB_URL=https://example.com
herdr pane run w9:pH "printf '\033]2;web:https://example.com/a?b=1\007'; exec sleep 120"
herdr pane rename w9:pH "web https://example.com"
herdr pane report-metadata w9:pH --source herdlight --title Example --token url=https://example.com/x
herdr pane get w9:pH
```
Result (also seen in `pane.list`; values were still present about 6 s later; no TTL was given):
```json
{"label":"web https://example.com","terminal_title":"web:https://example.com/a?b=1",
 "title":"Example","tokens":{"url":"https://example.com/x"},"revision":2,"agent_status":"unknown", ...}
```
- `--env` on split or plugin-pane open is **not visible** through the API.
- `pane process-info --pane` exposes the foreground `argv` (`["sleep","120"]`), so a placeholder command such as `herdr-web <url>` is also readable.
- Options, from most to least durable (durability is a guess; restart persistence was not tested):

| Where the URL goes | Visible in the API as | Notes |
|---|---|---|
| **Pane label** (`pane.rename` / `herdr pane rename`) | `label` | Set by any client, no process needed. `pane.rename` emits no event (collie), so it is seen on the next snapshot. herdr's sidebar shows the label (guess: probably restored with the session). |
| **Process argv** (`pane run "<placeholder-cmd> <url>"`) | `pane process-info` → `foreground_processes[].argv` | Survives as long as the process lives. Needs an extra call per pane. |
| **OSC 2 title** printed by the placeholder process | `terminal_title` | Free, live, in `pane.list`. Lost if the process redraws its title. |
| **report-metadata token** | `tokens.url` (+ `title`) | Made for "display-only pane metadata". `--ttl-ms`/`--seq` exist. herdr-world always sends a TTL (≤24 h). Whether a report without TTL lasts forever or survives restart was not verified. |

---

## Lessons for our app

**Copy**
1. **No bridge server on the Mac. Talk to herdr's two sockets directly.**
   - `herdr.sock`: NDJSON, **one request per connection**, string `id`, <1 MiB lines. Plus one long-lived `events.subscribe` whose events only *poke* a debounced `session.snapshot` re-read (collie, termote). Re-snapshot after every subscribe ack (roamgate's `session.resync_required`).
   - Subscribe per pane for `pane.agent_status_changed` and rebuild that subscription when the pane set changes.
   - Gate the subscription set on `ping.protocol` / `capabilities`, because one unknown type rejects the whole subscribe.
2. **Live terminal: use `herdr-client.sock`, never `pane.read` polling.**
   - Ponytail rung 1: legacy direct attach (`TerminalHello{version:22}` + `AttachTerminal{terminal_id}` → `Terminal{full,bytes}` ANSI) fed into SwiftTerm/libghostty. Or exec `herdr terminal session observe|control` (NDJSON base64 frames), which also works over plain `ssh host herdr …`.
   - Rung 2: an **endpoint gen-1 shell per tab**. One socket carries the cell grid for *all panes of a tab* (rects, scroll, cursor, links), gives per-client tab focus without moving the desktop TUI, and accepts semantic input. Render the `CellData` grid natively; skip roamgate's grid→ANSI→xterm round trip.
   - Port `bincode.ts` (about 140 lines) to Swift. Pin versions and fail closed: enum indices were renumbered between herdr releases.
3. **Layout comes from herdr**: `pane.layout` (`area`, `panes[].rect`, `splits[]`), `layout.updated`, `pane.split/resize/zoom/swap/move`. Store nothing.
4. **Chat view = the agent transcript JSONL**, located via `agent_session {kind:"id"|"path", value}` from `pane.list`/`agent.list`/`agent.get`. Check `agent_session.agent == pane.agent`. Tail by byte offset, not by re-reading 100+ MB files.
   - Paths: claude `~/.claude/projects/**/<id>.jsonl`, codex `~/.codex/sessions/**/*<id>*.jsonl`, pi gives a direct `path`.
   - Fall back to the terminal view on *events* (no log yet, blocked), as collie's ADR 0082 does.
5. **Sending from chat: use `agent.prompt {pane_id, text}`.** herdr handles bracketed paste and Enter as one ordered submission, and refuses with `agent_blocked` when a dialog is open. That refusal is the cheapest guard against the "blind Enter approved a permission dialog" bug.
   - Otherwise use `pane.send_input {pane_id, text, keys:["enter"]}`.
   - Serialise input per pane, because herdr may reorder concurrent sends.
6. **Approvals: start with status only.** `agent_status == "blocked"` → badge, then switch the pane to the terminal view with a key bar (Esc, 1–9, ↑↓, Enter).
   - Screen grammars (collie: about 34 fixtures, termote: about 100 screens) are high-maintenance scar tissue. If we add one-tap approve later, copy the **prompt binding**: re-read `pane.read {source:"visible", format:"ansi"}` and compare a signature immediately before `send_keys`.
7. **Notifications: one passive endpoint shell per host (`surface_active:false`)** delivers herdr's own `SemanticNotification` (needs_attention/finished with pane_id). Map it to `UNUserNotificationCenter`.
   - Copy collie's coordinator: about 30 s debounce, one coalesced summary, retract on resolve.
   - iOS background push needs APNs from something always on (guess: the Mac app or a tiny host relay). Payload ids only (termote).
8. **Multi-host = SSH forwarding of both unix sockets** (`-L local:remote/herdr.sock -L …herdr-client.sock`, `StreamLocalBindUnlink=yes`, `ExitOnForwardFailure=yes`, `ServerAliveInterval=20`).
   - No remote install beyond herdr. Key every id by `(host, id)` and stamp a per-host generation so stale replies are dropped.
   - On iOS, use an SSH library with `direct-streamlocal@openssh.com` channels (guess: swift-nio-ssh/Citadel, not verified).
9. **Web-page pane**: herdr-browser proves that a "browser pane" is just a plugin pane running a process. The URL lives only in env and daemon state, so we can't reuse it as-is.
   - Our placeholder: a pane that runs a tiny idle command, e.g. `printf '\e]2;herdr-web:%s\a' "$URL"; exec sleep infinity` or a `herdr-web <url>` script. It should also print the URL as text, so the TUI shows something useful and `pane wait-output` works.
   - Then `pane.rename` the label to the URL, or set `report-metadata --token url=…`.
   - The native UI detects `terminal_title`/`label` prefix `herdr-web:` (or `tokens.url`) and draws a WKWebView in that rect.
   - Optionally ship it as a herdr plugin `[[panes]]` entrypoint, so the TUI can open one with `herdr plugin pane open --env URL=…`, plus a `[[link_handlers]]` that turns clicked URLs into web panes.
10. **Mobile UX worth copying:**
    - Terminal tap scrolls and doesn't pop the keyboard; an explicit keyboard button.
    - A configurable floating key grid (roamgate defaults), sticky Ctrl, swipe gestures (termote: left = Ctrl+C, right = Tab, pinch = font).
    - Composer with OS dictation; image = upload to host and insert the path.
    - Drafts in memory only. "Needs you" hoisted, but rows never reorder on status change (collie ADR 0063).
11. **Never steal desktop focus.** Pass `focus:false` on every create. Only call `pane.focus` on the *control* socket after an explicit "show in terminal" action. Endpoint-shell focus is per client and safe.

**Avoid**
- `pane.read` with `source:"recent"` and `lines > viewport_rows` in any background path. It visibly scrolls the user's terminal and takes seconds.
- Assuming agent panes have scrollback: they are alt-screen. History comes from the transcript.
- Trusting `revision` (a stub) or an RPC ack as proof the TUI acted.
- Chunking long sends (a `\n` at a boundary submits half a message). Use `agent.prompt` or bracketed paste.
- `herdr` names that are wrong for `send_keys`: `PageUp`, `Home`, `End`, `Delete`, `C-c`.
- `control`/takeover or endpoint resize without user intent: the last-interacting client wins the shared geometry. Phone views should observe at the desktop size and scale or pan.
- Bridge-era complexity: collie's crew mTLS (3k-line protocol), roamgate/world's leases everywhere (190–290k LOC), alecuba16's re-implemented multiplexer. A native app on the sockets (plus SSH forwards) removes all of it.
- Storing the web-pane URL in the app (termote keeps tab metadata in localStorage). Keep it in herdr (label, title or token).
