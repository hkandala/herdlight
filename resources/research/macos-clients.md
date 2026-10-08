# Native macOS herdr clients: research report

Repos cloned to `/tmp/herdr-research/<name>` on 2026-10-08. None returned 404. Paths in this report are relative to each repo's root.
I verified the herdr 0.9.3 facts marked **[verified]** against the live socket with read-only calls.

## 0. Summary table

| | renderer | terminal byte transport | herdr state sync | remote | web panes | layout | iOS | glass |
|---|---|---|---|---|---|---|---|---|
| **bigtty** (AppKit) | libghostty (`libghostty-spm` SPM, exact pin) | `herdr terminal session control` subprocess (NDJSON) | `events.subscribe` push → re-snapshot | `ssh -N -L` of both sockets, plus `-D` SOCKS | **yes: herdr placeholder pane + pane tokens** | mirrors herdr (`layout.export`) | no | no |
| **uHerdr** (SwiftUI+AppKit) | libghostty (vendored wrapper, SPM binary xcframework) | private binary proto 22 on `herdr-client.sock`; falls back to `session control` | **poll** `session.snapshot` every 1.25 s | `ssh -N -L` of both sockets | no | mirrors herdr | no (the wrapper supports UIKit) | no |
| **herdrm** (SwiftUI) | libghostty (`libghostty-spm` exact pin) | PTY running `herdr agent attach / terminal attach --takeover` | push → re-snapshot | `ssh -L` API socket + `ssh -tt herdr attach`; libssh2 on iOS; Tailscale plugin | no | own (1 pane or a 2-way split) | **yes**: iOS 18 target, shared HerdrKit + Ghostty | no |
| **rai** (SwiftUI+AppKit) | SwiftTerm fork | PTY running `herdr terminal attach --takeover`; also private endpoint proto | push → re-snapshot | `ssh -N -L` both sockets; `herdr machine list` | no | mirrors herdr (snapshot `layouts`) | **yes**: iPhone via the Mac's WebSocket bridge | no |
| **paca** (SwiftUI) | SwiftTerm | `herdr terminal session control` (pipes, no PTY) | push → re-snapshot | `ssh -N -L` both sockets; `herdr machine` CLI | no | own tab strip | no | **tried `NSGlassEffectView`, removed 2 days later** |
| **allward** (AppKit, macOS 26) | own VT + Metal | none: runs the herdr TUI in its own PTY | CLI `herdr api snapshot` on demand | plain ssh | no | own | no | rejected by its design doc |
| **moo** (AppKit+SwiftUI) | SwiftTerm fork | none: the herdr TUI runs inside a Moo tab | push (read-only status) | none | app-only web **tabs**, not restored | own | no | no |

Main takeaways:
- bigtty is the reference design for our app: herdr owns everything, browser panes are herdr panes, events trigger re-reads, and the renderer is libghostty.
- uHerdr's agent icon set and its Ghostty response-suppression patch are worth taking.
- herdrm shows that the libghostty-spm + `InMemoryTerminalSession` code runs unchanged on iOS.

## 1. bigtty (v1k45/bigtty) — the closest match to our idea

**Stack.** Swift 6, SwiftPM, **AppKit** (not SwiftUI), macOS 14+. Targets: `HerdrKit` (pure socket/model lib, ~2.3k lines), `bigtty` (app), `btty` (CLI used by agents + placeholder process). ~21k Swift lines.
`Package.swift`: `.package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "1.6.20260929")`, product `GhosttyTerminal`. Bundles Ghostty theme collection as a resource.

**Terminal renderer.** libghostty via `GhosttyTerminal.AppTerminalView` with a **host-managed in-memory backend** (no PTY in the app):
```swift
// Sources/bigtty/HerdrTerminalView.swift
final class HerdrTerminalView: AppTerminalView, ... {
  session = InMemoryTerminalSession(
      write:  { data in DispatchQueue.main.async { box.value?.userInput(data) } },   // keys -> herdr
      resize: { vp   in DispatchQueue.main.async { box.value?.viewportChanged(vp) } }, // grid -> herdr resize
      suppressesPixelOnlyResizes: true)
  gate = FrameGate { surfaceSession.receive($0) }          // herdr frames -> ghostty
  configuration = TerminalSurfaceOptions(backend: .inMemory(session))
```
`FrameGate` holds frames during a resize so you see the redrawn result, not intermediate frames.

**herdr API socket (`HerdrKit/HerdrClient.swift`).** NDJSON, *one request per connection* (fresh unix socket per call): `{"id":uuid,"method":..,"params":{..}}` → `{"result":{..}}|{"error":{code,message}}`. Methods used:
`ping`, `session.snapshot` (→`result.snapshot`), `layout.export {tab_id}` (→`result.layout`), `pane.split {target_pane_id,direction:"right"|"down",ratio?,focus}` (→`result.pane`), `layout.set_split_ratio {tab_id,path:[Bool],ratio}`, `pane.focus`, `pane.focus_direction`, `pane.resize {pane_id?,direction,amount?}`, `pane.zoom`, `pane.swap {source_pane_id,target_pane_id}`, `pane.move {pane_id, destination:{type:"tab",tab_id,split,target_pane_id?,ratio?}|{type:"new_tab",workspace_id}|{type:"new_workspace",label?}, focus}` (→`move_result{changed,pane{pane_id,tab_id,workspace_id},closed_tab_id,closed_workspace_id}`; **moving into another workspace gives the pane a new id**), `pane.close`, `pane.process_info` (→`process_info.foreground_processes[{name,argv}]`), `pane.read {pane_id,source:"recent_unwrapped",lines}` (→`read.text`), `pane.send_text`, `pane.report_metadata {pane_id,source:"bigtty",title?,tokens:{k:v|null}}`, `tab.focus/create/close` (`tab.create`→`root_pane`), `workspace.focus/create{cwd?,label?,focus}/move{insert_index}/rename/close`.

