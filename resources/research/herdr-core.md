# herdr core: what our app can rely on

Scope: herdr **0.9.3** (installed `~/.local/bin/herdr`, `ping` → `protocol: 22`, `endpoint_protocol_generation: 1`).
Source: `git clone --depth 1 https://github.com/herdrdev/herdr` → `/tmp/herdr-research/herdr` (HEAD `4dc23bb`, `Cargo.toml` version 0.9.3).
The full JSON Schema for this binary is saved at `/tmp/herdr-research/herdr-api-0.9.3.schema.json` (`herdr api schema --output …`).
Live samples come from the running `pi-herd` session (`HERDR_SOCKET_PATH=~/.config/herdr/sessions/pi-herd/herdr.sock`; note that this session is a **named** session, not the default `~/.config/herdr/herdr.sock`). I created a throwaway workspace `wA`, tested in it, closed it, and set server focus back to `w7:p1`.

Labels used below: **[verified]** means I ran it live, **[source]** means I read it in the code, **[docs]** means it is from the docs, **[guess]** means it is my inference.

---

## 0. TL;DR for the app design

| Need | herdr gives us |
|---|---|
| Tree of workspaces/tabs/panes/agents | `session.snapshot` (one call) plus `events.subscribe` (push). JSON over a unix socket. |
| Live terminal content per pane | **`herdr terminal session control/observe <pane>`**: an NDJSON stream of `terminal.frame` records (base64 ANSI, rendered by the server at *our* cols×rows) plus JSON commands on stdin (input/resize/scroll/mouse). This is the only documented live stream. The JSON socket API has **no** output stream. |
| Text/scrollback for chat or preview | `pane.read` / `agent.read` (`visible`, `recent`, `recent_unwrapped`, `detection`; `text` or `ansi`). Polling only. |
| Layout | BSP tree with ratios, stored on the server: `layout.export`, `layout.set_split_ratio`, `pane.resize`, `pane.zoom`, `pane.swap`, `pane.move` (across tabs/workspaces). |
| Agent status | `agent_status` ∈ `idle|working|blocked|done|unknown` on every pane, plus a per-pane `pane.agent_status_changed` subscription. |
| Chat transcripts | `agent_session` on pane/agent records: `{source:"herdr:pi", kind:"path", value:"/…/session.jsonl"}` or `{source:"herdr:claude"|"herdr:codex", kind:"id", value:"<uuid>"}`. |
| Web-page placeholder | Pane **`label`**: free-form, no length cap, **persisted across server restart**. Tokens (`pane.report_metadata`) are capped at 80 chars and not persisted. |
| Remote hosts | `ssh <host> herdr [--session S] remote-api-bridge` = raw stdio↔API-socket pipe. `ssh <host> herdr terminal session control …` gives live panes. Auth is plain OpenSSH. |

---

## 1. Socket API (the public JSON API)

### 1.1 Transport [source + verified]
- Unix domain socket (named pipe on Windows), mode `0600` (`src/api/server.rs: SOCKET_PERMISSION_MODE = 0o600`). There is no auth beyond filesystem permissions.
- Path resolution order: `--session <name>` → `HERDR_SOCKET_PATH` → `HERDR_SESSION=<name>` (`~/.config/herdr/sessions/<name>/herdr.sock`) → default `~/.config/herdr/herdr.sock`.
- **Newline-delimited JSON. It is not JSON-RPC 2.0**, although it looks similar: request `{"id":"…","method":"…","params":{…}}`, success `{"id","result":{"type":"…",…}}`, error `{"id","error":{"code","message"}}`.
- **One request per connection.** `handle_connection_with_stop` reads one initial line (max 1 MiB, 5 s timeout), answers, and closes. Verified: I sent two pings on one connection, got one response, then EOF. Long-lived connections exist only for `events.subscribe` (stream), and for `events.wait`, `agent.wait`, `agent.prompt` (with wait), and `pane.wait_for_output` (one delayed response). A second `events.subscribe` on an open subscription is ignored (herdr-web-ui notes the same).
- Server-side app dispatch timeout is 5 s (`APP_RESPONSE_TIMEOUT`). Stream write timeout is 5 s.
- Subscriptions are **server-polled every 100 ms** (`CONNECTION_POLL_INTERVAL`) from a shared in-memory ring of **512 events** (`event_hub.rs MAX_EVENTS`). A slow reader gets `error.code:"events_lost"` and the server closes that connection. To recover: resubscribe, wait for `subscription_started`, call `session.snapshot` on another connection, and treat events as invalidation signals.
- `ping` → `{"type":"pong","version":"0.9.3","protocol":22,"capabilities":{"live_handoff":true,"detached_server_daemon":true,"endpoint_protocol_generation":1,"surface_interest":true,"health_check":true,"ssh_agent_registration":true}}` [verified]
- `herdr api schema --json` prints the full JSON Schema (request, success_response, error_response, event, subscription_event). We can generate Swift Codable types from it.

### 1.2 Every method in 0.9.3 (generated from the bundled schema)
Optional params have a `?` suffix. Methods marked *(undoc)* are in the schema but not in the public docs; they are used by the TUI client.

