# Collie (AltanS/collie) — research notes

Repo: `/tmp/herdr-research/collie` (shallow). What it is: a mobile PWA ("ColliePWA") for herdr, with
experimental tmux, zellij (plus tern and tuios) drivers. Stack: Bun bridge in TypeScript (`bridge/`),
React 19, React Router in library mode, Vite, Tailwind and shadcn (`web/`). There are about 90 ADRs
in `.adr/`, and they are the best "why" source. `HERDR_API.md` is a herdr socket contract that the
author verified against live servers. **Read it before writing the Swift client.** It is the most
useful thing in the repo for us.

---

## 1. Server/bridge architecture & transport

- **One long-lived daemon per machine.** It runs as a `systemd --user` unit or a launchd agent, not
  as a herdr plugin pane, so it survives herdr restarts (ARCHITECTURE.md §3). The herdr plugin
  (`herdr-plugin.toml`) is only `[[actions]]` + `[[build]]`, which call `bin/collie <verb>`
  (start/stop/update/print URL).
- **Browser ↔ bridge: plain HTTP JSON polling only. No WebSocket and no SSE anywhere.** ADR 0073
  turns both down on purpose: polling makes reconnect and backpressure trivial.
  - `GET /api/snapshot` returns the whole herd. Pane mirror: `GET /api/pane/:id?lines=N`.
  - Chat: `GET /api/pane/:id/chat`. History: `GET /api/pane/:id/history`.
  - Writes: `POST /api/pane/:id/{reply,keys,upload,close,rename,focus}`.
  - Also: `POST /api/tab`, `POST /api/workspace`, `POST /api/launch`, `GET /api/config`,
    `POST /api/subscribe` (push), `POST /api/pair`, `POST /api/stt`, `POST /api/refresh`.
  - The pane router is at `bridge/server.ts:~1455-1510`.
  - Every read is ETag'd from the serialised body. The bridge answers 304 when nothing changed, and
    gzips the rest: "the big win on a cellular link" (`readPane`, `server.ts:2764`).
  - The build stamp goes out in an `X-Collie-Build` header. When it doesn't match, the PWA says
    "new build, tap to update".
- **Front door.** The bridge binds `127.0.0.1` only and refuses any non-loopback bind unless an
  override is set.
  - `tailscale serve` is the default tunnel. It gives tailnet-only HTTPS on a MagicDNS name. The
    bridge trusts the `Tailscale-User-Login` header only when the source is loopback, and
    `COLLIE_TRUSTED_USER` pins the expected login.
  - The other option is a reverse proxy (Variant C), with per-device headers or Cloudflare Access
    JWT checks (`bridge/access-jwt.ts`).
  - Funnel (public exposure) is forbidden.
- **Auth.** Device pairing (`bridge/pairing.ts`) is always on.
  - `collie pair` prints a one-time code in the operator's terminal.
  - The phone trades the code at `POST /api/pair` for a 256-bit bearer token. The bridge stores
    only its SHA-256, in `<state>/paired-devices.json`.
  - Every `/api/*` route needs the token, except `/api/health` and `/api/pair` (ADR 0086).
  - The registry is re-read on every request, so `collie devices revoke` takes effect with no
    restart.
- **Hardening.**
  - `Host` header allowlist, against DNS rebinding.
  - Same-origin check (`Origin` host must equal `Host`).
  - Strict CSP `default-src 'self'`.
  - Pane text renders as React text nodes only. No `innerHTML`.
  - JSONL audit log of every write in `<state>/audit.log`, mode 0600.
  - Client-side confirm when typed input matches `rm`, `sudo`, `git push --force`, and similar
    (`web/src/lib/destructive.ts`).

## 2. herdr socket methods / CLI used

Transport: `bridge/mux/herdr/client.ts` is the only file that knows herdr's verbs. `bridge/dial.ts`
uses a Unix socket on POSIX and a named pipe on Windows.

- Newline-delimited JSON-RPC.
  - Request: `{"id":"<string!>","method":"…","params":{…}}`. An integer `id` gets `invalid_request`.
  - Reply: `{"id","result":{"type":"…",…}}` or `{"id":"","error":{"code","message"}}`.
