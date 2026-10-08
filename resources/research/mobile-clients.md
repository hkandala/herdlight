# Mobile herdr clients: how they work

Repos cloned (shallow) to `/tmp/herdr-research/<name>`: Heeler, Kelpie (`Getterbetter/Kelpie`, found through
r/SideProject), herdr-connect, whip, Multiplex, anyssh, pairfob, pdx. None returned 404.

## TL;DR matrix

| App | Platform / stack | Phone → host transport | Host-side helper | herdr access | Terminal renderer | Chat view | Push |
|---|---|---|---|---|---|---|---|
| **Heeler** | SwiftUI iOS 18+, iPhone/iPad | Direct SSH (own `HeelerSSH` pkg = libssh2+OpenSSL; Citadel/NIOSSH removed), optional jump host. LAN/Tailscale | herdr **plugin** (Node): pairing QR, `[[events]]` hooks for push | **direct-streamlocal channel → `herdr.sock`** (one channel per request + one long-lived `events.subscribe` channel); PTY = `herdr agent attach --takeover` over SSH exec | **libghostty-spm** (`GhosttyTerminal`, Metal) | No chat. Native Composer → `agent.prompt` | APNs through a **developer-run stateless Cloudflare Worker relay**, AES-GCM E2EE, plus Live Activities |
| **Kelpie** | Fork of Heeler | Same as Heeler | Same plugin (fork) | Same + root screen runs the full **herdr TUI client** (`exec herdr`) over the SSH PTY | libghostty-spm | iPhone: chat built from **Claude Code transcript JSONL** read over SSH (`tail -c +N`); sends with `agent.prompt` / `agent.send_keys` | Same relay design, own Worker instance |
| **herdr-connect** | Expo / React Native, iPhone | HTTPS to a **daemon on the host** over LAN (mDNS) or Tailscale. Self-signed cert, fingerprint pinned | **Go daemon** `herdr-connect` (launchd/systemd service) | Daemon **shells out to the `herdr` CLI** (`agent list`, `agent read`, `pane run`, `pane send-keys C-c`) and polls every 1 s | None (text/markdown of `agent read`) | Yes, history = `agent read --source recent-unwrapped`; send = `pane run <id> <text>` | None. Only foreground sound + local notification |
| **whip** | Expo RN + Rust core (russh, UniFFI), Android + iOS | Direct SSH (russh), nested jump hosts, Tailscale | None (only one-shot `whipair` for pairing) | direct-streamlocal → API socket (JSON) **and → `herdr-client.sock` (herdr's bincode client protocol, protocol 17–22)** for live terminal frames | **xterm.js in a WebView** | Yes for Codex/OpenCode/Claude: reads native agent transcripts over SSH (`tail -c +OFFSET -F`, `opencode export/db`); composer writes paste + `\r` to the terminal stream | Local notifications only (live connection). Android foreground service |
| **Multiplex** | SwiftUI visionOS/iPad/iPhone (tmux first) | Direct SSH (Citadel 0.12 + vendored swift-nio-ssh), optional clean-room mosh | None (closed-source `mpx bind` CLI only for pairing) | **SSH exec of the `herdr` CLI** (`herdr status --json`, `session list --json`, `--session s api snapshot`); attach = `herdr session attach` in a PTY | **SwiftTerm** (vendored fork) | Composer card types into the PTY | Local notifications only; `beginBackgroundTask` (~26 s) + `BGAppRefreshTask` |
| **anyssh** | SwiftUI iOS 26 SSH client | Direct SSH (libssh2+OpenSSL xcframework) | None | SSH exec of the CLI (`api snapshot`, `pane read`, `agent focus`, `tab focus`), polled 1 s visible / 5 s background; attach = `herdr session attach <s>` | **SwiftTerm** | No | Local notifications + Live Activity, only while the connection lives |
| **pairfob** | Go daemon + React **PWA** + Cloudflare Worker/Durable Object | **Computer dials out** over WSS to the `pairfob.com` relay; phone joins the same room. Upgrades to WebRTC DataChannel (STUN only, no TURN) | **Go daemon** `pairfob` (service) + optional herdr plugin | Daemon dials the local unix socket (`events.subscribe`, `session.snapshot`, `agent.prompt`...); terminal = child process **`herdr terminal session control <pane> --cols --rows`** (NDJSON on stdin/stdout) | **xterm.js 6** + WebGL addon (in the browser) | Yes: daemon reads agent journals (Claude/Codex/pi/OpenCode/Hermes); sends with `agent.prompt` | **Web Push (VAPID) sent straight from the daemon**. No developer APNs server |
| **pdx** | Kotlin/Compose Android (handheld game consoles) | Direct SSH (sshj) | None | SSH exec of the CLI (`agent list`, `pane read --format ansi`); live = `herdr terminal session control\|observe` | xterm.js in a WebView (offline bundle) | Codex only, through `codex app-server --listen stdio://` over SSH exec (`thread/read`, `thread/turns/list`) | None |

---

## 1. Heeler (`ZingerLittleBee/Heeler`). The reference implementation

The most complete design here. ADRs in `docs/adr/` explain each choice.

### Transport (ADR 0011 `libssh2-direct-streamlocal-transport.md`)
- They replaced Citadel + NIOSSH + `exec socat` with an in-repo `Packages/HeelerSSH` (libssh2 1.11.1 + OpenSSL
  XCFrameworks checked in). It uses non-blocking POSIX sockets and `DispatchSourceRead/Write`. It does not use SwiftNIO.
- Each herdr API request opens a new **`direct-streamlocal@openssh.com` channel to `herdr.sock`**. This follows herdr's
  "one request per socket connection" contract. One extra long-lived channel carries `events.subscribe`.
- Wire format (`Sources/Heeler/Transport/HerdrWire.swift`): NDJSON `{"id","method","params"}\n`.
  Subscribe: `{"method":"events.subscribe","params":{"subscriptions":[...]}}`. Event lines decode as `{event, data}`.
- Methods used (`HeelerSSHTransport.swift`): `ping`, `agent.list`, `session.snapshot`, `pane.read`, `agent.read`,
  `agent.prompt`, `agent.send_keys`, `agent.start`, `agent.focus`, `agent.rename`, `tab.create/rename/close`,
  `workspace.create/rename/close`, `worktree.create/list/remove`, `pane.close`, `plugin.list`.
- Events they subscribe to: `pane.agent_status_changed`, `pane.agent_detected`, `pane.created/closed/exited/moved/focused/updated`,
  `pane.output_matched`, `tab.*`, `workspace.*`, `worktree.*`.
- Interactive terminal: an SSH **PTY exec** that runs the herdr CLI and lets herdr do the attach:
  ```swift
  "/bin/sh -c '\(pathExport); export HERDR_SOCKET_PATH=\"$2\"; printf \"<marker>\"; exec \(attachCommand) \"$1\"\(takeover)' attach '<target>' <socket>"
  ```
  `attachCommand` is `herdr agent attach` (agents) or a terminal attach (shells), with `--takeover`. The marker lets them drop
  shell/rc chatter that prints before the exec.
- On Windows hosts (no unix socket) they speak `herdr terminal session control`-style records instead:
  `{"type":"terminal.input","bytes":b64}`, `{"type":"terminal.resize","cols","rows"}`, and they read `terminal.frame`
  (`WindowsTerminalChannel.swift`).
- Health check: herdr `ping`, not SSH keepalive. Budgets: 8 RPC channels + 1 events channel (forwarding budget), and
  8 exec/SFTP channels + 1 attach PTY (session budget). Both stay under OpenSSH `MaxSessions` 10.
- Precondition: sshd must allow stream-local forwarding (OpenSSH default). If a channel open fails, they run
  `test -S <socket>` to diagnose. If herdr is not running, they say so; it is a permanent, non-retryable error.

### Pairing (ADR 0007), using a herdr plugin (`plugin/herdr-plugin.toml`)
- `herdr plugin install ZingerLittleBee/Heeler/plugin` and then `herdr plugin action invoke heeler.pair`. A `[[panes]]`
  popup renders the QR.
- The QR payload holds: candidate addresses, port, username, **host key fingerprint**, and a **Bootstrap Key**. The Bootstrap
  Key is a one-time Ed25519 private seed with a 2-minute TTL. Its `authorized_keys` line is `restrict,command="<accept script>"`.
- The app connects with the Bootstrap Key. The forced command appends the **Device Key** public key (generated on the
  device, private key kept in a Keychain-backed CryptoKit object). The app then reconnects with the Device Key. The Host is
  saved only after the whole ceremony succeeds.
- The SSH package never sees the private key. It gets the public blob plus a signing closure.

### Push (ADR 0008 + 0014): who runs APNs?
- The **developer runs it**: a stateless Cloudflare Worker (`relay/src/worker.js`, `apns-jwt.js`) that holds the `.p8`.
  Default URL: `https://heeler-apns.bybee.dev`. The relay keeps no state, has no DB, and never retries.
- Trigger: a plugin `[[events]] on = "pane.agent_status_changed"` hook runs `node src/notify-hook.js` once per event
  (`HERDR_PLUGIN_EVENT_JSON`). It waits about 5 s, re-checks the status through `HERDR_BIN_PATH` (debounce), and dedupes
  through `HERDR_PLUGIN_STATE_DIR`.
- Registration: the app writes its APNs token and a fresh 32-byte Notification Key into `notifications.json` on the host
  over SSH. The key also stays in the shared Keychain. The plugin seals the payload with AES-256-GCM (`{v,kid,n,ct}`,
  AAD `HERDR-NOTIFY:1`) and POSTs it to the relay. A Notification Service Extension decrypts it.
- Live Activities: one per Host, updated by a second hook. Status counts are plaintext and details are sealed
  (`HERDR-ACTIVITY:1`). The widget decrypts at render time.
- Foreground: system banners are suppressed (`willPresent` returns `[]`). An in-app banner runs from the live event stream.

### Background and reconnect
- `AppActivityCoordinator.swift`: on background, `beginBackgroundTask` opens a grace period of about 30 s and the
  connections stay up. When the grace period expires, the app tears the connections down on purpose. On foreground it
  reconnects. `EventsSession` has bounded backoff, re-subscribes on the same SSH connection if only the channel dropped,
  and opens a new transport if the connection died.

### Input
- **Composer** (ADR 0013): the terminal displays output only. The user drafts in a native text view, then Send →
  `agent.prompt`. If the agent is `blocked`, Send types the draft into the PTY without Enter instead. A "tools keyboard"
  (Esc, Tab, Shift-Tab, arrows, Enter, snippets, skills) replaces the system keyboard through a zero-height `inputView` swap.
- **Direct Input** (ADR 0016, opt-in): the system keyboard goes straight to the PTY. A shortcut row (Esc/Tab/S-Tab/Enter)
  is **normal content, not `inputAccessoryView`**. `TerminalScreenView.inputAccessoryView` returns `nil`, because UIKit
  tears down an accessory view when the keyboard mode switches.
- libghostty (ADR 0004): `UITerminalView` + `InMemoryTerminalSession`. PTY bytes go in through `receive(_:)` and Ghostty's
  write/resize callbacks feed the SSH channel. Keys are sent with `UITerminalView.sendKey`, so Ghostty encodes them for the
  active mode (kitty/fixterms).
- Attachments: SFTP to a temp path, then the path is inserted into the draft.

## 2. Kelpie (`Getterbetter/Kelpie`). Heeler fork for iPad/iPhone

Source: reddit `r/SideProject/comments/1we8kte`; TestFlight `AkJxAbnJ`. It is a hard fork of Heeler v0.1.8 and keeps
the transport, pairing, plugin and relay. The relay runs on the author's own Worker (`kelpie-apns.…workers.dev`).
Differences:
- **ADR 0017 `herdr-client-is-the-screen`**: the root view is a full-screen attach that runs the **herdr TUI client
  itself** (`exec herdr` / `exec herdr --session "<name>"`) over the SSH PTY. The native Console is one tap away in a
  `fullScreenCover`. Each attach exports `COLORTERM=truecolor` and `LANG`. One Transport carries one attach channel, so the
  client detaches while the Console is open. herdr keeps scrollback on the host, so nothing is lost.
  Below 64 columns herdr's own mobile layout takes over.
- **URL taps are caught on the client**: herdr would `open` the URL **on the Mac**. Kelpie finds URLs in the viewport
  text, because libghostty iOS has no "link at point" API.
- **ADR 0016 `ipad-pointer-input`**: a trackpad right-click and a long-press send an SGR right click (button 2) so herdr's
  menu opens. Hold-then-drag sends a left-button drag, which resizes herdr panes. Trackpad scroll uses a scroll-type
  `UIPanGestureRecognizer`. Touch selection uses its own overlay. Keyboard mode switches automatically between Composer and
  Direct Input from `GCKeyboard.coalesced` (hardware keyboard detection).
- Key row: `TerminalKeyBar` **is** returned as `inputAccessoryView` and shared with the composer field
  (`TerminalScreenView.swift:1241`). Heeler made the opposite choice.
- **ADR 0018 iCloud pairing sync**: `kSecAttrSynchronizable` Keychain items hold one **shared Device Key** plus one record
  per Host (host, fingerprints, Notification Key, `pendingPublicKeys`). They use no CloudKit. A sibling device that can
  reach the Host appends any pending keys to `authorized_keys`.
- **ADR 0019 native chat over Claude transcripts** (iPhone, currently paused): `pane.process_info` gives the pid and cwd.
  From those the app finds `~/.claude/sessions/<pid>.json` and then `~/.claude/projects/<enc cwd>/<sessionId>.jsonl`. It reads
  incrementally by byte offset (`tail -c +N` over an SSH exec channel) and refreshes on `pane.agent_status_changed` plus a
  timer. It sends with `agent.prompt`. Permission prompts (herdr `blocked` + a tool call with no result) are answered with
  `agent.send_keys`. Parser code: `Sources/Heeler/Chat/ClaudeTranscriptParser.swift`.

## 3. herdr-connect (`Tomyail/herdr-connect`)

- Architecture: iPhone app (Expo RN) ⇄ **HTTPS** ⇄ **Go daemon** (`cmd/herdr-connect`, installed as a launchd/systemd service
  with `herdr-connect service install`) ⇄ `herdr` CLI. The phone does not use SSH.
- Discovery: mDNS `_herdr-connect._tcp` (on macOS through `dns-sd -R`), TXT `fp=<cert fp>`. Over Tailscale, a `--host`
  override is baked into the QR.
- Pairing (`docs/security/lan-tls-pairing.md`): `herdr-connect pair` prints a QR with a 32-byte one-time secret (5-minute
  TTL, stored hashed), the cert fingerprint, addresses and port. The phone calls `POST /v1/pair` and gets a per-device
  **bearer token**, stored hashed in SQLite on the host. The cert is self-signed ECDSA P-256 with no SANs and is pinned by
  SHA-256. **The iOS app has to set `NSAllowsArbitraryLoads: true`**, because ATS rejects SAN-less certs on non-"local"
  interfaces such as Tailscale before the delegate can pin. Devices are revoked with `herdr-connect devices revoke`.
- herdr access (`internal/herdrsource/herdr_cli.go`): `exec herdr agent list`, `workspace list`, `tab list`,
  `agent read <id> --source recent-unwrapped --lines N`, `agent get`, **`pane run <id> <text>`** (send),
  **`pane send-keys <id> C-c`** (interrupt), `agent focus`. `Changes()` returns "no trusted incremental subscription": the
  daemon never uses `events.subscribe`.
- API: `GET /v1/agents`, `/v1/agents/<id>/{history,messages,focus,interrupt}`, and SSE `/v1/agents/events`. The SSE stream
  comes from **polling the snapshot every 1 s** (1 s cache TTL).
- The phone renders history text as markdown (`HistoryMarkdown.tsx`). It has voice input and no terminal emulator.
- Notifications: foreground only, a sound plus a local notification (`DoneSoundProvider.tsx`). Push is "a future
  milestone" (planned HPKE E2EE relay). On background the app stops polling and SSE entirely.

## 4. whip (`kosumic/whip`). RN + Rust, Android-first, iOS on the App Store

- SSH: Rust **russh 0.63** + russh-sftp inside a single Tokio runtime, bridged to RN through UniFFI
  (`packages/react-native-whip-ssh`). It supports nested jump hosts, agent forwarding, and a strict global known-hosts list.
- herdr access (`rust/src/herdr_connection.rs`, `herdr_api.rs`): `channel_open_direct_streamlocal(socket_path)` for both:
  - the **API socket** (JSON NDJSON): snapshot, events, `agent.prompt`, `pane.send_input`, `pane.send_text`, etc. It
    supports protocols 17–22 and ships schema files in `protocol/herdr-api-v17..v20.schema.json`;
  - the **client socket** `herdr-client.sock` (`client_socket_path()` strips `.sock` and adds `-client.sock`). Over it they
    speak **herdr's binary client protocol** (`herdr_codec.rs`: bincode, messages `Hello/Input/Resize/Detach/Attach/Scroll`;
    server `Welcome/Terminal{sequence,width,height,full,bytes}/Graphics/Closed/Notify/Clipboard/Title/MouseCapture/…`).
    This is the same protocol herdr's own thin client uses, version-tabled because it breaks between versions (p18, p20, p22
    changed tags). **Fragile.**
