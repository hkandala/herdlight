# Floating panes

Research for the request "speaking of floating panes we should have support
for it as well". It covers two things:

1. herdr's own floating things (popups and overlays) and how the app shows them.
2. Floating panes that the user makes in the app: a scratch terminal, an agent,
   or a plugin pane that floats above the tabs.

- Date: 2026-10-08. herdr **0.9.3** (source `/tmp/herdr-research/herdr`,
  commit `4dc23bb`, `Cargo.toml` version 0.9.3), schema
  `/tmp/herdr-research/herdr-api-0.9.3.schema.json`, binary
  `~/.local/bin/herdr` 0.9.3.
- Live tests ran on a throwaway server: `XDG_CONFIG_HOME=/tmp/hnfloat-cfg
  herdr --session hnfloat server`, with a throwaway linked plugin. That server
  had its own config folder, so the user's plugin registry and sessions were
  not touched. It was stopped and deleted afterwards. No focus method was
  called. The `pi-herd` server was only read (`plugin list`).
- Labels: **fact** = read in code or docs, or seen in the live test.
  **guess** = not checked.

---

## 0. Answer in one screen

1. **herdr has exactly one real floating object: the popup.** It is a
   terminal drawn as a centred box over the tab. There is at most one popup per
   server. It is **not a pane**: it has no `pane_id`, it is not in
   `session.snapshot`, it sends no events, it is not saved, and herdr does not
   detect agents in it. Its `terminal_id` exists, but only herdr's private
   client socket reports it. The public API can only open it (`plugin.pane.open
   placement:"popup"`, plugin entrypoints only) and close it (`popup.close`).
