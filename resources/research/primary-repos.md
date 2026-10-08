# Primary reference repos: herdr-gpui, herdr-web-ui, herdrup, agentaps

Researched 2026-10-08. Shallow clones are in `/tmp/herdr-research/<repo>`. The facts below come from the code.
Guesses are marked. Local herdr is v0.9.3, protocol 22, so method claims were checked against
`herdr api schema --json` and `herdr status client --json`.

## TL;DR

| | herdr-gpui | herdr-web-ui | herdrup | agentaps |
|---|---|---|---|---|
| Platform | Rust GPUI desktop (macOS first) | Bun server + React/xterm.js PWA | Swift/SwiftUI iOS (iPad app on Mac) | Rust GPUI desktop + GPUI-WASM web |
| Uses herdr? | yes | yes | yes, but **needs the jerryfane/herdr fork** | **no** (ACP client that runs its own agents) |
| herdr transport | **binary client-shell endpoint** on `herdr-client.sock` (u32 length + bincode-2, JSON payloads inside) | JSON API `herdr.sock`, one connection per RPC, plus `events.subscribe` | JSON API over SSH exec of the fork-only `herdr api-bridge` | n/a (ACP JSON-RPC over agent stdio) |
| Live terminal | herdr renders on the server: pushed **cell grids** for the focused tab (splits included). No emulator. Custom GPUI painter | `herdr terminal attach <terminal_id>` in a node-pty sidecar → WS → **xterm.js** (`scrollback:0`) | fork-only `pane.stream` (base64 PTY bytes, reset keyframes) → vendored **SwiftTerm** | none for agents. A local `$SHELL` drawer through **libghostty** |
| Status | pushed snapshot (`agent_status`) | `pane.agent_status_changed` per-pane subscription + snapshot | fork events_v2 / `agent.list` polling | ACP `session/update` |
| Layout | herdr's splits drawn inside the grid. Side-by-side tabs need one connection each | **one pane at a time**. Splits become a pane menu | one pane at a time, agent-centric. Ignores workspaces and tabs | its own split tree of chat panes |
| Chat view | none | **yes: agent session JSONL located through herdr `agent.get`** + screen-parsed prompt cards | none ("gram" is an explicit message channel, fork only) | yes, from ACP events |
| Remote hosts | `ssh host … exec herdr --session S remote-client-bridge` (same binary protocol over stdio). All hosts connected at once | SSH local-forward to the **same bridge installed on each remote PC**. One hub server | SSH (Citadel) exec. Multi-machine through fork daemon federation | `ssh -T host 'exec agent'` per agent |
| Mobile link | none | user brings Tailscale (`tailscale serve` + QR), or SSH/VPN/proxy | SSH over Tailscale, QR pairing adds an ssh key | **iroh** QUIC (n0 relay from WASM), QR with `endpointId:oneTimeToken` |
| Push | local OS notifications from herdr `SemanticNotification` | **Web Push (VAPID)** on blocked/done from the status collector | **APNs** sent by the fork daemon through a Cloudflare Worker relay | none (desktop OS notifications only) |
| Web panes | client-only WKWebView "browser tabs" tied to `workspace_id`, saved in local JSON. Agents open them through an app control socket | none (has a file viewer) | none | none |

### Key findings for our app
1. **Upstream herdr has two client surfaces.** Both are usable today:
   - **JSON API** (`herdr.sock`): one request per connection, plus long-lived `events.subscribe`.
     It gives `session.snapshot`, `pane.read`, `send_text/keys`, `agent.prompt`, `agent.get`, `layout.export`, and more.
     Live bytes come only through `herdr terminal attach <terminal_id>`, a CLI on a PTY. Only one direct-attach
     client is allowed per terminal (`attach_held`, `--takeover`).
   - **Client-shell endpoint** (`herdr-client.sock`, the protocol the TUI and `herdr --remote` use): pushed
     snapshots + pushed **server-rendered cell grids** with pane rects and split handles, semantic input, and an
     allowlisted JSON-RPC lane. Remote access is `herdr remote-client-bridge` over ssh stdio.
     The cost: bincode is positional, so Swift needs a hand-written codec.
2. **Chat = the agent's own transcript file, found through herdr.** web-ui proves this. `agent.get {target}` →
   `agent.agent_session = {agent, kind:"id"|"path", source, value}`: a Claude session UUID →
   `~/.claude/projects/<proj>/<uuid>.jsonl`, or a pi/omp absolute JSONL path. Codex needs open-file-descriptor
   detective work (`lsof`) because its hook reports the wrong thread. Prompts and approvals are NOT in the
   transcript: web-ui parses them off the visible screen (`pane.read source:"detection"`) with per-agent regexes
   and answers with `pane.send_keys` arrow navigation. Sending uses `agent.prompt {target,text}` (herdr pastes,
   then presses Enter), with `send_text` + `send_keys Enter` as the fallback.
3. **Nobody renders a cross-tab strip of live panes.** gpui gets one surface per connection (the focused tab).
   web-ui and herdrup show one pane at a time. herdrup keeps an LRU of hidden live terminals so swiping is
   instant. That is the closest to our strip.
4. **Mobile transport options seen:** Tailscale + HTTPS (web-ui), SSH + Tailscale QR pairing (herdrup),
   iroh p2p (agentaps). **Push:** only herdrup does APNs, and it needs fork daemon support plus a relay.
   web-ui's server-side status collector → push is the upstream-compatible pattern.
5. The local schema lists `pane.report_metadata`, `workspace.report_metadata` and `agent.view.set`. None of the
   four repos uses them. They may be a way to tag a placeholder pane with a URL for our WEB pane
   (to verify; this is a guess).

---

## devswha/herdr-web-ui (browser + phone PWA, chat view, remote PCs over SSH, web push)

Clone: `/tmp/herdr-research/herdr-web-ui` (commit 4f074f4, 2026-10-08, v0.4.1). ~72k LOC TS.
The most complete herdr client of the four, and the only one with a real chat view. The design notes in its
`AGENTS.md`, `server/AGENTS.md` and `src/AGENTS.md` record many hard-won, live-verified herdr facts (quoted below).

### Architecture
- **Stack:** React 18 + `@xterm/xterm` 5.5.0 (patched) in the browser (`src/`). Bun.serve backend (`server/`) that
  bridges herdr's newline-JSON unix socket. `shared/` holds the wire contract (`shared/protocol.ts`, plus
  `shared/herdr-api.generated.ts`, generated from the herdr API schema "protocol 22, schema_version 1").
- **Ships as a herdr plugin** (`herdr-plugin.toml`, `min_herdr_version = "0.9.0"`): `[[build]]` runs `bun install` +
  `vite build`; `[[startup]]` runs `bun scripts/plugin.ts start` on every herdr start; `[[actions]]` start/stop/status;
  a `[[panes]]` entry `phone` opens a zoomed herdr pane that prints the phone-setup QR code.
- **Stated rule:** "The app is only a bridge: herdr owns every pty, scrollback and agent state."
- **PTY sidecar:** Bun cannot load node-pty, so `server/pty/pty-host.mjs` (Node + `@lydell/node-pty`) runs one command
  on a real PTY: `herdr terminal attach <terminal_id>`. Its stdin protocol is NDJSON
  `{"t":"i","d":text}` (write), `{"t":"r","c":cols,"r":rows}` (resize), `{"t":"p","paused":bool}` (flow control).
  Stdout is the raw PTY bytes.

### herdr socket usage (`server/herdr/client.ts`)
- **One connection per RPC.** "herdr closes the socket after each response". Frame `{"id","method","params"}\n` →
  `{"id","result"}` or `{"error":{"code","message"}}`. Timeout 10 s. No pooling.