- Rendering: xterm.js inside a WebView. They keep a cache of recent ANSI output so a read-only "virtual backend" shows the
  last screen while offline. A per-terminal **outbox** queues composer messages and replays them on reconnect.
- Chat View: **reads native agent transcripts over SSH**. Codex rollout JSONL matched by herdr's `agent_session` id;
  OpenCode via `opencode export` + `opencode db`; Claude by searching `~/.claude/projects/**/<session-uuid>.jsonl`
  (`docs/claude-chat-view.md`). It follows with `tail -c +OFFSET -F` and idles after 5 s once the agent is done.
- Sending from the composer (`src/lib/terminalSubmission.ts`): paste events into xterm (bracketed paste), then `"\r"`,
  written to the terminal stream.
- Pairing: `whipair` (Rust; runs with `npx` / `uvx` / `nix run`). It adds a temporary Ed25519 key with `restrict` and a
  forced command, and puts the seed, endpoint, user and host-key pin in the QR. The phone submits its permanent pubkey and
  **the host user approves it with [Y/n]**.
- Extras: "Reverse Control" sets up an MCP server for the agent through **SSH reverse TCP forwarding**, so a remote agent can
  drive the phone's browser and device. Links that point at loopback or private addresses are opened through an SSH
  direct-tcpip tunnel in the in-app browser.
