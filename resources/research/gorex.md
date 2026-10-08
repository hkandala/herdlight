# gorex (egoist/gorex) and MyGo: research report

Cloned on 2026-10-08 with `git clone --depth 1`:

- `/tmp/herdr-research/gorex`: `egoist/gorex` at `b206e67` (2026-10-08). The Rex-like app. 5.6k lines of Go.
- `/tmp/herdr-research/mygo`: `egoist/mygo` at `fa9e8e0` (2026-10-09). The framework gorex is built on (`go.mod` pins `github.com/egoist/mygo v0.3.5-…`).

Paths below are relative to those two roots. gorex points to no other example app; its screenshot is `gorex/docs/screenshot.png`.

## 0. The short version

- **The premise is wrong. gorex uses no SwiftUI, no AppKit controls and no Apple Liquid Glass.**
  - MyGo calls the Objective-C runtime from Go through `purego`. It makes no cgo calls and has no Swift code: `find . -name '*.swift'` returns nothing.
  - It makes one `NSWindow` and puts in one layer-backed `NSView` (`MyGoSurfaceView`). It then draws every tab, card, button and popover itself, on the GPU, through its own Metal renderer.
- **gorex itself does not use glass at all.** The Rex look comes from semi-transparent white or dark fills over a gradient that the app paints itself. MyGo has a `glass` plugin, but gorex does not import it. That plugin is a *shader that copies* Liquid Glass. It does not call Apple's API.
- **gorex has no sidebar.** It has a title bar (host chip, tab track, ⌘ and + buttons) over a split-pane area. MyGo's own `ui.Sidebar` widget and its `examples/vibrancy` sidebar are drawn by MyGo too, over an `NSVisualEffectView`.
- **The terminal is libghostty-vt** (Ghostty's VT parser only, loaded with `dlopen`). MyGo draws the cells. It is not the full libghostty with its Metal renderer.
- So gorex gives us **no Swift glass API code to copy.** It does give us good, measured **UI decisions and numbers**: tab capsule sizes, card styling, the gap used as the divider, status-dot rules, attention rules, tab icons stacked from the pane icons, text that fades out instead of ending in "…", and header controls that show on hover. MyGo's glass docs also list measurements of `NSGlassEffectView`. These help us make the HTML mocks look like the real thing.

## 1. What gorex and MyGo are, and how Go drives the Mac

### 1.1 gorex

A copy of Superlogical's Rex terminal (`gorex/README.md`). Its features: tabs and split panes as cards over a gradient; a session server (`GoRex -server`, `internal/rex/`) that keeps shells alive when the app quits; foreground-process detection that names each pane (`Node`, `Git Changes` for lazygit, `Codex`); a green dot while a program prints and an orange dot for attention; tab icons stacked from the panes' programs; a host chip; a command palette. It targets macOS 13 or later (`gorex/mygo.json`: `"minimumSystemVersion": "13.0"`) and Windows.

| File | Contents |
|---|---|
| `main.go` | window options, startup, `-server` |
| `view.go` | title bar, pane cards, split tree, divider, status dots |
| `tabs.go` | the tab track, tab capsules, stacked tiles, text fade, drag to reorder, rename |
| `style.go` | every colour (light and dark), the window gradient, terminal themes |
| `state.go` | tab, split tree and pane model; attention; equalize; save and restore |
| `programs.go` | process name → display name, glyph, tile colour |
| `internal/rex/` | PTY session server, headless libghostty-vt per session, snapshot on attach |

### 1.2 MyGo: the bridge (it is not a Swift bridge)

- `mygo/AGENTS.md`: "**No cgo.** … Call native code through purego (`internal/darwin`…)". `internal/darwin/objc.go` is the start of "the macOS backend (AppKit + WKWebView) in pure Go: Objective-C is driven through the runtime with purego". It registers typed `objc_msgSend` variants (`msgRect`, `msgInitWindow` …) and defines ObjC classes at run time (`classDef("MyGoSurfaceView", "NSView", []string{"NSTextInputClient"}, …)`, `internal/darwin/surface.go:603`).
- The pipeline (`mygo/docs/architecture.md`, "Native UI"):
  ```
  view (Go) ──► ui: build, layout, paint ──► internal/scene ──► internal/gpu: d3d11 | metal | gl, or internal/raster
  ```
  The backend only "provides a surface to draw on and its input" (a layer-backed NSView, with `CADisplayLink` frame pacing). Accessibility is done by hand: each node becomes a subclass of `NSAccessibilityElement`.
- The UI is in immediate mode. `ui.View(a.view)` calls `func (a *App) view(c *ui.Context)` again on every change, much like a SwiftUI `body`.

**What this means for us:** there is nothing to reuse at the code level. Herdlight's plan (SwiftUI with real `glassEffect`, libghostty-spm) is a different stack, and it is the more native one.

## 2. Window and title bar (the only real AppKit code)

`gorex/main.go:93`:
```go
opts := mygo.WindowOptions{
    Width: 1000, Height: 620, MinWidth: 560, MinHeight: 340,
    TitleBarStyle:        mygo.TitleBarHidden,
    TrafficLightPosition: &mygo.Point{X: 16, Y: 15},
    BackgroundColor:      "light-dark(#efe1e6, #231e27)",
    Content:              ui.View(a.view),
}
```
MyGo turns `TitleBarHidden` into plain AppKit calls (`mygo/internal/darwin/window.go:94–127`):
```go
style |= styleFullSizeContentView                     // 1 << 15
send(w.win, "setTitlebarAppearsTransparent:", 1)
send(w.win, "setTitleVisibility:", 1)                 // NSWindowTitleHidden
send(w.win, "setTabbingMode:", 2)                     // NSWindowTabbingModeDisallowed
// "hiddenInset" adds an empty NSToolbar with setShowsBaselineSeparator: 0
```
- **Moving the traffic lights:** `layoutTrafficLights()` (`window.go:626`) finds the close button with `standardWindowButton:0`. It takes that button's `superview.superview` (the title bar container), makes it `buttonHeight + 2*Y` tall, and moves the three buttons with `setFrameOrigin:`. AppKit lays the title bar out again on resize, title change and appearance change, so MyGo runs this again after each one. This is a known fragile trick.
- **How content avoids the lights:** `TitleBar()` (`window.go:576`) reports the right edge of the zoom button. gorex pads its title row by `bar.Left + 14` (`view.go:59–66`). In full screen the lights hide, and the padding falls back to 12.
- **Dragging the window:** the title row and the tab track are `.DragWindow()` (`view.go:66`, `tabs.go:35`). Gaps between tabs drag the window. A spacer of at least `titleFree = 56` pt is always left after the tabs, so there is always room to drag (`tabs.go:71`). A double click there runs the user's `AppleActionOnDoubleClick` setting: zoom or minimize (`window.go:603`).
- The window title follows the active tab, so the Window menu and Mission Control show it (`view.go:39–47`).

**Swift equivalents (our translation, not from gorex):** use `.windowStyle(.hiddenTitleBar)` or `.windowToolbarStyle(.unified)`, `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)`, `WindowDragGesture()` with `.allowsWindowActivationEvents(true)` on the empty part of the bar, and `navigationTitle` set to the active tab's label. Do not move the traffic lights. On macOS 26 a toolbar item already gets a correctly sized title bar. The `superview.superview` trick is exactly what we avoid by using the toolbar.

## 3. The tab bar (`gorex/tabs.go`)

It is not glass. It is a capsule-shaped "track" with capsule-shaped tabs inside, and the active tab is a raised, nearly opaque capsule.

```go
const ( tabH = 28; tabMaxW = 214; tabMinW = 120; tileW = 21; tileH = 16; tileStep = 5 )

track := ui.Row(c).Basis(total).Shrink(1).MinWidth(0).Height(tabH+4).Padding(2).Radius((tabH+4)/2).
    Background(k.track).Border(0.5, k.trackBorder).AlignItems(ui.Center).ClipX().
    DragWindow().Role(ui.RoleTabList)
...
e := ui.Row(c.Key(t.ID)).Height(tabH).Basis(width).Shrink(1).MinWidth(64).
    Padding(0, 10, 0, 6).Gap(9).Radius(tabH / 2).Role(ui.RoleTab).Selected(active)
if active {
    e.Background(k.tabActive).Shadow(0, 1, 2, 0, k.shadow).Shadow(0, 2, 8, 0, k.shadow)
} else if e.Hovered() { e.Background(k.hover) }
e.Transition(ui.ElementTransition{Colors: true, Position: true, Duration: 160 * time.Millisecond})
```
- **Sizes:** title bar 44 pt (`view.go:14`); track 32 pt tall with 2 pt padding and 0.5 pt border; tabs 28 pt tall, 120–214 pt wide by content, 64 pt minimum when squeezed. The label is 13.5 pt: name in weight 500, folder in 400 and a fainter colour.
- **Separators:** a 1×16 pt hairline goes between tabs, but not next to the active tab (`tabs.go:39–43`), as Safari and Rex do.
- **Overflow:** there is **no scrolling**. The track shrinks (`Shrink(1)`, `ClipX`), and each label **fades out over its last 30 pt** instead of ending in "…" (`fadeText`/`layoutFade`, `tabs.go:298–353`: each character's alpha is set to `f²` across the fade).
- **Right-hand slot:** one slot, chosen in this order: hover (and more than one tab) → `×` close button (18 pt, 12 pt icon); else attention → amber 7 pt dot; else busy → green halo dot (`tabs.go:115–124`).
- **Tab icon = stacked tiles:** the focused pane's program tile (21×16 pt, radius 4.5, white rim, 0.5 pt shadow, white sheen gradient on top) sits in front. Up to two more panes' tiles peek out 5 pt each behind it, each inset 0.8 pt per level (`tiles`/`drawTile`, `tabs.go:247–296`). Tile colours come from `programs.go`, and unknown programs get a hashed colour from an 8-colour palette.
- **Interaction:** a click selects; a double click renames in place (Enter keeps, Esc cancels, focus loss keeps, empty resets); dragging reorders (`e.Drag(t)` / `ui.Drop[*Tab]`, 40% opacity while dragging, a 1.5 pt accent border on the drop target); a context menu offers Rename, Reset Name, Move Left or Right, New, Close and Close Others.
- **Animation:** only colour and position transitions of 160 ms. No marker slides or morphs between tabs; the active background simply moves to the new tab.

## 4. Pane cards and split dividers (`gorex/view.go`)

```go
const ( gap = 8; titleH = 44; cardR = 12; headerH = 33 )

card := ui.Column(c.Key(p.ID)).Radius(cardR).Clip()
bg, border, shadow := k.card, k.cardBorder, k.shadow
if focused { bg, border, shadow = k.cardFocused, k.cardBorderFocused, k.shadowFocused }
card.Background(bg).Border(1, border).Shadow(0, 1, 2, 0, shadow).Shadow(0, 6, 22, -2, shadow)
card.Transition(ui.ElementTransition{Colors: true, Duration: 160 * time.Millisecond})
```
- **Layout:** there is an 8 pt gap between cards and around the area (no top padding under the title bar). Cards have a 12 pt radius, a 1 pt border and two shadows (a tight one and a soft 22 pt blur). The terminal sits inside with 5 pt side and 6 pt bottom padding.
- **Focus:** the focused card is the *more opaque* one. In dark mode an unfocused card is `rgba(20,20,24,.5)` and the focused card `rgba(36,36,41,.94)`, with a brighter border (`.05` → `.14` white) and a darker shadow. The terminal background is transparent (`Transparent: true`, `state.go:220`), so the card fill *is* the terminal background. The effect is that unfocused panes are dimmed.
- **Header (33 pt):** program glyph 14.5 pt, name 12.5 pt/600, folder 12.5 pt/500 at 86% alpha, then the status dot. The buttons (split right, split down, zoom, close; 26 pt, 16 pt icons) show **only when the card is focused or hovered** (`view.go:274`). A double click on the header zooms; a click focuses.
- **Zoom:** the zoomed pane fills the tab (`tabContent`, `view.go:157`), with no animation.
- **Divider = the gap.** Between two children sits an 8 pt `RoleSplitter` box with the resize cursor (`view.go:181–212`):
  ```go
  if dx, dy, ok := div.Dragged(); ok { n.Ratio = min(max(n.Ratio+d/total, 0.08), 0.92) }
  if div.DoubleClicked() { n.Ratio = 0.5 }
  if div.Hovered() || div.Dragging() || div.Pressed() {   // a 36×3 pt grip, radius 1.5, 60% muted colour
      p.Fill(ui.Rect{X: r.X + r.W/2 - 1.5, Y: r.Y + r.H/2 - 18, W: 3, H: 36}, k.iconMuted.Alpha(0.6), 1.5)
  }
  ```
  Children use `Grow(ratio).Basis(0)` / `Grow(1-ratio)`. Keyboard: ⌃⌘ arrows move the nearest split of that direction by 0.05, clamped to 0.1–0.9 (`state.go:485`). ⌃⌘= equalizes by counting leaves on each side (`equalize`, `state.go:507`).
- **Model:** a binary tree `Node{Pane | A, B, Vertical, Ratio}` (`state.go:37`), the same shape as our rebuilt herdr tree.

## 5. Status dots and attention (`view.go:327–378`, `state.go:258, 838`)

| State | Rule | Look |
|---|---|---|
| running | the program is not a shell and printed in the last 1.5 s (`activeFor`) | green dot 6 pt (5.5 on tabs) in a 22% alpha halo |
| attention | bell rang, or a program that was running became idle (finished), while the pane was not focused or the window was not active | amber 7 pt dot |
| quiet / idle | — | nothing |

- **The running dot is deliberately not animated:** "It does not animate, as drawing frames all along would cost more than it tells" (`view.go:358`).
- Attention clears when the pane's terminal gets focus (`view.go:258`).
- When the window is inactive and a command that ran more than 8 s since the last input finishes, the app posts a system notification ("Node finished · in ~/dir").
- A tab shows attention if any of its panes needs it, else running if any pane is printing.
- Colours, dark mode: busy `#4ade80`, attention `#fbbf24`. Light mode: `#34a853`, `#f59e0b`.

## 6. Terminal embedding

- MyGo's `plugins/terminal` loads **libghostty-vt** (Ghostty built with `zig build -Demit-lib-vt`) at run time through purego (`plugins/terminal/internal/vt/lib.go`: `ghostty_terminal_new`, `ghostty_terminal_vt_write`, `ghostty_render_state_*`, row iterators …). MyGo's own renderer then draws the cells (`plugins/terminal/paint.go`, `box.go`).
- gorex feeds each terminal from its session server through `terminal.Options{Conn: p.stream, Transparent: true, OnTitle, OnBell, OnNotify, OnExit}` (`state.go:215`). That is the same model as libghostty-spm's `InMemoryTerminalSession` (bytes in, keys out).
- The server keeps a **headless libghostty-vt per session** and sends `vt.Snapshot()` on attach, so full-screen TUIs come back exactly (`internal/rex/session.go:103, 207`). herdr already does this for us on its side.
- The library needs macOS 13 or later (`docs/plugins/terminal.md`, "The library").

## 7. Sidebar (not in gorex, only in MyGo examples)

- `mygo/examples/vibrancy/main.go`: `WindowOptions.Vibrancy` adds an `NSVisualEffectView` (`blendingMode = behindWindow`, `state = active`, material `sidebar` = 7) behind the drawing surface (`internal/darwin/window.go:516–550`). The sidebar draws no background, so the material shows through. Collapsing is a 250 ms `row.Animate("sidebar", …)` of its width, with the sidebar sliding left, and the toggle button sits at `bar.Left + 8`.
- `mygo/examples/gallery` uses MyGo's own `ui.Sidebar` / `ui.SidebarSection` / `ui.SidebarItem`.
- Neither one is the floating glass sidebar of macOS 26.

## 8. Liquid Glass: MyGo's copy, and what it says about Apple's

`mygo/plugins/glass` (`glass.metal`, `glass.go`, `docs/plugins/glass.md`) is a shader that copies Liquid Glass. It does not call `NSGlassEffectView`. Its docs record measurements of Apple's look. They are useful for our mocks (`docs/components/design/design.css`), and they are a second source for spike behaviour. These are MyGo's claims; I did not check them.

- **No shadow:** "Neither `NSGlassEffectView` nor a button of the glass bezel casts one: the pane's edge is its rim alone." The rim is a hairline: lit where it faces up or down, shaded on the sides.
- **Bezel:** flat in the middle, curving down to the edges along a squircle over the last 36 pt (at most half the pane), with refraction at index 1.5.
- **Regular material:** blurs by up to 10 pt (more for larger panes). Its lightness mapping: light mode, black → 54%, white → 100%; **dark mode, black → 15%, white → 51%**, keeping hue. `Clear` blurs about an eighth as much.
- **Interactive** (they say macOS 27): the pane grows about 1.1 pt left and right and 0.45 pt top and bottom while pressed, within 150 ms.
- **Scroll edge** (`safeAreaBar` + `scrollEdgeEffectStyle`): *soft* = background at 85% at the bar edge, falling to 0 over the bar height + 10 pt, no blur. *Hard* = Gaussian blur 6, saturation 1.25, then 82% background, then a hairline (black 10% in light mode, white 7% in dark). Window toolbars draw "an even blur under 60% of the background".
- MyGo's panes "do not merge into each other when close, as AppKit's `NSGlassEffectContainerView` does". This confirms that merging and morphing come only from the real container (`GlassEffectContainer` / `glassEffectID`), and a hand-made copy loses them.

**None of these APIs appears in gorex:** `glassEffect`, `GlassEffectContainer`, `glassEffectID`, `NSGlassEffectView`, toolbar placement, version gating above macOS 13. For those we still rely on Apple's docs and our spike S2.

## 9. Our design compared with gorex

### Confirms our plan

| Our design | gorex evidence |
|---|---|
| Tab = capsule; label with the folder part dimmed (`ui/window.mdx`) | Same: name in weight 500 and folder at weight 400 in a fainter colour, capsule radius = height/2 (`tabs.go:63–68`) |
| Hover shows × on a tab | Same, and the × replaces the status dot in the same slot (`tabs.go:115`) |
| Tab icon from the pane last selected | Same idea: the focused pane's tile is in front (`tabs.go:249`) |
| Pane cards follow the split tree with a fixed gap; drag a divider; 8 pt hit area (`layout.mdx`) | Same: 8 pt gap that *is* the divider, resize cursor, ratio from the drag delta / (container − gap) (`view.go:181–200`) |
| Thin card header: icon, title, zoom, close; controls on hover on macOS | Same, 33 pt; shows when focused **or** hovered (`view.go:274`) |
| Cards without focus slightly dimmed | Same effect, done by giving the focused card more opacity, a border and a shadow (`style.go:40–44, 96–101`) |
| A status glyph per tab, aggregated over its panes | Same: attention takes priority over busy (`tabs.go:117–123`) |
| "Seen" is the app's own, cleared by viewing the pane (`layout.mdx`) | Same: attention clears when the terminal is focused (`view.go:258`); set only when not focused or the window is inactive (`state.go:258`) |
| Dark styling with near-black, opaque terminal backgrounds | Dark cards are `#24242a` at 94% and the terminal background is `#1e1e22`; nothing in gorex needs glass behind panes |
| libghostty for terminals | Ghostty's VT core here too. The terminal is never a web view |

### Differs from our plan (not wrong; different choices)

- **Glass:** gorex has none. Its "glassy" look is translucent fills over a pastel or plum gradient that the app paints, so wallpaper never shows through. This supports our "glass only on chrome" rule more than it challenges it: Rex's look needs no glass under content. Our theme (`ui/theme.mdx`) uses an opaque `#0e0f12` window, which is flatter than gorex's dark gradient (`#2c2131 → #231e27 → #221f22 → #2a2619` plus a pink tint on the right, `style.go:130`). *Possible choice:* a very subtle dark gradient behind the cards.
- **No strip, no paging, no moving marker:** a gorex tab click swaps the content at once, and the active capsule changes with a 160 ms colour fade. Our strip with the scroll-linked marker and lit-tab maths (`platform.mdx`) is our own idea. gorex gives no evidence for or against it.
- **Overflow:** gorex shrinks tabs to 64 pt and fades the labels. It never scrolls the tab bar. Ours uses a horizontal `ScrollView`.
- **The tab bar is a custom row inside the title bar, not a toolbar item.** This is the same as our fallback (spike S2: hidden title bar + `WindowDragGesture`). gorex keeps ≥56 pt free to drag the window and pads for the traffic lights by measuring them.
- **Statuses:** gorex has 2 dots (busy, attention). We have 3 glyphs (◔ working, ✓ finished-unseen, ▲ needs you). gorex's "busy = printed in the last 1.5 s" is a heuristic. herdr gives us real agent status, so we do not need it.
- **Ratio clamp:** gorex allows 0.08–0.92 when dragging. herdr allows 0.1–0.9, so keep ours.
- **No sidebar** in gorex. Our floating glass sidebar is not touched by this research.

### Worth copying (proposals; none is in our docs yet)

1. **Double-click a divider → ratio 0.5** (send `layout.set_split_ratio` 0.5). Also show a **36×3 pt grip pill only on hover or drag**, and leave the gap empty otherwise.
2. **Keyboard divider moves and equalize:** ⌃⌘ arrows step the nearest matching split by 0.05; ⌃⌘= sets each split's ratio from the leaf counts on each side (`state.go:507`). Each one is a `layout.set_split_ratio` call.
3. **Double-click a card header → zoom; header controls show when focused or hovered** (not hover only), so the focused card always shows them.
4. **Fade long tab labels** over the last ~30 pt (in SwiftUI: a `.mask(LinearGradient)` on the label) instead of truncating with "…". Tab width ranges from 120 to 214 pt.
5. **One right-hand slot per tab, in priority order:** hover × → ▲ → ✓ → ◔. Write this order into `ui/window.mdx`.
6. **Do not animate the working glyph:** use a static ◔, with no repeating animation. That avoids a constant redraw in the tab bar, the sidebar and the pills. gorex states this cost explicitly (`view.go:358`).
7. **Stacked tab icons** (focused pane in front, up to 2 behind, 5 pt offset) as an option for multi-pane tabs. It shows at a glance what a tab holds.
8. **Hairline separators between inactive tabs**, hidden next to the active tab.
9. **The window title follows the active tab** (Mission Control and the Window menu).
10. **A notification when a long command finishes while the app is inactive** (gorex: more than 8 s since the last input). For us, use herdr's finished status in place of a timer.
11. **Mock fidelity:** in `design.css`, `.marker` (an inset top highlight and a 1 px white border, no drop shadow) already looks like the hairline rim with no shadow that §8 describes. Keep it that way. In dark mode, glass maps lightness into the 15–51% band.

### Gaps that remain (gorex cannot answer them)

- How `GlassEffectContainer` + `glassEffectID` behave inside a toolbar item with `sharedBackgroundVisibility(.hidden)`, and whether the toolbar squeezes a wide item: this is still **spike S2**.
- `NSGlassEffectView` in AppKit-hosted parts, or glass on iOS: no evidence here.