- **Methods used:** `ping` (→ `{version, protocol, capabilities}`; `capabilities.direct_terminal_attach`),
  `session.snapshot` (→ `{snapshot:{workspaces,tabs,panes,agents,layouts,...}}`), `server.agent_manifests`,
  `workspace.create {cwd,label,focus:false}`, `workspace.rename/move{insert_index}/close{close_group}`,
  `tab.create {workspace_id,cwd,label,focus:false}`, `tab.rename`, `tab.close`, `pane.rename`, `pane.close`,
  `pane.read {pane_id, source: "visible"|"recent"|"recent_unwrapped"|"detection", format:"text"|"ansi", strip_ansi, lines}`,
  `pane.get` (for `pane.scroll` info), `pane.scroll {pane_id, offset_from_bottom}`,
  `pane.selection.read {pane_id, anchor:{row,col}, cursor:{row,col}}`, `pane.send_text {pane_id,text}`,
  `pane.send_keys {pane_id, keys:[...]}`, `pane.process_info {pane_id}` ("takes `pane_id`, not `target`. Given
  `target`, it silently answers for the focused pane"), `agent.get {target}`, `agent.start {name,kind,pane_id,args,timeout_ms}`,
  `agent.prompt {target,text}`, `worktree.create/list/open/remove`.
- **Events:** `events.subscribe {subscriptions:[...]}` keeps the socket open. First frame `result.type =
  "subscription_started"`, then event frames. Facts from `server/collector.ts`:
  - `pane.agent_status_changed` REQUIRES `pane_id`; one connection can carry many per-pane subscriptions.
  - A second `events.subscribe` on an open connection is silently ignored → reopen with the full set when panes change.
  - `pane.created` / `pane.closed` / `pane.exited` / `pane.focused` subscribe globally (no pane_id).
  - Status frames are flat `{event:"pane.agent_status_changed", data:{pane_id, agent_status,...}}`; structure frames
    carry snake_case `data.type`, e.g. `{event:"pane_focused", data:{type, pane_id, workspace_id}}`.
  - herdr ≥0.9.2 closes a subscriber that falls behind (`events_lost`, which may not arrive). Correct order:
    subscribe → wait for `subscription_started` → `session.snapshot` → diff against last-told status.
  - `server/collector.ts` is the ONLY status subscription. It fans out over the browser WS and SSE. There is a 60 s
    backstop snapshot. The browser also polls `/api/session` every 5 s.

### Live terminal bytes and rendering
- **Attach, not polling.** One `herdr terminal attach <terminal_id>` child per pane per bridge (through the PTY
  sidecar). It is shared by all browser clients of that bridge, and late joiners get a 256 KiB replay tail.
  The attach stream is a screen-diff stream that herdr renders: "herdr's screen-diff attach stream consumes OSC 52
  before clients".
- **One direct-attach slot per terminal.** A second attacher gets `attach_held` ("already has an attached client …
  retry with --takeover"). They never pass `--takeover` on their own. Only an explicit user "Open here" does.
  "The herdr TUI stays connected" during a takeover. Only another `terminal attach` client is displaced.
- **xterm.js in the browser** with `scrollback: 0`: "never rebuild an attached terminal from `pane.read`. The attach
  byte stream is the source of truth". herdr owns scrollback. The browser scrolls it with `pane.scroll` and copies
  with `pane.selection.read`. Unicode width table "15-herdr" so wide glyphs match herdr's layout.
- **Flow control** (`docs/terminal-flow-control.md`): the client acks after xterm's write callback (`pty-ack
  {stream_id, offset}`). The bridge pauses PTY reads at 256 KiB outstanding and resumes at ≤64 KiB. A client stalled
  for 2 s is closed with WS code 4008.
- **Input:** WS `input {pane_id,text}` → written to the attach PTY (the fast path). WS `keys {pane_id, keys}` →
  `pane.send_keys`, "so Herdr encodes the target pane's keyboard protocol". `resize` → PTY resize. The resize of the
  attach PTY resizes the herdr pane's terminal.
- **Roles:** `interact` vs `observe`. An observer cannot type or resize, and it adopts the pane geometry (`pane-geometry`).
- **Mirror fallback** (`server/mirror.ts`) where attach is missing (Windows): poll `pane.read source:visible
  format:ansi` a few times a second, send only changed rows, and type through `pane.send_text`.
- WS frames (`shared/protocol.ts`), client→server: `attach{pane_id,cols,rows,flow_control?}`, `detach`, `take-over`,
  `input`, `keys`, `resize`, `submit{id,pane_id,text,payload,delivery:"immediate"|"queue"}`, `pending-action`,
  `secret`, `pty-ack`, `role`. Server→client: `snapshot{snapshot,features}`, `pty-data{pane_id,data,flow}`, `pty-exit`,
  `pane-geometry`, `pane-status`, `pane-exited`, `session-changed`, `submit-result`, `pending-messages`, `error`.

### Layout / UI ↔ herdr mapping
- **One pane at a time.** `src/components/TabStrip.tsx`: "The app shows one pane at a time, so a tab with several
  panes" gets a pane menu. herdr splits are NOT drawn. A tab opens the last-viewed pane, else
  `snapshot.layouts[].focused_pane_id`, else the first.
- **Sidebar:** PC → workspace → pane. Status roll-up per workspace in herdr's order: blocked > done > working > idle
  (`rollupStatus`, `src/lib/status.ts`). Labels: idle→READY, working→RUN, blocked→INPUT, done→DONE. There is also a
  separate "Agents" list joined from `snapshot.agents`. Workspace drag uses `workspace.move`. Worktree groups come from
  `worktree.list`.
- **Local storage:** UI preferences in one localStorage record. Per-pane view (`chat`/`terminal`), drafts and the
  last-viewed pane per tab are keyed `paneStorageId(machineId, paneId)`. The server stores push subscriptions, VAPID
  keys, paired devices (token hashes) and `machines.json` (remote PC registrations + last snapshot). Everything else is
  fetched from herdr.

### CHAT view (the key part)
**Where messages come from: the agent's own session transcript files, read-only, located through herdr.** Terminal
screen scraping is only the fallback. `server/conversation.ts` header:
- **Claude Code:** `agent.get {target: pane_id}` → `agent.agent_session.value` = session UUID (reported by herdr's
  Claude hook). File: `~/.claude/projects/<project>/<session>.jsonl` (`server/claude-store.ts`). It honours
  `CLAUDE_CONFIG_DIR` from the process's environment, found through `pane.process_info.foreground_processes[].pid`. If
  herdr has no id, it falls back to Claude's own PID record for that process.
- **pi / omp:** `agent.get` → `agent_session = {agent, kind:"path", source, value:"/abs/…jsonl"}`. It accepts only
  paths inside `~/.pi/agent/sessions/` (or `PI_CODING_AGENT_SESSION_DIR`/`PI_CODING_AGENT_DIR`) or
  `~/.omp/agent/sessions/`. "herdr's integration re-reports the session file on every `session_start`, so `/new`,
  `/resume`, `/fork` and `/clone` need no inference". pi's file is an entry tree (the `/tree` command moves the leaf),
  so `server/pi-tree.ts` projects it onto the active branch.
- **Codex:** the hardest case. `agent.get` gives a thread id from Codex's SessionStart hook, but "a hint, not proof":
  since Codex 0.157 the hook runs in a shared app-server daemon and reports every TUI's thread to the first pane. So
  `server/codex.ts` checks the rollout files the Codex processes hold open (`lsof -nPbw -a -p <pids> -Fn` on macOS,
  `/proc/<pid>/fd` on Linux), reads `CODEX_HOME` from the process environment, and matches on unique pane text as a
  tiebreaker. Rollouts can be hundreds of MB, so reads are paged (`TRANSCRIPT_WINDOW_BYTES = 16 MiB`).
- **omo / gjc:** found through the pane's process tree (`pane.process_info`). herdr's label is unreliable for them.
- **Fallback for unrecognised panes** (shells, unknown agents): `/api/pane/conversation` answers `{source:"scrollback"}`.
  The client then fetches `pane.read source:"recent" format:text` and splits it into bubbles with heuristics
  (`src/lib/transcript.ts`: the `❯` prompt echo = user, full-width `─━═` rules = turn breaks, status chrome dimmed).
- **Wire shape:** `GET /api/pane/conversation?pane_id&before|since|from` →
  `{source, turns:[{role:"user"|"assistant", ts, end_ts, parts:[...]}], metadata:{model, reasoning_effort}, cursor,
  history_id}` with an ETag (304 when unchanged). Part kinds: `text{phase?}`, `thinking`, `tool{name,summary,input,
  output,error,output_ref,images}`, `image{media_type,ref}`, `compact`, `notice`, `skill`, `task_result`. The client
  polls every 2 s (`ChatView.tsx POLL_MS = 2000`). A cache keyed by inode/size/mtime makes unchanged polls cheap. Long
  tool output is cut and fetched on demand (`/api/pane/conversation/tool-output`). Images come from
  `/api/pane/conversation/image`.
- **Rendering:** `splitTurn` folds tool calls, thinking and narration into one collapsible "work block" per turn.
  Each tool row is "verb + object" (`lib/toolVerbs.ts`). Markdown with KaTeX. A session panel lists derived activity.

**Sending a chat message** (`server/index.ts submitText`):
1. If an agent is in front: herdr's **`agent.prompt {target, text}`**. "pastes `text` into the pane's agent
   (bracketed), then its Enter 300ms later … Refuses with `agent_blocked` while the agent waits for an answer,
   `agent_not_found` / `agent_not_ready` without an agent".
2. Otherwise (or after `agent_not_found`/`agent_not_ready`): `pane.send_text` with the text wrapped in bracketed
   paste `\e[200~…\e[201~`, then `pane.send_keys ["Enter"]` `SUBMIT_DELAY_MS` later.
- **Messages typed while the agent works:** a server-owned "pending input" list (`server/pending-input.ts`). It is
  delivered automatically on the next idle/done only while the original connection is live. It is never resent after
  a disconnect, and an unknown delivery outcome is never retried. Before delivery it re-reads the screen
  (`pane.read source:"detection"`) and refuses if a menu, a password prompt or `blocked` status shows.
- Composer extras: `/` slash commands (per-agent built-ins + `.claude/commands/**/*.md`), `@` file mentions (git
  inventory), image paste (saved under `<pane cwd>/.herdr-web-ui/`, path inserted), voice dictation, Stop = Escape key.

**Approvals, questions, blocked prompts** (`server/prompt.ts`, 3k LOC): these come from the **visible screen**, not from
transcripts or hooks. `GET /api/pane/prompt` reads `pane.read source:"detection"` and runs per-agent regex parsers.
There are 27 "responders" (`claude-approval`, `claude-question`, `claude-plan`, `codex-approval`, `codex-question`,
`omp-*`, `pi-question/confirm/input/model`, `omo-*`, `fallback-menu`, `fallback-keys`…). Each turns the screen into
`InteractivePrompt {id (hash of text + asking), agent, kind: question|approval|plan|menu, title, question, body,
options[{label,description}], multi_select, custom_option_index}`. ChatView polls it every 2 s **whatever the status**:
"a menu can wait while herdr reports idle". The card answers with
`POST /api/pane/prompt/answer {pane_id, prompt_id, option_index|option_indices|custom_text}`. The server turns this into
**`pane.send_keys` navigation (↑/↓ then Enter/space, never digits)** and re-reads the screen between moves. A stale
`prompt_id` gets 409. There are special cases, for example Claude's `/model` list is answered with `s`, never Enter.
Masked password prompts use a separate `secret` WS frame (`send_text` + Enter; the value is never stored).

### Multi-host (remote PCs)
`docs/remote-pcs.md`: `Browser → connection server → OpenSSH local forward → remote loopback bridge → herdr Unix socket`.
- "Add PC" takes an SSH alias. The server uses its own OpenSSH config and ssh-agent. Host-key and password prompts are
  relayed through an askpass unix socket. It can register an app-specific ed25519 key (`<stateDir>/ssh/<machine-id>`).
- Setup installs a private, checksum-pinned runtime bundle (Bun + Node + node-pty + a pinned herdr fallback) on the
  remote and starts the **same bridge** there on loopback. It never stops a running herdr.
- The local server keeps one status-only WS per remote PC and merges rosters into SSE `/api/machines/events`. Terminal
  WSs are `/ws?machine_id=…`. Allowlisted routes go through a proxy at `/api/machines/:id/{session,agents,pane/*,workspace/*}`.
- So the design is a daemon on every host plus an SSH tunnel to it, with one "connection server" as the hub.

### Mobile connection and auth
- PWA (installable, service worker `public/sw.js`), with a key bar (Esc/Tab/Ctrl/Alt/arrows) above the soft keyboard.
- **Transport:** it ships no relay or tunnel of its own. The user brings Tailscale, an SSH tunnel, a VPN or a
  reverse proxy. The installer runs `tailscale serve --bg --https=<port> http://127.0.0.1:7317` and prints a QR code
  of the tailnet HTTPS URL. HTTPS is needed for PWA install and push.
- **Auth** (`server/access.ts`, `auth.ts`, `devices.ts`): trust by origin. Loopback is allowed. Through `tailscale
  serve`, the `Tailscale-User-Login` header must equal the PC's own login. Other devices pair with a **six-digit code
  valid 10 minutes** (`?pair=CODE` in the QR); the device token is stored only as a hash, in an HttpOnly SameSite=Strict
  cookie. An optional shared token exists too. Device roles: `drive` | `watch`.

### Push notifications
- **Web Push (VAPID)** from the server (`server/push.ts`, `web-push` lib, `generateRequestDetails` + `fetch`). Keys and
  subscriptions are stored server-side.
- **Trigger:** the collector's status events. `shouldNotifyStatus(prev,next)` = changed AND next ∈ {blocked, done}. The
  first sighting is ignored. "done" only after a long turn by default (`prefs.done: off|long|always`). Urgency is high
  for blocked, TTL 12 h. Tag = one notification slot per pane. Payload `{machine_id?, pane_id, title, body, tag}`.
- Tab-level notifications use the same policy (`shared/notify-policy.ts`) and are skipped when the device has push.

---

## penso/herdr-gpui — in-depth analysis

Repo: https://github.com/penso/herdr-gpui (shallow clone at `/tmp/herdr-research/herdr-gpui`,
HEAD `3871183`, 2026-10-07). About 234k lines of Rust, most of it tests and UI.
Facts below come from the code and the READMEs. Guesses are marked **(guess)**.

### TL;DR

- This is a GPUI (Zed's UI framework) desktop app for macOS, with experimental Linux and Windows builds.
  It **does not emulate a terminal** and **does not use the JSON API socket** (`herdr.sock`).
- It speaks herdr's **binary "client shell endpoint" protocol** on `herdr-client.sock`. Frames are
  length-prefixed bincode. The herdr TUI client and `herdr --remote` use the same split.
- herdr **renders server-side**. It pushes a ready-made cell grid (`PaneSurfaceFrame`) of the
  client's *focused tab*, already laid out with splits. It also pushes a full JSON state
  snapshot (`ClientShellSnapshot`) every time the state changes. Both are push-based, with no polling.
- Input goes up as *semantic* events (`ClientShellPaneInput { pane_id, events: [Key|TextCommit|Mouse|Paste] }`).
  Commands go up as JSON-RPC strings tunnelled in `ClientShellEndpointRequest`
  (`pane.split`, `tab.focus`, `layout.set_split_ratio`, …).
- Remote hosts: `ssh host sh -c '<discover herdr>; exec herdr --session S remote-client-bridge'`.
  The same binary protocol runs over the ssh child's stdin/stdout. There is no mobile app, relay,
  push, or chat view.
- Web pages are **client-only "browser tabs"** (WKWebView through wry), saved in a local JSON file.
  herdr never sees them.

### 1. Architecture

Cargo workspace (`Cargo.toml`), Rust edition 2024, `unsafe_code = "deny"`:

| crate | lines | role |
|---|---|---|
| `crates/herdr-protocol` | ~2.8k | Wire types copied from herdr 0.9.1 `src/protocol/{wire,endpoint}.rs` (see `NOTICE.md`). Bincode framing, plus decoders for surface scroll, delta and reuse. |
| `crates/herdr-client` | ~14k | Connection worker thread, handshake, revision fencing, request lane, SSH/WSL bridge, saved-host catalog, sessions list/delete, port forward, file upload. |
| `crates/herdr-gpui` | ~217k | The app: sidebar, tab strip, terminal painter, browser tabs, review/diff, PR lookup, usage meters, "Teleport", notifications, sound, settings, updater. |

Main dependencies: `gpui-pre =0.3.6`, `gpui-wry`/`lb-wry` (embedded WebKit), `bincode 2` (serde,
standard config), `serde_json`, `crossbeam-channel`, `rodio` (sounds), `syntect` (diffs), `ureq`,
`rusqlite` (browser cookies for usage providers), `objc2-*` (dock badge, WKWebView snapshot),
`security-framework` (Keychain). There is **no terminal-emulator crate** (no alacritty_terminal,
vte, or libghostty).

### 2. Transport and handshake (herdr socket)

**Socket discovery** (`herdr-client` README, "Local Discovery"): first `HERDR_SOCKET_PATH` (the
client socket name is derived from its stem as `-client.sock`), then `HERDR_CLIENT_SOCKET_PATH`,
then `HERDR_SESSION` (default `default`). The path is `~/.config/herdr/herdr-client.sock`, or
`sessions/<name>/herdr-client.sock` for a named session. The docs stress: "`--socket` must name
the binary **client** socket, not the JSON API socket." If no local server is running, the app
starts `herdr server` (`src/daemon.rs`).

**Framing** (`herdr-protocol/src/codec.rs`): each frame is a `u32` little-endian length followed
by a bincode-2 `standard()` payload (varint ints; an enum is a varint variant index followed by
its fields in order). Caps: 2 MiB outbound and 32 MiB inbound (graphics). Field order and variant
order are the contract: `// Field and variant order MUST remain unchanged: bincode uses positional encoding.`

**Handshake** (`herdr-client/src/session.rs:175-197`). The client sends
`ClientMessage::EndpointControl { kind: "endpoint.hello.v1", data: <JSON> }`:

```json
{ "generation": 1, "cell_width_px": 8, "cell_height_px": 16,
  "surface_size": {"cols": 80, "rows": 24}, "pixel_mouse": true,
  "direct_graphics": false, "endpoint_keybindings": false, "mouse_capture": false,
  "surface_active": true, "surface_reuse": true, "surface_delta": true, "surface_scroll": true,
  "snapshot_codecs": ["shell.snapshot.v1"], "surface_codecs": ["shell.surface.v1"],
  "input_codecs": ["shell.input.semantic.v1"], "blob_codecs": ["shell.blob.v1"] }
```

The server replies `EndpointControl { kind: "endpoint.welcome.v1", data }`:

```json
{ "generation": 1, "server_version": "0.9.3", "snapshot_codec": "shell.snapshot.v1",
  "surface_codec": "shell.surface.v1", "input_codec": "shell.input.semantic.v1",
  "blob_codec": "shell.blob.v1", "methods": ["pane.focus", ...],
  "capabilities": ["surface_interest","presentation_effects_fence","health_check", "surface_delta", ...] }
```

`methods` is a **server allowlist** of JSON-RPC methods this connection may call. The client
refuses to send anything not listed (`Method::advertised_in`). A daemon older than 0.9.0 answers
with a legacy `ServerMessage::Welcome` and is rejected (`Error::LegacyDaemon`).

The installed herdr agrees with this (read-only check): `herdr status client --json` →
`{"version":"0.9.3","protocol":22,"endpoint_protocol_generation":1,"endpoint_capabilities":["surface_interest","presentation_effects_fence","health_check"],"remote_host_bridge":true,"remote_bridge_idle_timeout":true,...}`.

**Server → client messages** (`wire.rs: enum ServerMessage`):
- `EndpointControl{kind:"shell.snapshot.v1", data:<JSON ClientShellSnapshot>}`: the **full** state,
  pushed on every change. `revision` only goes up within one `boot_id`. A changed boot or a lower
  revision causes a disconnect.
- `PaneSurface(PaneSurfaceFrame)`: a full cell grid. `PaneSurfacePatch` carries row patches
  against `base_surface_revision`.
- Optional encodings arrive as `EndpointControl` kinds: `endpoint.surface-scroll.v1` (base64
  bincode), `endpoint.surface-delta.v1` (base64), and `endpoint.surface-reuse.v1` (JSON).
- `ClientShellEndpointResponseChunk{boot_id, request_id, final_chunk, data}`: the JSON-RPC
  response, which may arrive in chunks.
- `SemanticNotification{kind: NeedsAttention|Finished|UpdateInstalled|Custom, title, body, sound, agent, workspace_id, tab_id, pane_id, position}`.
- `Clipboard{data}` (OSC 52), `TerminalBell{count}`, `WindowTitle`, `ServerShutdown`,
  `ClientShellKeyboardReportAll`, `MouseCapture`, `GraphicsFile`, and legacy `Notify`.

**Client → server messages** (`enum ClientMessage`, the subset in use):
`ClientShellPaneInput{pane_id, events}`, `ClientShellPopupInput{terminal_id, events}`,
`ClientShellResize{cell_width_px, cell_height_px, surface_size, pixel_mouse}`,
`ClientShellEndpointRequest{boot_id, request:<JSON string>}`, `ClientShellFocus{focused}`
(window focus), `ClientShellHostTheme{update}` (lets herdr answer OSC 10/11/4 colour queries),
`ClipboardImage{target, extension, data}`, and `EndpointControl{kind:"endpoint.health.ping.v1"}`.

**JSON-RPC envelope** (`herdr-client/src/handle.rs:240`):

```rust
let request = json!({"id": id, "method": method.as_str(), "params": params}).to_string();
self.enqueue(boot_id, ClientMessage::ClientShellEndpointRequest { boot_id: boot_id.into(), request }, ...)
```

The response is the endpoint's `{id,result}` or `{id,error}`. Only **one request is in flight**
at a time; later commands wait in FIFO order (60 s request deadline).

**Methods the GUI calls** (`herdr-client/src/method.rs`, the full closed set):
`client_shell.surface.set`, `command.invoke`, `integration.list|install`, `layout.set_split_ratio`,
`pane.clear|close|copy_motion|copy_search|edit_scrollback|focus|focus_direction|input.set|link.activate|link.resolve|rename|resize|scroll|selection.read|split|swap|zoom`,
`product_announcement.dismiss`, `release_notes.dismiss`, `server.reload_config`,
`tab.close|create|focus|move|rename`, `workspace.close|create|focus|move_block|rename`,
`worktree.create|list|open|remove`.
Example param shapes from the code:

```json
{"method":"pane.split","params":{"target_pane_id":"w1:p1","direction":"right","focus":true}}
{"method":"pane.zoom","params":{"pane_id":"w1:p1","mode":"on"|"off"|"toggle"}}
{"method":"pane.swap","params":{"source_pane_id":"…","target_pane_id":"…"}}
{"method":"pane.focus_direction","params":{"pane_id":"…","direction":"left"}}
{"method":"layout.set_split_ratio","params":{"tab_id":"w1:t1","path":[true,false],"ratio":0.42}}
{"method":"tab.move","params":{"tab_id":"…","insert_index":2}}
{"method":"tab.create","params":{"workspace_id":"w1","focus":true}}
{"method":"pane.input.set","params":{"pane_id":"…","right_click":"herdr"|"pane"}}
{"method":"client_shell.surface.set","params":{"active":false}}
```

The endpoint allowlist does **not** cover layouts, process details, or agent sessions
(`teleport.rs`: "The GUI connection's method allowlist lacks layouts, process details, and agent
sessions"). For those, the app runs the `herdr` CLI, locally or over SSH: `herdr pane run`,
`herdr agent start`, `herdr session list|stop|delete --json`, `herdr machine add|rename|remove`,
and `herdr worktree remove`.

**Threading and liveness** (`herdr-client` README, "Transport Rules"): one worker thread per
connection owns connect, writes and reads. A bounded queue (64 commands, 8 events) applies
backpressure. The GUI drains every connection's inbox on a **16 ms timer**
(`window.rs:647`, `endpoint/polling.rs::poll_endpoints`). Over SSH, a quiet link triggers
`endpoint.health.ping.v1` after 5 s, and the link is declared dead 10 s later with no reply.

**Reconnect**: the client crate has none ("No reconnect or replay"). The GUI owns it per
endpoint: `Duration::from_millis(500u64 << attempts.min(8)).min(30s)` (`endpoint.rs:315`). On
reconnect the GUI does a fresh handshake and gets a full snapshot and surface. Input is never
replayed.

### 3. Live terminal content and rendering

- **No PTY bytes reach the client.** herdr has its own emulator server-side. It sends
  `PaneSurfaceFrame`:

```rust
pub struct PaneSurfaceFrame { boot_id, projection_revision: u64, surface_revision: u64,
    frame: FrameData,            // whole client-sized grid of the focused tab
    panes: Vec<PaneSurfacePane>, // per pane: pane_id, rect, inner_rect, scrollbar_rect, scroll{offset_from_bottom,max,viewport_rows}, focused, mouse_reporting, alternate_screen_active
    splits: Vec<PaneSurfaceSplit>, // direction, pos, area, hit_rect, path: Vec<bool>
    popup: Option<Box<ClientShellPopupSurface>>, graphics: SurfaceGraphicsScene }
pub struct CellData { symbol: String, fg: u32, bg: u32, modifier: u16, skip: bool, hyperlink: Option<u32> }
// colours: 0..=16 named (0 = default), 0x010000XX indexed, 0x02RRGGBB rgb
```

- **Fencing**: a surface is shown only when `(boot_id, projection_revision)` equals the latest
  snapshot's `(boot_id, revision)`. This stops cells and metadata from mixing across focus changes.
- **Graphics** (kitty/sixel images) arrive as RGB/RGBA/PNG assets in `SurfaceGraphicsScene`. They
  are sent once and kept per connection (`herdr-client/src/surface_images.rs`).
- **Rendering**: a custom GPUI cell painter (`herdr-gpui/src/terminal_painter.rs`, ~1k lines plus
  submodules). It shapes runs per row with a glyph cache. Box-drawing, block and powerline glyphs
  are drawn as geometry snapped to device pixels. It also handles selection and search tints,
  cursor shapes (DECSCUSR 0-6), hyperlinks, and an accessibility transcript
  (`terminal/accessibility.rs`).
- **Scrollback** stays server-side. The surface is only the viewport. The scrollbar comes from
  `pane.scroll` metrics. Find, copy mode and selection use the
  `pane.copy_search`/`pane.copy_motion`/`pane.selection.read` RPCs (`scrollback.rs`). Wheel input
  goes up as `Mouse{ScrollUp/Down}` events.
- **Keys** (`terminal.rs:439-480`): GPUI keystrokes become `ClientPaneInputEvent::Key{code,
  modifiers: shift=1|ctrl=2|alt=4, kind: Press|Repeat, ...}`. Printable text goes through the
  IME input handler as `TextCommit(String)`, so dead keys and IME are not sent twice. Cmd-V sends
  `Paste(String)`. Images go through `ClipboardImage`.
- **Resize**: `viewport()` turns the terminal area's pixels into cols×rows (clamped to 4096 and
  1e6 cells). Those values go up in `ClientShellResize`, and herdr re-lays out the tab to that size.

### 4. Pane layout

- herdr **owns the layout and draws it inside the grid**. The client paints one grid for the
  focused tab. It uses `panes[].rect` to hit-test clicks and route input to a `pane_id`, and
  `splits[].hit_rect` to show resize cursors. Dragging a divider sends
  `layout.set_split_ratio{tab_id, path, ratio}` (`terminal/splits.rs`, `window/mouse.rs:637`).
- **Focus is per client**: "The daemon keeps a focused tab and projects a surface per client"
  (`group_terminals.rs`). To show another tab, the client sends `tab.focus` and waits for the new
  snapshot and surface. The herdr CLI or agents can move *every* client's focus. Parked groups
  then re-focus their own tab.
- **"Editor groups"** (side-by-side views, `group_terminals.rs`, README "Editor Groups"): **each
  group that shows a herdr tab opens its own extra client connection**. Non-active groups report
  `ClientShellFocus{focused:false}` and drop notifications. "A tab is live in one group at a time:
  the daemon sizes a tab for a single client", so a second view of the same tab shows a clipped
  or padded copy. The group layout is saved locally in `editor-groups.json`.
- There is no per-pane surface stream. A single pane is shown full-size only through `pane.zoom`.

### 5. State mapping: herdr vs. local

From the snapshot (pushed, full replace): `workspaces[]` (id, label, branch, git_ahead_behind,
worktree, `agent_status`, `tokens`), `tabs[]` (workspace_id, label, zoomed, `agent_status`),
`panes[]` (cwd, foreground_cwd, label), `agents[]` (pane_id, `agent` label such as
"claude"/"codex"/"pi", display_agent, title, terminal_title, `agent_status:
idle|working|blocked|done|unknown`, `state_change_seq`, state_labels, tokens), `agent_order`,
focused ids, `commands[]` (custom commands and keybindings), and update/release-notes info.
Unknown status strings decode to `Unknown`, which keeps newer servers compatible. The sidebar
says: "Status comes from the daemon's snapshot, never from guessing at terminal output"
(`sidebar/agents.rs`). Agent icons are SVGs keyed on herdr's `agent_label` list (24 agents,
`icons.rs`).

Kept locally (`~/.local/state/herdr/gpui/` and the herdr client state dir):
`window-state.json` (window geometry), `browser-tabs.json`, `editor-groups.json`,
`preferences.json`, `agent-skill.json`, `usage-keychain.json`, `config-gpui.toml` (GUI overrides
on top of the shared `~/.config/herdr/config.toml`), `gpui-wsl.json`. It also reads and writes
herdr's own `client/endpoints.json` (saved SSH hosts, `{version, ssh:[{id,label,target,session,enabled}]}`)
and `client/endpoint-selection.json`, and re-reads the catalog every 2 s. Theme, sound and toast
settings come from the local herdr config, not from the remote daemon.

### 6. Multiple hosts and remote machines

- `ConnectTarget::{Local, Session{name}, Socket(path), Ssh{target, session}, Wsl{distro, session}}`.
- **SSH bridge** (`herdr-client/src/ssh.rs`): runs `ssh -T -C -o BatchMode=yes -o
  StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ControlMaster=no
  host /bin/sh -c '<script>'`. The script searches PATH and known install roots for `herdr`, runs
  `herdr status client --json`, and prints `herdr-remote-output-ready:1`. The client checks
  generation and capabilities, then writes `accept` or `accept-idle`. The script then runs
  `exec herdr --session S remote-client-bridge [--idle-timeout-v1]`. **The same bincode stream
  runs over ssh stdio.** The bridge starts the remote daemon if needed. Disconnecting only detaches.
- It never prompts for passwords. MFA hosts need a user-configured `ControlMaster auto`.
- **All hosts connect at once**. The selected host has an active surface. The others send
  `client_shell.surface.set {"active":false}` and get snapshots only, which feed the cross-host
  Agents list and notifications. The capability `surface_interest` is required for this.
- Port forwarding: `ssh -N` master plus `ssh -O forward -L 127.0.0.1:L:localhost:R`
  (`forward.rs`). File upload goes over separate ssh processes (`upload.rs`).
- "Teleport" moves a worktree, its tabs and its agent sessions to another host. It copies each
  agent's session files (Claude, Codex, OpenCode, Pi, Copilot) and rewrites paths inside them
  (`teleport/sessions.rs`). This is the only place it touches agent JSONL storage.
- There is **no** iroh, relay, Tailscale integration, or remote agent of its own.

### 7. Mobile, push, chat

- **Mobile**: none. No iOS target, no pairing or QR, no relay, no auth or crypto beyond SSH.
- **Notifications**: the source is herdr's `SemanticNotification` (`NeedsAttention` /
  `Finished` / `UpdateInstalled` / `Custom`) from every connected endpoint. The app uses the
  TUI's timing rules: delayed attention needs a Blocked agent, and Finished needs projected Done.
  Finished is suppressed for the active tab while the window is focused. It shows in-app toasts
  and posts local OS notifications through GPUI (`UNUserNotificationCenter` on macOS,
  `window/system_notifications.rs`). A click routes back through boot-fenced navigation. Sounds
  play through rodio using herdr's MP3s. There is **no remote push (no APNs)**.
- **Chat view**: **none**. Agent output is shown only as terminal cells. The nearest thing is
  `agent_notes.rs`, which sends page annotations or review notes to an agent. When the agent is
  `Idle`/`Done`, it sends `ClientPaneInputEvent::Paste(text)` and then, 150 ms later, an `Enter`
  Key event. Delivery is held for up to 120 s while the agent is `Working`/`Blocked`. It never
  types into a `Blocked` prompt, and never into a plain shell (to avoid running the text).
  Otherwise the notes are queued for the agent to pull with `herdr-gpui browser feedback --wait`.
- Approvals and blocked prompts: shown only as status `blocked` (sidebar dot plus a
  NeedsAttention toast). The user answers by typing in the terminal.

### 8. Non-terminal panes (web pages)

- **Browser tabs** (`src/browser/*`): "Herdr panes are always terminals, so these tabs belong to
  this client alone; the daemon and its other clients never see them." They are native WKWebViews
  (wry) drawn above the GPUI window, and hidden while overlays are open. They are stored in
  `browser-tabs.json` as `{id, scope: "local:<socket>"|"<profile-id>", workspace_id, location, title, pane_id?}`.
  They are removed when herdr closes that workspace. They appear in the tab strip next to herdr
  tabs.
- Agents open pages through a **local control socket** owned by the app (`src/control/*`). The
  protocol is one JSON line in and one JSON line out:
  `{"method":"browser.open","page":{"url":"…"},"caller":{"pane_id":"$HERDR_PANE_ID","workspace_id":"$HERDR_WORKSPACE_ID","daemon_socket":"…"},"focus":true}`,
  plus `browser.reload` and `browser.feedback`. The CLI wrapper is `herdr-gpui browser open URL`.
  The app installs a skill (`skills/herdr-gpui-browser/SKILL.md`) into `~/.claude/skills` and
  `~/.agents/skills` so agents know about it. Remote agents cannot reach this socket.
- Other client-only views: the diff/review tab (syntect), PR badges (GitHub), usage meters for
  about 60 providers, and listening ports.

### Lessons for a native Swift macOS+iOS herdr GUI

**Copy**
1. **Use the client-shell endpoint on `herdr-client.sock`, not screen-scraping over `herdr.sock`.**
   It provides pushed full snapshots (workspaces, tabs, panes, agents with status and labels),
   server-rendered cell grids with pane rects and split handles, semantic input, and a JSON-RPC
   lane with an advertised method allowlist. This is the herdr-supported path for GUI clients
   (generation 1, herdr ≥0.9.0; 0.9.3 is installed here). With it we need no terminal emulator
   (no SwiftTerm or libghostty) and no layout engine.
2. **Remote access is just `ssh … herdr --session S remote-client-bridge`**, with the same
   protocol over stdio. On macOS, copy the discovery script and the `status client --json` /
   `accept` handshake as-is. Keep non-interactive SSH (`BatchMode`, strict host keys). Saved hosts
   come from herdr's own `client/endpoints.json`, edited through `herdr machine add/remove`, so the
   app stores nothing for this.
3. **Connect every host and mark the non-visible ones `client_shell.surface.set {"active":false}`**.
   This gives a cheap snapshot-only feed for the sidebar, the agent list, and notifications on all
   hosts. It maps directly onto our Arc-style host swiping.
4. **Fence on `(boot_id, revision)`**. Drop surfaces that do not match the latest snapshot.
   Disconnect on a boot change or a revision drop, reconnect with backoff (500 ms × 2ⁿ, at most
   30 s), and never replay input.
5. **Take agent status only from the snapshot** (`agent_status`, `state_change_seq`), and
   notifications only from `SemanticNotification`. Use herdr's `agent_label` strings as icon keys.
6. **Send to an agent by `Paste` + delayed `Enter`, and only when it is Idle/Done.** Do not type
   into a Blocked prompt or a plain shell. This is a sound rule for our chat composer.
7. Keep web pages client-side with a WKWebView. For a placeholder pane approach, tie each page to
   a herdr id (`workspace_id`/`pane_id`) and drop it when that id disappears from the snapshot.

**Avoid / watch out**
1. **Bincode is positional and has no schema.** Swift needs a hand-written bincode-2 varint codec
   that mirrors `wire.rs` variant order exactly, and it breaks silently if herdr reorders
   anything. Pin to the generation-1 types, copy herdr's JSON/bin fixtures as tests, and check
   `status client --json` first. Hello, welcome, snapshot and requests are JSON inside
   `EndpointControl`, so only surfaces and input need bincode. **(guess)** Asking upstream for a
   JSON surface codec would remove most of that risk.
2. **One surface per connection, sized to one client, for the focused tab only.** Our
   "horizontal strip of panes across tabs" cannot come from one connection. Options: (a) one
   parked connection per visible tab, which is what editor groups do; a tab shown twice is
   clipped. (b) Show live content only for the visible or centred tab and cached pictures for the
   rest. (c) Use `pane.zoom` on one pane at a time. Each pane's cells sit inside the tab grid at
   `panes[].rect`, so a per-pane view can crop from the tab surface.
3. **iOS cannot spawn `ssh`.** The stdio bridge works on macOS only. iOS needs another way to
   reach `remote-client-bridge`: a Swift SSH library (for example NIOSSH or Citadel) that runs the
   same command on an exec channel, or a relay. herdr-gpui has no answer here.
4. Do not copy the size of herdr-gpui. Its 234k lines include usage meters for about 60
   providers, Teleport, a PR/diff reviewer, an updater, and custom notification timing. Under
   ponytail, use herdr's `SemanticNotification` and OS notifications, and skip the rest.
5. There is no chat or transcript source here. Chat must come from another source: agent session
   JSONL, herdr-web-ui's approach, or `pane.selection.read`/scrollback RPCs. **(guess)** Scrollback
   RPCs are a poor source for structured chat.
6. The endpoint method allowlist is narrower than the JSON API. Layouts, process info, agent
   sessions and `pane run` are missing. For those you need the CLI or `herdr.sock`. Plan to keep
   a small JSON-API path as well; check `welcome.methods` before using any method.
7. herdr focus is per client but can be moved globally by the CLI or agents. The UI must accept
   focus changes pushed by the server and not fight them.

---

## herdrup (jerryfane/herdrup) — iOS client for herdr

Source: `/tmp/herdr-research/herdrup` (shallow clone). App Store app "HerdrUp", Apache-2.0.
All paths below are relative to the repo root.

### TL;DR

- Native **Swift/SwiftUI iOS** app (iPhone + iPad; runs on Apple Silicon Macs only as
  "Designed for iPad", `project.yml:233 SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: YES`). No AppKit target.
- Talks to herdr **only over SSH**: pure-Swift SSH (Citadel 0.12.1 / swift-nio-ssh), exec'ing
  `herdr api-bridge …` on the host and speaking herdr's newline-delimited JSON over its stdin/stdout.
- **Needs a fork of herdr** (`jerryfane/herdr`). Most of its interesting methods are NOT in upstream
  herdr 0.9.3: `pane.stream`, `pane.set_pty_size`, `api-bridge`, `events_v2`, `gram.*`,
  `notifications.*`, `guest.*`, `accounts.*`, `agent.archive`, `machine.status`, … (verified: the
  local `herdr api schema --json` for 0.9.3 contains none of them; `ping` caps = `live_handoff,
  detached_server_daemon, endpoint_protocol_generation, surface_interest, health_check,
  ssh_agent_registration`).
- Live terminal = **raw PTY byte stream** (`pane.stream`, base64 frames) fed into a **vendored
  SwiftTerm 1.15.0** with local patches. Input = `pane.send_text` with SwiftTerm's key→bytes output.
- UI is **agent-centric** (status board grouped by "needs you / working / done / stopped"), one
  terminal at a time; it ignores herdr workspaces/tabs/splits entirely.
- No transcript-based chat. "Gram" is a fork-only **explicit message channel** (`gram.post/list`)
  that agents use via a `herdr gram` CLI. Replies to agents go through `agent.prompt`.
- Push: fork daemon sends APNs via a **Cloudflare Worker relay** (`PushRelay/`). Guest sharing via a
  second Worker (`GuestRelay/`) with **Noise_IK** end-to-end. Pairing via QR over **Tailscale**.

### 1. Architecture

| Dir | Lang | What |
|---|---|---|
| `Sources/HerdrKit/` (~14.4k LOC, 48 files) | Swift, no UIKit | transport + typed API, Linux-testable (`Package.swift`, `platforms: [.macOS(.v14), .iOS(.v17)]`) |
| `App/` (~50 files; `HerdrApp.swift` 9.9k LOC, `LiveTerminalView.swift` 3.4k, `GramView.swift` 2.5k) | SwiftUI + UIKit | the iOS app |
| `Vendor/SwiftTerm/` | Swift | SwiftTerm v1.15.0 @ `dd2fb8ac`, patched |
| `HerdrWidgets/` + `Shared/` | SwiftUI/ActivityKit | Live Activity (lock screen / Dynamic Island) |
| `PushRelay/` | TypeScript, CF Worker | APNs relay (`push.herdrup.themartian.app`) |
| `GuestRelay/` | TypeScript, CF Worker + Durable Object | WSS relay for guest access |
| `Tests/`, `HerdrUITests/` | Swift | big unit + XCUITest suites |

Only external Swift dep: `Citadel` (pinned exact; pulls a swift-nio-ssh fork + swift-crypto/BoringSSL).
Xcode project is generated by XcodeGen from `project.yml`.

Key HerdrKit files: `CitadelTransport.swift` (SSH exec transport), `RequestChannel.swift`
(multiplexed `api-bridge --multi`), `HerdrClient.swift` (typed API actor), `Wire.swift` (JSON types),
`AgentStatusStream.swift` (events v2), `AgentList.swift` (status→group model), `InputIntent.swift`
(prompt vs raw-key routing), `SessionRecovery.swift`/`RecoveryExecutor.swift` (reconnect),
`Pairing*.swift`, `NoiseIK.swift`, `RelayTransport.swift`, `Guest*.swift`, `Gram*.swift`.

The code is extremely heavily commented (multi-paragraph "why" essays, experiment write-ups in
`docs/transport-measurements.md` with preregistered decision rules). Lots of complexity is
defensive engineering around a single-shot socket and SSH latency.

### 2. Transport to the herdr socket

#### 2.1 SSH exec, not socket forwarding
`CitadelTransport.swift:14-26`: nio-ssh has no `direct-streamlocal` (unix socket forward), so the app
runs the **`herdr api-bridge`** subcommand (fork-only) over SSH exec channels:

- Per-request: `herdr api-bridge <base64(requestLine)>` — one exec channel per call, request as a
  base64 argv word (Citadel's `executeCommandStream` can't write stdin).
- Held: `herdr api-bridge --multi` — one long-lived exec channel per herdr session; many request
  lines in, replies matched by `id`, any order (`RequestChannel.swift:140`). Max line 1 MiB.
  Used when `ping` advertises `api_bridge_multi`. Idle channel is re-probed with `ping`.
- Streams (`events.subscribe`, `pane.stream`, `pane.input.stream`, `gram.upload.stream`,
  `server.ssh_agent.register`) are refused on `--multi` (`RequestChannel.swift:163`) and each get
  their own exec channel running per-request `api-bridge <b64>` whose stdout stays open.
- Uploads: `herdr api-bridge --duplex` (stdin+stdout) for `gram.upload.stream`.
- Named sessions: global flag `herdr --session <name> api-bridge …`; `herdr session list --json` is
  exec'd directly to list sessions (`HerdrSession.swift`). Session "pills" show per-session needs-you counts.

Command wrapping is shell-agnostic: `/bin/sh -c '<resolve herdr path>; exec "$HERDR" api-bridge "$*"' sh '<b64 chunk>' …`
(`CitadelTransport.swift:258-296`) to survive fish/csh login shells and non-login PATH.

#### 2.2 Envelope
```json
→ {"id":"herdrkit:agent.list:7","method":"agent.list","params":{}}
← {"id":"herdrkit:agent.list:7","result":{...}}      // or {"id":..,"error":{"code":"pane_not_found","message":".."}}
```
`HerdrClient.swift:44-65`. JSON encoder uses `.withoutEscapingSlashes` (base64 payload size).

#### 2.3 Measured protocol facts (README table)
- Upstream command socket is **single-shot**: one request per connection, server closes after reply.
- `events.subscribe` is persistent → one long-lived event channel + N short request channels.
- Pre-v2 subscriptions are **pane-scoped, no wildcard** → N subscriptions + re-subscribe on pane creation.
- `agent.read --format ansi` returns real SGR styling.
- `agent.list` has `revision` + `state_change_seq`, but `state_change_seq` only tracks lifecycle,
  **not output** (a pane held seq 1092 across 13 different screens — `RefreshPolicy.swift:1-20`).
- SSH costs (`docs/transport-measurements.md`): handshake 18.6 ms, auth 20.4 ms, channel opened
  right after auth ~96 ms vs 0.3–0.5 ms on a 100 ms-old session → pool sessions, age-gate them,
  keep channels per request. `TCP_NODELAY` missing cost ~30 ms.

#### 2.4 Methods used (`HerdrClient.swift`)
Upstream-compatible: `ping`, `agent.list`, `agent.read`, `agent.prompt`, `agent.send_keys`,
`agent.start`, `agent.rename`, `pane.send_text`, `pane.send_keys`, `pane.split`, `pane.close`,
`pane.rename`, `events.subscribe`.
Fork-only: `pane.stream`, `pane.set_pty_size`, `pane.input.stream` (cap only), `machine.status`,
`accounts.list/create/remove`, `server.staged_update`, `server.apply_staged_update`, `fs.list_dir`,
`agent.kinds`, `agent.restart`, `agent.archive/unarchive/forget`, `agent.transfer_session`,
`notifications.register_device/unregister_device/register_activity/unregister_activity/status`,
`gram.list/post/mark_read/delete/upload_chunk/upload.stream/get_file/get_file_chunk`,
`guest.invite.create/update/list/revoke/audit`.

Fork detection: call `gram.list`; base daemon can't even deserialize an unknown method (its method
field is an enum) and answers `invalid_request` with empty `id` (`HerdrClient.swift:504-545`).
Capabilities from `ping` → `ServerCapabilities` (`Wire.swift:982`): `live_handoff`,
`detached_server_daemon`, `pane_input_stream`, `gram_upload_stream`, `agent_session_transfer(_harnesses)`,
`events_v2`, `agent_forget`, `api_bridge_multi`. Missing = false → hide feature.

#### 2.5 Key JSON shapes
`agent.read` params (`HerdrClient.swift:232`): `{"target":pane,"source":"visible|recent|recent_unwrapped|detection","format":"text|ansi","lines":N}`
(server clamps lines ≤1000, default 80; `detection`+`ansi` silently returns text).

`agent.prompt`: `{"target":pane,"text":"…","wait":{"until":["working","idle","blocked","done","unknown"],"timeout_ms":N}}`
→ `{"delivery":"submitted"|"written_to_pty"}`. Passing `wait` is what makes `delivery` truthful.
Rejections: `agent_prompt_unsubmitted`, `agent_prompt_unverifiable`, `agent_prompt_stalled`,
`agent_status_unobserved_after_submit`, `timeout`, and "agent is blocked" (`Wire.swift:635-665`).

`pane.send_text`: `{"pane_id":p,"text":"…"}`; `agent.send_keys`: `{"target":p,"keys":["Enter","Escape","Up"]}`
(refuses non-agent panes); `pane.send_keys`: `{"pane_id":p,"keys":[…]}`.
`pane.split`: `{"direction":"right"|"down","cwd":…,"focus":bool}` (splits the *focused* pane; no target).
`agent.start`: `{"name","kind","pane_id"}`.

`AgentInfo` (from `agent.list`, `Wire.swift:290-447`): `agent, name, agent_status, input_pending,
input_prompt_kind ("select"/"confirm"), pane_id, tab_id, workspace_id, terminal_id,
terminal_title_stripped, cwd, focused, interactive_ready, composer{state,attempt_id,evidence},
revision, state_change_seq, status_since_unix_ms, turn, turn_epoch, last_completed_turn,
machine_id, machine_label, reachability, last_known_status, account…, archived, session_transfer,
guest_running`. Plain shells are **not** in `agent.list` in this daemon ("agent-only census",
`SavedTerminals.swift:5`), so the app remembers shell pane ids it created locally.

### 3. Events / status updates

`events.subscribe` params: `{"subscriptions":[{"type":"pane.agent_status_changed","pane_id":?}...],"events_v2":true}`
(`Wire.swift:685-730`). Types: `pane.created/updated/focused/closed/exited/agent_detected/
agent_status_changed/turn_completed/scroll_changed/output_matched`, `layout.updated`.

events v2 (fork, `AgentStatusStream.swift:1-12`): ack `{"result":{"type":"subscription_started","rejected_indices":[]}}`,
then `{"seq":N,"event":"pane.agent_status_changed","data":{pane_id,workspace_id,agent_status,input_pending,input_prompt_kind,agent,turn,turn_epoch}}`;
lifecycle `pane_created/pane_closed/...` with tagged `data`; control lines `{"control":"heartbeat"}` every
15 s, `{"control":"lagged","first_missed_seq",…}` → reload `agent.list`. Entries without `pane_id`
= all panes (incl. federated peers, ids qualified as `alias/w1:p2`).

Refresh strategy: v2 → one status stream (45 s silence watchdog) + `agent.list` every 30 s backstop
and after reconnect; pane create/close/exit/detect/lagged → full `agent.list` reload; status events
patch rows in place. Old daemon → poll `agent.list` every 5 s.

### 4. Live terminal bytes, rendering, input, resize

#### 4.1 `pane.stream` (fork-only)
Request (`Wire.swift:863`): `{"pane_id","include_history":true,"resume_from"?,"epoch"?,"max_frame_bytes"?,"scrollback_lines"?,"viewer_id"}`.
Ack: `{"result":{"type":"stream_started","pane_id","epoch","cols","rows","base_seq","resync"}}`.
Frames, one JSON per line, tag `"stream":"pane.bytes"` (`Wire.swift:774-850`):
```json
{"stream":"pane.bytes","frame":"reset","seq":0,"epoch":3,"cols":120,"rows":40,"data_b64":"…","lagged":true?}
{"stream":"pane.bytes","frame":"data","seq":4711,"epoch":3,"data_b64":"…"}
{"stream":"pane.bytes","frame":"resize","seq":…,"epoch":…,"cols":80,"rows":30}
{"stream":"pane.bytes","frame":"ping","seq":…,"epoch":…}      // ~20 s idle
{"stream":"pane.bytes","frame":"exited","seq":…,"epoch":…}    // server then closes
```
`reset` = full-screen keyframe (server serialises its VT state); `lagged` = client fell behind,
server dropped backlog and re-seeded. Decode is strict: any bad line kills the stream → reconnect →
fresh reset (never feed a desynced emulator). `resume_from`/`epoch` exist but v1 always reseeds.

#### 4.2 Rendering
`App/LiveTerminalView.swift` (`UIViewRepresentable` around SwiftTerm's iOS `TerminalView`):
- On first `reset`: raise scrollback to 4000, backfill history via
  `agent.read {source:"recent",format:"ansi",lines:N}` (raced against a 1.2 s timeout), feed it,
  `ESC[0m`, then clear visible screen (not scrollback) and feed reset bytes (`LiveTerminalView.swift:2390-2430`).
- `data` → `view.feed(byteArray:)` after `TerminalGraphicsFilter` strips kitty-graphics APC strings
  (SwiftTerm 1.15 crashed on them; `TerminalGraphicsFilter.swift`).
- Watchdog: no frame in 50 s → reconnect; backoff `min(20, 0.5·2^(n-1))·rand(0.6…1)` s.
- `PaneKeepAlive.swift`: LRU of mounted-but-hidden terminals (opacity 0) with live streams, so swiping
  between agents is instant; only the front one holds input focus and the width lease.
- Vendored SwiftTerm patches: keep viewport anchors/modes on geometry changes, preserve archived
  row widths (no rewrap of history on resize; horizontal pan for wide rows), managed-size and
  completed-paint hooks (README "SwiftTerm is vendored").

#### 4.3 Input
- Direct typing: SwiftTerm `send(source:data:)` → bytes as String → serialized/coalesced queue →
  `pane.send_text` (`LiveTerminalView.swift:3072-3098`). One request per batch (no persistent input
  stream used yet, though `pane_input_stream` cap exists).
- Composer/reply field: `InputRouter` (`InputIntent.swift`) — agent pane → `agent.prompt` with
  `wait` (intent, server-verified delivery); shell/TUI → `pane.send_text` without Enter
  (Enter is a separate deliberate key); keycaps (Esc, arrows, Shift-Tab `ESC[Z`, Ctrl chords) →
  raw bytes via `pane.send_text` or named keys via `agent.send_keys`.
- Scroll on alternate screen → wheel/arrow sequences to the app.

#### 4.4 Resize / geometry ownership (fork `pane.set_pty_size`)
`{"pane_id","cols","rows","cell_width_px","cell_height_px","lock":bool,"viewer_id","ttl_ms"}` →
`{"type":"pane_pty_size","pane_id","cols","rows","locked"}`. The phone **locks the shared PTY to
its own grid** while viewing (the desktop herdr client narrows), with a per-view lease keyed by
`viewer_id` (same id on `pane.stream`; daemon drops the lease when that stream closes). Widest
active viewer wins; TTL 5 min, refreshed every 2 min only when foreground; `lock:false` on teardown.
Hidden panes keep but stop refreshing the lease (avoids two repaints per agent switch).
Distinct from upstream `pane.resize` (split ratio).

### 5. UI ↔ herdr state

- **Agents tab** = status board from `agent.list`. `AgentStatus` (`idle|working|blocked|done|unknown`)
  → `AgentGroup` (`needsYou` = blocked, `working`, `idle` = idle|done, `stopped`, `unrecognised`
  for unknown/absent — "fail-open visible", `AgentList.swift:24-215`). Colour = meaning (amber
  needs-you, blue working, green done, red died). Time-in-state badge from `status_since_unix_ms`.
- **Terminal tab** = locally remembered shell panes (`SavedTerminalsStore`, per host).
- **Gram tab** = message inbox. **Settings** (hosts, notifications, accounts, guests, federation).
- iPhone: tab bar, terminal covers roster. iPad/Mac: `NavigationSplitView`, empty detail column is an
  animated "live terminal field" typing agents' activity lines.
- Workspaces/tabs/layouts: **not shown**. `workspace_id`/`tab_id` are decoded but unused for layout;
  no `layout.*`, `tab.*`, `workspace.*` calls. New agents: `pane.split` (focused pane) + `agent.start`,
  then poll `agent.list` until `composer != nil` before delivering a pre-filled task via `agent.prompt`.
- Per-agent actions: rename, restart, archive/unarchive/forget, swap credential account, transfer a
  session claude↔codex↔omp (`agent.transfer_session` two-phase prepare/confirm), mute push, share.

### 6. Local storage vs fetched

Local (UserDefaults/Keychain): saved hosts (host/user list in UserDefaults, private key/password in
Keychain `dev.herdr.credentials[.password]`), TOFU SSH host-key pins (`HostKeyPinning.swift`),
selected herdr session per machine, plain-terminal pane ids + labels per host, saved prompts,
saved gram messages, gram file cache, muted panes, font size, guest Noise identity (Keychain).
Everything else (agents, statuses, screens, gram messages, guests) is fetched from the daemon.

### 7. Pane layout
One pane at a time, full-screen; swipe horizontally pages between agents (siblings snapshot at open).
No rendering of herdr splits, no own split layout. Width is forced to the phone via the PTY lock.

### 8. Multi-host / remote

- One connected `HerdrClient` at a time (`HerdrApp.swift:194 @State client`), host picker to switch.
- **Multi-machine = herdr federation (fork)**: the connected daemon is a coordinator that relays
  remote machines' agents (`machine_id`, `machine_label`, `reachability`, `last_known_status`; ids
  `alias/w1:p2`). `machine.status` lists saved SSH profiles; enabling federation for one is an SSH
  exec of a fixed herdr machine command (`setMachineFederation`). `PeerSummary` derives per-machine
  reachability worst-case from agents (`Federation.swift`). No iroh/p2p; daemon-to-daemon is SSH.
- Multiple herdr **sessions** on one machine via `--session` (pills).

### 9. How mobile connects / auth

- Plain SSH to host:port (user enters host, or pairs). Key or password auth. TOFU host-key pinning;
  Tailscale addresses (`100.64/10`, `*.ts.net`) recognised (`HostEndpoint.swift:60-90`).
- **QR pairing** (`Pairing.swift`): `herdr pair` (fork) prints QR `{"v","host"(tailnet IP),"port","user","token","fp":"SHA256:…"}`
  and listens on the Tailscale address. Phone generates an Ed25519 key (`PairingKey.swift`), opens a
  plain TCP socket and sends one line `{"type":"pair.redeem","token","public_key":"ssh-ed25519 …","device"}`;
  daemon appends to `~/.ssh/authorized_keys`, replies `{"type":"pair.ok"}`/`{"type":"pair.error","message"}`.
  Security relies on WireGuard + single-use token + host-key fp pin.
- Guest access (sharing one agent with an outsider): host daemon holds one WSS to `GuestRelay`
  (`/v1/host/<host_id>`, bearer secret, TOFU hash in a Durable Object). Guest connects
  `/v1/guest/<host_id>`; Noise_IK handshake end-to-end (prologue `herdr-guest/1:<host_id>`,
  `NoiseIK.swift`); host frames `type u8 | session u32 BE | payload` (OPEN/DATA/CLOSE). Inside, the
  same JSON API lines (restricted: `ping, agent.list, agent.get, agent.read, pane.stream, agent.prompt, gram.*…`).
  Invite = one-use QR/link `herdrup://guest-invite#<b64>`; guest messages labelled `<name> (via HerdrUp):`.

### 10. Push notifications

- App registers APNs token with the daemon: `notifications.register_device`
  `{"device_token","platform":"apns","notify_needs_input","notify_dies","notify_finishes","notify_gram","muted_panes":[…],"relay_capability"?}`.
  Re-sent on every connect. Live Activity tokens: `notifications.register_activity {"activity_push_token","relay_capability"}`.
- **Daemon** decides and sends (triggers: agent → needs input/blocked, dies, finishes; gram messages;
  Live Activity updates with counts). App never polls in background.
- `PushRelay/` CF Worker: app `POST /v1/enroll {"kind":"device|activity","token","environment"}` →
  sealed `hpr1.<AES-256-GCM>` capability; daemon `POST /v1/send {"capability","push_type":"alert|liveactivity","priority","collapse_id","payload":{"aps":…}}`;
  relay signs ES256 APNs JWT (only the publisher holds the .p8). Stateless, no logging of payloads.
  A daemon with its own APNs key can push directly using the raw token.
- Live Activity (`HerdrWidgets/AgentLiveActivity.swift`) shows needs-you/working counts.

### 11. Chat view?

**No transcript chat.** Nothing reads `~/.claude/projects`, `~/.codex/sessions`, or pi session JSONL,
and the app does not parse terminal screens into messages.
- **Gram** (fork daemon feature) = explicit owner↔agent message channel. Agents send with the
  `herdr gram send` CLI (agent-side, not modelled in the app); owner posts with
  `gram.post {"text","to"?:agentName,"file"?:{upload_id,name,mime}}` to one agent or a shared
  "grab queue" agents claim (`grabbed_by`). Messages: `{id,direction:"agent_to_owner|owner_to_agent",from,to,text,grabbed_by,created_unix_ms,read_by_owner,file{name,size,mime,sha256},machine_label}`.
  Polling (`gram.list`), not streamed. Files: chunked upload, then the agent is prompted with
  "`herdr gram get-file <id> -o /tmp/herdr-photo-<id>.png`" text (`GramAttachmentPrompt.swift`).
  Received HTML/SVG rendered in a locked-down `WKWebView` (no JS, network blocked via content rules —
  `WebViewPolicy.swift`, `HtmlWebView.swift`).
- **Approvals / blocked prompts**: no structured parsing of choices. `input_pending=true` /
  `agent_status=blocked` (+ `input_prompt_kind` select|confirm) flips input mode to raw keys
  (`InputRouter.mode`), user answers with arrow/Enter keycaps or typed text via `pane.send_text`
  while watching the live terminal. `agent.prompt` is rejected while blocked.
- No per-agent adapters in the app; agent-awareness all comes from herdr's own detection.

### 12. Web / non-terminal panes
None. Only WKWebView use is the gram attachment previewer. It strips kitty graphics, so a herdr pane
running `terminal-browser` shows nothing graphical.

### Lessons for a native Swift macOS+iOS herdr GUI

#### Copy
1. **Package split**: a UI-free `HerdrKit` Swift package (transport + Codable wire types + pure state
   logic) shared by both apps and testable from `swift test`. Their `Wire.swift` is a good starting
   point for `AgentInfo` / envelope / error types (lenient optionals, unknown enum → `.unrecognised`).
2. **SwiftTerm** works on both UIKit and AppKit and is good enough to feed raw PTY bytes; herdrup proves
   the `reset`-keyframe + `data`-delta model renders correctly. Budget for a kitty-graphics filter and
   a scrollback/backfill step (`agent.read --format ansi --source recent`) before the first keyframe.
3. **Capability gating** from `ping.capabilities` + `try?` degrade per method; hide UI for missing caps.
4. **Status model**: map `agent_status` + `input_pending` to a few user groups; treat unknown as
   visible, not idle. Use `status_since_unix_ms` for "time in state".
5. **Intent over keystrokes** for agent replies: `agent.prompt` with `wait.until=<all statuses>` to get a
   real `delivery`; fall back to `pane.send_text` (no Enter) when `input_pending`/blocked or not an agent.
6. Event stream + periodic full `agent.list` backstop + reload on `lagged`/pane lifecycle; silence
   watchdog on every long-lived stream; capped jittered backoff; strict stream decoding → reseed.
7. Keep several terminals mounted (LRU) so horizontal swiping across panes is instant — directly
   relevant to our horizontally scrolling pane strip.
8. Push through the daemon (it knows status transitions) + a stateless relay holding the APNs key;
   register tokens on each connect. Live Activity for needs-you count is cheap and nice on iOS.
9. Remote access via plain SSH + Tailscale + QR pairing that appends a device key to
   `authorized_keys` is simple and needs no new server. TOFU host-key pinning.
10. Handle PTY size explicitly: herdr has ONE PTY size per pane. A GUI renderer must either own it
    (set size) or follow it (fit/scale). herdrup's per-viewer lease ("widest viewer wins", TTL,
    release on stream close) is a sound design if/when upstream gains `pane.set_pty_size`.

#### Avoid / watch out
1. **Do not depend on the jerryfane fork.** Upstream herdr 0.9.3 has no `pane.stream`,
   `pane.set_pty_size`, `api-bridge`, `events_v2`, gram, push, guest. With upstream we must get live
   bytes another way (e.g. `herdr` client attach protocol, `pane.read` polling, or propose an
   upstream streaming method) — verify upstream's current API before designing.
2. SSH exec of a CLI bridge per request is a workaround for nio-ssh lacking `direct-streamlocal` and
   for upstream's single-shot socket. On macOS-local we should talk to the unix socket directly; for
   remote, prefer one multiplexed channel (like `--multi`) or `herdr --remote`, not per-call exec.
3. Massive defensive code/commentary (9.9k-line `HerdrApp.swift`, recovery state machines with
   "attempt authority" objects, preregistered latency experiments) — a ponytail app should not need
   this; keep one connection actor per host with simple reconnect.
4. Agent-only, one-pane UI throws away herdr's workspaces/tabs/splits; we want those as first-class.
   Their local "saved terminals" store exists only because their `agent.list` omits shells — use
   upstream `pane.list`/`workspace.list`/`tab.list`/`layout.export` + `layout.updated` instead and store nothing.
5. Locking the PTY to the phone's width reflows the desktop client — acceptable for a phone, but for a
   Mac GUI that is the primary viewer, size panes from our own layout and let herdr's layout follow
   (or use upstream `pane.resize`/`layout.set_split_ratio`), avoid fighting a desktop TUI.
6. No transcript chat: if we want a CHAT view we need another source (agent session JSONL or herdr
   hooks/`pane.report_agent_session`); herdrup offers nothing reusable there. Gram is a separate
   agent-opt-in channel, not a chat view of the terminal.
7. iOS-only UIKit `UIViewRepresentable`; for macOS we need an `NSViewRepresentable` twin (SwiftTerm has
   `MacTerminalView`) — design the terminal wrapper behind a tiny cross-platform seam from day one.

---

## domenkozar/agentaps: primary research report

Repo: https://github.com/domenkozar/agentaps, shallow clone at `/tmp/herdr-research/agentaps`
(HEAD `49c9491`, 2026-10-08, crate version 0.5.1). About 29k lines, almost all Rust.

### 0. TL;DR: it does not use herdr

- `grep -rni herdr` over the whole repo returns **zero hits**. There are no socket paths, no
  multiplexer client, and no tmux or zellij integration.
- Agentaps is an **ACP (Agent Client Protocol) client**. It is a desktop chat UI that **spawns
  ACP agent processes itself** (`codex-acp`, `claude-agent-acp`, `gemini --acp`, `opencode acp`)
  and talks JSON-RPC to them over stdio. Remote agents run over `ssh -T host 'cd … && exec agent'`.
- The chat view comes **only from ACP `session/update` notifications**. Nothing is parsed from a
  terminal screen and no JSONL is read. History lives in the harness and is replayed with
  `session/load` / `session/resume`.
- **Terminal**: an optional per-session *shell drawer* that uses `gpui-libghostty` (libghostty
  built with Zig). It is a local `$SHELL` with its own PTY, not connected to agents, local only.
- **Mobile**: "Web Connect" is a GPUI app compiled to WASM (WebGPU/WebGL2). It talks to the desktop
  over **iroh QUIC (relay + hole punching)** with a custom ALPN `agentaps/control/0`. Pairing works by
  QR code or by a URL fragment that holds a one-time secret. It uses per-browser revocable tokens.
  The browser vault is AES-GCM, keyed by a passkey (WebAuthn PRF) or a PBKDF2 passphrase. The
  browser **polls a full snapshot every 800 ms**. There are no push notifications.

So almost nothing about the herdr socket applies. The parts worth studying are the **iroh
transport, the pairing flow, the ACP chat model, and the split-pane layout model**.

### 1. Architecture

| Part | Path | Notes |
|---|---|---|
| Desktop app | `src/` (bin `agentaps`) | Rust 2024, UI with **GPUI via `gpui-kit = 0.7.0`** (Zed's GPUI plus the longbridge component kit) |
| Shared wire types | `crates/control-protocol/src/lib.rs` | about 100 lines, serde only. Used by the desktop and by WASM |
| Web Connect | `web/` (cdylib, wasm32) | Same GPUI kit running in the browser (`gpui_kit::platform::single_threaded_web()`), `iroh` 1.1, `rqrr` QR decoder, JS glue in `web/src/browser.js` |
| ACP transport | `src/acp.rs` | Spawns a child process (local or `ssh`) and moves JSON lines over stdin/stdout |
| Session logic | `src/session.rs`, `src/session/protocol.rs`, `src/session/prompt.rs` | ACP v1/v2 handling, normalised to one `SessionUpdate` enum |
| Pane layout | `src/panes.rs` (model), `src/app/panes.rs`, `src/app/render/panes.rs` | Own binary split tree |
| Terminal drawer | `src/app/terminal.rs` | `gpui-libghostty = 0.3.1` (feature `ghostty-terminal`, macOS + Linux Wayland) |
| Mobile server | `src/mobile.rs` (iroh endpoint, credentials), `src/app/mobile.rs` (snapshot + command apply) | |
| Notifications | `src/app/notifications.rs` | Local OS notifications only |
| Persistence | `src/config.rs`, `src/persistence.rs` | `~/.config/agentaps/config.json`, written by a single background writer |
| Other | `git_diff.rs`/`diff_watch.rs` (gix + notify), `git_clone.rs`, `file_search.rs` (nucleo), `theming.rs` (GTK/Qt/native-theme) | |

Key dependencies (`Cargo.toml`): `iroh = "1.1"` (tls-ring), `agent-client-protocol-schema = 1.9.1`
(`unstable_protocol_v2`), `secretspec 0.21` (keyring), `qrcode`, `subtle` (constant-time token
compare), `tokio`, `gix`, `notify`, `gpui-libghostty` (optional).

Threading model. The GPUI main thread runs a **polling tick**: 25 ms while the visible session is
connecting, otherwise 100 ms (`src/app.rs:1361-1398`). Each tick drains `std::sync::mpsc` channels:
agent events, mobile commands, persistence results. The agent I/O threads are plain
`std::thread`s. The iroh server runs its own tokio runtime on a dedicated thread.

### 2. "Backend" protocol (ACP instead of the herdr socket)

#### 2.1 Process transport (`src/acp.rs`)
```rust
let mut ssh = Command::new("ssh");
ssh.args(["-T","-o","BatchMode=yes","-o","StrictHostKeyChecking=yes","-o","ConnectTimeout=10", host])
   .arg(remote_command);           // "cd '/path' && exec 'agent' 'args'"  (remote.rs::agent_command)
...
for line in BufReader::new(stdout).lines() { serde_json::from_str(&line) → Event::Message{agent_id,value} }
```
- Newline-delimited JSON-RPC 2.0. Requests are built by hand with `serde_json::json!`.
- `Drop for Connection` kills the child, so **agents live only as long as the app**. The README
  says: "Closing the app can interrupt an active turn."
- Reconnect: on launch, sessions with a saved `session_id` restore through `session/resume` (v2, or v1
  with `sessionCapabilities.resume`) or `session/load` (v1 `loadSession: true`). Connections to
  hidden sessions are *deferred* until the visible one is ready (`poll_events`,
  `deferred_connections`). This is staggered startup.

#### 2.2 Methods used (client to agent)
| Method | Params (exact) |
|---|---|
| `initialize` (id 1) | `v2::InitializeRequest{protocolVersion:2, clientInfo:{name:"agentaps",…}, capabilities:{elicitation:{form:{}}}}` plus a duplicate `clientCapabilities:{elicitation:{form:{}}}` so v1 agents can read it (`session/protocol.rs:25`) |
| `session/new` (id 2) | `{"cwd":path,"mcpServers":[]}` |
| `session/resume` / `session/load` (id 2) | `{"sessionId","cwd","mcpServers":[]}`, plus `"replayFrom":{"type":"start"}` on v2 |
| `session/prompt` (id ≥3) | `{"sessionId","prompt":[{"type":"text",…},{"type":"image",…},{"type":"resource",…}/{"type":"resource_link",…}]}` |
| `session/cancel` (notification) | `{"sessionId"}` |
| `session/set_config_option` / `session/set_mode` | model, effort, mode, "collaboration" (the Codex Plan toggle) |

#### 2.3 Agent to client
- `session/update`, decoded into `SessionUpdate` (`session/protocol.rs:96-214`):
  `session_info_update`(title), `usage_update`(used/size → context meter), `config_option_update`,
  `current_mode_update`, `available_commands_update` (slash commands), v2 `state_update`
  (`running|requires_action|idle` + `stopReason`), `user_/agent_message[_chunk]`,
  `agent_thought[_chunk]` (v2 keyed by `messageId`), `tool_call`, `tool_call_update`,
  `tool_call_content_chunk`.
- `session/request_permission` is stored as `Permission{request_id, title, description, options:[(optionId,name)]}`.
  The answer is `{"id":req,"result":{"outcome":{"outcome":"selected","optionId":…}}}`.
  If there are no options, the client auto-replies `{"outcome":"cancelled"}`.
- `elicitation/create` (form only) and `$/cancel_request` are handled.
- Any other request gets `-32601 "Method not supported by this client"`. This covers **ACP `fs/*` and
  `terminal/*` client methods, which are NOT implemented**.

#### 2.4 Status model
`Status = Connecting | Idle | Working | Done | Error` (`session.rs:27`). The mobile snapshot sends
these as lowercase strings. "Needs attention" is derived as `elicitations.len() + permissions.len() > 0`.

### 3. Live terminal bytes / rendering

- **No agent terminal streaming exists.** Agents are headless ACP processes, so there are no TUI bytes.
- The terminal drawer (`src/app/terminal.rs`) works like this:
  ```rust
  let mut options = TerminalOptions::new(shell_words::quote(&shell).into_owned(), &project.path);
  options.configuration = TerminalConfiguration::UserDefaultWithOverride(theme);
  match Terminal::spawn(options, window, cx) { … }     // gpui_libghostty spawns PTY + renders
  ```
  libghostty owns the PTY, VT parsing, keys, and resize. The app only sets height and visibility and
  pushes a 16-colour `TerminalTheme` derived from the app palette (live light/dark). The comment
  "Native surfaces need explicit visibility" suggests it embeds a native Ghostty surface (a guess:
  an NSView/Metal child on macOS). It is local only, not restored on restart, and not on Web Connect.
- Built with Zig 0.16 (`.github/actions/setup-terminal/install-zig.py`). The first build downloads
  Ghostty's dependencies.

### 4. UI state model and pane layout

- Hierarchy: **Project (path + optional ssh_host) → Agents (sessions)**. Sidebar sessions can be
  nested under projects or flat (`nested_sidebar`, `sidebar_order`). Archive is a flag on `AgentConfig`.
- **Panes are a view layer, not process containers** (`src/panes.rs`):
  ```rust
  #[serde(tag = "kind", rename_all = "snake_case")]
  enum Node { Pane { id: u64, session: Option<u64> },
              Split { id: u64, direction: Direction /*Right|Down*/, ratio: f32, first: Box<Node>, second: Box<Node> } }
  struct Layout { root: Node, focused: u64 }
  ```
  Constants: `MIN_WIDTH 320`, `MIN_HEIGHT 280`, `DIVIDER 1px`. `sizes()` clamps the ratio against
  the subtree minimum sizes. A session shows in at most one pane: "sessions already visible receive
  focus". Closing a pane does not stop its agent. The layout is saved in `config.pane_layout` and
  restored on restart. The diff panel follows the active pane.
- Web Connect has **one session at a time** (a list of projects/agents, then a conversation).

### 5. Local storage vs fetched

`config.json` (`AgentConfig`, `src/config.rs:135`) stores: `id`, `command`, `archived`, names/titles,
**`session_id`** (the harness reference), `model`, `context`, `available_commands`,
**`pending_prompts`** (the queue survives restart), `active_prompt`, `was_working`, fork info. It also
stores the pane layout, theme, key bindings, and sidebar prefs.
`messages` has `#[serde(skip)]`, with the comment *"Conversation text belongs to the harness. These
fields are transient UI state."* The conversation comes back from ACP replay on reconnect. This
matches our "store as little as possible" goal.

Secrets (iroh identity and linked browser tokens) live in **SecretSpec** (system keyring, 1Password,
…). They are never written to `config.json`.

### 6. Multi-host

- **Agent hosts**: SSH only, per project, as `ssh://user@host/abs/path` (`src/remote.rs::parse_project`
  rejects hosts that start with `-`, which blocks `-oProxyCommand` injection). It uses
  `BatchMode=yes` and `StrictHostKeyChecking=yes`, so the user's existing keys and `known_hosts`
  must already work. Diff and terminal are local only. Nothing runs remotely except the agent itself.
  There is no remote daemon, so a remote agent dies when the SSH session ends.
- **Client devices**: iroh (next section). The desktop is the only "server". There is no
  desktop-to-desktop link.

### 7. Mobile / Web Connect transport (iroh)

#### 7.1 Wire protocol (`crates/control-protocol/src/lib.rs`)
```rust
pub const ALPN: &[u8] = b"agentaps/control/0";
pub const MAX_REQUEST_BYTES: usize = 64 * 1024;   pub const MAX_RESPONSE_BYTES: usize = 16 * 1024 * 1024;
struct Request { token: String, command: Command, client_name: Option<String> }
#[serde(tag="type", rename_all="snake_case")]
enum Command  { Pair, Snapshot, Prompt{agent_id,text}, Cancel{agent_id},
                Permission{agent_id,request_id,option_id}, NewSession{project,command:Vec<String>,name} }
enum Response { Paired{token}, Snapshot{projects:Vec<Project>, agent_options}, SessionCreated{agent_id},
                Accepted, Error{message} }
struct Agent { id:u64, name, status:String, active:bool, has_older_messages:bool,
               messages:Vec<Message{role,text}>, permissions:Vec<Permission{request_id,title,description,options:[{id,label}]}> }
```
Example `Snapshot` request on the wire: `{"token":"<64hex>","command":{"type":"snapshot"}}`.

#### 7.2 Framing
**One QUIC connection per request.** `endpoint.connect(remote, ALPN)`, then `open_bi`, then write the
JSON, then `finish`, then `read_to_end(16MB)`, then `connection.close`. See `web/src/connection.rs::request`.
The server does `accept_bi`, then `read_to_end(64KB)`, then dispatches, then `write_all` + `finish`,
then waits up to 30 s for the client to close (`src/mobile.rs::send_response`). This is plain
request/response with no streaming and no subscriptions.

#### 7.3 Endpoints
- Desktop: `Endpoint::builder(presets::N0).secret_key(secret).alpns(vec![ALPN]).bind()`. This uses n0's
  production relays and pkarr/DNS discovery. The EndpointId (the public key) is the stable address.
- Browser: `presets::Minimal` + `PkarrPublisher::n0_dns()` + a custom `DotlessRelays` wrapper around
  `PkarrResolver::n0_dns()` + `RelayMode::Custom(default prod relays without trailing dot)`. A
  comment explains why: *"Safari cannot connect to hostnames with a trailing dot, and n0's default
  relay URLs all end in one."* In a browser, iroh can only use the relay (WebSocket). There is no
  UDP hole punching from WASM, so all browser traffic goes through n0 relays. The relay only sees
  QUIC-encrypted bytes.

#### 7.4 Sync model
- Desktop: `poll_mobile` runs on each UI tick and rebuilds `Response::Snapshot` into a shared
  `Arc<Mutex<Response>>` at most every 500 ms (or right after a command or status change). A
  `Snapshot` request is served straight from that mutex, without a round trip to the UI thread.
  Other commands go to the UI thread through `mpsc`, and the reply comes back through a
  `tokio::oneshot`.
- The snapshot holds **every project and agent with its last 100 messages**. Each message is cut to
  4000 characters (`mobile_text`). There are no deltas. Tool calls are flattened to text lines
  (`"Title · status\n details"`).
- Browser: a loop drains queued commands, sends a `Snapshot` request, and then waits
  `pollDelay()` = **800 ms**. It stops when `document.hidden`. The page "locks when hidden or
  reloaded", so the user must unlock again.

#### 7.5 Pairing and auth
1. The desktop has a persistent iroh `SecretKey` and a rotating **pairing token** (random 32 bytes hex).
2. Link/QR: `{web_url}#{endpoint_id}:{pairing_token}`. The default base is `https://agentaps.dev/`,
   which can be overridden with `AGENTAPS_WEB_URL` or a setting. The secret is in the **fragment**,
   so the static host never receives it. The page calls `history.replaceState` to remove it. The
   in-page QR scanner (`rqrr` over camera frames) checks `url.origin() == location.origin`.
3. The browser sends `Request{token: pairing_token, command: Pair, client_name}`. The desktop
   compares in constant time (`subtle::ct_eq`), creates a per-client `{id, name, token, paired_at}`,
   saves it to SecretSpec (and reads it back to verify), **rotates the pairing token** (one use only),
   and returns `Paired{token}`.
4. Every later request carries this client token. `authorizes()` checks it in constant time against
   all linked clients. Revoking a client deletes it. The UI lists linked clients.
5. Browser at rest: `{endpoint, token}` is encrypted with AES-GCM in `localStorage`. The AAD is the
   storage key. The key comes from a **WebAuthn PRF passkey** (HKDF, info `"Agentaps phone unlock v2"`)
   or from a **PBKDF2 passphrase of 15 or more characters**.
6. To rotate everything, delete the `MOBILE_CREDENTIALS` secret. This gives a new iroh ID and drops
   all clients.

Transport security comes from iroh/QUIC TLS bound to the desktop's public key, so the client
authenticates the server by EndpointId. The server authenticates the client only by the bearer token
in the JSON body, not by the client's iroh key. (A fact: the server never checks
`connection.remote_id()`.)

#### 7.6 What mobile can do
Read conversations, send prompts (queued if the agent is busy), stop turns, answer permissions,
start a new session (local path or `ssh://`, with any ACP command). It cannot do diff,
elicitation forms, or terminal.

### 8. Push notifications

**There are none.** There is no APNs and no web push. `src/app/notifications.rs` raises desktop OS
notifications (`cx.show_system_notification`, tagged with agent_id) when:
- the attention request count goes up ("Needs your input": a permission or elicitation arrived), or
- the status changes to `Done` ("Finished"),

and only when the session is **not on screen** (window inactive, or another session displayed).
Clicking a notification opens that session. The phone learns about changes only while the page is
open and polling.

### 9. Chat view details

- Source: **ACP only**. There are no JSONL readers and no hooks. History is replayed by the harness
  (`replayFrom:{type:"start"}` on v2).
- Entries: `ChatEntry{role: User|Agent|Thought|Tool|System|ContextReset, key, text, images}`. Tool
  calls upsert by key `tool:{toolCallId}`, with the headline `"{title} · {status}"` (status one of
  `pending|in_progress|completed|failed`) and details after the first `\n`. The renderer groups
  consecutive Tool entries (`render/tool_group.rs`) and has special cases: "Guardian Review" is the
  Codex approval reviewer, and "Terminal"/"Using tool" are treated as generic titles.
  `shell_steps()` splits shell scripts into steps for display.
- Permissions are shown as cards with one button per option (desktop and `web/src/ui/render.rs:439`).
- Composer: `/` for agent slash commands (from `available_commands_update`), `@` for file search
  (nucleo), and `!cmd` asks the agent to run a shell command. Prompts sent while busy go to a
  persisted queue. Up/Down recalls history. Image paste is allowed if `promptCapabilities.image`.
  Text files are embedded as `resource` if `embeddedContext`, otherwise sent as `resource_link`.
- Per-agent adapters are minimal: discovery lists in `src/discovery.rs`, an env tweak for Claude
  (`CLAUDE_CODE_EXECUTABLE`, removes `ANTHROPIC_API_KEY`), and heuristics for config options
  (`model`/`thought_level`/`mode`/Codex "collaboration" Plan toggle). The rest is generic ACP.
- Fork: a new session seeded with the visible conversation as context. Reset context: `session/new`
  on the same process, with settings re-applied.

### 10. Web page / other non-terminal panes

None. The only pane content is a chat session or empty. The diff is a shared side panel. The
terminal is a drawer inside a chat pane.

### 11. Facts vs guesses
- Facts: everything with file paths above. Polling intervals: desktop tick 25/100 ms, snapshot
  rebuild every 500 ms or more, browser poll 800 ms.
- Guesses: browser iroh is relay-only (this is a known iroh-in-WASM limit and the code configures
  relays explicitly). gpui-libghostty uses a native child surface on macOS.

### Lessons for a native Swift macOS+iOS herdr GUI

**Copy**
1. **Iroh as the remote/mobile transport.** EndpointId = public key gives a stable address that
   survives NAT and network changes. A relay is the fallback, and native Swift can also hole-punch
   (unlike WASM). Use one small ALPN-tagged protocol (`ourapp/herdr/0`). Our iOS app is native, so it
   can use iroh through its FFI/Swift bindings (a guess: check how mature `iroh-ffi` is) and get direct
   UDP paths. A thin host-side bridge could forward an iroh stream to `~/.config/herdr/herdr.sock`
   **byte for byte**. Then the iOS client speaks the exact herdr socket protocol and we write no
   second protocol. Agentaps had to invent `control-protocol` only because it had no backend
   protocol of its own.
2. **Pairing UX**: a QR code or link with `endpointId:oneTimeSecret`, exchanged for a per-device,
   revocable token, compared in constant time, with the one-time secret rotated after use. Keep
   secrets in the Keychain (their SecretSpec plays that role) and keep app config separate.
   Since we are native on both sides, we can do better: authorise the **client's iroh public key**
   (`connection.remote_id()`) instead of a bearer token in the body.
3. **Store nothing the backend owns.** Their `messages` are `#[serde(skip)]` and history comes from
   the harness. For us, herdr owns layout, panes, and agents. The app should keep only host list and
   keys (and maybe UI prefs).
4. **"Needs attention" = pending permissions + questions; notify only when off screen; tag the
   notification with the session id to deep-link.** Same rule for our herdr agent status
   (`blocked`/`done`).
5. **Split model** (if we ever render splits): the `Node{Pane|Split{direction,ratio,first,second}}`
   tree with minimum-size clamping is the simplest correct model. It probably mirrors herdr's own
   layout tree, so render herdr's tree instead of keeping our own.
6. **libghostty for terminal rendering.** On Apple platforms, use libghostty (or SwiftTerm) and feed
   it herdr pane bytes. Agentaps proves libghostty can be embedded in a non-Ghostty app with live
   theming.
7. **ACP as an optional chat source.** Their v1/v2 `session/update` normaliser (`protocol.rs`) is a
   compact reference for message, thought, and tool-call chunk merging (upsert by `toolCallId`,
   `title · status`) and for the permission option shape (`optionId`/`name`, reply
   `{"outcome":{"outcome":"selected","optionId"}}`). It is useful if a herdr chat view ever drives
   agents through ACP instead of the TUI.

**Avoid**
1. **Full-snapshot polling** (800 ms, all projects, 100 messages each, one new QUIC connection per
   request). It wastes battery and bandwidth on mobile and has no live terminal at all. Use one
   long-lived iroh connection with herdr's event subscription and stream the data.
2. **The app owning agent processes.** In Agentaps, quitting the app kills agents ("Closing the app
   can interrupt an active turn"), and SSH agents die when the SSH session drops. herdr already
   solves this. Keep herdr as the sole owner.
3. **SSH with `BatchMode`/`StrictHostKeyChecking`, one process per agent.** It is fragile, and you
   get no diff or terminal remotely. Prefer one iroh link per host to herdr.
4. **Lossy mobile payloads** (4000-character truncation, tool calls flattened to text). Send
   structured data.
5. **A web/WASM client.** It forces relay-only transport, page-hidden lockouts, and no push. A
   native iOS app with APNs (through a tiny relay, or a later iroh-woken flow) is clearly better
   for the "agent needs input" case. Agentaps has no push at all.
6. **Hand-written JSON-RPC with magic ids** (`id 1` = initialize, `id 2` = session/new|load). This
   is brittle. Use typed Codable request/response pairs with a correlation map.

---

## Lessons for our app (all four repos together)

**Copy**
1. **herdr is the only backend.** Store only the host list, keys and UI preferences. Every repo that tried to
   own more paid for it: agentaps kills agents when the app quits, and herdrup keeps a "saved terminals" store
   because the fork's `agent.list` omits shells. Use `session.snapshot` (workspaces, tabs, panes, agents, layouts)
   or the endpoint snapshot as the single source of truth.
2. **Status = herdr events + a snapshot backstop.** On the JSON API: subscribe → wait for `subscription_started`
   → `session.snapshot` → diff. Use per-pane `pane.agent_status_changed` subscriptions and global
   `pane.created/closed/exited/focused`. Reopen the subscription with the full set when panes change, because a
   second subscribe on the same connection is ignored. Run one collector per host. Its output drives the
   sidebar, the in-app alerts and push.
3. **Chat view = web-ui's recipe, done in Swift.** Locate the transcript with `agent.get` → `agent_session`
   (Claude id → `~/.claude/projects/*/<id>.jsonl`; pi/omp path, re-reported on `/new`, `/resume` and `/fork`).
   Parse it into turns of `text/thinking/tool/image` parts. Re-read only when the file's mtime or size changes,
   and page large files. Send with `agent.prompt` (refused while blocked) and fall back to bracketed
   `send_text` + `send_keys Enter`. Fall back to `pane.read source:"recent"` text for unknown agents.
   Prompt and approval cards come from the screen (`pane.read source:"detection"`) and are answered with arrow
   keys, never digits. Start with Claude + pi + a generic fallback card, and add Codex later (its lookup is the
   hardest: lsof on open rollouts).
   For remote hosts the transcript files are on the remote machine. Something there must read them: the
   web-ui bridge, an ssh `cat`/`tail`, or a tiny host helper. This is the main reason for a per-host helper.
4. **Pick the terminal path deliberately** (decide this in the design doc):
   - (a) Client-shell endpoint (gpui): no emulator, herdr draws splits, and the remote path is free
     (`remote-client-bridge`). But it is a bincode codec, it gives one focused-tab surface per connection, and
     the method allowlist is narrow.
   - (b) `terminal attach` bytes → SwiftTerm or libghostty (web-ui + herdrup): per-pane streams fit a pane strip.
     But it needs a PTY or a helper per pane, only one attach slot exists per terminal (it conflicts with
     web-ui running beside us), and iOS cannot spawn it, so the bytes must be relayed.
5. **Swipe performance:** keep a small LRU of mounted-but-hidden live terminals (herdrup `PaneKeepAlive`).
   Give input focus and size authority only to the visible pane.
6. **PTY size:** herdr has one size per pane. Resizing the attach PTY or sending `ClientShellResize` reflows the
   TUI. A phone should observe and scale (web-ui "observe" role adopts `pane-geometry`). The Mac app may own
   the size.
7. **Remote:** reuse herdr's own remote paths (`herdr remote-client-bridge` over SSH, and herdr's
   `client/endpoints.json` + `herdr machine add` for saved hosts). Do not invent a protocol. For iOS, use an SSH
   library (Citadel, as herdrup does) or iroh as a byte pipe to the host's herdr sockets. Authorize by the
   client's iroh public key, not by a bearer token in the body.
8. **Pairing:** a QR with a one-time secret, exchanged for a per-device revocable credential (herdrup appends an
   ssh key; agentaps/web-ui issue a token whose hash is stored). The secret goes in the URL fragment or over
   Tailscale. Keep secrets in the Keychain.
9. **Push:** decide on the host from status transitions (blocked always, done only after a long turn, ignore
   the first sighting, one notification slot per pane: `shared/notify-policy.ts`). APNs needs either a host
   process holding the device token plus a relay with the .p8 key (herdrup's sealed-capability Worker), or the
   Mac app acting as the sender while it runs.
10. **Web pages:** gpui's model fits ponytail: a client-side WKWebView tied to a herdr id, dropped when that id
    disappears. Our twist (a placeholder herdr pane that holds the URL) keeps "app stores nothing" true.
    Check whether `pane.report_metadata` / `agent.view.set` can carry the URL instead of the pane's command line.

**Avoid**
- Depending on the jerryfane fork (`pane.stream`, `api-bridge`, gram, push, `pane.set_pty_size`).
- Full-snapshot polling of chat over the network (agentaps polls every 800 ms with text cut to 4000 characters).
  Poll with an ETag or 304, or push.
- Pooling JSON-API connections: herdr closes them after each reply.
- Passing `--takeover` on our own initiative. Do it only on an explicit user action.
- Using screen scraping for chat content when a transcript exists. Use the screen only for live prompts.
- Copying the size of these codebases: gpui is about 234k lines, herdrup has a 9.9k-line `HerdrApp.swift`, and
  web-ui has a 3k-line prompt parser.