- Push: none. Local notifications while connected. Android uses `HerdrBackgroundModule.kt` (foreground service). iOS
  declares `UIBackgroundModes: audio` (used for the voice announcements).

## 5. Multiplex (`multiplex-term/Multiplex`). tmux first, herdr as a per-host backend

- SSH: **Citadel 0.12.0** (pinned exact, because 0.12.1 moved to an unaudited NIO-SSH fork) + vendored swift-nio-ssh 0.3.5.
  They also wrote a clean-room mosh.
- herdr (`Services/HerdrProbe.swift`, `docs/agents/backends-and-probe.md`): **every interaction is an SSH exec of the CLI**.
  The probe script runs `command -v herdr; herdr status --json; herdr session list --json; herdr --session <s> api snapshot`.
  Each tick costs about 25 KB, against 3.5 KB for tmux. Attach is `herdr session attach <name>` in a PTY (it auto-creates or
  revives the session). Tabs and workspaces are created with `tab create` / `workspace create --focus`. Shortcut keys send
  herdr's `⌃B` defaults, read from `herdr --default-config`.
- Rendering: **SwiftTerm** (vendored fork; `docs/agents/swiftterm-fork.md`). Key rail with hold-CTRL chords and macros,
  dictation with RNNoise.
- Pairing: closed-source `mpx bind` (QR / Bonjour + PIN / clipboard). The app's **public** key goes into `authorized_keys`
  with a `multiplex:bind:<id>` comment. The offer pins all host key fingerprints. Hosts sync through iCloud Keychain.
