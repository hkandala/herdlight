# Phase 3b: UI style (match the reference look)

Goal: the shell from phase 3 looks like the reference screenshots. Same data and behavior,
new look. This phase replaces the look parts of phase 3 and of the design where they
conflict (see "Changes to the design" below).

## References

- Screenshots in `resources/inspirations/ui-target/` (Rex and similar apps; some in a light
  theme, Herdlight stays dark). Study every one at full size.
  - `01-titlebar-tabs-single-pane.jpeg`: compact title bar with the session name, one tab
    capsule, ⌘ and + on the right; one pane card inset under it.
  - `02-titlebar-tabs-pane-header.png`: several tab capsules in the title bar (icon tile +
    title, selected one raised on glass, thin separators between the others), a pane card
    with a header row (icon, title; split right, split down, zoom, close on the right).
  - `03-sidebar-filter-light.png`: sidebar shown: tabs listed as rows (icon tile + title),
    grouped under section headers, the selected row a raised rounded pill; a Filter field
    at the bottom with two icon buttons; the content pane is a rounded card with a header.
  - `04-session-picker-filter.png`: the session picker: a title-bar button (session name,
    host underneath) opening a glass popover with a "Filter or create…" field, sessions
    grouped by host ("This Mac", remote names), ⌘1/⌘2 shortcuts, a check on the selected
    one, then "New Session ⇧⌘N" and "Add Remote Host…".
- **supaterm** (`https://github.com/supabitapp/supaterm`, MIT, Swift, libghostty): a real
  macOS app with this kind of chrome. Clone it to `/tmp/supaterm` and study how it builds
  the sidebar, title-bar tabs, glass, pane cards, window background and theme
  (`docs/theming.md`, `apps/mac/supaterm/`, `apps/shared/SupaTheme/`). Learn the
  techniques; write our own code; keep it far smaller.
- Design pages still valid for behavior: `docs/content/docs/ui/window.mdx`,
  `docs/content/docs/layout.mdx`.

## Target

1. **Window**: full-size content view, hidden title text, traffic lights at the top left,
   no visible title bar band. The window background is frosted (behind-window blur,
   dark-tinted), so the desktop shows through softly. Rounded pane cards float on it.
2. **Title bar row** (one row, aligned with the traffic lights):
   - sidebar toggle;
   - **session picker button**: icon + session name, the machine ("This Mac") as a small
     second line;
   - **tab capsules** of the selected workspace, shown only while the sidebar is hidden:
     an icon tile + title; the selected capsule raised on Liquid Glass; others flat with
     thin separators; scrolls sideways when they overflow; one glass marker that morphs
     between capsules (`glassEffectID`);
   - right side: `⌘` and `+` as in the references.
3. **Session picker popover** (glass): "Filter or create…" field that filters as you type;
   sessions grouped under "This Mac" (remote hosts come later); running sessions
   selectable, stopped ones dimmed; ⌘1…⌘9 on the first nine; a check on the current one.
   Then "New Session ⇧⌘N" and "Add Remote Host…" rows.
4. **Sidebar** (when shown): Liquid Glass, floating with rounded corners like macOS 26.
   - Workspaces are section headers; each workspace's tabs are rows (icon tile + tab
     label, agent status glyph on the right ▲ / ◔).
   - The selected tab is a raised rounded pill.
   - Bottom: a **Filter** field that filters tabs (and workspaces) by label.
   - Clicking a row selects that workspace and tab (app-only selection, never herdr focus).
5. **Pane cards**: rounded (≈10–12 pt), hairline border, frosted / Liquid Glass surface
   with a dark tint, 8 pt gaps, inset from the window edges like the screenshots.
   - A header row inside the card: kind icon + pane title (the label or cwd), and on hover
     split right / split down buttons (`pane.split` with `focus:false`, then the snapshot
     redraws; this is the only write added), plus zoom and close buttons.
   - The focused card is fully bright; others slightly dimmed.
   - Phase 4 puts the terminal inside the card body with a transparent or translucent
     terminal background, so the frosted card shows through. Leave a clean slot for it.
6. **Icon tiles**: the small rounded-square terminal tile (`>_`) used on tabs, rows and
   headers. SF Symbols are fine (`apple.terminal`, `terminal`).
7. **Typography and color**: system font for chrome (13 pt rows, 11 pt secondary text);
   dark palette; selected and hover states as in the screenshots; no bright accent fills
   except the selection pill and status glyphs.
