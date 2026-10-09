# Phase 4b: actions (close, zoom, new tab/workspace/session, palette)

Goal: the placeholder controls from 3b work, plus the actions the user asked for after
testing. Everything is a herdr call followed by a snapshot read (never patch state by hand),
creates pass `focus:false`, and closes ask first.

Read first: `docs/content/docs/talking-to-herdr.mdx` ("Writes are herdr calls"),
`docs/content/docs/ui/window.mdx` (zoom), `docs/content/docs/layout.mdx` (zoom is the
app's own), decisions D11, D39, D41.

## Build

1. **Close pane** (card header ×, ⌘W): `pane.close`. Ask first unless the pane's only
   foreground process is its shell (`pane.process_info`, D41).
2. **Zoom pane** (card header button, ⇧⌘↩, double-click the header): the app's own zoom
   (D11): the card fills the whole strip page as if it were the only pane; same button or
   keys restore. Its terminal resizes to the zoomed size; the others keep theirs. Never
   `pane.zoom`.
3. **New tab**: the title-bar `+` and ⌘T: `tab.create {workspace_id, cwd}` with the cwd of
   the keyboard card; select the new tab once the snapshot shows it.
4. **Close tab**: an × on hover on each tab row in the sidebar and each title-bar capsule
   (it takes the capsule's single status slot while hovered, gorex order). Always asks,
   with the pane count (D41). `tab.close`.
5. **New workspace**: a `+` in the sidebar (e.g. at the right of the bottom bar or the
   top): `workspace.create {cwd: $HOME}`; select it once it appears.
6. **Session picker**:
   - show running sessions only by default, with a small toggle ("Show stopped") that
     reveals stopped ones (dimmed, not selectable, or selectable = starts them, see 7);
   - **New Session** (row and ⇧⌘N) and "Filter or create…" + Enter with a name that does
     not exist create a session and switch to it. A name is required for the row: generate
     a readable two-word name (like the references: `lunar-ridge`) when none is typed.
7. **Starting a session server** (amends D39). D39 forbade starting herdr from the app
   because the app would become the macOS "responsible process" for every agent (privacy
   prompts would name Herdlight) and share its process group. Start it so launchd, not
   the app, is the parent and responsible process: research the simplest reliable way
   (e.g. `launchctl` with a one-shot job, no KeepAlive) and verify with a throwaway
   session that the server's parent is launchd and that it survives the app quitting.
   If nothing clean works, open a Terminal window running `herdr --session <name>` and
   record why. Record the outcome as a new decision amending D39.
8. **Command palette** (the title-bar ⌘ button and ⌘K): a centered floating glass panel
   with a search field listing sessions, workspaces and tabs (and later actions);
   type to filter, arrows to move, Enter to jump, Esc to close. Reuse the session picker's
   filter and row styles.
9. **e2e** for each: close pane (shell-only, no prompt) removes the card; close tab asks and
   removes it; + makes a tab and selects it; + workspace appears and is selected; zoom
   fills the page and restores; new session appears in the picker and is selected (then
   deleted by the test); the palette filters and jumps to a tab; "Show stopped" toggles.

## Done when

- e2e green locally and in CI; screenshots of the confirmation dialogs, zoom, palette.
- Decisions recorded (D39 amendment, palette shortcut).

## Findings

- **Writes.** One `HostStore.write`: the herdr call, then `refresh()`; a failure is the 4 s notice.
  `workspace.create` and `tab.create` return the new tab (`Created`); the store selects it in the
  first snapshot that has it, never by hand. Closing a tab's last pane closes the tab, and the
  last tab closes the workspace (herdr 0.9.3); the snapshot shows it.
- **Close pane (D41).** `pane.process_info` lists the foreground process group. Only the shell
  there = close at once; anything else asks "Close ‹title›? ‹program› is running…". While a new
  shell starts, its rc files (e.g. `brew shellenv`) are in the foreground too, so a close right
  after a split may ask once. A program the shell `exec`ed keeps the shell's pid, so the shell's
  pid counts as "only the shell" only while it is still a shell (argv0 `-zsh`, or a shell name).
  A write while another is in flight shows "Busy, try again" instead of dropping it. A failed check asks. Native `.confirmationDialog` (a sheet with
  Cancel), one per window, driven by `HostStore.closing`.
- **Zoom (D11).** `HostStore.zoomedPaneID`, in memory. Each split above the zoomed card swaps its
  `AnyLayout` to a `ZStackLayout`: the zoomed side at full size, the other side hidden at the size
  it has without zoom (`SplitLayout.natural`, so a hidden card deeper in the tree does not grow
  with its zoomed parent). Hidden cards leave the accessibility tree through an environment
  value; `accessibilityHidden` on the hidden side did not reach a card nested in a split. The views keep their identity, so no terminal view changes host; the zoomed PTY resizes
  to the page and the hidden ones keep theirs (checked with `stty size`: 58×89 → 58×181 → 58×89,
  the neighbor 58×89 throughout; the e2e test checks a nested neighbor too). A first version drew the zoomed card in its own branch
  (`if zoomed … else SplitLayout`): SwiftUI kept the split branch's hosts alive, so on restore
  the terminal view stayed in the zoom branch's host and the split card came back blank at the
  zoomed PTY size. The zoomed card gets the keyboard. Header button, a double-click on the
  header (a background, so the header buttons keep their clicks), ⇧⌘↩ (View ▸ Zoom Pane). Esc
  is not used.
- **Menu commands** read the window's store through `focusedSceneValue(\.store)`, so ⌘T, ⇧⌘N,
  ⌘W and ⇧⌘↩ work while a terminal has the keyboard. File ▸ Close is replaced: ⌘W closes the
  keyboard card (herdr's focused pane of the tab when no terminal has the keyboard), ⇧⌘W the
  window (design keyboard table). ⌘K is on the title-bar ⌘ button.
- **Starting a server (D47, amends D39).** `launchctl submit` keeps its job alive: after
  `herdr session stop` launchd restarted the server within 10 s (`runs = 2`). A plist loaded
  with `launchctl bootstrap gui/<uid>` (`RunAtLoad`, no `KeepAlive`) works: the server's parent
  is launchd (ppid 1), it has its own process group, `responsibility_get_pid_responsible_for_pid`
  gives the server itself (pane shells give the server; a shell from a terminal gives the
  terminal app), and after `herdr session stop` the job stays loaded with `state = not running`.
  A label loads once, so the app boots out an old job of that label first, unless the server
  already answers `ping`. The job runs with `ProcessType` `Interactive` (launchd's default
  throttles CPU and I/O for the server and every agent in it) and logs stderr to
  `~/Library/Logs/Herdlight/<session>.log`. Session names are checked against herdr's rule
  (ASCII letters, digits, `.`, `_`, `-`; at most 64 bytes; not `.` or `..`) before they reach the
  label or a path. A launchd server
  gets launchd's small environment; herdr's panes still run login shells (PATH from the
  profile) and herdr sets `LANG=C.UTF-8`. `scripts/herdr-session.sh down` boots the job out.
- **Session picker.** Running sessions only; "Show stopped" (a checkbox in the "This Mac"
  header) adds stopped ones, dimmed, and picking one starts it. Enter picks the first match;
  with no match it creates the typed name. The New Session row reads "New Session “name”" when
  the typed text is a valid new name (herdr: ASCII letters, digits, `.`, `_`, `-`), else it makes
  a two-word name (`lunar-ridge`). A new server gets one workspace in `$HOME`. The "not running"
  page has a **Start** button.
- **Palette (D48).** ⌘K or the ⌘ button: tabs, then workspaces, then the other running sessions;
  filter on the title and a tab's workspace, arrows, Enter, Esc, click outside.
  `onKeyPress` on the filter field gets the arrows. Rows share `MenuRow` with the session list.
- **Sidebar.** The bottom bar's first icon is now New Workspace (`workspace.create {cwd: $HOME}`);
  New Session lives in the picker and ⇧⌘N.
- **Strip bug seen (not fixed here, phase 5's area):** picking a tab of another workspace in the
  sidebar selects it, but the new strip opens at the workspace's first page (`scrollPosition` on
  a strip made with `.id(workspace.id)`). The old split test only passed because XCUITest's
  `hover()` on an off-screen card scrolled it into view. Tests that click a new tab make it in
  the selected workspace.
- **Review round 2.**
  - A TextField keeps the `onSubmit` action of its first draw, so after ↓ Enter jumped to the
    first row. Enter is an `onKeyPress(.return)` next to the arrows, reading the current index.
  - A first responder set during a SwiftUI update is undone: after a palette jump or a new
    workspace no card had the keyboard. `takeKeyboard` asks on the next turn of the run loop;
    only the latest request wins. `focusKeyboardCard` makes the target's terminal if its card
    has not drawn yet, so it takes the keyboard once it is in the window.
  - The one strip for all workspaces sometimes stayed blank after + workspace (seen by the
    reviewer, not here): a scroll to the new workspace's page in the same update as its pages
    can miss. The strip uses a `ScrollPosition` and scrolls once more in a `Task` after a
    workspace switch. The new-workspace e2e test hides and shows the sidebar first and checks
    the card takes keys.
  - ⌘T asks herdr for the keyboard card's cwd (`pane.get`): a `cd` sends no event, so the
    snapshot's cwd can be old.
  - The session list lights the row Enter picks while a filter is typed; the tab commands get
    their own focused value (nil while the list is open), so ⇧⌘N works there.
- **e2e.** Hover a card's header, not its center: XCUITest moves the pointer straight into the
  terminal view, which takes the mouse moves, so SwiftUI never sees the hover. A container's
  `accessibilityIdentifier` is copied onto its children (the palette's field lost its id). The
  close dialogs are `app.sheets`. `scripts/e2e.sh` adds a stopped session (for "Show stopped")
  and the name New Session makes; both are removed after.