- Notifications (`Services/AttentionCenter.swift`): **local only**, from probe events and in-band bells, so "the app must be
  running". Background: an opt-in per-host `beginBackgroundTask`, measured at **about 26 s on iPad**, plus `BGAppRefreshTask`.
  They explicitly decided against fake `audio`/`voip` background modes (App Review rejection risk). The code comment says
  "True background delivery would need a push service."

## 6. anyssh (`patricio0312rev/anyssh`)

- General-purpose iOS SSH client: libssh2+OpenSSL xcframework (`make vendor`), SwiftTerm, a tree-sitter git diff view, and
  a file browser.
- herdr adapter (`Packages/AnySSHKit/Sources/Multiplexers/Adapters/HerdrCommands.swift`): CLI over exec, batched with
  labelled sections. `herdr session list --json`, `herdr [--session s] api snapshot`, `agent focus <pane>`,
  `tab focus <id>`, `pane read <pane> --source recent-unwrapped --format text --lines N`, and the config file is read with
  `cat ~/.config/herdr/config.toml`. Attach is `'herdr' session attach '<session>'` (`MuxAttachCommand.swift`).
- Polling (`MuxPollCadence`): 1 s while visible, 5 s in background, stopped when suspended.
- `HerdrStallWatcher` diffs `agentStatus` between snapshots and schedules a local "job finished" notification on a change to
  `blocked`/`done`, plus a Live Activity. Both only work while the connection is alive. It has no push and no chat.