8. Keep every accessibility identifier from phase 3 working (update the e2e tests where
   the structure changes, such as tabs moving between the sidebar and the title bar).

## Placeholder controls

The user wants the full look now. Controls shown in the references that v0 does not
implement are present and styled but do nothing when clicked (a no-op, no alert):
title-bar `⌘` and `+`, "New Session", "Add Remote Host…", the pane card's zoom and close,
and the sidebar's bottom icon buttons. Mark each with a one-line `// ponytail: no-op until
<feature>` comment so they are easy to find.

## Changes to the design

- D33 said "opaque near-black window, opaque cards". The user now wants frosted / Liquid
  Glass panes and a frosted window. Dark tint stays; light theme stays out.
- The design put tabs only in a tab bar. Now: tabs live in the sidebar while it is shown,
  and in the title bar while it is hidden (as in the references).
- The sidebar lists workspaces with their tabs (not agent rows) in v0.

Record these in `docs/content/docs/decisions.mdx` (new decision numbers; D33 marked as
changed) once the look is settled.

## Done when

- Side-by-side screenshots (ours vs each reference) show the same structure, spacing,
  shapes and glass feel. Put them in `/tmp/hl-shots/phase3b-*.png`, including: sidebar
  shown, sidebar hidden with title-bar tabs, the session picker open with a filter typed,
  the sidebar filter in use, a tab with nested splits.
- e2e tests pass locally and in CI, including new ones: the session picker filter narrows
  the list; the sidebar filter narrows the tabs; hiding the sidebar shows the title-bar
  capsules; a split button adds a pane (throwaway session).
- Ponytail still holds: system glass APIs first, no custom renderers, the minimum of
  AppKit bridging needed for the window (visual effect background, title bar).

## Findings

- **Frosted window.** `containerBackground(.ultraThinMaterial, for: .window)` does not blur the
  desktop; SwiftUI materials blend within the window. The window background is one
  `NSVisualEffectView` (`.behindWindow`, `.hudWindow`, `state = .active` so an inactive window
  stays dark) under a black 40 % tint. Cards are white 4 % with a hairline, so they read lighter
  than the window, as in the references. `screencapture -l` shows the window without what is
  behind it (flat gray); capture the screen region (`-R`) to see the real look.
- **Title-bar row.** With `.hiddenTitleBar` the traffic lights sit in a 28 pt bar, off-center
  from a two-line session button. A `.unifiedCompact` toolbar holding only a `ToolbarSpacer`
  (title removed, background hidden) gives a 40 pt bar with the lights centered. Our row is the
  first content row under it (`ignoresSafeArea(.top)`), 78 pt from the left edge.
- **Session picker.** SwiftUI's `.popover` always draws an arrow on macOS. The list is a glass
  panel in a window overlay under the button, closed by a click outside or Esc.
- **Accessibility.** A pane card that is an `.accessibilityElement(children: .contain)` merges
  into a one-pane page's own container (the card id is lost). The card's element is its
  background shape instead (a leaf with the title as label), so the buttons stay separate.
- **Tabs.** Tabs are sidebar rows while the sidebar shows, title-bar capsules (120–220 pt,
  truncating) while it is hidden; both carry `tab.<id>`. Workspace headers are buttons, so
  their text is the `label`, not the `value`.
- **⌘1…⌘9** work while the session list is open (shortcuts on its rows), not globally.
- **No NavigationSplitView.** The title row spans the sidebar (toggle and session picker sit
  over it, as in the references) and the sidebar is a fixed-width floating panel; the
  system split view puts its own toolbar and toggle there. The sidebar is a plain view in an
  `HStack`; don't revert.
- **Keyboard at launch.** The window gives the first text field the keyboard when it opens;
  `defaultFocus` on another view did not stop it. Filter fields are plain text until clicked,
  so there is none to give (phase 4: the terminal takes it). Focus asked for the moment a
  field appears is dropped; a 100 ms wait works (`ponytail:` comment in `FilterField`).
- **Split layout.** Both children of a split get an exact width and height; a card clips
  its header. Unframed, a card's header buttons pushed neighbors off the page.
- **Full screen.** The empty toolbar covers the title row in full screen;
  `windowToolbarFullScreenVisibility(.onHover)` hides it there.
- **Window size.** `windowResizability(.contentMinSize)`: the title-bar tabs' ideal width
  grew the window when the sidebar hid.