```
ping: {}
server.stop | server.reload_config | server.agent_manifests | server.reload_agent_manifests: {}
server.live_handoff: {expected_protocol?, expected_version?, import_exe?}        (internal)
server.ssh_agent.register: {socket_path}                                         (internal)
notification.show: {title, body?, position?: top-left|top-right|bottom-left|bottom-right, sound?: none|done|request}
product_announcement.dismiss: {id, version}   release_notes.dismiss: {version}  (internal)
command.invoke: {command_id, pane_id?, selection?, tab_id?, workspace_id?}      (undoc)
client.window_title.set: {title}   client.window_title.clear: {}
client_shell.surface.set: {active}                                               (internal)
session.snapshot: {}
workspace.create: {cwd?, env?, focus?, label?, source_workspace_id?}
workspace.list: {}  workspace.get|focus: {workspace_id}  workspace.rename: {workspace_id, label}
workspace.move: {workspace_id, insert_index}  workspace.move_block: {workspace_ids[], before_workspace_id?}
workspace.report_metadata: {workspace_id, source, tokens: map, ttl_ms?, seq?}
workspace.close: {workspace_id, close_group?}
worktree.list|create|open|remove: (git worktree ↔ workspace helpers)
tab.create: {workspace_id?, cwd?, env?, focus?, label?}  tab.list: {workspace_id?}
tab.get|focus|close: {tab_id}  tab.rename: {tab_id, label}  tab.move: {tab_id, insert_index}
agent.list: {}  agent.get|explain|focus: {target}
agent.read: {target, source: visible|recent|recent_unwrapped|detection, lines?, format?: text|ansi, strip_ansi?}
agent.send_keys: {target, keys[]}  agent.rename: {target, name?}
agent.start: {name, kind, pane_id, args?, timeout_ms?}
agent.prompt: {target, text, wait?: {until[], timeout_ms?}}
agent.wait: {target, until?[], timeout_ms?}
agent.view.set: {source, label?, filter?, sort?}  agent.view.clear: {source?}
pane.split: {direction: right|down, target_pane_id?, workspace_id?, ratio?, cwd?, env?, focus?, right_click?}
pane.swap: {pane_id?|source_pane_id+target_pane_id, direction?}
pane.move: {pane_id, destination: {type:"tab",tab_id,split,target_pane_id?,ratio?} | {type:"new_tab",workspace_id?,label?} | {type:"new_workspace",label?,tab_label?}, focus?}
pane.zoom: {pane_id?, mode?: toggle|on|off}
pane.layout|process_info|edges: {pane_id?}  pane.neighbor|focus_direction: {direction, pane_id?}
pane.resize: {direction: left|right|up|down, amount?, pane_id?}
layout.export: {tab_id?|pane_id?}  layout.apply: {root: LayoutNode, workspace_id?, tab_id?, tab_label?, focus?}
layout.set_split_ratio: {tab_id?|pane_id?, path: [bool], ratio}
pane.scroll: {pane_id, offset_from_bottom}                                       (undoc)
pane.clear | pane.edit_scrollback: {pane_id}                                     (undoc)
pane.selection.read | pane.copy_motion | pane.copy_search | pane.link.resolve | pane.link.activate  (undoc, copy-mode helpers)
pane.list: {workspace_id?}  pane.current: {caller_pane_id?}  pane.get|focus|close: {pane_id}
pane.input.set: {pane_id, right_click: herdr|pane}
pane.rename: {pane_id, label?}
pane.send_text: {pane_id, text}  pane.send_keys: {pane_id, keys[]}  pane.send_input: {pane_id, text?, keys?}
pane.read: {pane_id, source, lines?, format?: text|ansi, strip_ansi?}
pane.wait_for_output: {pane_id, source, match: {type: substring|regex, value}, lines?, strip_ansi?, timeout_ms?}
pane.report_agent: {pane_id, source, agent, state: idle|working|blocked|unknown, message?, agent_session_id?, agent_session_path?, resume_argv?, seq?}
pane.report_agent_session: {pane_id, source, agent, agent_session_id?, agent_session_path?, resume_argv?, session_start_source?, seq?}
pane.report_metadata: {pane_id, source, agent?, applies_to_source?, title?, display_agent?, state_labels?, tokens?, ttl_ms?, seq?, clear_*?}
pane.clear_agent_authority: {pane_id, source?, seq?}  pane.release_agent: {pane_id, source, agent, seq?}
popup.close: {}
events.subscribe: {subscriptions: [Subscription]}
events.wait: {match_event: EventMatch, timeout_ms?}     (only pane_agent_status_changed is implemented, see 1.4)
integration.list | integration.install|uninstall: {target: pi|omp|claude|codex|copilot|devin|droid|kimi|opencode|kilo|hermes|qodercli|qwen|cursor|mastracode|antigravity_cli|grok}
plugin.link|list|unlink|enable|disable|action.list|action.invoke|log.list|pane.open|pane.focus|pane.close
```
Key strings for `send_keys` look like `enter`, `esc`, `ctrl+c`, `alt+x`, `shift+tab`, `f1`, `minus`. `prefix+` strings are not accepted.

### 1.3 Real response shapes [verified]
`session.snapshot` → `{"type":"session_snapshot","snapshot":{version, protocol, focused_workspace_id, focused_tab_id, focused_pane_id, workspaces[], tabs[], panes[], layouts[], agents[]}}`
```json
// workspace
{"workspace_id":"w7","number":1,"label":"~/AAI/aai_labs_mira","focused":true,"pane_count":2,"tab_count":2,"active_tab_id":"w7:t1","agent_status":"idle"}
// tab
{"tab_id":"w7:t1","workspace_id":"w7","number":1,"label":"smart-inbox-v2-impl","focused":true,"pane_count":1,"agent_status":"idle"}
// pane (PaneInfo)
{"pane_id":"w9:p1","terminal_id":"term_65d523af6cab317","workspace_id":"w9","tab_id":"w9:t1","focused":false,
 "cwd":"/Users/hkandala","foreground_cwd":"/Users/hkandala","agent":"pi",
 "terminal_title":"π - herdr-core-analyst - hkandala","terminal_title_stripped":"π - herdr-core-analyst - hkandala",
 "agent_status":"working",
 "agent_session":{"source":"herdr:pi","agent":"pi","kind":"path","value":"/Users/hkandala/.pi/agent/pi-herd/sessions/2026-10-08T11-07-04-561Z_….jsonl"},
 "scroll":{"offset_from_bottom":0,"max_offset_from_bottom":0,"viewport_rows":40},"revision":1}
// agent (AgentInfo) adds: "screen_detection_skipped":true,"state_change_seq":55,"completion_seq":55
```
Note: the `AgentInfo` values above come from a different, idle agent (`w7:p1`). herdr sets `completion_seq` only when an agent goes from working or blocked to idle, and clears it to null on every other status change (`src/app/actions.rs` ~1756), so a working agent has `completion_seq: null`.
Other optional PaneInfo fields (`src/api/schema/panes.rs:449`): `label`, `title`, `display_agent`, `state_labels`, `tokens`, `restore_error`. `revision` is a metadata revision: it went from 0 to 1 after `report_metadata`. It is not an output counter.