**Push, not polling.** `HerdrKit/EventStream.swift`: long-lived `events.subscribe` connection:
```json
{"id":"subscribe","method":"events.subscribe","params":{"subscriptions":[{"type":"workspace.created"},…,{"type":"layout.updated"},
  {"type":"pane.agent_status_changed","pane_id":"…"}]}}
```
Global types: `workspace.{created,updated,metadata_updated,renamed,moved,reordered,closed,focused}`, `worktree.{created,opened,removed}`, `tab.{created,closed,focused,renamed,moved}`, `pane.{created,updated,closed,focused,moved,exited,agent_detected}`, `layout.updated`. `pane.agent_status_changed` must be subscribed **per pane**, so the stream is re-opened whenever the pane set changes. Server drops slow readers with `events_lost` → resnapshot+resubscribe. Event line shape: `{"event":"…","data":{…}}`.
`SessionStore.swift`: **events are only signals** — any event → coalesced (16 ms) `session.snapshot` + `layout.export` for every tab in parallel; diff-and-notify. Order: snapshot → subscribe (waits for `subscription_started`) → refresh, so nothing is missed. Backoff 0.5 s→5 s reconnect.

**Live terminal bytes.** `HerdrKit/TerminalChannel.swift` spawns the **herdr CLI** per visible pane: `herdr [--session X] terminal session control <terminal_id> [--takeover] --cols C --rows R` (or `observe`). Comment: *"The CLI is used instead of the binary client protocol because that protocol is private and changes between herdr releases."* stdout NDJSON: `{"type":"terminal.frame","bytes":"<b64 ANSI>","width":W,"height":H}`, `{"type":"terminal.closed","reason":…}`. stdin NDJSON: `terminal.input{bytes:b64}`, `terminal.resize{cols,rows,cell_width_px?,cell_height_px?}`, `terminal.mouse{action:down|up|drag|move,button,column,row,modifiers}`, `terminal.scroll{direction,lines,source:"wheel",column?,row?}`, `terminal.release`. herdr re-renders the pane **at the client's size** and owns scrollback (wheel goes to herdr). One client controls a pane, others observe; `ControlArbiter.swift` makes the last-focused window control and others `observe` so bigtty windows never fight; `--takeover` steals from the herdr TUI.

**Remote hosts.** `Machines/SSHTunnel.swift`: probe via `ssh target sh -s` (script prints sock/bin/running/version/home), then a dedicated long-lived process:
```
/usr/bin/ssh -o ConnectTimeout=10 -o ControlMaster=no -o ControlPath=none -N -o ExitOnForwardFailure=yes
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o StreamLocalBindUnlink=yes
  -L <dir>/herdr.sock:<remote>/herdr.sock -L <dir>/herdr-client.sock:<remote>/herdr-client.sock
  -D 127.0.0.1:<free port> -- <target>
```
Local herdr CLI is then pointed at the forwarded socket with `HERDR_SOCKET_PATH` (it derives `herdr-client.sock` beside it) — "the rest of the app doesn't know the difference". Small probes (git branch, ports, file reads) via `ssh` with a ControlMaster=auto shared connection; exit status smuggled in stdout (`RemoteStatus`) because Tailscale SSH always exits 0. `SSHAskpass` handles prompts. Saved machines in UserDefaults (`MachineManager`).

**Browser/file panes — modeled IN herdr** (`Sources/bigtty/HostPanes.swift`, `Sources/btty/main.swift`). Flow: `pane.split` → `pane.report_metadata` with `tokens {btty_kind: browser|files|diff, btty_id, btty_url…}` → `pane.send_text "exec btty pane-host browser <id> <title>\r"`. The placeholder prints a banner ("🌐 bigtty browser pane — open this workspace in bigtty to see it"), disables echo/ICANON, ignores SIGINT and swallows stdin forever. Remote panes (no btty there) use `sh -c "printf '<banner incl. URL>'; stty -echo -icanon; exec cat >/dev/null"`.
Gotchas they hit and solved:
- **herdr keeps only 80 chars per token value** → long URLs are chunked into `btty_url`, `btty_url_2`, … (max 32 parts), next key set to `null` as terminator.
- **herdr drops pane tokens on server restart / live handoff** while the placeholder keeps running → `restoreTags()` inspects `pane.process_info` argv for `pane-host <kind> <id>`, or `pane.read`s the banner text and parses the URL back out, then re-tags.
- They *also* keep `~/Library/Application Support/bigtty/panes.json` (`HostPaneStore`, id→`{kind,url,title,path,selection,mode,paneID,machine}`), pruned against live panes. So tokens are the cross-device truth, the JSON is a cache/extra state.
- `BrowserRegistry` owns WKWebViews independently of windows (agents can drive an off-screen browser via `btty browser …` over the app's own unix socket `ControlServer`, mode 0600). Remote-machine browser panes use a per-machine `WKWebsiteDataStore(forIdentifier:)` with `ProxyConfiguration(socksv5Proxy:)` → the ssh `-D` port, so `localhost` means the remote machine. uBlock Origin Lite web extension supported.

**Layout.** Mirrors herdr's split tree exactly: `layout.export` → `LayoutNode = .pane(id) | .split(direction, ratio, first, second)` (JSON `{type:"split",direction,ratio,first,second}` / `{type:"pane",pane_id}`), `TabLayout{tab_id,zoomed,focused_pane_id,root}`. `SplitTreeView.swift` renders it; divider drags → `layout.set_split_ratio` with a `[Bool]` path; drag-to-rearrange → `pane.swap`/`pane.move`. Only app-local layout extra: a "pin column" (`PinLayout.swift`, width in UserDefaults).

**Stored locally.** UserDefaults: UI prefs (sidebar width/visibility, opacity, sound, notify mode, links, windowPerSpace…), active session, remote machines. `panes.json` (host-pane cache). Nothing about workspaces/tabs.

**Notifications.** `HerdrKit/Attention.swift` + `AttentionCenter.swift`: client-side "seen" model (herdr tracks seen per client): transition to `blocked` or witnessed `done` while pane not visible+focused in key window → `UNUserNotification` + Dock badge + ring on pane; "Needs You" list sorted by urgency. `AgentTitles.swift` reads the agent's own session files (claude/codex jsonl, keyed by herdr's `agent_session`) for nice tab titles (remote via ssh shell snippet).

