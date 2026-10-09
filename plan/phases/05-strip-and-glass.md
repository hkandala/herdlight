# Phase 5: swipe across tabs, tab pills, chrome polish

Goal: a two-finger horizontal swipe anywhere in the strip pages between tabs, vertical
scroll still reaches terminals, and the chrome is finished Liquid Glass.

Read first: [platform: making the strip work, tab bar and Liquid Glass](../../docs/content/docs/platform.mdx),
[ui/swiping](../../docs/content/docs/ui/swiping.mdx), `resources/research/gorex.md`.

## Build

1. **Scroll routing** (macOS): one `NSEvent` local monitor for `.scrollWheel` that locks the
   axis at the start of each gesture (`phase == .began`): mostly horizontal → the strip
   pages (the terminal never sees it); otherwise the event goes to the view under the
   pointer for the whole gesture. Momentum follows the locked axis. Mouse wheels with
   Shift (horizontal) page too.
2. **Paging**: snaps to one tab per page; the selected tab updates when the scroll stops;
   streams switch then (neighbor pages show their last image during the swipe).
3. **Tab marker**: one glass marker follows the strip's scroll offset
   (`onScrollGeometryChange`), lit tabs from `floor(x/w)` to `ceil((x+w)/w) − 1`; when the
   scroll stops, the selection changes and the marker moves to it (no grow-from-center
   morph; see item 6). Unit test the lit-tab math if it has branches.
4. **Keyboard paths**: ⌘1…⌘9 and ⇧⌘[ / ⇧⌘] switch tabs; also in the menu bar.
5. **Glass polish**: the look from phase 3b holds during swipes (no double glass, no
   flicker of frosted cards). Reduce Motion turns off page and morph animations.
6. **Tab click = scroll.** Clicking a pill (or sidebar row) moves the strip to that page
   and the selection marker moves exactly as it does during a swipe. No pill
   grow-from-center animation.
7. **Bug: wrong tab after a workspace switch.** Coming from another workspace and clicking
   the 2nd tab shows the 1st; clicking the 1st does nothing, then the 2nd works. Find the
   root cause (strip scroll position vs selection binding on workspace change) and add an
   e2e test that fails before the fix.
8. **Pill spacing** like the references (`resources/inspirations/ui-target/02-*`): more
   leading padding (the icon tile is at the capsule edge now), consistent top/bottom
   space, consistent spacing between pills.
9. **Chrome polish from the user's test:**
   - the session button shows only the session name (drop "This Mac"); its icon the same
     size as the other title-bar icons;
   - full screen: no empty traffic-light inset on the left of the title row;
   - the sidebar sits on the flat window background, no glass panel (as in ref 03): only
     the pane cards are frosted; selected and hover rows keep their pills. Update D44/D45.
10. **e2e**: synthesize horizontal scroll gestures (XCUITest `scroll(byDeltaX:deltaY:)` or a
   `CGEvent` scroll with phases) over a terminal card → the next tab becomes selected and
   its panes attach; a vertical scroll over the same card scrolls the terminal and does not
   page; ⌘2 selects the second tab; screenshots of each step.

## Done when

- e2e green locally and in CI. The orchestrator swiped with a real trackpad gesture (or a
  synthesized one) and checked screenshots: the marker follows, nothing flickers, the
  terminal under the pointer does not get the horizontal swipe.

## Out of scope

Sidebar machine pages, iOS gestures, drag and drop.

## Findings

- **Why a swipe over a terminal was slow and did not page.** The terminal passed on each
  event that was more sideways than up or down, one by one. A gesture's begin and end
  events carry no movement, so they went to the terminal: the strip saw a gesture with no
  end and never snapped to a page. The monitor (`SwipeRouter` in `Strip.swift`, installed at launch)
  picks the axis once a gesture moved 4 pt (from `.began`; until then events go the usual
  way) and sends the rest of it, momentum and a stopping touch included, to the scroll view
  under the pointer (`enclosingScrollView`; SwiftUI's horizontal `ScrollView` is an
  `NSScrollView`, `SwiftUI.HostingScrollView`). The terminal now reads only up and down.
- **Mouse wheels.** A wheel has no phases; it picks per event. A mouse's line steps would
  only nudge a paged strip (it snaps back), so over the strip a burst of sideways line steps
  (events less than 0.3 s apart) turns one page (`HostStore.step`). AppKit turns Shift+wheel
  into sideways steps itself. The strip marks its scroll view with an invisible
  `StripAnchor` view so the router knows it.
- **Wrong tab after a workspace switch.** The strip was rebuilt per workspace
  (`.id(workspace.id)`) with `scrollPosition(id:)` bound to the selection. A new scroll
  view drops its first scroll position (its lazy pages are not laid out yet), so it showed
  the first tab while the selection said the second, and a click on the first changed
  nothing. Now one strip serves every workspace; the page in view is the strip's own state,
  a new workspace or selection scrolls to it (no animation across workspaces), and the
  selection follows the page in view only when the scroll stops.
- **Marker.** The strip writes its offset in pages to `HostStore.page` (one strip shows
  every workspace; a number per workspace went stale after a switch at the same offset); the title-bar tab
  bar draws one glass capsule between the frames of the two capsules around it. Lit tabs
  are `floor(page)...ceil(page)` (the design's formula); the page is rounded to a
  thousandth so a page at rest lights one tab. No unit test: no branches.
- **Keys.** ⌘1…⌘9, ⇧⌘[ and ⇧⌘] are Window menu items. They work while a terminal has the
  keyboard. While the session list is open they are off, so its own ⌘1…⌘9 pick sessions.
  ⌘N finds the workspace when pressed: the menu can be older than a workspace switch.
- **⌃⌘F.** AppKit's window toggles full screen only for a key no view takes, and libghostty
  takes every key (it typed `\e[102;5u`). The terminal view toggles full screen for ⌃⌘F
  itself. Passing ⌘ keys on with `nextResponder?.keyDown` crashed: the window asks the views
  for key equivalents again, and libghostty's `performKeyEquivalent` calls `keyDown`.
- **Full screen.** A small view (`FullScreenReader`) reads its own window's style when it
  joins the window and follows that window's `willEnter/ExitFullScreen` notifications; in
  full screen the title row starts at the window edge (the traffic lights are not there).
- **Tests.** XCUITest's `scroll(byDeltaX:)` sends wheel events, which page the strip.
  Synthesized trackpad gestures (CGEvent with scroll phases) page only with enough speed:
  ~600 pt in 8 events does, 400 pt in 12 snaps back, as a slow real swipe would. With the
  4 pt threshold, 600/8, 400/10, 300/4 and 900/30 (pt/events) all page both ways, over a
  card and over its header; a vertical gesture does not. The phased path (trackpad
  gestures) is covered by these hand checks only; e2e covers the wheel path.
- **Open: a window that opens in full screen** (macOS restores it so) shows AppKit's empty
  title-bar window over the title row; `windowToolbarFullScreenVisibility(.onHover)` holds
  only for a window that enters full screen after it opened. Hiding the toolbar in full
  screen (`.toolbar(.hidden, for: .windowToolbar)`) made the bar show every time, and
  `NSApp.presentationOptions` with `.autoHideToolbar` on entering changed nothing. Leaving
  and entering full screen again fixes it. Not fixed in phase 5; e2e launches ignore saved
  window state.