## 7. pairfob (`arronKler/pairfob`). Outbound relay, PWA client

- Topology (README): `phone --HTTPS/WSS--> pairfob.com (Cloudflare Worker + Durable Object) <--outbound WSS-- pairfob daemon --loopback--> herdr`.
  The host opens no inbound ports and needs no VPN. After authenticated setup, the session **upgrades to a WebRTC
  DataChannel** (`proto/direct-transport.md`; STUN `stun.cloudflare.com`, no TURN, so the relay stays as fallback).
- Crypto: SPAKE2+ pairing with a code both sides confirm (PGP word list), Argon2id, AEAD envelopes (`proto/envelope-v2.md`).
  The relay sees only ciphertext `FWD` frames. Pairing runs from `pairfob pair` or the herdr plugin action
  (`[[panes]] placement = "overlay"`).
- herdr access (`internal/runtime/`): **the daemon dials the unix socket directly** (`net.DialContext("unix", socket)`) for
  `session.snapshot`, `events.subscribe`, `agent.prompt`, `agent.start`, `pane.split/swap/zoom/resize/close/rename`,
  `pane.send_keys`, `pane.send_text`, `pane.read`, `pane.process_info`, `tab.*`, `workspace.*`, `agent.explain`.
- **Terminal = `herdr terminal session control <pane> [--takeover] --cols N --rows M`** as a child process
  (`herdr_terminal.go`). It speaks NDJSON on stdio:
  - out: `{"type":"terminal.frame","sequence":n,"width":w,"height":h,"full":bool,"encoding":"ansi","bytes":"<b64>"}`,
    `{"type":"terminal.closed","reason":…}`
  - in: `{"type":"terminal.input","bytes":"<b64>"}`, `{"type":"terminal.resize","cols","rows","cell_width_px","cell_height_px"}`,
    `terminal.scroll {direction,lines,source:"wheel"|"page_key",modifiers}`, `terminal.mouse`, `terminal.release`.
  - This is a **public, JSON, versioned-by-CLI** form of herdr's client protocol. Verified locally:
    `herdr terminal session {control,observe} <TARGET> [--takeover] [--cols] [--rows]` exists in 0.9.3.
