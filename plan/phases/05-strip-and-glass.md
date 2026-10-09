# Phase 5: swipe across tabs, glass polish

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
   scroll stops, the selection changes inside `withAnimation` and the marker morphs
   (`glassEffectID`). Unit test the lit-tab math if it has branches.
4. **Keyboard paths**: ⌘1…⌘9 and ⇧⌘[ / ⇧⌘] switch tabs; also in the menu bar.
5. **Glass polish**: the look from phase 3b holds during swipes (no double glass, no
   flicker of frosted cards). Reduce Motion turns off page and morph animations.
6. **e2e**: synthesize horizontal scroll gestures (XCUITest `scroll(byDeltaX:deltaY:)` or a
   `CGEvent` scroll with phases) over a terminal card → the next tab becomes selected and
   its panes attach; a vertical scroll over the same card scrolls the terminal and does not
   page; ⌘2 selects the second tab; screenshots of each step.

## Done when

- e2e green locally and in CI. The orchestrator swiped with a real trackpad gesture (or a
  synthesized one) and checked screenshots: the marker follows, nothing flickers, the
  terminal under the pointer does not get the horizontal swipe.

## Out of scope

Sidebar machine pages, iOS gestures, drag and drop.