- **One request per connection.** The server closes the connection after one reply. The exception
  is `events.subscribe`, which keeps it open.
- A request line is capped at 1 MiB. Above that the server never answers.
- Bun's `socket.write` does partial writes, so the bridge resumes on `drain`
  (`bridge/write-drain.ts`). Swift `NWConnection` handles this for us.
- Socket path: `$HERDR_SOCKET_PATH`, falling back to `~/.config/herdr/herdr.sock`. Named sessions
  live at `<root>/sessions/<name>/herdr.sock`. A socket file that exists means the session is live
  (`bridge/mux/herdr/sessions.ts`). The UI can switch between herdr sessions.

Methods actually called (from grep of `bridge/mux/herdr/*.ts`):

| method | params | notes |
|---|---|---|
| `session.snapshot` | `{}` | The poll source of truth. Returns `{workspaces[],tabs[],panes[],agents[],layouts[],focused_workspace_id,focused_tab_id,focused_pane_id,version,protocol}`. If the error says `unknown variant`, it falls back to `workspace.list` + `pane.list` + `tab.list`. |
| `pane.read` | `{pane_id, source: visible\|recent\|recent_unwrapped\|detection, lines, format: text\|ansi}` | Returns `{read:{pane_id,text,truncated,revision}}`. |
| `pane.send_text` | `{pane_id, text}` | Raw bytes. No bracketed paste. `\n` is a real Enter keypress. No size cap (verified at 40 KB). |
| `pane.send_keys` | `{pane_id, keys:[…]}` | Keys are applied in order. |
| `pane.focus` | `{pane_id}` | Moves the **operator's** screen (pane, tab and workspace in one call). Called only from an explicit "Show in terminal" tap. |
| `pane.rename` | `{pane_id, label: string\|null}` | `null` clears the label. Emits **no event**. |
| `pane.close` | `{pane_id}` | |
| `tab.create` | `{workspace_id, focus:false, label?, cwd?}` | Returns `{root_pane}`. |
| `tab.rename` | `{tab_id, label}` | Label must be a non-null string. `""` is stored literally. |
| `tab.close` | `{tab_id}` | Kills every pane in the tab. |
| `workspace.create` | `{cwd, focus:false, label?}` | Returns `{workspace, root_pane}`. |
| `worktree.list` | `{cwd}` or `{workspace_id}` | |
| `worktree.create` | `{cwd, branch, focus:false}` | Not atomic. If the open fails, recover by opening, not by re-creating. |
| `worktree.open` | `{cwd, path, focus:false}` | Answers `already_open:true` when it is already open. |
| `events.subscribe` | `{subscriptions:[{type, pane_id?}]}` | Ack: `{"result":{"type":"subscription_started"}}`. Each event line: `{"event":"pane_agent_status_changed","data":{…}}`. |

- **Always `focus:false`** on create, so the desktop TUI's focus never jumps.
- The bridge never uses split methods. New panes come only from new tabs or workspaces, and a
  launcher types a command into the fresh shell.
- **CLI shell-outs:** only `herdr machine list --json`, which suggests machines for `crew add`
  (`bridge/mux/herdr/machine-list.ts`). Documented but not used: `herdr api schema --json` (the
  machine-readable contract) and `herdr api snapshot`.

Subscriptions (`bridge/mux/herdr/events.ts`):

- Global: `workspace.{created,updated,renamed,closed,focused}`, `tab.{created,closed,focused,renamed}`,
  `pane.{created,closed,focused,moved,exited,agent_detected}`.
- Per agent pane: `{type:"pane.agent_status_changed", pane_id}`. This one *requires* `pane_id`, as do
  `pane.scroll_changed` and `pane.output_matched`.
- They resubscribe whenever the set of agent panes changes.
- They leave out `workspace.moved`, `tab.moved` and `layout.updated`: "one unknown subscription
  type rejects the whole subscribe" on older servers.
- Subscription types are dot-form. The streamed `event` field is snake_case.