- Phone renders **xterm.js 6 + WebGL addon**. Modes: Control (terminal + system keyboard + keypad), Terminal (raw PTY),
  Chat.
- Chat: the daemon reads agent journals (`internal/journal/`: claude `agent-transcripts/<id>/<id>.jsonl`, codex, pi,
  opencode, hermes) and serves an `agentTrace` RPC. It sends with `agent.prompt`. The UI keeps sending, accepted, processing,
  and transcript-received as separate states and **never replays** a send.
- Push (`internal/daemon/push.go`): **standard Web Push (RFC 8291 aes128gcm + VAPID) sent straight from the daemon** to the
  browser's push endpoint (Apple Web Push for an installed PWA). It debounces for 30 s and refuses private or loopback
  endpoint IPs. The project runs no APNs server. This only works because the client is a PWA. A native app cannot use it.

## 8. pdx (`leekt/pdx`). Android handheld

- sshj 0.40 over exec. Commands (`HerdrCommandBuilder.kt`): `herdr --session S agent list`, `agent get <pane>`,
  `pane read <pane> --source recent-unwrapped --lines 160 --format ansi` (2 s poll), and live
  **`herdr terminal session control|observe <terminal_id> --cols --rows`**. It targets herdr 0.9.0 / protocol 22.
- Renders with an offline xterm.js bundle in a WebView. "Send + Enter" writes paste bytes and then a separate Enter on the
  control channel. Writes are never replayed.