**Agent icons.** None bundled (status dots/text; `display_agent`). **Liquid glass:** none (`NSVisualEffectView` only; a macOS 26 Network-framework crash workaround in `NetworkWarmup.swift`). **iOS:** none, but HerdrKit is Foundation-only and portable.

## 2. uHerdr (MrMySQL/uherdr)

**Stack.** SwiftPM, **SwiftUI + AppKit**, macOS 14 (built with Xcode 26 SDK). Targets `HerdrCore` (Foundation) + `HerdrMac`. ~6.6k lines of own code + vendored wrapper.

**Renderer / embedding.** libghostty, **vendored Swift wrapper** of `Lakr233/libghostty-spm` 1.5.20260906 in `Vendor/GhosttyTerminal` (only `Sources/GhosttyKit` + `Sources/GhosttyTerminal` copied; the native lib still a checksummed SPM binary target):
```swift
.binaryTarget(name: "libghostty",
  url: "https://github.com/Lakr233/libghostty-spm/releases/download/upstream.c4e16970a803/GhosttyKit.xcframework.zip",
  checksum: "bd9bba3b…385da")
// GhosttyKit target links c++ + Carbon; GhosttyTerminal depends on MSDisplayLink 2.2.0, ships Resources/Ghostty + terminfo
```
Local patches (Vendor/GhosttyTerminal/README.md): `InMemoryTerminalSession(suppressesTerminalResponses:)` → uses `ghostty_surface_write_buffer_replay` so **herdr's ANSI frames don't make Ghostty answer DA/DSR queries back into the shell** ("Herdr owns the authoritative terminal and answers its queries… a Swift callback gate around receive is insufficient"); resource-bundle lookup in `Contents/Resources`; `clipboardPasteHandler` hook for file/image paste. Note the wrapper already contains `Platform/UIKit/UITerminalView*` — the same wrapper works on iOS.

**API socket.** `HerdrCore/HerdrClient.swift`: same NDJSON, one socket per request, serialized on a queue, 8 s timeout. Methods seen: `session.snapshot`, `layout.export`, `layout.set_split_ratio`, `pane.focus/move/read/split/swap/zoom`, `tab.create/focus`, `workspace.create/focus`, `worktree.create`, `agent.start`.
**Polling, not push**: `SessionStore.start()` loops `refresh()` every **1.25 s** (no `events.subscribe`).

**Live bytes — two paths** (`HerdrMac/TerminalSurface.swift`):
1. If server protocol == 22: `HerdrCore/NativeTerminalConnection.swift` + `NativeTerminalWire.swift` speak **herdr's private binary client protocol directly on `herdr-client.sock`** (4-byte LE length-prefixed packets, varint ints; hello `[0,22,cols,rows,0,0,0]`, control `[8,pane,takeover]`, input `[1,blob]`, resize `[3,…]`, scroll `[6,…]`, SGR mouse reports re-encoded as tag 16; server frames tag 1, clipboard tag 5 (OSC52), mouse-capture tag 8…). A second "shell endpoint" lane (`endpoint.hello.v1` JSON) is opened only for focused panes to receive clipboard writes. Pinned to v22 — breaks on herdr upgrades (hence path 2).
2. Fallback: spawn `herdr terminal session control <pane> --cols --rows [--takeover]` with `HERDR_SOCKET_PATH` env, same NDJSON as bigtty.

**Remote.** `HerdrCore/SSHTunnel.swift`: discovery via `ssh host <cmd>`, then `ssh -N -o ExitOnForwardFailure=yes -o StreamLocalBindMask=0177 -L local.sock:remote/herdr.sock -L local-client.sock:remote/herdr-client.sock -- host`. Requires `AllowStreamLocalForwarding` on server; retries every 10 s. Remote file/image drops stream bytes over a separate ssh channel (`RemoteFileTransfer.swift`) — never typed into the pane — then paste the remote path. Local sessions auto-discovered via `herdr session list` every 15 s; can start/stop/delete sessions through the CLI (`SessionControl.swift`, strips inherited `HERDR_SESSION`/`HERDR_SOCKET_PATH`). Shows remote Mac battery (`pmset` via ssh).

**Browser panes:** none. **Layout:** mirrors herdr (`LayoutNode` in `HerdrCore/Models.swift`, `PaneLayoutView.swift` computes frames, drag → `pane.move/swap`). Tab order is app-local (`tabOrder:<device>` in UserDefaults).

**Stored locally.** UserDefaults keys: `appearance`, `fontSize`, `selectedDeviceID`, `selectedSpace:<id>`, `selectedTab:<id>`, `tabOrder:<id>`, device profiles.

**Notifications.** `AttentionNotifier.swift`: `UNUserNotificationCenter`, posts when an agent starts waiting; click reveals the pane (held until device connects); Dock badge = attention count.