Layout snapshot (`pane.layout`, also in `snapshot.layouts[]`, `layout.updated`). Rects are in **terminal cells**:
```json
{"workspace_id":"wA","tab_id":"wA:t1","zoomed":false,"area":{"x":0,"y":0,"width":120,"height":40},"focused_pane_id":"wA:p1",
 "panes":[{"pane_id":"wA:p1","focused":true,"rect":{"x":0,"y":0,"width":36,"height":40}},
          {"pane_id":"wA:p2","focused":false,"rect":{"x":36,"y":0,"width":84,"height":20}}, …],
 "splits":[{"id":"split_0_root","direction":"right","ratio":0.3,"rect":{…}},{"id":"split_1_1","direction":"down","ratio":0.5,"rect":{…}}]}
```
Portable tree (`layout.export`, also returned by `set_split_ratio`):
```json
{"root":{"type":"split","direction":"right","ratio":0.3,
  "first":{"type":"pane","pane_id":"wA:p1","cwd":"/private/tmp"},
  "second":{"type":"split","direction":"down","ratio":0.5,"first":{…"wA:p2"},"second":{…"wA:p3"}}}}
```
`layout.set_split_ratio {"tab_id":"wA:t1","path":[true],"ratio":0.7}` changed the **second** child split, so in `path`, `false` = first and `true` = second; `[]` is the root. `pane.resize {direction:"right",amount:0.1}` moved the root ratio from 0.3 to 0.4.

`pane.read` (ansi):
```json
{"type":"pane_read","read":{"pane_id":"wA:p1","workspace_id":"wA","tab_id":"wA:t1","source":"recent","format":"ansi",
 "text":"…hello-from-api\r\n\u001b[0m\u001b[38;5;1mred\u001b[0m\r\n…","revision":0,"truncated":true}}
```
`pane.process_info` → `{shell_pid, foreground_process_group_id, foreground_processes:[{pid,name,argv0,argv,cmdline,cwd}]}`.
`pane.move` → `{type:"pane_move", move_result:{changed, previous_pane_id, previous_workspace_id, previous_tab_id, pane, source_layout, target_layout, created_tab?, created_workspace?, closed_tab_id?, closed_workspace_id?, focused_pane_id}}`.
`pane.zoom` → `{type:"pane_zoom", zoom:{changed, zoom_changed, focus_changed, pane_id, focused_pane_id, zoomed, layout}}`.

### 1.4 Events [source + verified]
Subscription types: `workspace.{created,updated,metadata_updated,renamed,moved,reordered,closed,focused}`, `worktree.{created,opened,removed}`, `tab.{created,closed,focused,renamed,moved}`, `pane.{created,closed,updated,focused,moved,exited,agent_detected}`, `layout.updated` (all global), plus **per-pane** ones: `pane.agent_status_changed {pane_id, agent_status?}`, `pane.scroll_changed {pane_id}`, `pane.output_matched {pane_id, source, match, lines?}`.

Frames (note the two naming styles):
```json
{"id":"r1","result":{"type":"subscription_started"}}
{"event":"layout_updated","data":{"type":"layout_updated","layout":{…PaneLayoutSnapshot}}}
{"event":"tab_renamed","data":{"type":"tab_renamed","tab_id":"wA:t2","workspace_id":"wA","label":"renamed"}}
{"event":"pane_focused","data":{"type":"pane_focused","pane_id":"wA:p1","workspace_id":"wA"}}
{"event":"pane.output_matched","data":{"pane_id":"wA:p1","matched_line":"… echo MARKER42","read":{…full pane_read…}}}
```
Lifecycle events use `snake_case` names. Subscription-only events (`pane.output_matched`, `pane.agent_status_changed`, `pane.scroll_changed`) use dot names.

Gaps and quirks I found:
- **There is no output stream.** `pane.output_changed` exists in the schema, but no code emits it (`plugins/mod.rs` tests say "warning-only until hook semantics exist"). `events.wait` accepts only `pane_agent_status_changed`; everything else returns `unsupported_event_wait_match` (`src/api/wait.rs:760`). `pane.output_matched` is the server polling `pane.read` every 100 ms.
- **`pane.rename` emits no event** [verified]. Neither `pane.updated` nor anything else fires, so a label change must be followed by a re-read. Metadata `title`/`display_agent`/`state_labels` changes arrive through the per-pane `pane.agent_status_changed`. Token changes and terminal-title changes emit `pane.updated`.
- `pane.agent_status_changed` needs a `pane_id`, so the client needs one subscription entry per pane and must reopen the stream when the pane set changes (herdr-web-ui `server/collector.ts` does this).
- `pane.focus` / `agent.focus` move the **server's** focused workspace/tab/pane [verified: `session.snapshot.focused_*` changed to `wA`]. **Correction (see 7.6):** they also move **every attached TUI client** to that tab, and they mark the whole tab as seen. The docs line "does not move other clients' views" is about `pane.focused` events caused by *manual* selection in one client. Our app should not call focus casually.

### 1.5 Reading output, sending input, resize
- **Read:** `pane.read`/`agent.read` with `source=visible` (current screen), `recent` (scrollback, wrapped), `recent_unwrapped` (logs), `detection` (the bottom buffer the agent detector sees). `format=ansi` keeps SGR. `lines` limits rows. The result has `truncated`. The JSON API has no raw PTY byte stream.
- **Input:** `pane.send_text` (literal), `pane.send_keys` (key names), `pane.send_input` (both, ordered), `agent.prompt` (honors bracketed paste and sends a delayed Enter; can also wait).
- **Resize:** the JSON API cannot set PTY cols/rows. Pane PTY size = layout rect × the viewing client's area (with no client viewing, the default area is 120×40 [verified for `wA`]). Ratios are server state. The only external way to set a pane's PTY size is `terminal session control` + `terminal.resize` (see 2.2). That also **locks** the pane from layout-driven resizes while the controller is attached (`direct_attach_resize_locks`, `src/ui/panes.rs:331`).

---

## 2. Client↔server protocol and live terminal bytes