Verified gotchas (HERDR_API.md):

- **`send_keys` grammar is not tmux.**
  - Works: `Up Down Left Right Tab Enter Escape Space Backspace F1..F12`, any single character, and
    chords like `ctrl+c`, `shift+tab`, `alt+Up`, `ctrl+shift+p`.
  - Rejected with `invalid_key`: `PageUp`, `PageDown`, `Home`, `End`, `Insert`, `Delete`, and
    `C-c`.
- **`pane.read` `recent` + `text` with `lines > viewport_rows` scrolls the operator's real
  terminal.** herdr harvests alt-screen agents through their mouse-scroll interface: 400 lines took
  13.8 s. `ansi` was never seen to do this, and `visible` can't. **Background polls must use
  `visible`, or `ansi`.**
- `revision` is always `0`, a stub, so it can't detect changes. `agent_session` is
  `{source, agent, kind:"id"|"path", value}` and can be stale after the harness changes. Check
  `agent_session.agent == pane.agent` before trusting it.
- On 0.9, API `agent_status` (`idle|working|blocked|done|unknown`) differs from the TUI's "unread
  done". Collie keeps its own seen ledger.
- Tabs: array order is what counts. `tab.move` doesn't renumber, so never sort tabs by `number`.
  `workspace.move` does renumber.
- `insert_index` counts positions in the list *before* the item is removed. Moving toward the end
  needs `+1`.
- herdr doesn't answer OSC 10/11 background queries, and it relays SGR verbatim: palette indexes,
  not RGB. So the client applies its own 16-colour table.
- Pane geometry is applied only while a desktop client is attached (upstream `herdr#1709`).

## 3. Live terminal streaming technique

- **Snapshot polling, not a byte stream. There is no terminal emulator anywhere.** ADR 0008 is the
  long argument: `pane.read` returns herdr's *already-rendered grid* with SGR re-attached, and no
  cursor moves. A second emulator would only disagree with the first.
- **Bridge cadence** (`bridge/state-engine.ts`, `event-poker.ts`):
  - It polls `session.snapshot` every `COLLIE_POLL_MS`=1500 ms, relaxed to 12 s while the event
    stream is healthy.
  - An event triggers a debounced re-poll (200 ms). Reconnect backoff is `[1s,2s,5s,15s]`.
  - **Events only "poke" a re-poll. They never change state directly.**
  - After an input, the bridge goes "hot" for 8 polls. Polls count down; there are no clock
    deadlines.
- **Browser cadence** (`web/src/hooks/use-polling.ts`):
  - `BURST_MS`=300 for about 5 polls after a send.
  - `HOT_MS`=1500 while following a working or changing pane.
  - `HOME_BUSY_MS`=4000 and `IDLE_MS`=6000 otherwise. `RETRY_MS`=500, doubling.
  - It pauses while the tab is hidden.
- **Pane read** (`server.ts readPane`):
  - Uses `source:"recent", format:"ansi"`. `lines` defaults to `COLLIE_READ_LINES`=200, and the
    history view asks for 600.
  - When the grid shows a URL cut at the column edge, the bridge does one extra
    `recent_unwrapped` read to rebuild the full href (`hasSplitUrl`).
  - The ETag gives 304 when nothing changed, which is the "diffing".
- **Renderer:** its own SGR-only parser (`web/src/lib/ansi.ts`, 278 lines) turns each run into
  React `<span>`s. No xterm.js and no ghostty-web.
  - Rows wrap to phone width.
  - Box-drawing tables are grouped into horizontally panned scrollers (`table-run.ts`, ADR 0072).
  - Colours are inverted for the light theme (ADR 0002).
  - Paths in the output become links (ADR 0088).
- **Scrollback comes from the agent's transcript, not the terminal.** Alt-screen TUIs have no
  scrollback ring. If the newest reply is longer than the screen, the mirror replaces its cut-off
  top with the full turn from the journal (`web/src/lib/latest-reply.ts`).
- They know about `herdr terminal session observe|control` (NDJSON ANSI frames, with
  `terminal.input|resize|scroll|release`) and rejected it on purpose. `control` resizes the
  *shared* PTY and fights the desktop.