**Agent icons — best of the set.** `Sources/HerdrMac/Resources/AgentIcons/<herdr agent id>.png` (≤64 px): agy, amp, claude, cline, codex, copilot, cursor, devin, droid, gemini, grok, hermes, kilo, kimi, kiro, letta, maki, opencode, pi, qodercli, qwen; `SOURCES.md` lists official asset URLs. `templateMarks = ["codex","copilot","pi"]` drawn in text color; fallback SF Symbol `sparkles`. Lookup is simply `agent.lowercased() + ".png"`.

**Liquid glass:** none; only `#available(macOS 26)` for `onDragSessionUpdated`. **iOS:** none.

## 3. herdrm (missuo/herdrm)

**Stack.**
- SwiftUI, with AppKit bridges.
- XcodeGen `project.yml` defines two targets: `HerdrM` (macOS 14) and `HerdrMobile` (iOS/iPadOS 18). The app is not sandboxed because it spawns `ssh` and `herdr`.
- Local packages:
  - `Packages/HerdrKit`: RPC, models, SSH tunnel, devices.
  - `Packages/HerdrSSH`: libssh2 + OpenSSL xcframeworks for iOS, vendored.
  - `Packages/HerdrTailcat`: a gomobile WireGuard/DERP client xcframework.
- The README says the app uses SwiftTerm. That is out of date: the code uses libghostty.

**Renderer.**
```yaml
# project.yml
GhosttyTerminal:
  url: https://github.com/Lakr233/libghostty-spm
  exactVersion: "1.6.20260909"   # binary xcframework: pin exactly, review checksum diff
```
- One process-wide `TerminalController(configSource: .none, theme:)`, in `Sources/HerdrM/TerminalView.swift` (`enum GhosttyRuntime`).
- Font, cursor and `copy-on-select` are set through `TerminalConfiguration { builder.withFontSize(..); builder.withCustom("copy-on-select","clipboard") }`.
- Each terminal is an `AppTerminalView` subclass with `TerminalSurfaceOptions(backend: .inMemory(session))`.
- **The same `GhosttyTerminal` API runs in `Sources/HerdrMobile/MobileTerminalView.swift` on iOS.**
- Build notes: Xcode 27 needs `xcodebuild -downloadComponent MetalToolchain`, and `-skipPackagePluginValidation` is required.

**Socket.** `HerdrKit/SocketRPC.swift`:
- NDJSON, one connection per request. `params` must always be present (send `{}` when empty).
- Methods:
  - `session.snapshot`, `agent.list`, `workspace.list`, `server.agent_manifests`
  - `agent.prompt {target,text}`, `agent.start {name,kind,pane_id,args}` (retried while the pane is busy), `agent.rename`
  - `workspace.create/rename/move/move_block/close`, `tab.create/rename/move`
  - `pane.get`, `pane.read {source:"visible",format:"ansi"}`, `pane.send_input {pane_id,text}` or `{pane_id,keys:["enter","ctrl+c"]}`, `pane.scroll`, `pane.close`
  - `plugin.action.list/invoke`
- Push: one long-lived `events.subscribe` with the same global types as bigtty, plus a per-pane `pane.agent_status_changed`. If the subscribe fails with `pane_not_found`, it retries without the per-pane subscriptions.
- Every event triggers a debounced `session.snapshot` (200 ms leading edge, plus a trailing run). Status changes are patched in place.
- Event names arrive with underscores (`pane_created`), so they are normalized.

**Live bytes.**
- `TerminalProcess.swift` calls `forkpty` to run the herdr CLI client: `agent attach <pane> --takeover` or `terminal attach <terminal_id> --takeover`, with `HERDR_ATTACH_GRAPHICS=1`. The PTY output goes into `session.receive`.
- The attach protocol needs the **CLI and server versions to match exactly**, so the app searches `$PATH` for a herdr binary whose `--version` equals the server's.
- Rebuilding the view kills the attach process, and it then re-takes the pane with `--takeover`. Because of this, the layout must stay structurally stable.

