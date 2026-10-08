# Floating agent pills on macOS 26

Research for a macOS-only feature: small always-on-top capsules ("pills") that
show agent status while Herdlight is not in front. A pill expands into a
small card with the agent's latest output and a reply box. A click opens the
main window at that pane.

- Date: 2026-10-08. Machine: macOS 27.0.1, Command Line Tools SDK 27.0, Swift 6.4.
  Target in DESIGN.md: macOS 26.
- Repos cloned (shallow) to `/tmp/herdr-research/<name>`. Short commit ids
  are in the links.
- Spike code (compiles and runs) is in `/tmp/herdr-research/floating-panels-spike/`.
  The full skeleton is also in §9 below.
- Labels: **fact** = read in code, docs or SDK headers, or seen on this Mac.
  **guess** = not verified; each one is in the spike list (§11).

---

## 0. Answer in one screen

1. **Use AppKit `NSPanel` with an `NSHostingView`, not a SwiftUI scene.** No
   SwiftUI scene on macOS 26 can make a non-activating window. `UtilityWindow`
   hides when the app is not active. `Window` + `.windowLevel(.floating)` is a
   normal `NSWindow`, so clicking it activates the app (§3).
2. **One panel for all pills,** not one panel per pill. It has a fixed size
   (380 × 560 pt) and sits in the bottom-right corner of the screen's
   `visibleFrame`. Its transparent parts let clicks through. One SwiftUI view
   tree holds every pill, so the pill-to-card morph is a plain
   `glassEffectID`/`GlassEffectContainer` change and the window never resizes.
3. **Panel settings:**
   - `styleMask` = `[.borderless, .nonactivatingPanel]`, set in `init`.
   - `level` = `.floating`.
   - `collectionBehavior` = `[.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary, .canJoinAllApplications]`.
   - `hidesOnDeactivate = false`, `canHide = false`, `becomesKeyOnlyIfNeeded = true`.
   - `canBecomeKey` returns `true` only while a card is expanded.
   - `hasShadow = false`, clear background.
   - Never assign `ignoresMouseEvents`.
4. **"Away"** = `!NSApp.isActive` and the main window's `occlusionState` does
   not contain `.visible`. Four notifications drive it: did become active,
   did resign active, occlusion changed, screen parameters changed. There are
   no timers.
5. **Content follows the design's one control rule.** Pills read only the
   snapshot. The expanded card is the existing chat view (§11 of DESIGN.md):
   transcript or screen text, `agent.prompt`, and the blocked panel. It never
   opens a `terminal session` stream.
6. **No double alerts.** While the pill panel is on screen, status changes
   show as pills, not as banners. Banners still post when pills are off or
   VoiceOver is running.
7. **Spike result on this Mac (fact).** The panel showed at CG layer 3
   (`.floating`) with glass capsules. It did not become key, the app stayed
   inactive, and Ghostty stayed frontmost. The collection-behavior set raised
   no exception. Screenshot: `research/floating-panels-smoke.png`.

---

## 1. How shipping apps configure their panels

