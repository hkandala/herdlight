# Phase 3: app shell (sidebar, tabs, strip, splits)

Goal: the app opens on the `default` session (or the `-session` launch argument) and shows
herdr's workspaces, tabs and split layouts live, with placeholder pane cards. Changes made
in herdr show up within a second.

Read first: [ui/window](../../docs/content/docs/ui/window.mdx),
[layout](../../docs/content/docs/layout.mdx),
[platform: tab bar and Liquid Glass](../../docs/content/docs/platform.mdx),
[theme](../../docs/content/docs/ui/theme-and-accessibility.mdx),
`resources/research/gorex.md` (tab capsule behavior).

## Build

1. **`HostStore`** (`@Observable`, main actor): owns one `HerdrClient`, applies each
   snapshot to stable `Workspace`/`Tab`/`Pane` objects keyed by id, setting only changed
   fields (design D6). Holds the app's own selection (workspace, tab), defaulting to
   herdr's focused workspace and its active tab. Never calls herdr focus methods.
   Connection state (connecting, live, error with message) for the UI.
2. **Session picker** at the top of the sidebar: a glass menu listing `herdr session list`
   (running ones selectable; stopped ones shown disabled), default `default`, overridable
   with `-session <name>`. Switching tears down the old HostStore and builds a new one.
   Label "This Mac" for `default`, "This Mac · ‹session›" otherwise.
3. **Sidebar** (`NavigationSplitView`, system glass): workspaces in herdr's order with
   label and an agent status glyph (◔ working, ▲ needs you; static). Clicking selects it
   in the app only. Keep it this simple for v0: no agent rows, no status area.
4. **Tab bar**: top of the detail column, one glass capsule per tab of the selected
   workspace in a horizontal `ScrollView` inside a `GlassEffectContainer`, one status
   slot (▲ > ◔), selected capsule marked with glass. Clicking selects. Window title = the
   selected tab's label. Try the design's `ToolbarItem` +
   `.sharedBackgroundVisibility(.hidden)` first; if the toolbar squeezes it, fall back to
   the top of the detail column (design spike S2) and note which one you kept.
5. **Strip**: a horizontal paged `ScrollView` (`scrollTargetBehavior(.paging)`), one page
   per tab of the selected workspace, bound to the selected tab both ways (`scrollPosition`).
   Swiping by trackpad comes in phase 5; here make sure clicking a tab scrolls to its page.
6. **Split layout**: each page draws the tab's `SplitNode` with ratios and an 8 pt gap.
   Leaves are opaque dark **placeholder cards** showing the pane label and id (phase 4
   puts terminals in them). No divider dragging.
7. **States**: connecting, herdr not found / too old, session not running, empty session.
   Plain text with the command to run (design D39: the app never starts herdr on This Mac).
8. **Accessibility identifiers** on the session picker, each workspace row, each tab
   capsule, each strip page and each pane card.
9. **e2e helper**: the XCUITest runner is sandboxed (phase 1 findings) and cannot reach
   herdr, but it can make network client connections. `make e2e` starts a tiny localhost
   helper outside the sandbox (stdlib only, e.g. `python3 -m`-style `http.server`, ~30
   lines) that runs `herdr --session <the hl-e2e session> <args>` for the test and returns
   stdout. It refuses any other session, binds 127.0.0.1 on a random port passed in as
   `TEST_RUNNER_HL_HELPER`, and dies with the e2e run. Tests use it to build layouts,
   make changes mid-test and check results (`session.snapshot`, `pane.read`). If you find
   something simpler that works, use it and record why.
10. **e2e** (`HerdlightUITests`): against a throwaway session built with a known layout
   (2 workspaces; one tab with a right split whose second child splits down; a second
   tab):
   - the sidebar lists both workspaces; the tab bar shows the tabs;
   - the selected tab shows 3 pane cards, and their frames match the ratios roughly
     (right split: first card left of the others; down split: stacked);
   - clicking the second tab shows its page; clicking the second workspace switches tabs;
   - a tab created through herdr while the app runs appears in the tab bar within 2 s;
     a closed one disappears;
   - the session picker lists the throwaway session; switching sessions works (use two
     throwaway sessions).