## 4. Layout model

- **There is no split tree.** `layouts[]` from `session.snapshot` is carried but "intentionally
  unused" (`client.ts:160`). `layout.updated` isn't subscribed.
- The model is flat: host › workspace ("Space") › tab › panes (`web/src/lib/spaces.ts`,
  `pane-groups.ts`).
  - Workspaces sort by `number`. Tabs keep array order.
  - Inside a tab: agents first, then shells, each in the mux's own position order.
- The phone shows **one pane at a time**, with a space strip, a tab strip and a pane strip (pills).
  Swipe up for the switcher sheet. Long-press a pane pill for rename, close or "show in terminal".
- **ADR 0063:** a pane never moves when its status changes. Urgency is a mark on the row, never a
  position.
- Home is a triage dashboard: one summary line ("N need you") plus Focus, Crew and Changes tabs.

## 5. Chat view

- **Data source: the agent's own transcript files on disk, never the screen** (`bridge/journal/`).
  - One adapter per harness:
    - claude: `~/.claude/projects/<mangled-cwd>/<uuid>.jsonl`
    - codex: `$CODEX_HOME/sessions`
    - pi and omp: `~/.pi/agent/sessions/--cwd--/<ts>_<uuid>.jsonl`
    - opencode and hermes: SQLite
    - also grok and muse
  - The pane is mapped to its file through herdr's `pane.agent_session` (`kind:id` is a uuid
    lookup, `kind:path` is a direct path). If the pane reports no session, an adapter-specific
    `discover(cwd)` scans newest-first.
  - Several roots per harness are allowed (`CLAUDE_CONFIG_DIR` profiles), each path-contained.
- **Shape:** `TranscriptEntry{uuid, ts, role: user|assistant|summary|note, parts[]}`. A part is
  `text | thinking | image | tool{name, summary, call, result{text, isError, denied}}`.
- **Live window** (ADR 0073, `bridge/journal/live.ts`):
  - Bounded to 2 MB or 2000 entries per session, with a cursor.
  - Polled through `GET /api/pane/:id/chat`, with 304s and `before=` for older pages.
  - It tails the file instead of re-parsing whole logs. Real sessions measured 186 MB.
- **ADR 0082:** Chat is the **default** view for agent panes. It falls back to the terminal mirror
  on *events*, never timers:
  - the agent goes `blocked` with no log yet,
  - the first turn ends with no session,
  - or there is still no log after a fresh read.
  - The fallback isn't sticky: a log that arrives later brings Chat back.
  - Codex reports its session only on the first prompt. pi writes its log only after the first
    reply.
- **Dialogs and approvals still come from parsing the screen**, even in Chat view.
  - Per-harness grammars in `web/src/lib/harness/<agent>/` (claude, codex, opencode, omp, grok,
    agy, muse) are pure functions over `StyledLine[]`, tested against about 34 byte-exact fixtures.
  - They lift the screen into `Block`s: `prompt-select | wizard | preview-select | multi-select |
    menu | autocomplete | unread-dialog | raw`.
  - The **tail invariant:** a dialog's footer hint must be the last non-blank line. A menu that has
    scrolled up doesn't match.
  - Lifted cards dock in one fixed slot above the action belt (ADR 0059).
- **`HarnessAdapter` interface** (`harness/types.ts`): `buildBlocks`, `composerReady`,
  `extractInputDraft`, `extractStatusLines`, `cancelKey`, `modalOnScreen`, `composerPrompt`,
  `newlineSubmits`, `draftCarriesSend`, `bracketedPaste`, `replyChunks`.
- **Answering a dialog:** `pane.send_keys {keys:["1"]}` for a permission prompt, or `["2","Enter"]`
  for a select. A pointed list is walked: `[Down×n]`, then re-read and check the pointer, then
  `Enter` (ADR 0080).
  - Race guard (`web/src/lib/dialog-guard.ts`): a fresh read, then re-derive through the same
    adapter, then compare the dialog signature. Only then send.
  - The client also sends `expected_prompt` (and `expected_styled`). The **bridge re-reads the pane
    just before `send_keys`** and answers 409 if the region is gone (`bridge/prompt-binding.ts`,
    `checkPromptBinding`). That shrinks the race window from a network round trip to two local
    RPCs.