### 2.1 `herdr-client.sock`: private binary protocol [source]
- Path = the API socket path with `-client` inserted (`herdr.sock` → `herdr-client.sock`, `src/server/socket_paths.rs`).
- Framing: **u32 little-endian length prefix + bincode-encoded Rust enums** (`src/protocol/wire.rs`; `MAX_FRAME_SIZE` 2 MiB, 32 MiB with graphics). `PROTOCOL_VERSION = 22`.
- `ClientMessage` variants (order frozen for endpoint gen 1): `TerminalHello`, `Input{data}`, `ClipboardImage`, `Resize`, `Detach`, `AttachTerminal{terminal_id,takeover}`, `AttachScroll`, `ObserveTerminal{target}`, `ControlTerminal{target,takeover}`, …, `ClientShellHello{surface_size,…}`, `ClientShellResize`, `ClientShellPaneInput{pane_id,events}`, `ClientShellEndpointRequest{boot_id,request}` (JSON API tunnelled over this socket), …, `EndpointControl{kind,data}`.
- `ServerMessage`: `Welcome{encoding: SemanticFrame|TerminalAnsi}`, `Terminal(TerminalFrame{seq,width,height,full,bytes})`, `Graphics`, `ServerShutdown{reason}`, `Notify`, `Clipboard` (OSC 52), `ClientShellSnapshot`, **`PaneSurface`** ("active-tab pane content rendered at a client-requested size"), `PaneSurfacePatch`, `SemanticNotification{kind: NeedsAttention|Finished|UpdateInstalled|Custom,…}`, `ClientShellEndpointResponseChunk`, `EndpointControl{kind,data}`.
- Since 0.9, the TUI is a "client-owned shell" (`src/protocol/endpoint.rs`): the client draws the sidebar and tabs. The server sends a JSON snapshot (`shell.snapshot.v1`) and cell surfaces (`shell.surface.v1`) for **the client's one active tab**. The hello/welcome negotiate codecs, advertised `methods` and `capabilities` (`surface_interest`, `health_check`, `agent_view_projection`, `agent_completions`). A third party *could* implement this in Swift (bincode of Rust enums, cell grids), but it is a private, Rust-shaped protocol tied to one active tab per connection. **Not recommended.**

### 2.2 Documented bridge: `herdr terminal session observe|control` [source + verified]
This is the supported way for third-party GUIs to get live pane content (`src/client/terminal_sessions.rs`). It is a CLI that speaks the binary protocol (handshake with `RenderEncoding::TerminalAnsi`, then `ObserveTerminal`/`ControlTerminal`) and converts it to NDJSON on stdout/stdin. Unix only (no Windows direct attach).
```
herdr terminal session observe <pane|terminal|agent target> [--cols N] [--rows N]     # read-only, many observers
herdr terminal session control <target> [--takeover] [--cols N] [--rows N]             # one writer per terminal
```
stdout:
```json
{"type":"terminal.frame","seq":1,"encoding":"ansi","width":50,"height":10,"full":true,"bytes":"<base64>"}
{"type":"terminal.frame","seq":2,"encoding":"ansi","width":50,"height":10,"full":false,"bytes":"<base64>"}
{"type":"terminal.closed","reason":"detached"}
```
stdin (control only):
```json
{"type":"terminal.input","text":"echo hi\r"}            // or "bytes":"<base64>"
{"type":"terminal.resize","cols":40,"rows":8,"cell_width_px":0,"cell_height_px":0}
{"type":"terminal.scroll","direction":"up","lines":3,"source":"wheel"|"page_key","column":0,"row":0,"modifiers":0}
{"type":"terminal.mouse","action":"down|up|drag|move","button":"left|right|middle","column":12,"row":5,"modifiers":0}
{"type":"terminal.release"}
```
What the bytes are (important):
- They are **not raw PTY bytes**. The server keeps its own VT state (ghostty-vt) and renders that pane's **visible viewport** at the client's cols×rows, then sends **diffed ANSI**: the first frame is `full:true` with `ESC[2J`, later frames are cursor-addressed patches wrapped in `?2026h/l` (synchronized output) [verified sample: `\x1b[?2026h\x1b[?25l\x1b]8;;\x1b\\\x1b[8;29H…CTRL-OK…\x1b[?2026l`]. A `terminal.resize` produces a new `full:true` frame at the new size.
- Scrollback is **not streamed**. `terminal.scroll` moves the server-side viewport, and the frames show the scrolled view. Feeding these bytes into SwiftTerm gives a correct screen, but SwiftTerm's own scrollback will be meaningless. For history, use `pane.read recent` or the server viewport (`terminal.scroll`, or the undocumented `pane.scroll`).
- `control` **resizes the actual PTY** to the controller size and locks layout-driven resize while attached (`attach_terminal_client` in `src/server/headless.rs:1722`). After release the PTY **stays** at the controller size until a TUI shell client re-lays out that tab [verified: `viewport_rows` stayed 8 after release]. `observe` never resizes. It renders the PTY screen clipped or padded to the observer size [verified: 60×10 observe of a 40-row pane showed the top-left region].
- Only one controller per terminal. A second controller gets `ServerShutdown "already has an attached client; retry with --takeover"`, and with `--takeover` the old one gets `"terminal attach taken over"`. The full-screen sibling is `herdr terminal attach <terminal_id>` / `herdr agent attach <target>` (for humans; detach with `ctrl+b q`).
- Observers that make no write progress for 30 s are dropped.

**How existing GUIs do it:** herdr-web-ui (`/tmp/herdr-research/herdr-web-ui`) runs `herdr terminal attach` inside a node-pty sidecar (`server/pty/sidecar.ts`). It uses the JSON socket for `session.snapshot` + `events.subscribe` (`server/herdr/client.ts`, `server/collector.ts`), and reads agent transcript files for chat. herdr's own TUI uses the private client-shell protocol.

**For our app [guess, needs a spike]:** on macOS, spawn one `herdr terminal session control` per *visible* pane (observe for off-screen thumbnails). On iOS (no subprocess), run the same command over an SSH exec channel to the host. That works for local too if the Mac runs sshd, or a Mac-side relay could do it. The alternative is to implement the bincode `ObserveTerminal`/`ControlTerminal` subset natively. That subset is small (handshake, then `Terminal` frames, `Input`/`Resize`/`AttachScroll`/`AttachMouse`/`Detach`), but it is private and version-coupled (`PROTOCOL_VERSION` guards it; docs: "check `ping` before using those operations across different builds").

---

## 3. Data model