2. **"Overlay" and "zoomed" are not floating.** Each one is a normal split
   pane in a tab, and herdr then sets that tab's `zoomed` flag. The app already
   shows these as normal cards (D10 ignores herdr's zoom).
3. **So the app cannot show herdr popups in v1.** No public call reveals one.
   herdr-gpui and roamgate show them through the private client socket. That is
   rejected (D6, D20), and roamgate's observer also calls `workspace.focus`,
   which D12 forbids. To fix this, ask herdr to add a `popup` field to
   `session.snapshot`. The app could then stream the popup by its
   `terminal_id`, which works today (§2.4).
4. **Floating panes made in the app are normal herdr panes that live in a
   floating tab.** That is one tab per workspace whose label is `hl:float`.
   Every pane in that tab floats. herdr keeps the tab, its label and its panes
   across restarts (tested). The app stores nothing except where each card sits
   on the screen and whether the floating panes are shown. Both are kept in
   memory only.
5. **To float a pane:** `pane.move` into the floating tab, or
   `pane.move {type:"new_tab", workspace_id, label:"hl:float"}` when there is
   no floating tab yet. **To dock it:** `pane.move` into a strip tab. herdr
   closes the floating tab when its last pane leaves (tested). The
   `terminal_id` stays the same, so the stream and the cached view survive.
6. **macOS and iPad:** the card floats inside the main window, above the strip
   and the zoom overlay. It is not a separate `NSPanel`: a second window that
   opens terminal streams breaks D24. **iPhone:** no floating. The floating tab
   shows as one more tab named "Floating".
7. **⌥⌘F** shows or hides the selected workspace's floating panes. If there
   are none, it opens the new-pane picker and the new pane floats. The "⧉ n"
   button at the end of the tab bar does the same, and you can drop a card on it.
8. Every existing rule is unchanged. D7 (one controller per pane), D12 (no
   focus calls), D10 (zoom is the app's), the status area, chat view and pills
   all work, because a floating pane is just a pane.

---

## 1. What floats in herdr 0.9.3

### 1.1 The three "floating" placements

`plugin.pane.open` accepts `placement` = `overlay` (the default), `popup`,
`split`, `tab` or `zoomed` (schema `PluginPanePlacement`;
`src/api/schema/plugins.rs:441`). Custom-command keybindings in the herdr TUI
have matching types: `type = "popup"` and `type = "pane"` (a temporary zoomed
pane) (`src/config/keybinds.rs:112`).

| Placement | What it really is | In snapshot | `pane_id` / `terminal_id` | Saved across restart | Events | Moves herdr focus |
|---|---|---|---|---|---|---|
| `popup` | a single terminal for the whole server, drawn as a centred box (`AppState.popup_pane`) | **no** | no public `pane_id`; `terminal_id` only on the private client socket | **no** | **none** | no, but it is modal for TUI clients on its owner tab |
| `overlay` | a split of herdr's **focused** pane, then that tab gets `zoomed = true`; when its process exits, herdr restores the old focus and zoom (`App.overlay_panes`, kept in memory) | yes, a normal pane; `layouts[].zoomed: true` | yes, both | the pane is saved like any pane; the "restore when done" record is not | `pane.created`, `layout.updated`, `pane.focused`, `tab.focused`, `workspace.focused` (live test) | **yes** |
| `zoomed` | a split of `target_pane_id`, then the tab is zoomed; it stays open | yes; `zoomed: true` | yes, both | yes | as for a split, plus focus | **yes** (`src/app/api/plugins/panes.rs:119-160`) |

Facts from the live test on 0.9.3:
- `plugin.pane.open {placement:"popup"}` returned `{"type":"ok"}`, with no pane
  information. The snapshot and `pane.list` did not change. The event stream
  (workspace, tab, pane, layout and focus events) sent nothing.
- A second popup open returned `ui_busy` "a popup pane is already open".
- `popup.close` returned `ok`. A second `popup.close` returned
  `popup_not_open`.
- An overlay open returned `plugin_pane_opened` with a full pane (`w1:p4`,
  `label: "Ov"`, which is the manifest pane's `title`). The snapshot showed
  `zoomed: true` and `focused_pane_id` = the overlay. `pane.move` of the
  overlay returned `changed:false, reason:"zoomed_tab"`.
- A popup placement with `width` on a non-popup placement returns
  `invalid_params` "width and height are only supported when placement is
  popup".

### 1.2 The popup in detail (source)

- **One per server.** `spawn_popup_command` refuses with "popup already open"
  (`src/app/popup.rs:116`).
- **Context is herdr's focus.** It uses `state.active` (herdr's focused
  workspace), its active tab and focused pane for the cwd (`popup.rs:119-136`).
  `overlay` and `popup` refuse `workspace_id`, `target_pane_id` and
  `direction`: "overlay and popup plugin panes target the active pane"
  (`src/app/api/plugins/mod.rs:505-515`).
- **Size:** `width` and `height` are cells or `"N%"` of the terminal area,
  including the border. The default is half the area, at least 6×4, and the
  box is centred (`src/popup_size.rs:50-80`).
- **Agents are never detected in it.** It is spawned with
  `AgentDetection::Disabled` (`popup.rs:54, 85`).
- **Owner tab.** The server remembers `popup_owner_tab_id`: the tab of the TUI
  client that opened it, or the default shell target. Only TUI clients on that
  tab see it. Their pane input and clipboard paste are blocked while it is open
  (`src/server/headless.rs:1189, 2000, 2379`). If the owner tab closes, herdr
  closes the popup (`src/server/headless/client_views.rs:128-141`).
- **Closes** when its process exits (`PaneDied` → `close_popup_pane`,
  `src/app/api.rs:209-218`), on `popup.close` (`api.rs:1209`), or when its owner
  tab goes away.
- **Not saved.** `src/persist/` has no popup state. herdr's docs say: "A popup
  is a singleton session resource rather than a Herdr pane: it has no pane ID,
  … emits no pane lifecycle events, and does not participate in pane, layout,
  persistence, or agent APIs" (`docs/next/website/src/content/docs/plugins.mdx:332`,
  also https://herdr.dev/docs/plugins/ and https://herdr.dev/docs/socket-api/).
- Added in herdr 0.7.4: "session-modal popup floating terminal panes for
  `type = "popup"` custom command keybindings and plugin panes" (CHANGELOG,
  #1125).

### 1.3 How the herdr TUI draws it
The TUI composites the popup over the tiled tab as a bordered box at
`resolve_popup_geometry(width, height, terminal_area)`. While a direct attach
holds the popup terminal, the box resizes its PTY only if no resize lock is set
(`src/ui/panes.rs:524-550`). Toasts and Kitty images are cropped around the box
(CHANGELOG 0.9.x). On the private client protocol the popup arrives as
`PaneSurfaceFrame.popup: ClientShellPopupSurface {terminal_id, title, width,
height, frame, …}`, and input goes back as `ClientShellPopupInput {terminal_id,
events}` (herdr-gpui's copy of the protocol:
`crates/herdr-protocol/src/wire.rs:188, 544-580`).

### 1.4 Can `herdr terminal session control/observe` target a popup?
- **Yes, if you know its `terminal_id`.** The server looks the target up in
  `state.terminals`, and that map holds the popup terminal
  (`terminal_id_by_string`, `src/server/headless.rs:1079-1104`). herdr's own
  invariant check says the popup terminal is in `terminals` but not attached to
  a tiled pane (`src/app/state.rs:1290`). `resize_popup_pane` honours
  `direct_attach_resize_locks`, so a `control` stream keeps our size.
  roamgate does exactly this: "the popup terminal uses direct attach"
  (`roamgate/docs/ARCHITECTURE.md:103`).
- **But the public API never gives that id.** `plugin.pane.open` returns
  `ok`, the snapshot leaves it out, no event carries it, and ids are
  `term_<micros><counter>` (`src/terminal/id.rs:16`), so it cannot be guessed.
  Not tried live, for this reason.

### 1.5 Events
None for popups. The event list (`src/api/schema/events.rs`) has no
popup or overlay kind. Overlays send the normal pane, layout and focus events.

---

## 2. What others do

### 2.1 herdr plugins that "float"
| Plugin | How | Persistence |
|---|---|---|
| **Tyru5/herdr-floax** (`d6b2831`, targets herdr 0.7.1) | No popup existed then. Its toggle action opens a `split` plugin pane labelled `⌂ floax`, then calls `pane zoom --on`. A Rust TUI inside it draws a centred box over a solid backdrop and hosts a shell PTY. It finds "its" pane by label in the workspace: none → open; open but not focused → `pane zoom --on`; focused → `plugin pane close`. The README says overlay/zoomed "vanish when opened from a keybinding action" on 0.7.1 (**not checked on 0.9.3**; the live overlay above stayed open) | the shell runs inside `dtach`/`abduco`/`tmux`, one session per workspace (`scripts/floating-shell.sh`), so closing the pane only detaches |
| **meerzulee/herdr-float** (`6301b7e`, ≥0.7.4) | native `placement = "popup"`, 86%×82%; the toggle action checks that herdr's focused workspace is the one asked for, otherwise "Space changed" | one tmux session per Space; a `workspace.closed` event hook cleans up |
| **jeromychu23/herdr-popupx** (`84a5ea3`) | popup, 85%×80%, workspace or session scope | its own detach helper |
| **maro114510/herdr-toggle-popup** (`a34d8c6`, ≥0.9.0) | popup 100%×100% plus tmux | tmux |
| **coryshaw1/herdr-cliamp** (`8963932`) | popup that runs `herdr --session cliamp attach`: a hidden herdr session holds the player | the hidden herdr session |

The lesson: herdr's popup is short-lived by design. Every "persistent float"
plugin keeps its state in a second multiplexer (tmux, dtach, or a hidden herdr
session) behind the popup. herdr-floax shows the other way: a **real pane found
by a label marker**. That pane is persistent, movable and agent-detectable.

### 2.2 Other clients
| Client | Popups | Overlays / zoom |
|---|---|---|
| **herdr-gpui** (`3871183`) | Speaks the private client protocol, so it gets `surface.popup` and paints it centred over the grid (`window/render.rs:459`, `terminal.rs:66-125`). Input goes to the popup, and pane menus, find, copy mode and splits turn off while one is open | herdr's server-drawn layout, zoom included |
| **roamgate** / herdr-studio (`4476392`) | Keeps one extra private-socket "endpoint observer" open only to learn popup identity. It calls `workspace.focus` so the popup follows the browser's Space (`server/src/bridge/terminal-bridge.ts:290-360`). It draws `PopupOverlay.tsx` (xterm.js) sized from herdr's cells-or-percent, streams the popup over direct attach, and closes it with `popup.close`. Its toggle tries `popup.close` first and invokes the `herdr-float` action on `popup_not_open` (`web/src/store.ts:3912-3960`) | normal panes |
| **bigtty** (`2c20e1f`) | none | follows herdr's `layout.zoomed` and shows herdr's focused pane full size (`MainWindowController.swift:533`) |
| **herdr-web-ui** (`4f074f4`) | none | normal panes |

Nobody shows herdr popups through the public API, because they cannot.

---

## 3. Design for Herdlight

### 3.1 herdr-originated popups and overlays
- **Overlay, zoomed, and `type = "pane"` commands** are real panes in the
  snapshot. The app draws them as normal cards in their tab and ignores
  herdr's zoom flag (D10). They go away by themselves when their process exits.
  While that tab is zoomed in herdr, a move into or out of it returns
  `zoomed_tab`, which the app already shows in words (§5.8). No new code.
  The app does not try to float them: herdr does not expose which panes are
  overlays (`overlay_panes` is internal), and a title match would be a guess.
- **Popups:** not shown in v1, because no public call reveals one. They do not
  affect the app. Our `terminal session` streams are direct attaches, and the
  input block only applies to TUI clients on the popup's owner tab (source,
  `headless.rs:1189`; not tested live).
- **The app never opens herdr popups or overlays.** Both act on herdr's
  focused tab, and overlay moves herdr's focus (D12). §10.4.2 already says the
  app always opens herdr plugin panes as `split` or `tab`, whatever the
  manifest says. That also covers floating: see §3.3.
- **Later, if herdr adds it** (a small upstream request): `session.snapshot.popup
  = {terminal_id, title, width, height, owner_tab_id} | null`, plus any event
  (for example `layout.updated`) when it opens or closes. The app would then
  draw a modal floating card over the owner tab, sized from `width`/`height`
  against the strip, streamed with `terminal session control <terminal_id>`
  (this works today). ✕ would call `popup.close`. It could not dock, because it
  has no `pane_id`. About 40 lines. Rejected until then: the private client
  socket (D6, D20) and roamgate's focus-following observer (D12).

### 3.2 Where a user-created floating pane lives
**In a floating tab:** a normal herdr tab in the workspace whose label is
exactly `hl:float`. Every pane in any tab with that label floats.

| Option | Verdict |
|---|---|
| **herdr popup** | reject. One per server, no `pane_id`, not in snapshot, not saved, no agent detection, opened only from plugin entrypoints against herdr's focused tab, and modal on herdr TUI screens |
| **pane label marker** (`float:` …) | reject. The pane label already holds the `web:`/`hl:` marker or the user's own label. A web page or plugin pane could not float |
| **metadata token** | reject. Lost on restart, 80 characters (§10.3) |
| **app-side list of floating `terminal_id`s** | reject. Breaks D1. Ids change on a cold restart. Other devices would not agree |
| **a tab labelled `hl:float`** | **chosen**. One marker per workspace. Any pane kind can float. herdr saves the tab label, panes and labels (tested across a cold restart). `pane.move` keeps `terminal_id`. Every device and the herdr TUI see the same thing |

- The `hl:` prefix stops a user's own tab label from turning into a floating
  tab by accident (the same rule as §10.4.4). `float` joins `web` as a reserved
  plugin id.
- herdr TUI users see one more tab, "hl:float", with the floating panes as
  splits. That is honest: it is where they live. They can use the panes there.
- If two devices both create a floating tab, both tabs float. No dedupe is
  needed. If a herdr TUI user renames the tab, its panes simply show as docked.
- Scope is per workspace, like herdr-float's "per Space". A floating pane shows
  over any tab of its workspace.

### 3.3 herdr calls

| User action | herdr call (all with `focus:false`, herdr's default) |
|---|---|
| New floating terminal, no floating tab yet | `tab.create {workspace_id, cwd, label:"hl:float"}` |
| New floating terminal, floating tab exists | `pane.split {target_pane_id: <any pane in it>, direction:"right"}` |
| New floating agent | the row above, then `agent.start` in the new pane (§10.2) |
| New floating web page or app plugin | the row above, then rename, placeholder and `hl_rev` token (§10.3, §10.4.4) |
| New floating herdr TUI plugin pane | first: `plugin.pane.open {placement:"tab", workspace_id}` then `tab.rename {label:"hl:float"}`; after that: `plugin.pane.open {placement:"split", target_pane_id: <a floating pane>}` |
| Float a docked pane (card menu **Float**, or drop on the "⧉" button) | `pane.move {pane_id, destination:{type:"tab", tab_id: <floating tab>, split:"right"}}`, or with no floating tab `pane.move {pane_id, destination:{type:"new_tab", workspace_id, label:"hl:float"}}` |
| Dock a floating pane (card menu **Move to tab ▸**, or drag its header onto a tab capsule or a card edge) | the existing §7.7 rows: `pane.move {destination:{type:"tab", tab_id, split, target_pane_id}}` |
| Close | `pane.close` (asks first if an agent is working) |

Live facts (0.9.3, throwaway server):
- `tab.create {label:"hl:float"}` returns the tab and its `root_pane` in one
  reply.
- Moving the only pane out of the floating tab closes that tab (`w1:t2` was
  gone).
- `pane.move {type:"new_tab", workspace_id, label:"hl:float"}` makes the
  floating tab and moves the pane in one call. `focused_tab_id` did not change.
- After `server.stop` and a fresh start, the `hl:float` tab and its pane came
  back. The `terminal_id`s were new, as already known (§14.5).

### 3.4 How it looks (macOS, iPad in regular width)
```
┌─────────────┬──────────────────────────────────────────────────────────────┐
│ sidebar     │  (>_ api) (✳ fix-auth) (π docs)               +   ⧉ 2       │ ← "⧉ n" = floating panes
│             │ ┌─ ✳ claude ───────────────────┐┌─ >_ zsh ───────────────┐  │   in this workspace
│             │ │                ┌─ >_ scratch ─────────── ⤓ ⤢ ✕ ┐       │  │
│             │ │                │ $ git log --oneline           │       │  │ ← floating card:
│             │ │                │ a1b2c3 fix auth               │       │  │   opaque, shadow,
│             │ │                │                               │◢      │  │   drag header, resize corner
│             │ └────────────────└───────────────────────────────┘───────┘  │
└─────────────┴──────────────────────────────────────────────────────────────┘
```
- **Inside the main window**, as a SwiftUI overlay on the detail column under
  the tab bar. Order from bottom to top: strip, zoom overlay, floating cards.
  A scratch terminal over a zoomed agent is the main use.
- **Not an `NSPanel`.** A second window that streams terminals breaks D24's
  "one window" rule (two key windows would fight over the same panes). It
  would also need its own registry handoff and window restoration. The pill
  panel is different: it opens no streams. Simpler choice: add "Pop out" to a
  window when someone asks.
- **Card:** the normal pane card (header, chat|term switch, zoom, ✕) plus a
  **Dock** button (⤓), which moves it into the selected tab, split right of the
  pane that has keyboard focus. It has a shadow, a 1 pt border and a corner
  resize grip. Drag the header to move it. Drag the header onto a tab capsule
  or a card edge to dock there (§5.4 drop rules). Clicking a card brings it to
  the front.
- **Size and position: client-side, in memory**, keyed by `(host,
  terminal_id)`. The default is centred, 70% × 75% of the strip, with each
  extra card 24 pt down and to the right. Cards are kept inside the strip when
  the window resizes. When a drag or resize ends, the card sends
  `terminal.resize` like any card (§7.6). Nothing is saved. After an app
  restart, cards come back at the default spot. Simpler choice: save frames in
  `@SceneStorage` keyed by pane label if people ask (terminal ids change on a
  herdr restart).
- **Shown or hidden: client-side, in memory, per (host, workspace).** After
  launch they start hidden, and the "⧉ n" button shows the count. A newly
  created or newly floated pane shows at once. Hide does not close: the process
  keeps running in herdr.
- **⌥⌘F** (menu Pane ▸ Show/Hide Floating Panes):
  - floating panes hidden → show them, and keyboard focus goes to the top card;
  - shown → hide them, and keyboard focus goes back to the strip card that
    last had it;
  - none in this workspace → open the new-pane picker (§10) with Terminal
    already selected. Return makes a floating scratch terminal.

  It is a Command chord, so it never reaches the terminal. Menu shortcuts go
  first (§14.3), and users can rebind it in System Settings › Keyboard ›
  App Shortcuts. The "⧉ n" button does the same and is a drop target for
  **Float**.
- **The strip:** the floating tab is not a tab page. It is left out of the tab
  bar, the strip, ⌘1…⌘9 and the lit-tab maths. Selecting another tab or
  swiping does not move the floating cards. Selecting another workspace shows
  that workspace's floating panes, if that workspace has them shown.
- **Scroll routing:** a gesture that starts on a floating card goes to that
  card, never to the strip (the §14.3 monitor checks "starts in the strip"
  against the floating card frames first).
- **Sidebar and status:** floating agents are listed under their workspace like
  any agent, with a small ⧉ badge. Clicking the row (or a status-area row, a
  notification, or a pill's **Open in app**) shows the floating panes and
  focuses that card.

### 3.5 iPhone (compact width)
No floating. The floating tab shows as one more tab, labelled "Floating" with
⧉, after the other tabs of the workspace. Its panes are phone pages like any
other (§5.6). **Float** and **Move to tab** stay in the card menu. This is zero
new code: the floating tab is just a tab, and only its display name changes.

### 3.6 Rules it keeps
- **D1 / §13:** herdr holds which panes float (the tab label), their content,
  their order and their lifetime. The app holds only the card frames, the
  shown/hidden flag and the z-order, all in memory.
- **D7 one control rule:** a shown floating card opens its stream as
  `control` without takeover, watches if refused, and takes over on the first
  key, click or "Take back". The same code as every card. A hidden card sends
  `terminal.release` and closes its stream.
- **D10 zoom:** zoom stays one `zoomed: terminal_id?`. Zooming a floating card
  draws it in the zoom overlay. Un-zooming puts it back at its floating frame.
  herdr's zoom flag on the floating tab is ignored, except that moves are
  refused with `zoomed_tab`, which the app shows.
- **D12:** no focus calls. Every create and move above passes `focus:false`.
  `tab.rename` and `plugin.pane.open {placement:"tab"|"split"}` do not move
  focus (source, `open_plugin_tab`/`open_plugin_split_pane` switch tabs only
  when `focus` is true or the placement is `zoomed`).
- **Streams (§7.6, §8.4):** the panes of the selected tab **plus the shown
  floating cards** of the selected workspace on the selected host. Add one line
  to the channel budget.
- **Registry (§14.3):** a pane that moves between the strip and the floating
  layer keeps its `(host, terminal_id)`, so the PaneViewRegistry's "newest
  container adopts the view" rule hands the surface over with no reload.
- **Seen:** a shown floating agent card in the key window counts as "looking
  at that pane" (§9.6, §12.1).
- **herdr TUI:** sees an ordinary tab. Nothing in herdr changes.

### 3.7 Multiple floating panes and restarts
- Many floating panes means many panes in the `hl:float` tab. herdr keeps them
  as splits there, which only herdr TUI users see. The app draws each one as
  its own card and ignores that tab's split tree and ratios. While we control a
  pane, its PTY follows our card size (§9.5).
- herdr restart: the tab and its panes come back. Shells come back as shells.
  Agents come back the way herdr restores agents. `web:`/`hl:` labels survive
  (§10.3).
- App restart: the floating panes are still in herdr, hidden, with the count on
  "⧉ n" and default frames.

### 3.8 Simpler choices
- No floating across workspaces or hosts. A floating pane belongs to one
  workspace. Use **Move to ▸** to take it elsewhere.
- No saved frames, no saved shown state, and no separate window.
- No showing herdr popups until herdr puts them in the snapshot.
- No snapping, tiling or minimising of floating cards.

---

## 4. Changes to DESIGN.md (proposal)
- §0: add item 12, "Floating panes: panes in a workspace tab labelled
  `hl:float` float as cards above the strip (macOS, iPad). ⌥⌘F shows or hides
  them. herdr popups are not shown until herdr reports them."
- §5: new §5.10 "Floating panes" = §3.4 and §3.5 above. §5.4: add "drop on the
  ⧉ button → float". §5.5: add the z-order line.
- §7.7: add the rows from §3.3.
- §8.4 and §7.6 "Which panes stream": add "+ shown floating cards".
- §10.4.2 L0: add that floating herdr plugin panes use `placement:"tab"` and
  `"split"` into the floating tab, never `popup` or `overlay`.
- §13: add rows "Which panes float | herdr | tab label `hl:float`" and
  "Floating card frames, shown/hidden, z-order | app | memory".
- §15: **D41** "Floating panes live in a tab labelled `hl:float` per workspace;
  float and dock = `pane.move`; card frames and visibility are the app's own,
  in memory." Rejected: herdr popup, pane label marker, metadata token, an
  app-side list. **D42** "Floating cards draw inside the main window above the
  strip and zoom; no `NSPanel`; iPhone shows the floating tab as a tab."
  Rejected: an `NSPanel` per card (D24), a floating sheet on iPhone. **D43**
  "herdr popups are not shown until `session.snapshot` reports them; never the
  private socket." Rejected: roamgate's observer (D6, D20, D12).
- §16 risks: "A herdr TUI user renames or splits the floating tab | panes dock
  or appear | accepted; self-healing."
- §17 spike **S6 floating card:** one libghostty surface in a draggable,
  resizable overlay card above the S1 strip. Pass if it moves between the strip
  and the floating layer without a reload (registry handoff), a scroll that
  starts on the card never pages the strip, `terminal.resize` is sent only when
  a resize ends, and ⌥⌘F reaches the menu while the terminal has focus.