- Chat: Codex only. It runs `exec <codex> app-server --listen stdio://` over SSH and calls `thread/read` and
  `thread/turns/list` (read-only).
- It has no push and no background notifications. Its device key is Ed25519, encrypted on the device, and the user copies
  the public key into `authorized_keys` by hand.

---

## Cross-cutting findings

**Reaching the host**: the clients use five patterns.
1. **Direct SSH + direct-streamlocal to `herdr.sock`**. Used by Heeler, Kelpie and whip. Nothing to install on the host. It
   gives a full JSON API, live events, and one channel per request. Needs LAN, Tailscale, or a jump host.
2. **Direct SSH + exec of the `herdr` CLI**. Used by Multiplex, anyssh and pdx. Simplest, but it polls (1–2 s), pays for a
   process spawn and PATH discovery each time, and has no events.
3. **LAN daemon + HTTPS** (herdr-connect). Needs a host daemon, a self-signed pinned cert, and ATS disabled.
4. **Outbound relay + WebRTC** (pairfob). Works anywhere with no inbound ports. Needs a daemon and a hosted relay.
5. iroh was not used by any client.

**herdr terminal streams**: there are three ways to get pane pixels.
- `herdr agent attach --takeover` / `herdr session attach` / `exec herdr` in an **SSH PTY**. The raw byte stream goes to a
  local emulator. Simplest. Used by Heeler, Kelpie, Multiplex and anyssh.
- `herdr terminal session control <pane>`: **NDJSON frames** (`terminal.frame` with ANSI bytes, `full` flag, sequence) on
  stdio. A public CLI with explicit resize/scroll/mouse messages. Used by pairfob and pdx, and by Heeler on Windows.
- `herdr-client.sock` with the bincode client protocol (whip). Fastest, but it breaks every few protocol versions.

**Chat data source**: no client builds chat from herdr alone. Everyone who has chat reads the **agent's own transcript file**
on the host (Claude `~/.claude/projects/**/<session>.jsonl`, Codex rollout JSONL, OpenCode export/db, pi sessions), keyed by
herdr's `agent_session` id or by `pane.process_info` pid/cwd. They read it incrementally by byte offset. They send with
`agent.prompt`, or with paste + `\r` into the terminal. They answer permission prompts with `agent.send_keys`.

**Push**: APNs needs the developer's `.p8`, so a native app needs a server the developer runs. The best design here is
Heeler's: a stateless Worker relay, a herdr plugin `[[events]]` hook as the trigger (no daemon), and E2EE with a key the app
writes to the host over SSH. pairfob avoids APNs entirely through PWA Web Push. Everyone else has foreground or
local notifications only. iOS gives a backgrounded app about 26–30 s through `beginBackgroundTask`. Faking
`audio`/`voip` background modes risks App Store rejection (Multiplex ADR, herdr-connect's `expo-audio` note).

**Pairing**: the common pattern is a QR printed on the host that carries addresses, the host-key fingerprint, and a
one-time secret. The SSH flavour (Heeler, whipair) uses a **one-time `restrict,command=` bootstrap key** that enrols the
device's own Ed25519 public key. The private device key never leaves the Keychain (Secure Enclave is not possible for
Ed25519. They use CryptoKit Curve25519 in the Keychain). Kelpie and Multiplex sync through iCloud Keychain
(`kSecAttrSynchronizable`) so the user pairs once for all devices.