- **IDs** (per server and session; two machines can both have `w1:p1`): workspace `w7`, `wA` (base-36-ish counter); tab `w7:t1`; pane `w7:p1`; terminal `term_65d4963eec1341` (stable for the terminal process, survives `pane.move`). Tab and pane numbers are public counters per workspace (`session.json: public_pane_numbers`, `next_public_pane_number`). **A cross-workspace `pane.move` assigns a new public `pane_id`** but keeps the terminal. Key caches by `terminal_id` when you need continuity.
- **Layout:** a BSP tree per tab, `direction: right|down`, `ratio: f32`, persisted (`persist/snapshot.rs LayoutSnapshot::Split{direction,ratio,first,second}`). It is exposed and settable: `layout.export`/`layout.set_split_ratio`/`pane.resize`/`layout.apply` (creates a new tab from a tree; does not keep live PTYs). `pane.split` takes `ratio`.
- **Zoom:** per tab (`zoomed` in the layout). `pane.zoom on|off|toggle` also focuses the pane inside the tab. Moves into or out of a zoomed tab fail with `reason:"zoomed_tab"`.
- **Move:** `pane.swap` (same tab, keeps ratios), `pane.move` to an existing tab (`split` + `target_pane_id?` + `ratio?`), `new_tab`, or `new_workspace`. It emits `pane.moved` (no fake close/create). Tabs: `tab.move {insert_index}`. Workspaces: `workspace.move`/`move_block`.
- **Labels and metadata:**
  - `workspace.label`, `tab.label` (rename methods; events `workspace.renamed`/`tab.renamed`).
  - `pane.label` (`pane.rename`): trimmed, **no length cap** (`terminal/state.rs set_manual_label`), **persisted** in `session.json` (`PaneSnapshot.label`), restored after a cold restart, **no change event** [verified]. A 127-char URL label round-tripped intact [verified].
  - `pane.report_metadata`: `title`, `display_agent`, `state_labels{idle|working|blocked|done|unknown}`, and `tokens{name: value}`. Values are capped at **80 chars**, there are at most 32 keys, and they are **not persisted** across restart. They need a `source` like `user:foo`. Workspace tokens work the same way via `workspace.report_metadata`.
  - `pane.split/tab.create/workspace.create` accept `env` for the new process only. Env is **not** exposed by the API and **not** persisted.
  - `launch_argv` (from `layout.apply` commands or plugin panes) is persisted, but on cold restore it is re-run **only for live handoff** (`persist/restore.rs:692 if was_imported`). After a normal restart the pane comes back as a shell.
  - ⇒ **The only durable free-form field on a pane is `label`.** A placeholder convention like `label = "web:https://…"` survives restarts and moves. We must re-read after renaming, because no event fires.
- **cwd and process:** `cwd` (pane/workspace cwd), `foreground_cwd` (live foreground process), `pane.process_info` (pids, argv, cwd per foreground process).
- **Agents:** `agent` (label like `pi`, `claude`, `codex`), `agent_status` (`idle|working|blocked|done|unknown`; `done` = idle and not yet seen by the server), `terminal_title(_stripped)` from OSC 0/2, `display_agent`/`title`/`state_labels` from metadata, and `agent_session`. Rollups: workspace and tab `agent_status`. AgentInfo also has `state_change_seq`, `completion_seq`, `screen_detection_skipped`. Detection uses foreground process + screen manifests (`~/.config/herdr/agent-detection/*.toml` overrides) + integration hooks (`pane.report_agent`). `agent.explain` shows why.
- **Notifications:** the JSON API has `notification.show` (outbound, shows a toast in the TUI). Agent finished/needs-attention notifications go to client shells only, as private `SemanticNotification` messages. **Our app must derive notifications itself** from `pane.agent_status_changed` (working→done or blocked). The per-client "seen" state is client-local, as in the TUI.

---

## 4. Remote machines (0.9 "connecting machines")

- **Architecture:** each machine runs its own `herdr server`. Since 0.9 the client renders the outer UI, and servers "supply the terminal views". Only the **selected** machine streams pane surfaces (`surface_interest`). Others send only workspace, agent and notification state (`docs: connecting-machines.mdx`; blog `herdr.dev/blog/connecting-the-machines/`).
- **Transport = OpenSSH subprocesses**, no custom daemon or port:
  - UI connection: `ssh <target> herdr --session <s> remote-client-bridge [--idle-timeout-v1]`. This pipes stdio ↔ the remote `herdr-client.sock` (binary protocol) (`src/remote/attach.rs:403`).
  - API forwarding (`herdr --machine <label> <cmd>`): `ssh <target> <herdr> --session <s> remote-api-bridge`, after a probe `remote-api-bridge --check` → prints `herdr-api-bridge-v1` (`src/remote.rs`, `attach.rs:2662`). The bridge is a **byte pipe** stdin/stdout ↔ the API socket (`forward_remote_bridge_stdio`), so each request is one SSH exec, since the API is one request per connection. Verified locally: `echo '{"id":"x","method":"workspace.list","params":{}}' | herdr remote-api-bridge` returns the normal JSON.
  - Herdr requests `-C` compression and, if `remote.manage_ssh_config=true`, a generated ssh config with keepalives and a shared ControlMaster (`ControlPersist 600`). This user has `manage_ssh_config = false`.
  - Setup (`herdr machine add`, `herdr --remote`) finds or installs the remote binary (`~/.local/bin/herdr`), and starts the remote server as a detached daemon.
- **Auth model:** only OpenSSH (keys, agent, host keys). Profiles (`~/.config/herdr` state dir `client/endpoints.json`) store id, label, ssh target, remote session and enabled flag. No secrets. The remote socket relies on filesystem permissions (`0600`).
- **Third-party options:** (a) `ssh host herdr remote-api-bridge` per request, plus one long-lived one for `events.subscribe`. (b) `ssh host herdr terminal session control <pane>` for live panes (works because it is just a CLI on the remote). (c) SSH stream-local forwarding of `herdr.sock` (`ssh -L /tmp/x.sock:~/.config/herdr/herdr.sock`, or a `direct-streamlocal@openssh.com` channel from a Swift SSH library) [guess, not tested; it should work because it is just a unix socket]. Named sessions: add `--session <name>`.
- `~/.config/herdr/herdr-remote.sh` is **the user's own** zsh helper (per-host ControlMaster + YubiKey OTP). It is not part of herdr.
- Related: discussion #515 (multi-server) was closed by the maintainer with the 0.9 release. Next steps per the blog: cross-machine CLI and "Herdr Cloud" relay (E2E encrypted).

---

## 5. Plugins, browser panes, hooks