| App (source) | Class / mask | Level | collectionBehavior | Key? | Notes |
|---|---|---|---|---|---|
| boring.notch ([BoringNotchWindow.swift L10-50](https://github.com/TheBoredTeam/boring.notch/blob/e2654ee/boringNotch/components/Notch/BoringNotchWindow.swift#L10-L50), [boringNotchApp.swift L236](https://github.com/TheBoredTeam/boring.notch/blob/e2654ee/boringNotch/boringNotchApp.swift#L236)) | `NSPanel`, `[.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]`, `isFloatingPanel` | `.mainMenu + 3` | `.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle` | `canBecomeKey false` | `hasShadow = false`, clear background, not movable |
| DynamicNotchKit ([DynamicNotchPanel.swift](https://github.com/MrKai77/DynamicNotchKit/blob/cd0b3e5/Sources/DynamicNotchKit/Utility/DynamicNotchPanel.swift), [DynamicNotch.swift L362](https://github.com/MrKai77/DynamicNotchKit/blob/cd0b3e5/Sources/DynamicNotchKit/DynamicNotch/DynamicNotch.swift#L362)) | `NSPanel`, `[.borderless, .nonactivatingPanel]` | `.screenSaver` | `.canJoinAllSpaces, .stationary` | `canBecomeKey true` | The panel is **half the screen** and mostly transparent. It relies on transparent pixels letting clicks through (§6) |
| NotchDrop ([NotchWindow.swift](https://github.com/Lakr233/NotchDrop/blob/e70b3d7/NotchDrop/NotchWindow.swift)) | plain `NSWindow` | `.statusBar + 8` | same four as boring.notch | key and main `true` | An `NSWindow`, so a click activates the app. Do not copy this |
| Maccy ([FloatingPanel.swift L27-46, L230](https://github.com/p0deje/Maccy/blob/a92c11a/Maccy/FloatingPanel.swift#L27-L46)) | `NSPanel`, `[.nonactivatingPanel, .resizable, .closable, .fullSizeContentView]` | `.statusBar` | `.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary` | `canBecomeKey true` ("so text inputs can receive focus") | `hidesOnDeactivate = false`; closes on `resignKey`. On macOS 26 it uses `NSGlassEffectView` as the background ([VisualEffectView.swift](https://github.com/p0deje/Maccy/blob/a92c11a/Maccy/Views/VisualEffectView.swift#L19-L32)) |
| Ice search ([MenuBarSearchPanel.swift L52-68](https://github.com/jordanbaird/Ice/blob/11edd39/Ice/MenuBar/Search/MenuBarSearchPanel.swift#L52-L68)) | `NSPanel`, `[.titled, .fullSizeContentView, .nonactivatingPanel, .utilityWindow, .hudWindow]` | `.floating` | `.fullScreenAuxiliary, .ignoresCycle, .moveToActiveSpace` | `canBecomeKey true` | Typing without activating; `makeKeyAndOrderFront`; Esc closes |
| CodexBar overlays ([QuotaWarningAlertOverlayController.swift L69-90](https://github.com/steipete/CodexBar/blob/b0aa7fe/Sources/CodexBar/QuotaWarningAlertOverlayController.swift#L69-L90)) | `NSPanel`, `[.borderless, .nonactivatingPanel]` | `.statusBar` | `.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary` | `false` | `ignoresMouseEvents = true` (no interaction), **`canHide = false`**, `hidesOnDeactivate = false` |
| ApolloShell, macOS 26 desktop shell ([ShellPanel.swift](https://github.com/Silvertree2010/ApolloShell/blob/3c88b90/Sources/ApolloShell/ShellPanel.swift)) | `NSPanel`, `[.borderless, .nonactivatingPanel]` | per panel | per panel | `canBecomeKey { takesKeyboard }` | `hasShadow = false` (a window shadow drew a second, almost square edge around the round glass); `animationBehavior = .none`; `becomesKeyOnlyIfNeeded = false` |
| BrightIntosh ([OverlayWindow.swift](https://github.com/niklasr22/BrightIntosh/blob/main/BrightIntosh/OverlayWindow.swift)) | overlay | n/a | `.stationary, .canJoinAllSpaces, .ignoresCycle, .canJoinAllApplications, .fullScreenAuxiliary` | n/a | This is the full set we use, in a shipping app |
| Raycast 2.7.2 (closed source) | strings in the binary include `ActionPanelWindow`, `FocusNotificationToastPanel`, `canBecomeKeyWindow`, `isFloatingPanel` | "Main Window" is at **CG layer 8** (`.modalPanel`), seen with `CGWindowListCopyWindowInfo` on this Mac | n/a | n/a | Fact: the layer number. Guess: it is a non-activating `NSPanel` (the menu bar stays with the previous app) |
| Alcove 1.2.5 (closed source) | binary has class `Alcove.NotchPanel`, a subclass of `NSPanel` (`So7NSPanelC`), and overrides `canBecomeKeyWindow` | not running, so not measured | n/a | n/a | |
| NotchNook | not installed, closed source | n/a | n/a | n/a | No evidence gathered |
| Unwait (an AI-agent overlay; [blog](https://unwait.ai/blog/macos-overlay-that-never-steals-focus)) | Tauri → `NSPanel`, non-activating, `can_become_key_window: false` | Status | `canJoinAllSpaces, stationary, fullScreenAuxiliary` | never | "Focus stealing is two separate problems": the window becoming key, and the app becoming active. You must turn off both |

**What they agree on:** `NSPanel` + `.nonactivatingPanel` + a clear background +
`[.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]` +
`hidesOnDeactivate = false`. The pill panels never take the keyboard. Panels
that need typing (Maccy, Ice, Raycast) return `canBecomeKey = true`, and the
app stays inactive.

## 2. Each setting and why

| Setting | Value | Why (evidence) |
|---|---|---|
| Class | `NSPanel` subclass | `.nonactivatingPanel`, `.utilityWindow` and `.hudWindow` are "only applicable for NSPanel" (SDK `AppKit/NSWindow.h` L49-52). |
| `styleMask` | `[.borderless, .nonactivatingPanel]` **in `init`** | `NSPanel.init` calls the private `-_setPreventsActivation:`, which sets the WindowServer tag `kCGSPreventsActivationTagBit`. Changing the mask later does not update the tag: the window then looks key but gets no keys ([philz.blog](https://philz.blog/nspanel-nonactivating-style-mask-flag/), [repro](https://github.com/philptr/NonactivatingPanelBug)). Skip `.utilityWindow` and `.hudWindow`: we draw our own chrome. |
| `level` | `.floating` (3) | Measured on this Mac: floating 3, modalPanel 8 (Raycast), Dock 20, Notification Center 21, mainMenu 24, statusBar 25, popUpMenu 101, screenSaver 1000. `.floating` sits above normal windows and below Raycast, Spotlight, the Dock, banners and menus, which is polite. CodexBar, Maccy and Unwait use `.statusBar`; switch to it only if the spike shows pills hidden under other apps' floating panels. SwiftUI's `WindowLevel` offers only `automatic`, `desktop`, `floating` and `normal` (SDK `SwiftUI.swiftinterface` L684). |
| `.canJoinAllSpaces` | on | Visible on every Space of the display. Mutually exclusive with `.moveToActiveSpace` (CodexBar comment, [PreferencesView.swift L264](https://github.com/steipete/CodexBar/blob/b0aa7fe/Sources/CodexBar/PreferencesView.swift#L264)). |
| `.fullScreenAuxiliary` | on | Without it the panel does not show over full-screen apps, and nothing tells you why (Unwait). Header: use at most one of Primary, Auxiliary or None. |
| `.stationary` | on | "Unaffected by exposé. Stays visible and stationary" (`NSWindow.h`). Mission Control does not move it. |
| `.ignoresCycle` | on | Not in ⌘\` window cycling. |
| `.canJoinAllApplications` | on | macOS 13+. "Windows marked with this behavior don't participate in Stage Manager layout but can join the windows of other apps in full screen spaces… Use this collection behavior for floating windows and system overlays" ([Apple](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications)). Use only one of `.primary`, `.auxiliary` or `.canJoinAllApplications`. Fact: our full set raised no exception at runtime (spike). |
| `hidesOnDeactivate` | `false` | The NSPanel default is `true` ([Apple](https://developer.apple.com/documentation/appkit/nswindow/hidesondeactivate)), so the panel would vanish exactly when the user leaves the app. |
| `canHide` | `false` | The default is `true`: ⌘H on the app would hide the pills too, yet "app hidden" is a main reason to show them (CodexBar sets it; [Apple](https://developer.apple.com/documentation/appkit/nswindow/canhide)). |
| `canBecomeKey` | `takesKeyboard` (true only while expanded) | Collapsed pills can never take keystrokes from the user's terminal (Unwait's rule). ApolloShell uses the same flag. |
| `becomesKeyOnlyIfNeeded` | `true` | "If the panel is a non-activating panel, then it becomes key only if the hit view returns true from `needsPanelToBecomeKey`" ([Apple](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded)). Clicking the key buttons on a blocked card then does not take the keyboard; clicking the reply field does. **Guess:** SwiftUI's `TextField` hit view returns `true`. If the spike shows the field cannot get focus, set this to `false`. The flag above still guards collapsed pills. |
| `canBecomeMain` | `false` | The panel is never a document window. |
| `isOpaque` / `backgroundColor` | `false` / `.clear` | Needed for glass and for click-through. |
| `hasShadow` | `false` | ApolloShell: the window shadow is computed from the window shape, and with glass it drew a second, almost square edge. Glass brings its own edge and depth. |
| `isMovable` | `false` (v1) | Pills stay in a fixed corner (§7). |
| `animationBehavior` | `.none` | SwiftUI animates the content; AppKit must not add a window zoom. |
| `ignoresMouseEvents` | **never assign it** | See §6. |

## 3. SwiftUI scenes against AppKit `NSPanel` (macOS 26)

| Option | What it gives | Why it fails for pills |
|---|---|---|
| `UtilityWindow` (macOS 15) | Floating level, takes focus only when needed, Esc dismisses ([Apple](https://developer.apple.com/documentation/swiftui/utilitywindow)) | "They hide when the window is no longer active." That is wrong by design for a feature shown while the app is away. It also adds a View-menu item. |
| `Window`/`WindowGroup` + `.windowLevel(.floating)` + `.windowStyle(.plain)` + `.windowManagerRole(.associated)` + `.defaultWindowPlacement` (macOS 15; [polpiella.dev](https://www.polpiella.dev/creating-a-floating-window-using-swiftui-in-macos-15)) | A floating, borderless SwiftUI window | It is an `NSWindow`, not an `NSPanel`. A click activates the whole app: the menu bar changes, and `didBecomeActive` fires, which would hide the pills. It has no scene modifier for all Spaces, full-screen auxiliary, stationary or `canHide`. `.associated` only means "shown alongside principal windows" in full screen and Stage Manager. |
| `.allowsWindowActivationEvents()` (macOS 15, view modifier) | Lets gestures handle the click that activates a window | Not a scene option, but **useful inside our panel** (§9). |
| `MenuBarExtra` | A menu bar item with a window | A different feature. The menu bar is crowded and the notch hides items (that is why Ice exists). Not pills. |
| **AppKit `NSPanel` + `NSHostingView`** | Everything in §2, in about 40 lines | **Chosen.** It is also what every app in §1 does. |

DESIGN.md D24 says "one window", because two windows would fight over control
of the same panes. The pill panel opens no terminal stream, so that reason
does not apply. The design keeps one *terminal* window.

## 4. Typing in the reply box without activating the app

- A non-activating panel can become key while the app stays inactive. AppKit
  "steals key focus" through `-[NSApplication _stealKeyFocusWithOptions:]` →
  `CPSStealKeyFocusReturningID`. The previous app keeps the menu bar and stays
  active (philz.blog). Fact for Maccy, Ice and Raycast-style launchers.
- **Never call `makeKey()` or focus the field when a pill shows or expands.**
  The user may be typing in a terminal; one stolen keystroke breaks the
  feature (Unwait). The field gets focus only when the user clicks it.
- **Esc** collapses the card (`.onExitCommand`).
  - **Guess:** to give the keyboard back to the previous app at once,
    `panel.orderOut(nil); panel.orderFrontRegardless()` after collapsing.
    Otherwise the keyboard returns when the user clicks their other window.
- **⌘V, ⌘C, ⌘A in the field.** **Guess:** these work through the app's main
  menu (SwiftUI apps have the standard Edit menu) even while the app is
  inactive, because the panel is key. Maccy pastes this way. Spike item.
- **Known bug:** the I-beam cursor does not show over a text field in a
  non-activating panel while the app is inactive. Spotlight and 1Password work
  around it in some way ([PitNikola/NonActivatingPanelIssue](https://github.com/PitNikola/NonActivatingPanelIssue)).
  Accept it.
- **AppKit controls draw "inactive" (grey) while the app is inactive,** even in
  a key panel. ApolloShell had to draw its own switch: "grau sogar in einem
  Fenster, das sich als Schlüsselfenster meldet; `controlActiveState` ändert
  daran nichts" ("grey even in a window that reports itself as key;
  `controlActiveState` changes nothing", [UtilitiesView.swift L174-180](https://github.com/Silvertree2010/ApolloShell/blob/3c88b90/Sources/ApolloShell/UtilitiesView.swift#L174-L180)).
  Pills use plain shapes and our own status colours, not tinted `.borderedProminent`.
- **First click:** in a window that is not key, SwiftUI gestures may ignore the
  click that activates the window. Add `.allowsWindowActivationEvents()` on the
  root view ([Apple](https://developer.apple.com/documentation/swiftui/view/allowswindowactivationevents(_:))).
  ApolloShell instead overrides `acceptsFirstMouse` on its hosting view
  ([SidebarContent.swift L312](https://github.com/Silvertree2010/ApolloShell/blob/3c88b90/Sources/ApolloShell/SidebarContent.swift#L312)).
  Use one; keep the other as the fallback.
- **Avoid hover-only behaviour.** Expand on click. Guess: SwiftUI `.onHover`
  may not fire in a window of an inactive app.

## 5. SwiftUI and Liquid Glass inside a borderless panel

- **Use SwiftUI glass:** `.glassEffect(.regular, in: .capsule)` on each pill
  and `.rect(cornerRadius: 20)` on the card, inside one `GlassEffectContainer`,
  with `.glassEffectID(id, in: ns)`. The pill then morphs into the card on
  expand. ApolloShell uses SwiftUI glass for its toasts for this reason: "Ein
  eingebettetes AppKit-Glas folgt SwiftUIs Übergängen nicht sicher" ("embedded
  AppKit glass does not reliably follow SwiftUI transitions",
  [ToastGlass.swift](https://github.com/Silvertree2010/ApolloShell/blob/3c88b90/Sources/ApolloShell/ToastGlass.swift)).
  Fact: our spike drew glass capsules over the desktop (screenshot).
- **`NSGlassEffectView`** (macOS 26; `cornerRadius`, `tintColor`, `style`
  `.regular`/`.clear`, `contentView`; SDK `NSGlassEffectView.h`) suits a
  whole-window glass background (Maccy, ApolloShell edge panels). Pills do not
  need it.
- `host.sizingOptions = []`. Without it, SwiftUI's preferred size fights the
  panel frame and the glass edge moves (ApolloShell
  [SidebarScreen.swift L37-40](https://github.com/Silvertree2010/ApolloShell/blob/3c88b90/Sources/ApolloShell/SidebarScreen.swift#L37-L40);
  [Reddit post by its author](https://www.reddit.com/r/SwiftUI/comments/1whyoc0/hosting_swiftui_views_inside_nsglasseffectview/)).
- Shadows: `hasShadow = false` on the window. The glass has its own edge. Add
  no SwiftUI `.shadow` unless the spike shows pills lack contrast on a light
  wallpaper.
- **Pitfall:** glass may look flatter, "a simple blur", while the app is not
  focused ([HWS forum, open question, Sep 2025 – Mar 2026](https://www.hackingwithswift.com/forums/swiftui/glasseffect-in-floating-window-panel/30067)).
  Our app is always inactive while pills show. Nobody has found a fix; accept
  it. Our screenshot looks fine.
- **Pitfall:** glass drawn off screen is white (ApolloShell ToastGlass
  comment). Snapshot tests cannot check it. Keep it out of the test target,
  as §14.6 of DESIGN.md already says.
- Reduce Transparency and Increase Contrast: the system glass handles them
  (DESIGN.md §5.9).

## 6. Click-through for transparent areas

- **Fact (DynamicNotchKit owner, [issue #48](https://github.com/MrKai77/DynamicNotchKit/issues/48)):**
  `ignoresMouseEvents` has three states. On a borderless window, *never
  assigning* the property lets clicks hit opaque pixels and pass through
  transparent ones. *Assigning `false`* turns that pass-through off for the
  life of the window. `NSWindow` has no `hitTest` to override. Sources there:
  [loomhq/ElectronMacOSClickThrough](https://github.com/loomhq/ElectronMacOSClickThrough)
  and [SO 29441015](https://stackoverflow.com/questions/29441015/click-through-custom-nswindow/29451199#29451199).
- DynamicNotchKit ships a half-screen transparent panel that depends on this.
- So the fixed 380 × 560 panel costs nothing where it is empty. Gaps between
  pills, and the area above them, pass clicks to the app below.
- `ignoresMouseEvents = true` is only for overlays with no interaction at all
  (CodexBar confetti and alerts).
- Not tested here by clicking (the spike posts no synthetic events). Spike item.

## 7. Showing, placing and leaving

**"Away" predicate (fact: these APIs exist in SDK headers):**
`!NSApp.isActive && !(mainWindow?.occlusionState.contains(.visible) ?? false)`.
- `occlusionState` is not `.visible` when the window is minimised, hidden
  (⌘H), on another Space, or fully covered.
  - **Guess:** a window on another Space reports "not visible". Spike item.
- Inputs: `NSApplication.didBecomeActive` and `didResignActive`,
  `NSWindow.didChangeOcclusionState` (ignore the panel's own),
  `NSApplication.didChangeScreenParameters`. There is no polling.
- The occlusion part stops duplicates: if the main window is in plain view on
  a second display, the status area already shows everything.

**Which screen:** the screen under the pointer when the pills appear. The user
just clicked there to leave our app. Fallback is `NSScreen.main`, which
means "the screen containing the window that is currently receiving keyboard
events" ([Apple](https://developer.apple.com/documentation/appkit/nsscreen/main)).
- **Guess:** while our app is inactive, `NSScreen.main` may report our own last
  key window's screen. That is why the pointer comes first.

**Where:** bottom-right of `screen.visibleFrame`, inset 12 pt.
- `visibleFrame` leaves out the menu bar (with the notch) and the Dock.
- Pills stay away from the top-right corner, where system banners appear.
- With Dock auto-hide, `visibleFrame` includes the Dock strip. The Dock
  (level 20) then covers the pills while shown, which is acceptable.
- Placed again on each show and on screen-parameter changes.
- With "Displays have separate Spaces", the panel lives on one display.

**Simpler choice, skipped:**
- Notch placement. It needs `safeAreaInsets` and `auxiliaryTopLeftArea` maths
  or DynamicNotchKit. It exists only on built-in displays, and menu bar items
  live there. Add it when asked.
- Dragging with a remembered position. It needs `isMovable = true`,
  `WindowDragGesture()` + `.allowsWindowActivationEvents()` (Apple's own
  example), and an origin per screen in `UserDefaults`. That is a display
  preference, which DESIGN.md §13 allows. Add it when someone wants another
  corner.

**Full screen, Spaces, Stage Manager:**
- `.canJoinAllSpaces + .fullScreenAuxiliary` shows the panel over other apps'
  full-screen Spaces. `.stationary` keeps it still in Mission Control.
  `.canJoinAllApplications` keeps it out of Stage Manager layout.
- When our own main window is full screen and the user swipes away, occlusion
  reports it not visible, so the pills show.

**Open the main window at the pane (click on a pill, or "Open"):**
- Reuse the status-area row action (DESIGN.md §12: select host, workspace,
  tab and pane). Then `NSApp.activate()` and bring the main `Window` forward.
- Store the `OpenWindowAction` from the main scene at launch, so "Open" also
  works after the user closed the window.
- `activate()` "doesn't guarantee app activation" under cooperative activation
  ([Apple](https://developer.apple.com/documentation/appkit/nsapplication/activate())).
  - **Guess:** a click in our own panel counts as user intent. If the spike
    shows a refusal, fall back to the deprecated `activate(ignoringOtherApps: true)`.
- Activation fires `didBecomeActive`, and the panel orders out by itself.
- It never calls herdr focus methods (D12).

## 8. How pills fit the rest of the design

**Which pills:**
- One pill per agent that needs you: blocked, or finished and not seen. That
  is the same list as the status area rows (§12), so it is already computed.
- Plus one summary pill, "3 working", which opens the main window.
- Order: blocked, then done. At most 4 agent pills, then "+N", which opens
  the main window.
- Simpler choice: no pill per working agent, because ten permanent capsules
  are noise. No workspace grouping until asked.

**Data:**
- Pills read only `agent_status` and `completion_seq` from the existing
  `HostStore` snapshot (DESIGN.md §7.5, §12). No extra herdr calls.
- SwiftUI redraws when the `@Observable` objects change. There are no timers.

**One control rule (D7):**
- The card is the existing chat view in a compact size: transcript tail for
  pi, Claude and Codex, screen text otherwise, the composer with
  `agent.prompt`, and the blocked panel with `agent.send_keys` buttons
  (DESIGN.md §11.1–11.3).
- It never opens `terminal session control` or `observe`. So looking at a pill
  never resizes a PTY or takes a pane.
- `agent.prompt` refuses while blocked (`agent_blocked`), so a reply can never
  approve a prompt by accident.

**Energy:**
- Collapsed pills cost nothing beyond drawing.
- Only one card can be expanded. While it is open, it costs what the chat view
  costs: one `tail -F` channel, or the 1 s `pane.read` for screen text (D18).
  The cost stops on collapse.
- Do not use `repeatForever` animations or animated "working" dots in pills.
  Use a static SF Symbol, because the panel can sit on screen for hours.

**Seen (§9.6):**
- Expanding a "done" pill does not mark it seen. Collapsing it, sending a
  reply, or "Open" does. Opening selects the pane, which marks it seen through
  the normal path.
- So the pill does not vanish from under the user while the card is open.
  Showing or hovering a pill never marks it seen.

**Notifications (D20):**
- Rule: `postBanner = !pillPanelOnScreen || NSWorkspace.shared.isVoiceOverEnabled`.
- While pills show, they are the alert, and status changes post no banner.
- The Dock badge stays as it is.
- Notification removal on "seen" stays as it is (id `"<host>|<terminal_id>"`).
- When the user returns to the app, the panel hides. Nothing posts
  retroactively, because the status area shows the same list.
- **Guess:** `UNNotificationInterruptionLevel.passive` ("added to the
  notification list without lighting up the screen or playing a sound",
  [Apple](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel/passive))
  might keep history in Notification Center without a banner on macOS. Check
  before relying on it.

**Accessibility:**
- Each pill is one element. Label: "codex, blocked, infra" (symbol plus word,
  never colour alone, §5.9). Actions: Expand (the button) and "Open in
  Herdlight" (`accessibilityAction(named:)`, plus a context menu).
- Pills cannot be reached by keyboard while another app is active, and v1 has
  no global hotkey. So pills must never be the only path. The status area,
  banners when VoiceOver is on, and the Dock badge remain.
- Reduce Motion: `@Environment(\.accessibilityReduceMotion)` turns off the
  morph animation (the skeleton passes `nil` animation).

**iOS:** none of this applies. The code goes behind `#if os(macOS)`. The iOS
counterpart would be a Live Activity, which is out of scope.

## 9. Code skeleton (compile-checked)

- Checked with `swiftc -typecheck -parse-as-library -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos26.0 -swift-version 6`.
  Command Line Tools SDK 27.0, Swift 6.4.
- **TYPECHECK_OK, then built and run.**
- Command Line Tools lack the `SwiftUIMacros` plugin. On this SDK `@State` is
  a macro, so it failed with "plugin for module 'SwiftUIMacros' not found".
  The checked copy (`Pills_clt.swift`) spells `@State` out as a `State<…>`
  property. Xcode has the plugin, so use the version below there.
- Run result (`main.swift` in the spike folder): `layer 3`, `visible true`,
  `key false`, `appActive false`, frontmost app stayed `Ghostty`.

```swift
import AppKit
import SwiftUI

/// One borderless, non-activating panel that holds every pill.
final class PillPanel: NSPanel {
    /// True only while a card is expanded, so a collapsed pill can never take the keyboard.
    var takesKeyboard = false
    override var canBecomeKey: Bool { takesKeyboard }
    override var canBecomeMain: Bool { false }

    init(rootView: some View, size: NSSize = NSSize(width: 380, height: 560)) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            // .nonactivatingPanel must be in the init mask: setting it later does not
            // update the WindowServer tag (philz.blog/nspanel-nonactivating-style-mask-flag).
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
                              .fullScreenAuxiliary, .canJoinAllApplications]
        hidesOnDeactivate = false      // NSPanel default is true: it would vanish exactly when we need it
        canHide = false                // stays up when the user presses Cmd-H on the app
        becomesKeyOnlyIfNeeded = true  // clicks on buttons do not take the keyboard; text fields do
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false              // SwiftUI glass draws its own edge; a window shadow doubles it
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        let host = NSHostingView(rootView: rootView)
        host.sizingOptions = []        // the panel has a fixed size; SwiftUI must not resize it
        contentView = host
        // Do NOT assign ignoresMouseEvents at all. Left unset, clicks on fully
        // transparent pixels pass through to the window below (DynamicNotchKit #48).
    }
}

@MainActor
final class PillController {
    let panel: PillPanel
    weak var mainWindow: NSWindow?
    var enabled = true { didSet { update() } }
    private var tokens: [NSObjectProtocol] = []

    init(panel: PillPanel) {
        self.panel = panel
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didChangeScreenParametersNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]
        for name in names {
            tokens.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] note in
                guard !(note.object is PillPanel) else { return }
                MainActor.assumeIsolated { self?.update() }
            })
        }
    }

    /// "Away" = the app is not frontmost and its main window cannot be seen
    /// (minimised, hidden, covered, or on another Space).
    func update() {
        let mainVisible = mainWindow?.occlusionState.contains(.visible) ?? false
        if enabled && !NSApp.isActive && !mainVisible {
            place()
            panel.orderFrontRegardless()   // shows without making it key or activating the app
        } else {
            panel.orderOut(nil)
        }
    }

    /// Bottom-right corner of the visible frame of the screen the pointer is on (the user
    /// just clicked there to leave the app): never under the menu bar, notch or Dock,
    /// and away from the top-right corner where system banners appear.
    private func place() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let v = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: v.maxX - panel.frame.width - 12, y: v.minY + 12))
    }

    func setExpanded(_ expanded: Bool) {
        panel.takesKeyboard = expanded
    }
}

struct PillItem: Identifiable, Hashable, Sendable {
    let id: String          // "<host>|<terminal_id>"
    let agent: String       // "codex"
    let status: String      // "blocked", "done", "working"
    let symbol: String      // SF Symbol for the status
    let workspace: String
}

struct PillStack<Card: View>: View {
    let pills: [PillItem]                      // same list as the sidebar status area
    let card: (PillItem) -> Card               // the existing chat view, compact
    let open: (PillItem) -> Void               // activate app, select host/workspace/tab/pane
    let expandedChanged: (PillItem?) -> Void   // panel.takesKeyboard + mark seen on collapse

    @State private var expanded: PillItem.ID?
    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(pills) { p in
                    if expanded == p.id { expandedCard(p) } else { pill(p) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: expanded)
        .allowsWindowActivationEvents()        // first click in an inactive window reaches the buttons
        .onChange(of: expanded) { _, id in
            expandedChanged(pills.first { $0.id == id })
        }
    }

    private func pill(_ p: PillItem) -> some View {
        Button { expanded = p.id } label: {
            Label("\(p.agent) · \(p.status)", systemImage: p.symbol)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .capsule)
        .glassEffectID(p.id, in: glass)
        .accessibilityLabel("\(p.agent), \(p.status), \(p.workspace)")
        .accessibilityAction(named: "Open in Herdlight") { open(p) }
        .contextMenu { Button("Open in Herdlight") { open(p) } }
    }

    private func expandedCard(_ p: PillItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(p.agent) · \(p.workspace)", systemImage: p.symbol).font(.headline)
                Spacer()
                Button("Open", systemImage: "arrow.up.forward.app") { open(p) }
                Button("Close", systemImage: "xmark") { expanded = nil }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            card(p)
        }
        .padding(12)
        .frame(width: 356, height: 300)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .glassEffectID(p.id, in: glass)
        .onExitCommand { expanded = nil }
    }
}
```

Wiring in the app delegate (not compiled; uses app types):
```swift
let panel = PillPanel(rootView: PillStack(
    pills: store.needsYou,                                   // status-area list (+ the expanded one)
    card: { ChatView(pane: store.pane($0.id), compact: true) },
    open: { store.select($0.id); NSApp.activate(); openMainWindow() },
    expandedChanged: { pills.setExpanded($0 != nil); if $0 == nil { store.markSeenLastExpanded() } }))
let pills = PillController(panel: panel)
pills.mainWindow = mainWindow                                // from the Window scene, once
```
- Simpler choice: the panel stays ordered front while away even when the list
  is empty. An empty view is fully transparent and lets clicks through, so no
  "is empty" wiring is needed.
  - **Guess:** VoiceOver may list an empty window. If so, order out when the
    list is empty.

## 10. Pitfalls (checklist)

1. `.nonactivatingPanel` must be in the `init` style mask. Never toggle it later (philz.blog).
2. NSPanel `hidesOnDeactivate` defaults to `true`, so set it to `false`.
3. `canHide` defaults to `true`, and ⌘H would hide the pills. Set it to `false` (CodexBar).
4. Never assign `ignoresMouseEvents = false`. It kills click-through for good (DynamicNotchKit #48).
5. Collapsed pills: `canBecomeKey == false`. Never call `makeKey` or autofocus on show or expand (Unwait).
6. The first click may be swallowed. Use `.allowsWindowActivationEvents()`, or override `acceptsFirstMouse` (ApolloShell).
7. Use `sizingOptions = []` and a fixed panel size. Resizing a panel on every content change flickers unless it is one `setFrame(_:display:)` call (Unwait); a fixed size avoids it.
8. `hasShadow = false` with glass (ApolloShell).
9. AppKit controls draw grey or inactive in an inactive app (ApolloShell). Use our own colours for status.
10. Glass may render flatter while the app is inactive (HWS forum), and glass drawn off screen is white (ApolloShell). Do not snapshot-test it.
11. No I-beam cursor over the field in an inactive app (PitNikola). This is a known bug; accept it.
12. Observe occlusion for the main window only (filter the panel's own notification).
13. `NSApp.activate()` is a request under cooperative activation (macOS 14+).
14. With Dock auto-hide, `visibleFrame` includes the Dock strip. The Dock covers the pills while shown.
15. The card must reuse the chat view. A terminal surface in the card would break D7 (one control rule) and the PTY size rule (§9.5).
16. Do not post a banner and show a pill for the same event (§8).

## 11. Spike list (S-pill, half a day)

Pass criteria, all on macOS 26:
1. Type in Ghostty while the pills appear and update. No character is lost,
   and Ghostty's title bar stays active (Unwait's test).
2. Click a pill, then a key button on a blocked card. The app stays inactive
   and the menu bar stays Ghostty's.
3. Click the reply field. Typing works, as do ⌘V and ⌘A. Enter sends
   `agent.prompt`. Esc collapses the card. Check whether
   `orderOut` + `orderFrontRegardless` gives the keyboard back.
4. Test `becomesKeyOnlyIfNeeded = true` with a SwiftUI `TextField`: does the
   field get focus? If not, set it to `false`.
5. Clicks in the transparent 380 × 560 area reach the window below.
6. Pills show over a full-screen app, on every Space, in Mission Control and
   with Stage Manager on, and while our app is hidden (⌘H).
7. `occlusionState` is not `.visible` for a main window on another Space, and
   for a minimised one.
8. Two displays: the pills follow the pointer's screen on each show.
9. "Open": the app activates, the window comes forward at the pane, and the
   pills hide.
10. VoiceOver reads "codex, blocked, infra" and offers the Open action.
    Reduce Motion stops the morph.
11. Activity Monitor: no wakeups from the app while pills are idle.

---

## Lessons for our app

**Copy:**
- `NSPanel` with `[.borderless, .nonactivatingPanel]` set in `init`;
  `[.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary, .canJoinAllApplications]`;
  `hidesOnDeactivate = false`; `canHide = false`.
  Seen in boring.notch, CodexBar, BrightIntosh and Unwait.
- A `canBecomeKey` flag that is true only while expanded (ApolloShell).
- One fixed-size transparent panel for all pills, with click-through left at
  its default (DynamicNotchKit).
- SwiftUI `.glassEffect` + `glassEffectID` in one `GlassEffectContainer` for
  the morph; `hasShadow = false`; `sizingOptions = []` (ApolloShell).
- Reuse what exists: the status-area list for pills, the chat view for the
  card, the status-row action for "Open". The new code is about 170 lines.

**Avoid:**
- SwiftUI `UtilityWindow` (it hides when the app is inactive).
- `Window` + `.windowLevel(.floating)` (it activates the app).
- A plain `NSWindow` (NotchDrop).
- Setting `ignoresMouseEvents = false`.
- Toggling the style mask after `init`.
- Autofocusing the reply field.
- Terminal streams in the card.
- Animated "working" dots.
- A banner and a pill for the same event.
- Notch placement, dragging and per-workspace pills until someone asks.