**Keyboard**: everyone has a key row (Esc, Tab, Shift-Tab, Ctrl latch, arrows, Enter). Heeler moved it out of
`inputAccessoryView` into normal layout because keyboard mode switches tore it down. Kelpie and anyssh use
`inputAccessoryView`. Hardware keyboard detection uses `GCKeyboard.coalesced` (Kelpie), and Multiplex has a
`HardwareKeyboardMonitor`. Most apps offer a native Composer (local draft with autocorrect and dictation) that sends once,
next to a direct-to-PTY mode.

---

## Lessons for our app

**Copy**
1. **Transport = SSH + `direct-streamlocal` to `herdr.sock`** for remote hosts (Heeler/whip). For the local host, use the
   same JSON protocol over a plain unix socket. One code path and nothing installed on the host: NDJSON
   `{"id","method","params"}`, one request per connection, plus one long-lived `events.subscribe` connection.
   Use herdr `ping` as the health check.
2. **Pane rendering through `herdr terminal session control <pane> --cols --rows`** over an SSH exec channel (or a local
   `Process`). It gives per-pane frames, not the whole TUI, and that fits our "strip of panes" UI better than
   `herdr agent attach`. It is JSON, public, and survives protocol bumps better than whip's bincode. The SSH PTY plus
   `herdr agent attach --takeover` is the fallback. Watch the `--takeover` semantics: a second viewer may kick the desktop
   client. Confirm this with the herdr-protocol researcher.
3. **libghostty-spm (`GhosttyTerminal`)** for rendering on macOS and iOS: Metal, IME, scrollback, `sendKey`, with
   `InMemoryTerminalSession.receive(_:)` fed from our transport. Heeler measured SwiftTerm and rejected it.
4. **Chat view = agent transcript file + herdr control**: find the transcript through `agent_session` /
   `pane.process_info`, read it incrementally by byte offset, refresh on `pane.agent_status_changed`, send with
   `agent.prompt`, and answer permission prompts with `agent.send_keys`. Add one parser per agent and keep it lenient.
   The app stores nothing.
5. **Pairing**: a herdr plugin action renders a QR (addresses + host-key fingerprint + one-time `restrict,command=`
   bootstrap key). The app enrols its Keychain Ed25519 key, then syncs Hosts and the key through iCloud Keychain
   (`kSecAttrSynchronizable`) so macOS and iOS share pairings for free. This matches "app stores as little as possible".
6. **Push, if wanted**: a herdr plugin `[[events]] on="pane.agent_status_changed"` hook, debounced and re-checked, seals with
   AES-GCM and posts to a tiny stateless relay that holds the APNs key. Register by writing the token and key file on the
   host over SSH. No daemon. Defer this until needed; foreground in-app banners from the event stream cost nothing.
7. Background on iOS: hold the connections for the `beginBackgroundTask` grace period (about 30 s), tear down on purpose
   when it ends, and reconnect and re-snapshot on foreground. Do not declare fake background modes.
8. Composer UX: a local draft with Send-once is better than typing into a remote TUI on a phone. When the agent is
   `blocked`, fall back to typing into the PTY (Heeler ADR 0013). Never auto-replay a send whose delivery is uncertain
   (pairfob, pdx).

**Avoid**
- A custom host daemon (herdr-connect, pairfob): it adds an install step, a service lifecycle, TLS and ATS problems, and
  auth tokens. SSH already provides auth and encryption.
- Polling the CLI over exec (Multiplex 25 KB/tick, anyssh 1 s, pdx 2 s) when `events.subscribe` exists.
- herdr's bincode client socket (whip): it is undocumented and changed in protocols 18, 20 and 22.
- Text-scraping `agent read` as "chat" (herdr-connect): it is capped, shows only the viewport for alternate-screen TUIs,
  and breaks when the TUI changes.
- Letting herdr open URLs: it runs `open` on the **host**. Catch link taps on the client (Kelpie ADR 0017).
- Relying on `inputAccessoryView` for the key row if the keyboard mode switches (Heeler's lesson). Put the row in normal layout.
- A relay or WebRTC for remote reach before it is needed. Tailscale and a jump host cover it (Heeler's VPS jump-host guide).