- **Free-text reply** (`web/src/lib/reply-action.ts` + `server.ts sendReplySteps`). "Enter is never
  sent blind":
  1. Pre-flight: `composerReady`. Refuse if a modal has the keyboard.
  2. Pre-clear sweep: `ctrl+k` + N×`Backspace`, bound to `composerPrompt`.
  3. `send_text` with `submit:false`.
  4. Poll reads until our text shows on the `❯` line.
  5. Only then `send_keys ["Enter"]`. If the text never appears, no Enter is sent and the draft is
     kept.
  - Why: issue #34. A blind Enter answered a focused Claude permission dialog with "Yes", and both
    RPCs reported ok. **An ack means "herdr took the bytes", never "the TUI acted".**
  - When the text lands but submit fails, the reply returns `textDelivered:true`, so the client
    does not resend.
- **Paste handling** (ADR 0010):
  - Claude collapses long input to `[Pasted text #N +M lines]`. `draftCarriesSend` accepts that
    token as proof of delivery when its line count matches.
  - Replies over 800 characters to Claude are wrapped by Collie itself as `ESC[200~…ESC[201~`,
    because `send_text` doesn't bracket and macOS PTYs split writes into ~1 KB reads. Without the
    wrapper, 12,029 characters arrived as 787.
  - **Chunking is rejected:** a chunk boundary that lands on `\n` would submit a half message.
- **Password prompts** (sudo, ssh) turn echo off, so the verification can never succeed. Collie
  detects them and changes what it tells the user (ADR 0017, `lib/no-echo.ts`).
- **Attachments:** a multipart upload to `<state>/uploads/<pane>-<time>-<hex>.<ext>`, max 10 MB,
  swept by TTL. The **absolute path is typed into the message**; agents read files by path. The UI
  shows the attachment as a chip, not the raw path (ADR 0060).

## 6. Multi-host ("crew")

- **Every machine runs a full Collie.** One of them, the **lead**, holds the front door. The phone
  talks only to the lead (ARCHITECTURE.md §2.1, CREW_PROTOCOL.md is 3,159 lines).
- The lead consumes peers' *Collie HTTP API* over `/crew/v1/*`. That path is gated by pinned mutual
  TLS **and** a crew secret, and the lead dials out.
- **No herdr verb crosses machines** (ADR 0011). Only Collie's domain model does: snapshots, grids,
  replies, uploads.
- The lead merges snapshots (`bridge/crew/merge.ts`) and forwards pane requests to the owning peer.
  Every key is `(host, workspaceId)`, because herdr ids are unique only per machine
  (`lib/hosts.ts spaceKey`).
- Extras on top: a named deputy with a signed warrant, a standby door, and updates pushed over the
  operator's ssh. This is heavy, and it exists mainly because a PWA can talk to only one origin.

## 7. Mobile UX tricks

- **Composer.** A plain textarea, so system dictation works for free. There is an explicit Send
  button, and "Sent ✓" closes the loop, followed by the blocked → working flip.
- **Keys tray.**
  - Fixed keys: Esc, arrows, Enter/Tab/Space, modifiers, digits, F1–F12.
  - Presets: by default Ctrl C/D/U/R/L/Z. They can be overridden per agent in `keys.toml`, and
    `danger=true` needs two taps.
  - A key queue: compose chords, review them as chips, send them as one `send_keys`. A non-empty
    queue asks for a confirm before it is discarded (ADR 0005).
- **Quick replies** per agent (`quick-replies.toml`), slash-command rows (`commands.toml`), and
  launchers (`launchers.toml`). The launchers file is the allowlist for `/api/launch`: a launcher
  types its command into a fresh tab and presses Enter.
- **Direct typing mode** (`use-direct-typing.ts`): textarea input/keydown is mapped to `send_keys`
  in order. An "armed" strip says that keystrokes go live (`direct-typing-strip.tsx`).