- **Plugins** (`docs/plugins.mdx`, `herdr-plugin.toml`): `[[actions]]`, `[[events]]` (hooks on event names; env `HERDR_PLUGIN_EVENT_JSON`), `[[startup]]`, `[[panes]]` (terminal-only entrypoints; placement `overlay|popup|split|tab|zoomed`), `[[link_handlers]]` (Ctrl-click URL regex → action, gets `HERDR_PLUGIN_CLICKED_URL`), `[[build]]`. The registry is `plugins.json` beside `session.json`. Linking a local folder (e.g. this user's `~/code/pi-hkandala/herdr/plugin`) works the same as `local-plugins/`. "The entire Herdr CLI is the plugin API." **"Native non-terminal plugin UI is not part of plugin v1."** Popups have no pane id.
- **Browser panes:** herdr has **no** browser pane. `ogulcancelik/herdr-browser` is **deprecated**. It streamed Chromium frames through `pane.graphics.stream`, which was **removed** in 0.9 (`pane.graphics.{info,set,clear,stream}` now return unknown-method; "no replacement socket image API"; apps should emit Kitty graphics in their own output). The successor is zenbu-labs/terminal-browser (Kitty graphics in a terminal pane). ⇒ Our WKWebView-over-placeholder approach does not compete with any herdr feature.
- **Agent state hooks:** `herdr integration install <agent>` writes agent-side hooks or plugins that call `pane.report_agent` / `pane.report_agent_session` (Claude: SessionStart → session id only, state from screen manifest; Codex `--no-daemon`: session + turn state; Pi/OpenCode/Kimi/Kilo/OMP: full state). Third-party agents can call these methods themselves (`docs/add-herdr-support.mdx`), including `resume_argv` so herdr re-runs them after a restart. `agent.view.set` lets a caller customize the TUI's agent list ordering and filtering.

---

## 6. Agent sessions and transcripts (for the chat view)

- `agent_session` on `pane.get/list`, `agent.get/list` and `session.snapshot` is a pointer to the agent's native session:
  - Pi: `kind:"path"`, `value` = `~/.pi/agent/<…>/sessions/<ts>_<uuid>.jsonl` [verified].
  - Claude: `kind:"id"`, `value` = uuid → `~/.claude/projects/<cwd with / → ->/<uuid>.jsonl` [verified: `-Users-hkandala-AAI/212e0097-….jsonl`].
  - Codex: `kind:"id"` → `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl` [verified].
  - Others (opencode, kimi, …) are ids into their own stores (see the resume table in `docs/session-state.mdx`, `src/agent_resume.rs`).
- herdr does **not** parse or serve transcripts. The chat view must read those files on the pane's host. For remote hosts that means `ssh host cat/tail` or a helper [guess]. herdr-web-ui does exactly this (`server/claude-store.ts`, `codex.ts`, `pi.ts`, `conversation.ts`).
- Sending a chat message = `agent.prompt {target, text, wait?}` (paste-aware, returns `agent_blocked` if the agent is blocked). Answering a blocked prompt = `agent.send_keys`. A screen fallback is `agent.read source=recent_unwrapped`.
- `pane_history = true` (enabled for this user) stores pane screen history in `session-history.json` for replay after a restart. It is not a chat transcript.

---

## Lessons for our app

**Copy / rely on:**
1. **The JSON socket is the control plane.** Bootstrap with `session.snapshot`, then keep one `events.subscribe` connection (global lifecycle events plus one `pane.agent_status_changed` entry per pane), and reconcile by re-reading. Treat events as invalidations, not deltas. On `events_lost`, resubscribe then snapshot. Generate Codable types from `herdr api schema --json`.
2. **Open a new connection for every request.** That is how the server works. Keep a tiny `call(method, params)` helper. Do not build a multiplexed RPC layer.
3. **Live panes via `herdr terminal session control/observe`.** Render the frames with SwiftTerm as a screen mirror. Send keys as `terminal.input`, and send `terminal.resize` from the SwiftUI view size. Only stream panes that are on screen (herdr itself only streams the selected machine). Use `observe` for previews.
4. **Layout is server state.** Draw our strip from `layout.export` ratios. Write back with `layout.set_split_ratio`/`pane.resize`/`pane.zoom`/`pane.move`/`tab.move`. The app stores nothing.
5. **Web panes = a herdr pane with `label` = `web:<url>`.** It is durable, uncapped and moves with the pane. Re-read after renaming (no event). Run something quiet in it (or leave the shell) so herdr keeps the slot.
6. **Chat view = `agent_session` → native JSONL** on the pane's host, plus `agent.prompt` / `agent.send_keys` for input.
7. **Remote = OpenSSH.** Use `ssh host herdr [--session s] remote-api-bridge` for API calls and `ssh host herdr terminal session control …` for panes, the same building blocks herdr uses. No credentials stored. Host list = ssh targets. Optionally import `herdr machine list --json`.
8. **Notifications:** derive locally from status transitions (`working→done`, `→blocked`), as the TUI does per client.

**Avoid:**
- Implementing the private bincode `herdr-client.sock` protocol (Rust-enum layout, one active tab per connection, version-guarded) unless the subprocess/SSH path proves too slow.
- Expecting raw PTY bytes or streamed scrollback. Frames are server-rendered viewports. Get history from `pane.read`.
- Holding `control` on panes the user is also driving in the TUI. It takes over input, pins the PTY size and leaves it pinned after release. Use `observe` unless the user is typing in our app, and send `terminal.release` promptly.
- Calling `pane.focus`/`agent.focus` (or `focus:true` on create/move) just to view a pane. It moves server focus, moves **all attached TUI clients** to that tab, and marks the tab's agents seen (7.6).
- Storing placeholder data in tokens (80-char cap, lost on restart) or env (invisible, not persisted).
- Assuming ids are globally unique (scope them by host + session) or that `pane_id` survives cross-workspace moves (`terminal_id` does).
- Relying on `pane.output_changed` / `events.wait` for output. They are not implemented in 0.9.3.

---

## 7. Design spikes

All spikes ran on herdr 0.9.3 in the live `pi-herd` session. I used throwaway workspaces `wB`, `wC` (created by a move) and `wD` (created by a move), all with `focus:false`, and closed all three afterwards. Server focus stayed at `w7:t1 / w7:p1` the whole time (checked before and after with `session.snapshot`). Commands are run through a small helper `rpc.py METHOD 'PARAMS'`: one unix-socket connection, one JSON line.

### 7.1 Web placeholder pane: [verified], with one caveat
```
pane.split  {"target_pane_id":"wB:p1","direction":"right","focus":false}           → wB:p2
pane.rename {"pane_id":"wB:p2","label":"web:https://example.com/some/long/path?x=1"}
pane.send_text {"pane_id":"wB:p2","text":"exec sh -c 'printf \"\\033]2;web:%s\\007\\360\\237\\214\\220 %s\\n(rendered by the native app)\\n\" \"$0\" \"$0\"; stty -echo; exec cat >/dev/null' 'https://example.com/some/long/path?x=1'\n"}
```
`pane.get wB:p2` afterwards:
```json
{"pane_id":"wB:p2","terminal_id":"term_65d527849439b2c","tab_id":"wB:t1",
 "label":"web:https://example.com/some/long/path?x=1",
 "terminal_title":"web:https://example.com/some/long/path?x=1",
 "terminal_title_stripped":"web:https://example.com/some/long/path?x=1","agent_status":"unknown","revision":1}
```
- `label` ✅ and `terminal_title` ✅ (from OSC 2) both show the URL.
- `pane.process_info` argv ❌ with the command as given. The final `exec cat` replaces `sh`, so argv is just `["cat"]`:
  `{"foreground_processes":[{"pid":89194,"name":"cat","argv":["cat"],"cmdline":"cat"}]}`
- **Variant that keeps the URL in argv** ✅: do not `exec` the last command, so `sh` stays in the foreground process group. Also put `clear;` first so the typed command does not stay on screen:
  ```
  clear; exec sh -c 'printf "\033]2;web:%s\007" "$0"; stty -echo; while :; do cat >/dev/null; done' 'https://example.com/variant?y=2'
  ```
  → `foreground_processes: [{"name":"cat","argv":["cat"]}, {"name":"bash","argv0":"sh","argv":["sh","-c","printf … done","https://example.com/variant?y=2"]}]`. The screen is blank after `clear`. The `while` loop also survives a Ctrl-D, which would end a plain `cat` and so end the pane, because the login shell was `exec`'d away [guess for the Ctrl-D part].
- Without `clear`, the typed `exec sh -c …` line stays visible above the 🌐 line (`pane.read visible`).
- **Moves:**
  - `pane.move {"pane_id":"wB:p2","destination":{"type":"new_tab","workspace_id":"wB","label":"webtab"},"focus":false}` → `wB:p2` in `wB:t2`. Label and terminal_title unchanged ✅.
  - `pane.move {"pane_id":"wB:p2","destination":{"type":"new_workspace","label":"spike-ws2"},"focus":false}` → **new id `wC:p1`**, same `terminal_id term_65d527849439b2c`, label and terminal_title unchanged ✅. The `cat` process kept running. The move result reported `created_workspace` = `wC` and `closed_tab_id` = `wB:t2`.
- **What the TUI shows as the pane border title** (`src/terminal/state.rs:2410 border_label`), in this order:
  1. metadata `title` (`pane.report_metadata`, the effective title),
  2. manual `label` (`pane.rename`),
  3. only if `ui.show_agent_labels_on_pane_borders`: `display_agent`, then the agent label.

  The OSC `terminal_title` is **not** used for the pane border. It feeds the outer window title and the `terminal_title` API fields. Borders only render when pane borders are shown (multi-pane tabs).
- Persistence: `pane.rename` calls only `mark_session_dirty()`, and the dirty flag triggers a debounced save (`app/mod.rs` test `session_dirty_flag_schedules_debounced_save`). The label then lands in `session.json` `PaneSnapshot.label` (seen for other panes in section 3).

### 7.2 Does a label change emit any event? [verified: no]
I opened one subscription with every pane, workspace, tab and layout type: `workspace.updated`, `workspace.renamed`, `tab.renamed`, `pane.created`, `pane.updated`, `pane.closed`, `pane.focused`, `pane.moved`, `pane.agent_detected`, `layout.updated`, plus per-pane `pane.agent_status_changed {pane_id:"wB:p2"}` and `pane.scroll_changed {pane_id:"wB:p2"}`. Then I renamed `wB:p2` twice, 2 s apart. The stream printed only `{"id":"r1","result":{"type":"subscription_started"}}` and nothing else in 8 s.
Source confirms it: `handle_pane_rename` (`src/app/api/panes.rs:1486`) sets the label, calls `mark_session_dirty()`, and returns `pane_info`. It calls no `emit_*`.
⇒ The renaming client must update its own cache from the response. Other clients only see the change on their next `pane.get`/`session.snapshot`. Workaround [guess]: after a rename, also send a token patch (`pane.report_metadata {tokens:{web:"1"}}`), because token changes emit `pane.updated`.

### 7.3 Terminal session control, several at once: [verified]
```
herdr terminal session control term_65d5277a5ae642b --cols 70 --rows 12   # A: wB:p1, targeted by terminal_id
herdr terminal session control wB:p3 --cols 33 --rows 7                    # B: same tab wB:t1
```
- Two controllers on two panes of the same tab with different sizes ✅. Each got its own `full:true` first frame at its size (`width:70,height:12` and `width:33,height:7`). A's `terminal.input "echo A-ALIVE\r"` came back as a diff frame.
- Targeting by `terminal_id` ✅. Targets can be pane id, terminal id, or agent name (`resolve_terminal_target_id_string`).
- **Layout vs PTY:** while both controllers were attached, `pane.layout` still reported the layout rects `wB:p1 60×40` and `wB:p3 60×40` (area 120×40). But `pane.get` reported `scroll.viewport_rows` 12 and 7. **The layout rect shows the layout's idea of the size, not the PTY size.** Use `scroll.viewport_rows` or the frame width/height for the real size.
- After B sent `terminal.release` (→ `{"type":"terminal.closed","reason":"detached"}`), `herdr terminal session observe wB:p3 --cols 33 --rows 7` worked ✅ and printed a `full:true` frame.
- **Moving a controlled pane** with `pane.move {"pane_id":"wB:p1","destination":{"type":"new_workspace","label":"spike-ws3"},"focus":false}` → `changed:true`, new id `wD:p1`, same `terminal_id`. **Controller A's stream survived** ✅: its later `terminal.input "echo A-AFTER-MOVE\r"` came back as frame `seq:3`, then a clean `terminal.closed {reason:"detached"}` on release. The stream is bound to the terminal, not the pane id.

### 7.4 Long-lived subscribe through `remote-api-bridge`: [verified]
```
( echo '{"id":"sub","method":"events.subscribe","params":{"subscriptions":[{"type":"tab.renamed"},{"type":"layout.updated"}]}}'; sleep 6 ) | herdr remote-api-bridge
```
While it ran I called `tab.rename wD:t1` twice:
```json
{"id":"sub","result":{"type":"subscription_started"}}
{"data":{"label":"via-bridge-test","tab_id":"wD:t1","type":"tab_renamed","workspace_id":"wD"},"event":"tab_renamed"}
{"data":{"label":"via-bridge-test2","tab_id":"wD:t1","type":"tab_renamed","workspace_id":"wD"},"event":"tab_renamed"}
```
**Caveat:** stdin must stay open. With `echo … | herdr remote-api-bridge` (stdin closes right after the request), the bridge printed `subscription_started` and then exited 0 at once. So over SSH exec, keep the channel's stdin open for the life of the subscription. Closing stdin is a clean way to unsubscribe.

### 7.5 `agent.start`, manifests, installed agents: [verified + source]
- **Semantics** (`src/app/agents.rs:145 start_agent`): it validates `name` (`[a-z][a-z0-9_-]{0,31}`, unique among live agents) and `kind` (parsed by `parse_agent_label`). Unknown kinds give `{"code":"unsupported_agent_kind","message":"unsupported interactive agent kind notanagent"}` ✅. The pane must be an idle interactive shell: not an agent, and the shell owns the foreground (`available_shell_name`), otherwise `agent_pane_busy`. Then it **types** `interactive_agent_executable(kind) + args` into the shell, with the shell's own quoting and paste handling (`encode_api_submission`). It marks the pane `launch_pending` and returns **immediately**.
- **It does not check whether the agent is installed** ✅. `agent.start {"name":"spike-amp","kind":"amp","pane_id":"wD:p1","timeout_ms":5000}` returned in about 0.6 s with `{"type":"agent_started","agent":{…,"name":"spike-amp","launch_pending":true},"argv":["amp"]}`. The pane then showed `zsh: command not found: amp`, and the name was dropped (later `pane.get` had no agent). The "returns only after the agent is ready" behavior in the docs is the **CLI** (`src/cli/agent.rs: agent_start` → `wait_for_named_agent` polling, plus a retry while the shell is still starting). Raw API callers must wait themselves, e.g. with `agent.wait` or by polling `agent.get`.
- Valid kinds → executables (`src/detect/mod.rs:153`): pi→`pi`, claude, codex, gemini, cursor→`cursor-agent`, devin, agy (Antigravity), cline, omp, mastracode, opencode, copilot, kimi, kiro→`kiro-cli`, droid, amp, grok, hermes, kilo, qodercli, qwen, letta, maki, muse.
- `server.agent_manifests` sample (22 manifests):
  ```json
  {"type":"agent_manifest_status","last_check_unix":1791458422,"last_result":"checked","manifests":[
   {"agent":"pi","source":"remote:/Users/hkandala/.local/state/herdr/agent-detection/remote/pi.toml","source_kind":"remote",
    "active_version":"2026.10.01.1","cached_remote_version":"2026.10.01.1","local_override_shadowing_remote":false,
    "remote_update_result":"current","remote_last_checked_unix":1791458422}, …]}
  ```
  agents: agy, amp, claude, cline, codex, copilot, cursor, devin, droid, gemini, grok, hermes, kilo, kimi, kiro, letta, maki, muse, opencode, pi, qodercli, qwen. These are detection rules, **not** an install check.
- **Which agents are installed:** `integration.list` has `available` = command found on the *server's* PATH, or an install layout found (`src/integration/registry.rs:97 integration_target_available`):
  `pi ✓ current, claude ✓ current, codex ✓ current, opencode ✓ current, cursor ✓ current, grok ✓ current, omp/copilot/devin/droid/kimi/kilo/hermes/qodercli/qwen/mastracode/antigravity_cli ✗ not_installed`.
  This covers only the 17 integration targets. Kinds without an integration (amp, gemini, cline, kiro, maki, muse, letta) have no API probe. For those, run `command -v <exe>` in a pane or over ssh [guess].

### 7.6 `pane.focus` from a non-TUI caller: [source]. ⚠️ It DOES move attached TUIs.
`src/server/headless/client_views.rs:817-900`: for public `workspace.focus`, `tab.focus`, `pane.focus`, `agent.focus`, `workspace.create/tab.create` with `focus:true`, and `pane.move` with `focus:true`, the server computes the target tab. If the focus succeeded, it calls `focus_all_shell_clients_on_default_target()`, which runs `location.focus_tab(...)` for **every attached shell client**. So a GUI calling `pane.focus` switches the user's herdr TUI(s) to that tab. This means my earlier `pane.focus wA:p1` in section 1 briefly moved the user's TUI, and `pane.focus w7:p1` moved it back.
Seen state: `handle_pane_focus` calls `mark_active_tab_seen()` (`src/app/actions.rs:453`), which sets `seen = true` for **all panes in that tab**, so every `done` agent in the tab becomes `idle`. I confirmed that `done` = idle + unseen: a custom `pane.report_agent` working→idle on unfocused `wB:p3` gave `"agent_status":"done"`. I then released it with `pane.release_agent`. I did not focus it, to avoid moving the user's TUI. There is no "mark seen" API that does not also focus. ⇒ Our app should track "seen" locally, as each TUI client does, and never call focus unless it deliberately wants to drive the TUI too.

### 7.7 Latency (20 sequential calls, macOS, local): [verified]
| Path | median | p95 | total for 20 |
|---|---|---|---|
| direct unix socket `ping` | 0.47 ms | 0.96 ms | 11.9 ms |
| direct unix socket `session.snapshot` (2 ws / 11 panes) | 0.89 ms | 1.78 ms | 20.8 ms |
| `herdr remote-api-bridge` subprocess per `ping` | 18.1 ms | 130 ms | 874 ms |
| `ssh localhost herdr remote-api-bridge` | **skipped**: `ssh -o BatchMode=yes localhost` → "No ED25519 host key is known for localhost … Host key verification failed". I did not change known_hosts. | | |

⇒ Talk to the local socket directly (sub-millisecond). Spawning a process costs about 18 ms per call, plus spikes. Over SSH, reuse one ControlMaster connection or one persistent channel, and batch reads through `session.snapshot` rather than many small calls.