**Remote.** Three transports:
1. macOS: `ssh -N -L $TMPDIR/herdrm-tunnels/<hash>.sock:$HOME/.config/herdr/herdr.sock` forwards the API socket only. The terminal runs as a separate `ssh -tt target "exec herdr agent attach … --takeover"`.
2. iOS: libssh2 opens one `direct-streamlocal` channel per RPC and one long-lived channel for events. The terminal is an SSH PTY channel that runs `herdr agent attach`.
   - The app prints an APC marker `ESC _ herdrm-attach ESC \` before `exec` and renders only the bytes after it, which skips shell rc noise.
   - An Ed25519 device key is stored in the Keychain. Host keys use TOFU (trust on first use).
3. Tailcat: a gomobile bridge to a `herdr.tailcat` plugin. It re-serves the API socket and the `-client` socket locally.

**Other details.**
- No web panes.
- Layout is the app's own (one pane, or a ⌘D two-pane split). It does not mirror herdr.
- Stored locally:
  - `~/Library/Application Support/HerdrM/devices.json`
  - Keychain: passwords, tokens, keys
  - `@AppStorage`: UI prefs
- Notifications: `UNUserNotificationCenter` when an agent becomes `done` (sound "Glass") or `blocked` (sound "Funk"). No notification for the pane being watched.
- Agent icons: bundled LobeHub SVGs in `Resources/AgentIcons/*.svg`, mono and `-color` variants.
  - `BrandIconLoader.agentIcon(for:)` maps herdr `kind` to a file name (`claude-code`→`claude`, `github-copilot`→`githubcopilot`), falls back to the longest prefix match, and prefers the `-color` file.
  - Mono icons load as template `NSImage`.
- Glass: none. It uses `NSVisualEffectView(.sidebar)`, and works around an NSPopover crash on macOS 26.
- iOS: shares HerdrKit models and events, GhosttyTerminal and Tailcat. The UI is separate (`NavigationSplitView`), with its own `MobileTransport` protocol.

## 4. paca (adarshzpatel/paca)

**Stack.**
- Pure SwiftPM (tools 6.0), SwiftUI app, macOS 14. `scripts/install.sh` builds the `.app` and ad-hoc signs it, because notifications need a signed app.
- Also has a `MenuBarExtra`, a global ⌥Space Carbon hotkey, and a floating `NSPanel`.
- Renderer: SwiftTerm `from: "1.2.0"` with the Metal renderer, fed by `feed(byteArray:)`.

**Socket.**
- Short-lived connection per call.
- Methods:
  - `ping`, `session.snapshot`, `server.agent_manifests`
  - `workspace.create/rename/move/close`, `tab.create`
  - `pane.split/rename/close/focus`, `pane.read {source:"recent_unwrapped",strip_ansi:true}`
  - `agent.focus/start/rename/prompt`; `agent.start` replies `launch_pending:true` and is retried on `agent_pane_busy` for up to 10 s
  - `worktree.*`
- Sessions and machines go through the **herdr CLI**: `herdr session list --json`, `herdr --session N server`, `herdr machine list --json`, `herdr machine add/remove`. The machine list belongs to herdr and is shared with the TUI.
- Events: lifecycle types plus a per-pane `pane.agent_status_changed`. Each event triggers a full re-snapshot. `pane.updated` is skipped on purpose because it fires on every title change.

**Live bytes.** `HerdrKit/TerminalSession.swift` runs `herdr terminal session control <pane_id> --cols N --rows N [--takeover]` as a `Process` with pipes (no PTY). Wire format:
```
stdout: {"type":"terminal.frame","seq":1,"full":true,"width":80,"height":12,"encoding":"ansi","bytes":"<b64>"}
        {"type":"terminal.closed","reason":"..."}
stdin:  {"type":"terminal.input","bytes":"<b64>"} | terminal.resize{cols,rows} | terminal.scroll{direction,lines} | terminal.release
```
- The first frame is a full repaint. After that, frames are diffs.
- A second controller that connects without `--takeover` receives `terminal.closed` with "already has an attached client", and the UI then shows a **Take over** button.
- If no TUI is attached, the controller's size becomes the pane's real size. Headless panes default to 120x40.
- herdr owns scrollback.
- Hidden tabs stay attached, but their frames are dropped before decoding. To show a tab again, paca sends a resize to the same size, which forces a full repaint without SIGWINCH.
- A FramePacer caps redraws at 30 fps (15 fps for the unfocused split). Resizes are debounced because each resize makes Claude Code redraw.
- `herdr terminal session observe` is the read-only variant.

**Remote.**
- `ssh -N -o BatchMode=yes -L <dir>/herdr.sock:<remote>/herdr.sock -L <dir>/herdr-client.sock:<remote>/herdr-client.sock`.
- `docs/PLAN.md`: "Forwarding only the API socket fails with 'failed to connect to server' from the terminal."
- Only one machine is active at a time.

**Other details.**
- No web panes.
- Layout: its own tab strip, holding the pane ids the user opened, plus one app-side split.
- Stored locally:
  - UserDefaults: `paca.*`
  - `activity.jsonl` and `rules.json` (automation rules: "when agent X becomes done → `agent.prompt` Y")
- Notifications: from snapshot diffs.
- Agent icons: `scripts/sync-agent-icons.sh` downloads LobeHub `@lobehub/icons-static-svg` and fixes the SVGs so NSImage can parse them (`currentColor`→`#000`, `1em`→`24`, arc flags). Files are `agent-<kind>.svg`, drawn as templates.
- Testing trick: `pane.report_agent {source,agent,state}` fakes a status change.
- **Glass: tried, then removed.** `docs/PLAN.md`:
  - 2026-10-03: the window background became `NSGlassEffectView` on macOS 26.
  - 2026-10-05: "Glass removed: solid window only".
  - `scripts/snapshot.sh` rendered the glass as white.
  - The app icon is an Icon Composer `.icon` file.

## 5. rai (YogevKr/rai)

**Stack.**
- SwiftPM, `platforms: [.macOS(.v14), .iOS(.v17)]`.
- `RaiCore` (herdr client, wire types, bridge protocol) is shared with iOS.
- The macOS app uses SwiftUI `WindowGroup`s, with AppKit for terminals.
- The iOS project is defined with XcodeGen in `ios/project.yml` and compiles about 15 macOS view files directly, using `#if os(...)`.
- Renderer: a SwiftTerm fork pinned by revision `97d70b0`. The fork adds a selection API, `pinGridSize` for iOS, and Metal fixes.

**Terminal paths.**
1. **Main Mac window** (`Sources/RaiApp/TerminalPool.swift:354`): a SwiftTerm `LocalProcess` runs `herdr terminal attach <terminal_id> --takeover` in a PTY.
   - An LRU pool keeps 8 to 32 attached views. Hidden views are suspended: the attach process is killed and the buffer is kept.
   - The process is spawned only after the first layout, so the pane starts at its real size.
   - A comment at line 184 says that frequent `--takeover` attaches made **the displaced herdr client panic**.
2. **"Independent" windows**: rai speaks herdr's private binary endpoint protocol ("generation one", `endpoint.hello.v1`) directly on `herdr-client.sock` and renders cell grids composited by the server (`Sources/RaiCore/HerdrEndpoint*.swift`). This is reverse-engineered and fragile.
3. **iPhone**:
   - The phone never talks to herdr. The Mac runs a WebSocket bridge (`NWListener`, Bonjour `_rai._tcp`, reachable over LAN or through `tailscale serve --https`).
   - The Mac spawns `herdr terminal session observe <pane> --rows N` and forwards frames as `.paneFrame(paneID, b64, full, seq, cols, rows)`. Without `--rows`, observe defaults to 40 rows.
   - Phone input goes through `pane.send_input`. Pairing uses a QR code, and the token is kept in the Keychain.
   - **The Mac is the APNs provider**: it signs ES256 JWTs with a `.p8` key that the user pastes in.

**Socket.**
- Push through `events.subscribe` on its own thread.
- The subscription list depends on the protocol version, because **unknown event types make older servers close the whole stream**.
- `pane.output_changed` cannot be subscribed to. rai uses `pane.updated` plus a poll of the focused pane instead.
- Methods also include `pane.resize/zoom/move`, `agent.prompt`, `agent.explain`, `pane.selection.read`, `plugin.pane.open` and `agent.view.set/clear`.

**Remote.**
- `ssh -N -o BatchMode=yes -o StrictHostKeyChecking=yes -o StreamLocalBindUnlink=yes -o ExitOnForwardFailure=yes -L sock -L client.sock`, then `HERDR_SOCKET_PATH` is set to the local copy.
- The host list comes from `herdr machine list --json` and `herdr session list --json` (`MachineDirectory.swift:128`).

**Layout.** Mirrors herdr. `PaneLayoutTreeBuilder` (`Sources/RaiCore/PaneLayoutTree.swift`) turns the snapshot's flat `panes[]` + `splits[]` rects into a binary tree.

**Other details.**
- No web panes. No agent icons: status is a colored dot, and Claude spinner glyphs are stripped from titles.
- No glass.
- Claude Code hooks (`ClaudeHooksInstaller.swift`) send beacons to `~/Library/Application Support/Rai/hooks.sock`, which gives exact permission prompts. The phone can approve or deny them.

## 6. allward (joshuaswarren/allward)

**Stack.**
- SwiftPM 6.2, **macOS 26 only**, AppKit-first, with SwiftUI in `NSHostingView`.
- Its own VT engine (`Sources/AllwardTerminal`) and Metal renderer (`Sources/AllwardRenderer`), with a `forkpty` C shim.
- Config is a single file, `~/.config/allward/allward.toml`.

**herdr integration.** Shallow, and pinned to herdr **0.7.5 / protocol 17**:
- All calls are CLI subprocesses: `["herdr"] + args`, or `["ssh", host, "herdr"] + args`.
- Calls used: `herdr api snapshot`, `herdr agent list`, `herdr agent focus <pane>`.
- No socket or event source is wired up in production. Snapshots refresh only on demand.
- To show herdr content it runs the herdr TUI (`herdr --remote host`) inside its own pane. "Teleport" means `herdr agent focus`.
- `docs/evidence/HERDR.md` is a good capability table: `pane.read` returns a rendered snapshot, not a byte stream, and `pane_output_changed` cannot be subscribed to.

**Other details.**
- Remote: plain ssh.
- No web panes, no notifications through UN, no agent icons (SF Symbols show state).
- The layout is its own split tree.
- **Glass rejected on purpose** (`docs/DESIGN-LANGUAGE.md:452`): "permanent glass … outside the language. The opaque grid is the baseline."
- It also ships an MCP server, `allward-mcp`.

## 7. moo-mac-terminal (ventz/moo-mac-terminal)

**Stack.**
- A standalone terminal emulator: AppKit+SwiftUI, macOS 15.5, Xcode project.
- Renderer: SwiftTerm fork `ventz/SwiftTerm@perf/moo`.

**herdr integration.**
- **Not a herdr front-end.** The user runs the herdr TUI in a Moo tab.
- Discovery: every 2 s Moo finds `herdr` processes in its own PTYs (`sysctl KERN_PROCARGS2` for argv and env) and resolves the socket the way herdr does.
- It then opens the socket **read-only** to show agent status in its sidebar. A type-level method whitelist (`ping`, `session.snapshot`, `events.subscribe`, `pane.focus`, `agent.focus`) enforces this.

**Useful herdr facts** (`Moo/Herdr/HerdrBridge.swift`, `MooTests/HerdrFixtures.swift` holds **real 0.9.3 JSON fixtures**, and `FakeHerdrServer.swift` is a fake server for tests):
- If one pane id in a `pane.agent_status_changed` subscription is unknown, **the whole subscribe fails** with `pane_not_found`.
  - Moo uses 1 lifecycle connection plus 1 connection per agent pane.
  - It caps these at 32 per session and 64 overall.
- Event names are mixed: the subscription types use dots, while pushed events such as `pane_created` use underscores. Normalize them.
- `done` becomes `idle` after a herdr client has shown it.
- An agent exit arrives as `pane_agent_detected` with `released:true`.
- Raw POSIX socket + `DispatchSourceRead` instead of NWConnection. The code comment says "NWConnection could report the hang-up first and drop a large reply".

**Other details.**
- Web pages are app-only **tabs** (a `WKWebView` plus an address bar, ad blocking with `WKContentRuleList`). They are **not restored** after relaunch.
- Its own split tree. Terminal and web objects live in `ProjectRuntime`, outside the SwiftUI tree, so they survive navigation.
- Notifications:
  - UN banners, a Dock badge and bounce, speech, and a menu-bar `NSStatusItem`.
  - Rate limits: 1 alert per pane per 30 s, and 10 per session per minute.
  - No alert while the user is viewing the pane.
  - "Finished" alerts are opt-in.
- No agent icons. No glass. No iOS.

---

## 8. Cross-cutting herdr 0.9.3 facts (all clients agree, plus my own checks)

**API socket (`herdr.sock`).**
- NDJSON: `{"id","method","params"}\n` → `{"id","result":{…}}` or `{"error":{code,message}}`.
- **One request per connection**: the server closes after it replies. `params` is required.

**Snapshot [verified].**
- `session.snapshot` → `result.snapshot` has the keys `version, protocol(22), focused_*_id, workspaces, tabs, panes, layouts, agents`.
- `layouts[]` per tab:
  ```json
  {"workspace_id":"w4","tab_id":"w4:t7N","zoomed":false,"area":{x,y,width,height},"focused_pane_id":"w4:pDD",
   "panes":[{"pane_id":"w4:pDE","focused":false,"rect":{"x":0,"y":0,"width":90,"height":60}},…],
   "splits":[{"id":"split_0_root","direction":"right","ratio":0.5,"rect":{…}}]}
  ```
  One snapshot therefore carries every tab's layout. bigtty also calls `layout.export {tab_id}` once per tab to get the nested tree `{type:"split",direction,ratio,first,second}` / `{type:"pane",pane_id}`. rai rebuilds the tree from the flat `splits` instead.
- Pane keys [verified]: `pane_id, terminal_id, workspace_id, tab_id, focused, cwd, foreground_cwd, agent, terminal_title, terminal_title_stripped, agent_status, scroll, revision`. `tokens`, `label` and `agent_session` appear when set (bigtty decodes them as optional).

**Events.**
- `events.subscribe {subscriptions:[{type}…]}` → ack `result.type == "subscription_started"`, then lines `{"event":"pane_created","data":{…}}`.
- Status events require a `pane_id` per subscription.
- If the client reads too slowly, the server sends `events_lost` and closes the stream.
- Unknown types can kill the stream on older servers.
- Standard sync: subscribe → ack → snapshot → treat each event as a signal to re-snapshot (debounced 16–200 ms).

**Live terminal.**
- The supported surface is the CLI: `herdr terminal session control|observe <target> --cols --rows [--takeover]` [verified with `--help`].
- It speaks NDJSON over stdin/stdout:
  - out: `terminal.frame{bytes b64, width, height, seq, full}` and `terminal.closed{reason}`
  - in: `terminal.input{bytes}`, `terminal.resize{cols,rows,cell_*_px}`, `terminal.mouse`, `terminal.scroll`, `terminal.release`
- herdr renders the pane at the client's size and owns scrollback.
- One client controls a terminal and any number can observe. `--takeover` steals control.
- It needs `herdr-client.sock` next to `HERDR_SOCKET_PATH`.
- The alternatives are worse:
  - `terminal attach` / `agent attach` in a PTY needs the CLI and server versions to match exactly.
  - The private binary protocol 22 is used by uHerdr and rai, and changes between releases.

**Pane tokens (bigtty).**
- `pane.report_metadata {pane_id, source, title?, tokens:{k: v|null}}` merges tokens per source.
- **Values are cut to 80 characters**, so long values must be split into chunks.
- **Tokens are lost on a server restart or live handoff**, so the app must re-derive them (see bigtty's `restoreTags`).

**Remote.**
- The consensus is `ssh -N -L local/herdr.sock:remote/herdr.sock -L local/herdr-client.sock:remote/herdr-client.sock` with `ExitOnForwardFailure=yes`, `StreamLocalBindUnlink=yes`, `ControlMaster=no`, `ControlPath=none` and `ServerAliveInterval=15`. Without `ControlPath=none`, the forward is handed to an existing master connection and ssh exits.
- The remote sshd must allow `AllowStreamLocalForwarding`.
- Keep local socket paths short: `sockaddr_un` has a 104-byte limit.
- The host list can come from herdr itself: `herdr machine list --json` and `herdr session list --json` (paca, rai).

## 9. Embedding libghostty (what we will need)

- Use **`https://github.com/Lakr233/libghostty-spm`** (MIT). It ships a pre-built static `GhosttyKit.xcframework` as an SPM `binaryTarget` with a checksum.
  - Platforms: macOS 13+, **iOS 15+**, Mac Catalyst, visionOS.
  - Requires Swift 6.2 / Xcode 26.
- Products:
  - `GhosttyKit`: the C API.
  - `GhosttyTerminal`: Swift wrapper, AppKit/UIKit/SwiftUI views, input, display link.
  - `GhosttyTheme`: 485 themes.
- It is a trimmed build: no custom shaders, no inspector, no app runtime.
- It **adds a host-managed I/O backend** (`GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED`). This is exactly what we need, because herdr owns the PTY.
- Versioning:
  - Releases are weekly and follow Ghostty main. The version scheme is `<major.minor>.<YYYYMMDD><NN>`.
  - Every client pins **exact**: bigtty `1.6.20260929`, herdrm `1.6.20260909`.
  - uHerdr vendors the Swift wrapper from 1.5.20260906, and SPM still downloads the binary: `releases/download/upstream.c4e16970a803/GhosttyKit.xcframework.zip`.
- To build it yourself: `./build.sh --platforms macos,ios` (needs zig 0.16, applies `Patches/ghostty/`). `Package.local.swift` points at the local `BinaryTarget/`.
- Code pattern (bigtty `HerdrTerminalView.swift`, herdrm, and the libghostty-spm README):
  ```swift
  import GhosttyTerminal
  let session = InMemoryTerminalSession(
      write:  { bytes in channel.sendInput(bytes) },                       // -> terminal.input
      resize: { vp in channel.resize(columns: Int(vp.columns), rows: Int(vp.rows),
                                     cellWidth: Int(vp.cellWidthPixels), cellHeight: Int(vp.cellHeightPixels)) },
      suppressesPixelOnlyResizes: true)
  view.controller = TerminalController(...)            // one shared, process-wide
  view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
  channel.onFrame = { session.receive($0) }            // terminal.frame bytes -> ghostty
  ```
  In SwiftUI, use `TerminalSurfaceView(context: TerminalViewState)`. `TerminalView` is a typealias for `AppTerminalView` on macOS and `UITerminalView` on iOS. Set `terminal.isSurfaceVisible = false` for hidden surfaces: the grid is kept and only rendering stops. That fits our scrolling pane strip.
- **Gotcha (uHerdr `Vendor/GhosttyTerminal/README.md`).** herdr's frames contain the app's terminal queries, and herdr already answers them. Ghostty must not answer them again into the shell.
  - uHerdr patched `InMemoryTerminalSession(suppressesTerminalResponses:)` to use `ghostty_surface_write_buffer_replay`, which upstream now ships as "History replay".
  - uHerdr says a Swift-side gate around `receive` "is insufficient".
  - Check whether the current libghostty-spm exposes this as an option (guess: yes, since the binary exports it).
- bigtty's `FrameGate` holds frames during a resize so that intermediate frames are never shown.

---

## Lessons for our app

**Copy**
1. **bigtty's architecture as the baseline:**
   - Foundation-only `HerdrKit`: per-request socket, one `events.subscribe` stream, events trigger a coalesced re-snapshot.
   - The view mirrors herdr's split tree.
   - Every mutation is a herdr call (`pane.split/move/swap/zoom/resize`, `layout.set_split_ratio`, `tab.*`, `workspace.*`), followed by a re-read.
   - Use snapshot `layouts[]` instead of N `layout.export` calls where the flat form is enough.
2. **Terminal transport = `herdr terminal session control` → libghostty `InMemoryTerminalSession`.**
   - It is public, needs no PTY and no exact version match, and works remotely once both sockets are forwarded.
   - Attach once at the final size. Debounce resizes. Pause hidden panes with `isSurfaceVisible=false`, plus paca's trick of a same-size resize to repaint.
   - Use `observe` for non-focused or duplicate views (bigtty's `ControlArbiter`).
3. **Web panes as real herdr panes (bigtty `HostPanes.swift`):**
   - `pane.split` → `pane.report_metadata tokens{kind,url}` → `pane.send_text "exec <placeholder>\r"`. The placeholder prints a banner that includes the URL, turns off echo, and swallows input.
   - herdr then handles split, move, zoom, resize, and persistence of the pane.
   - For "the app stores nothing", drop bigtty's `panes.json` and rely on:
     - **(a)** chunked tokens (80-character limit), and
     - **(b)** re-deriving the URL after a herdr restart, by reading the placeholder's argv through `pane.process_info` (e.g. `sh -c '…' herdr-web <url>`) or its banner through `pane.read`.
   - Making the URL part of the placeholder's argv is the most robust option, since it survives token loss.
   - Remote web panes can reach the remote machine's `localhost` with ssh `-D` + `WKWebsiteDataStore.proxyConfigurations` (bigtty `BrowserProxy`).
4. **Remote:** `ssh -N -L` both sockets with bigtty's or rai's flags, then set `HERDR_SOCKET_PATH`. The rest of the app is host-agnostic. Use `herdr machine list --json` / `herdr session list --json` as the host list so the app stores nothing.
5. **Agent icons:** uHerdr's `Resources/AgentIcons/<herdr agent id>.png` set with its `SOURCES.md`.
   - Template-render `codex`, `copilot`, `pi`.
   - Fall back to the SF Symbol `sparkles`.
   - Lookup is `agent.lowercased() + ".png"`.
   - herdrm and paca use LobeHub SVGs as an alternative.
6. **Notifications:**
   - Client-side "seen" model (bigtty `Attention.swift`): blocked, or a witnessed `done`, while the pane is not focused in the key window → `UNUserNotification` + Dock badge.
   - Moo's rate limits and opt-in "finished" alerts.
   - `pane.report_agent` fakes status changes for tests.
7. **Testing:** Moo's real 0.9.3 fixtures and fake socket server.
8. **iOS sharing:** one SPM package (herdr client + models) plus libghostty-spm, which has the same API on UIKit (herdrm proves this). iOS cannot spawn `herdr` or `ssh`. Options:
   - run `herdr terminal session control` over an SSH exec channel (NDJSON over stdin/stdout, no PTY needed; guess, not verified), with libssh2 `direct-streamlocal` for the API socket as herdrm does; or
   - use a Mac hub (rai). This is heavier and contradicts "store nothing".

**Avoid**
- Private binary protocol 22 / the endpoint protocol (uHerdr, rai). It is pinned to one version and breaks on herdr upgrades.
- `herdr terminal/agent attach` in a PTY (herdrm, rai). It needs the exact CLI version, and frequent `--takeover` churn crashed the displaced client. **We run inside herdr: avoid `--takeover` by default and offer it as an explicit action (paca's "Take over" button).**
- Polling (uHerdr's 1.25 s loop). Use events.
- App-owned layout or tab models (herdrm, paca, moo, allward). They drift from herdr.
- Subscribing to `pane.updated` without debouncing: it fires on every title change.
- Glass behind terminals. paca shipped `NSGlassEffectView` and removed it after 2 days, and allward's design rules forbid it. No client uses `.glassEffect`. Put Liquid Glass only on chrome (sidebar, toolbars, tab bar) and keep terminals opaque, with glass gated by `#available(macOS 26, iOS 26)`.
- Over-building transports (herdrm has ssh, libssh2, a Tailscale plugin, and a Windows bridge) and the APNs-from-Mac setup (rai).