- **Other touches.**
  - A left/right hand setting mirrors the action belt.
  - Haptics, swipe-up for the switcher, long-press sheets.
  - An idle lock, which pauses polling and gates nothing.
  - A zen mode that hides chrome.
  - Find in output, and jump to the user's turn in history.
- **Voice:** an opt-in STT provider seam (`bridge/stt/`: openai, codex, local-cli, http). The audio
  is POSTed to `/api/stt`. Hands-free sends go through the same guarded reply path.
- **Other views:** a read-only git Changes/Files view (diffs, images), and machine load charts.

## 8. Push notifications

- **Web Push with VAPID** through the optional `web-push` npm package (`bridge/push.ts`).
  - `collie push-keys` writes `COLLIE_VAPID_PUBLIC/PRIVATE` to `.env`.
  - Subscriptions are stored in `<state>/push-subscriptions.json`.
  - The service worker is `web/src/sw.ts` (handles `push` and `notificationclick`, which deep-links
    to the pane).
- **Triggers** (`bridge/notifications.ts` NotificationCoordinator), driven by status transitions in
  the snapshot poll:
  - `blocked` (Needs input, on by default) and `done` (Finished: working → idle, off by default).
  - App update, sustained machine load, and "prompt cache goes cold in about 5 minutes" (read from
    the transcript).
- **Debounce** of `COLLIE_NOTIFY_DELAY_MS`=30 s. An agent that blocks and unblocks inside the
  window was handled at the desk, so no push goes out. This is a presence heuristic, because herdr
  has no "user present" signal.
- **Coalescing:** one herd summary notification ("claude needs you" or "3 agents need you"),
  re-rendered on each change.
- **Retraction:** a `{type:"clear"}` push removes the notification once the agent is handled.
- The service worker suppresses the notification if a Collie tab is visible.
- **Delivery options learned the hard way:**
  - `{TTL: 21600, topic: "collie-herd", urgency: "high"}`.
  - The topic is the collapse key.
  - **Apple rejects topics whose length ≡ 1 (mod 4)**, because the topic must decode as base64.
  - Android defers anything below `urgency:"high"`.
- **Push titles go out as codes** (ADR 0074), so each phone translates them. The body is the pane's
  place (`workspace › tab`), not the question. This is a known gap.

## 9. Persistence

- **Bridge state directory:** `$COLLIE_STATE_DIR`, default `~/.local/state/collie/`.
  - `paired-devices.json` and `pairing-pending.json`
  - `push-subscriptions.json`
  - `activity.json`: `{activeAt, seenAt}` per pane, keyed by session. This is the shared "seen"
    ledger (ADR 0003); herdr records have no timestamps.
  - `snooze.json`, `notify-prefs.json`, `cache-watch.json`, `folders.json` (starred dirs)
  - `update-state.json`, `audit.log`, `uploads/`, and crew trust stores
- **Operator configuration:** `.env` plus TOML files (`keys`, `commands`, `quick-replies`,
  `launchers`, `theme`, `cache-rules`) in the plugin configuration directory. They are re-read on
  mtime change.
- **Phone:** one on-device store (ADR 0087). It holds the last snapshot and pane mirrors for a cold
  offline open, the token and display preferences. It is wiped on unpair.
- **herdr is the source of truth for everything structural.** Collie stores no layout.

## 10. Clever things, and pitfalls

Clever (worth copying):

- **`session.snapshot` poll + `events.subscribe` as a poke.** It self-heals: a missed event costs
  one interval. Relax the poll while the stream is healthy.
- **Verify before Enter.** Type, then read back, then submit. Plus a server-side prompt binding:
  re-read and match right before the keys go. For a native app on the same host, this is one local
  RPC pair.
- **Chat from the transcript JSONL through `agent_session` (`id` or `path`); approvals from the
  screen grammar.** Two sources, each used for what it does well.
- **Bracketed-paste framing done by the client** for long sends, because herdr doesn't do it.
- **The ETag/304 pattern** on pane reads and chat.
- **The notification coordinator:** debounce, then coalesce into one summary, then retract.
- **Capability declarations** (`bridge/mux/capabilities.ts`). The UI asks for a capability, never
  for the multiplexer's name.