## Done when

- e2e green locally and in CI; screenshots of the window reviewed by the orchestrator.
- Looks like herdr's layout for the same session (compare with `herdr` TUI or the
  snapshot), dark, glass on chrome only.

## Out of scope

Terminals, trackpad paging, divider drag, splits/close/new-tab actions, zoom.

## Findings

- **Tab bar placement: top of the detail column** (spike S2 fallback). As a `ToolbarItem` with
  `.sharedBackgroundVisibility(.hidden)` the bar shows while its tabs fit, but the toolbar
  sizes an item to its ideal width: with 10 tabs the whole item vanished (moved to overflow),
  and a flexible frame (`minWidth`, `maxWidth: .infinity`) did not make it fill the free
  space; it stayed at its minimum. Only a fixed width worked. So the window uses
  `.windowStyle(.hiddenTitleBar)` and the bar is the first row of the detail column, pulled
  into the title bar line with `.ignoresSafeArea(edges: .top)`, with `WindowDragGesture` on
  its empty space. The system sidebar toggle stays in the sidebar's toolbar; clicks on the
  capsules under the (empty) detail toolbar area reach them (e2e clicks them).
- **Observation skips equal values.** With Xcode 27, assigning an equal value to an
  `@Observable` property does not notify (checked with `withObservationTracking`), so
  `HostStore` assigns fields plainly; only the object lists compare ids before replacing.
- **Strip and resizing.** `scrollPosition(id:anchor: .leading)` keeps the selected page in
  place when the detail column changes width. Without the anchor a launch once showed the
  strip half a page off and wrote the wrong tab back into the selection.
- **e2e helper.** `scripts/e2e-helper.py` (stdlib `http.server`) takes one API request line
  per `POST /<session>` and pipes it to `herdr --session <session> remote-api-bridge`. It
  serves only the two sessions `make e2e` made (`scripts/e2e.sh`: `hl-e2e-<id>-a` and `-b`;
  the second one is for the session switch). It binds 127.0.0.1 on a random port and is
  killed by the script's exit trap. Tests reach it as `HL_HELPER`.
- **Accessibility.** An identifier set on a container also lands on the first control in
  `safeAreaInset` content (the session picker got the List's `sidebar` id), so only leaf
  elements carry identifiers. Rows combine their text: a workspace row's text is its
  `value`, not its `label`.
- **The sidebar.** `NavigationSplitView`'s sidebar on macOS 27.0.1 draws full height, not as a
  floating inset panel; it is the system one, unchanged.
- The session list loads when a store starts and again after each error (to tell "not
  running" from other failures); a session started later shows up after the next switch or
  error. Good enough for v0.
- **Lost EOF in `ProcessExec` (HerdrKit bug, fixed).** On CI, `locate` or `sessions()` often
  timed out after 10 s, even though the child (`sh -c …`, `session list`) had exited in
  milliseconds. The pipe's `readabilityHandler` did not keep its `FileHandle` alive. Once a
  fast child's `Process` and `Pipe` were released, the handle went too, and EOF never
  arrived. Now the handler holds the handle until EOF. `terminate` (and a dropped stream)
  also cancels both pipe readers, which clears the handlers, so a grandchild that keeps a
  pipe open cannot keep a handle alive for the app's life. The tests `output of fast
  commands always ends` (30 parallel `sh -c 'echo hi'`) and `terminate stops the readers
  when a grandchild keeps the pipes open` fail without the fix on this Mac. Extra logging in `spawn` hid the bug, so it was found with `os_log`.
- **CI e2e details.** Python's `HTTPServer` calls `getfqdn()`, and that showed a Local
  Network prompt for "Python" on the runner. The helper uses `socketserver.TCPServer`
  instead. After a failed test, Xcode starts a new test runner process, so the layout is
  built when herdr's snapshot has no workspaces, not behind a static flag. `make e2e` passes
  `-default-test-execution-time-allowance 120`, so a hung test fails and keeps its result
  bundle. The first launch on a runner takes up to about 12 s to connect, so the tests wait
  30 s for it.
