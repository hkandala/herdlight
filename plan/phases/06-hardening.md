# Phase 6: hardening and v0 wrap-up

Goal: v0 is solid end to end and documented; CI green; nothing extra.

## Build

1. **Failure paths, each with an e2e test or a recorded manual check**:
   - herdr session stopped while the app runs → clear state, recovers when restarted;
   - a pane closed in herdr while streaming → card disappears, no crash, no zombie
     `herdr` children (`pgrep -f "terminal session"` after quit is empty);
   - another client takes over a pane → card shows "In use elsewhere · Take back"; Take
     back works;
   - switching sessions repeatedly leaks no processes.
2. **Ponytail audit** of the whole app with the ponytail-audit skill; delete what is not
   needed.
3. **Docs**: update the root `README.md` (how to build, run, test; layout of the code),
   `AGENTS.md` (only if a rule changed), and mark build-order step 1's v0 subset done in
   `plan/README.md` with what was deferred.
4. **CI**: all jobs green on `main`; e2e time reasonable (note it).

## Done when

- The orchestrator runs the full e2e suite, plays with the app against a throwaway session
  (and looks at `default` read only), and finds nothing broken.

## Known issues carried in (fix or record)

- **Window restored in full screen** loses the whole title row (no session button,
  sidebar toggle or pills; hovering shows an empty gray bar) until ⌃⌘F twice. Appears
  after quitting while in full screen. `.windowToolbarFullScreenVisibility(.onHover)` only
  takes effect on an enter transition. Fix it (e.g. leave and re-enter full screen once on
  restore, or don't restore full screen) and add a check. See phase 5 findings.
- **IME composition** (marked text, e.g. Japanese kana) was not tested; only committed
  text (Character Viewer) was. Test with an input source if it can be added and removed
  cleanly, otherwise record.
- **Phased trackpad gestures** are covered by hand checks only (e2e covers the wheel path).
- `Package.resolved` `originHash` churns when Xcode resolves in another checkout; make
  sure builds don't leave the tree dirty (or document it).

## Findings

- **Session stopped while the app runs.** The events stream ends, the next read fails, and the app reloads the
  session list first, so it shows "‹session› is not running" with a Start button (not "No answer"). The
  sidebar keeps the last layout until the session is back. The control streams end with the server; nothing is
  left. Recovery was the 30 s `ping`: 14 s measured once, up to 30 s. Now the keep-alive ticks every 2 s and
  pings at every tick while the last read failed, so a session started again in a terminal comes back about
  2 s later (herdr restores its workspaces; terminal ids are new, so every card opens a new stream). e2e:
  `testStoppedSessionSaysSoAndComesBackWhenStartedAgain` (its own session, `hl-e2e-<id>-e`).
- **Pane closed in herdr while streaming.** The card goes with the next snapshot and its `control` run exits
  (herdr ends it: `terminal … not found`/exited); no zombie children (`ps` shows no `Z` child of the app).
  e2e: `testPaneClosedInHerdrDropsItsCardAndStream`.
- **Takeover.** Another client's `control --takeover` closes our stream with `taken over`; the card watches
  with `observe` and shows "In use elsewhere · Take back" (now `pane.<id>.take-back`); Take back reattaches
  with `--takeover`, and typing reaches the pane. e2e: `testTakenOverCardOffersTakeBack`.
- **Session switches.** Three round trips between two sessions, then ⌘Q: the old session has no
  `terminal session` runs after each switch, the shown one has exactly its tab's cards, and after quit there
  are none. e2e: `testSwitchingSessionsAndQuittingLeaveNoStreams`. Also checked by hand: after `kill -9` of
  the app its `control` children exit too (their stdin closes), so even a crash leaves no runs.
- **e2e helper.** New actions, still only for the run's own sessions: `/<s>/takeover` (a `control
  --takeover`, released at once), `/<s>/streams` (`pgrep -lf "herdr --session <s> terminal session"`; the
  helper serves one request at a time, so none is its own), `/<s>/stop` and `/<s>/start` (a headless server,
  as a user would start one in a terminal; `e2e.sh`'s cleanup stops and deletes it).
- **Start button id.** The not-running page's container id (`detail.message`) was copied onto its Start
  button, so `detail.start` never existed. The container id is gone (nothing used it).
- **Full screen restore.** Reproduced only with ⌥⌘Q (Quit and Keep Windows) while in full screen: with "Close
  windows when quitting an application" on (the default), a plain quit or a crash saved no window state here.
  On relaunch the window joins its view not in full screen, then AppKit enters full screen (the will/did
  notifications fire), yet the toolbar's on-hover look does not apply, so the empty bar covers the title row.
  Leaving and entering again from `viewDidMoveToWindow` did nothing (the window is not in full screen yet
  then). `.restorationBehavior(.disabled)` on the scene fixed it but also dropped the saved window frame.
  Fix: `window.isRestorable = false` in `FullScreenReader`. The frame still comes back (SwiftUI's frame
  autosave, checked: 1000×700 at 100,100 after ⌥⌘Q in full screen), full screen does not. An e2e check was
  tried and dropped: ⌃⌘F then ⌥⌘Q did not quit the app under XCUITest during the full-screen animation, and
  waiting on the window frame timed out. Recorded hand check instead (above), and user-entered full screen
  still hides the toolbar until hover.
- **IME composition.** Not exercised. Switching to a Japanese input source changes the user's input sources
  on this shared Mac, and XCUITest's `typeText` inserts text without going through an input method. The code
  path is guarded: while libghostty has marked text, `PaneSurfaceView.keyDown` sends every key (arrows,
  Enter, Esc) to libghostty's input handling instead of herdr keys; committed text arrives through the same
  `insertText` → `terminal.input` path as the Character Viewer (checked in phase 4).
- **`Package.resolved` `originHash`.** Not reproduced: `xcodebuild -resolvePackageDependencies`, `make build`
  and `make test` in a second worktree left the tree clean, and the file has had one version since it was
  added. Most likely Xcode's GUI rewrote it once in another checkout. Documented in the README (don't commit
  that change).
- **Ponytail audit** (read-only reviewer): applied all items except 8 (keep `isTab`) and the flag part of 7
  (keep `loadedSessions`, so a failing `sessions()` is not retried on every snapshot), and 22 (`Frame.full`
  stays: the integration test reads it to find the first frame after a resize). One `TabButton` serves the
  sidebar and the title bar; one `floatingPanel(open:)` for the palette and session list; one `jsonLine` in
  HerdrKit; the UI tests share their helpers from `HerdlightUITests.swift` (`read`, `waitFor`, `newTab`,
  `split`, `foreground`, `newTabID`, `openSessions`, `openPalette`); `testKeysGoToTheClickedCard` became part
  of `testEachTabKeepsItsKeyboardCard` and `testFollowsTabsMadeAndClosedInHerdr` was dropped (covered by
  `testSelectsAnotherTabWhenTheSelectedOneCloses`). A helper used from another file with a closure
  parameter (`waitFor`) must take it `@escaping`: the compiler's module pass rejected the non-escaping one
  ("escaping local function captures non-escaping value") once it was not private.
- **CI flake.** `testTabRowOfAnotherWorkspaceShowsThatTab` read the title-bar capsules' "in view" values
  right after hiding the sidebar; on CI the strip was still scrolling to t1, so both tabs were lit. It now
  waits for the settled values.
- **e2e time.** 32 tests in 6 min 18 s locally (`make e2e` 6 min 31 s with the build).
- **Streams open small.** The first `control` of a card at launch opens at libghostty's first grid
  (50×17 here) and resizes once the layout settles. Not changed (harmless, one resize per card at launch).