Pitfalls they hit:

- **The `pane.read` harvest** that scrolls the user's terminal. Use `visible` or `ansi`.
- `revision` is a stub. Ids are unique only per host.
- `pane.rename` emits no event. Tab order is array order.
- herdr records carry no timestamps, so you must own "seen" and "active-at" yourself.
- Agents on the alt screen give no scrollback through `pane.read`.
- New panes aren't ready right after `tab.create`. Collie polls `visible` reads until two in a row
  match: ≥ 300 ms floor, 5 s cap (`awaitPaneReady`, `server.ts`). Otherwise the typed command
  arrives before the prompt is drawn.
- Wide desktop-sized panes on a phone. Wrapping vs faithful columns is a product choice.
- Fragile screen grammars. 90 ADRs are mostly scar tissue from regex over TUIs that change every
  release. They keep `verified-versions.json` per harness.

## Lessons for our app (native Swift macOS + iOS)

**Copy:**

1. **Talk to the herdr socket directly from the Mac app.** One connection per request.
   - `session.snapshot` gives workspaces, tabs, panes, agents, layouts and focused_*.
   - One long-lived `events.subscribe` stream pokes a re-snapshot (debounced about 200 ms, backoff
     1/2/5/15 s).
   - Subscribe to `layout.updated` too, because **we** render the split tree from
     `layouts[].splits/panes[].rect`, which Collie ignores. Feature-detect against `protocol`.
2. **Always pass `focus:false`** on create, and treat `pane.focus` as an explicit user act. It moves
   the desktop TUI.
3. **Use `herdr api schema --json`** to generate the Swift Codable types instead of hand-probing.
4. **Chat view.**
   - Read the agent transcript (claude/codex/pi JSONL) via `pane.agent_session`, with
     `kind:"id"|"path"`, and check `agent_session.agent == pane.agent`.
   - Detect approvals with screen grammar on `pane.read(visible, ansi)`, or let `agent_status ==
     blocked` alone open the terminal view. Start with the latter. That is the ponytail rung.
5. **Send.**
   - `pane.send_text` (raw, no bracketed paste). Wrap long text in `ESC[200~…ESC[201~` for harnesses
     that enable bracketed paste.
   - Send Enter as a separate `send_keys ["Enter"]`, ideally only after reading back the draft.
   - Key names follow herdr's grammar (`ctrl+c`, no `PageUp`/`Home`/`End`/`Delete`).
6. **Push.**
   - Native APNs needs a relay. Alternatively, use local notifications while the app is alive.
   - Copy the coordinator semantics: debounce of about 30 s, one coalesced summary, retract on
     resolve.
7. **Web-page panes.** Collie has nothing to copy here. Our "placeholder pane encodes URL" idea is
   new. The label carrier could be `pane.rename` (no event, so it is seen on the next snapshot).

**Avoid:**

- Polling `pane.read` with `source:"recent", format:"text"` and `lines > viewport_rows`. It
  visibly scrolls the user's real terminal.
- Trusting the RPC ack as delivery.
- Chunking long sends.
- Sorting tabs by `number`.
- Trusting `revision`.
- Collie's crew machinery: mTLS, warrants, deputy. For multiple hosts, have each app instance
  connect to each host's own endpoint (an SSH tunnel to the socket, or a tiny relay). Keep
  per-host state keyed by `(host, id)`.
- The custom SGR-only renderer, *if* we want real interactive terminals. On the Mac, a real
  terminal view (e.g. SwiftTerm) fed by `herdr terminal session observe/control` (or
  `terminal attach`) gives true interactivity. Collie's ADR 0008 warns that `control` resizes the
  **shared** PTY. That is acceptable for a desktop-class client but must be explicit. For read-only
  and phone views, the `pane.read(visible, ansi)` snapshot + SGR parse approach is proven and cheap.
  (Guess: `observe` frames are full ANSI and need an emulator. This was not verified here.)
