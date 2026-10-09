# Coding standards

Tools enforce what they can (SwiftFormat, SwiftLint, the compiler in Swift 6 language mode
with strict concurrency). This file covers only what tools cannot check.

## Ponytail

Read `/Users/hkandala/code/pi-hkandala/extensions/pi-ponytail/skills/ponytail/SKILL.md`
before writing code. In short:

- Does it need to exist? Is it already here? Does the stdlib, SwiftUI, AppKit or an
  installed package do it? Only then write the minimum.
- No protocol with one implementation, except `Exec` (the design's one seam for local,
  remote and iOS). No factories, managers, coordinators or "service" layers.
- No scaffolding for later phases. A later phase adds what it needs.
- Mark a deliberate shortcut with a `// ponytail:` comment naming its ceiling and upgrade
  path.
- Fewest files. A type gets its own file when it is used from more than one place or
  passes ~200 lines.

## Swift

- Swift 6 language mode, strict concurrency complete. No `@unchecked Sendable` or
  `nonisolated(unsafe)` without a one-line reason.
- UI state: `@Observable` classes on the main actor. No Combine, no `ObservableObject`
  (except where libghostty-spm's API requires it).
- Async: `async`/`await`, `AsyncStream`, structured tasks. Cancel tasks you start.
- Errors: `throws` with a small error enum per module. Show errors in the UI as text; never
  crash on bad input from herdr. No `try!`, no force unwraps outside tests.
- Decoding: hand-written, lenient `Decodable` models with only the fields the app uses
  (design D6). Unknown fields and enum values must not fail decoding.
- Platform code: `#if os(macOS)` at the smallest scope that works.
- Names follow the design's terms: machine, session, workspace, tab, pane, card, strip,
  HostStore, PaneViewRegistry.
- Comments explain why, not what. No commented-out code.

## SwiftUI and look

- Dark theme only, frosted (D44, `docs/content/docs/ui/theme-and-accessibility.mdx`): the
  window background is one behind-window `NSVisualEffectView` under a dark tint (the only
  blur bridge to AppKit); pane cards are translucent with a hairline border; Liquid Glass on
  chrome: sidebar, tab capsules, the session list.
- Use the system glass APIs (`glassEffect`, `glassEffectID`, `GlassEffectContainer`). No
  other custom blur.
- Every control and region an e2e test touches has an `accessibilityIdentifier`
  (`titlebar.session-picker`, `tab.<tab_id>`, `pane.<pane_id>`, ...).
- No hardcoded sizes where layout can decide; the 8 pt gap between cards is the one fixed
  number (design: Layout and sizing).

## herdr

- Every herdr argv carries `--session <name>`.
- Never call herdr focus methods (`*.focus`). Creates pass `focus:false`.
- Never patch local state after a write; read the snapshot again.
- Child processes die with the app; signal by pid, never by process group.

## Tests

- e2e first: XCUITest in `HerdlightUITests` against a throwaway herdr session with a known
  layout. Assert through accessibility identifiers and through herdr itself (`pane.read`,
  `session.snapshot`), not through pixels.
- Unit tests (`swift test` in `Packages/HerdrKit`) only for logic with branches: decoding,
  split-tree rebuild, pacing, envelope/argv building, frame parsing. Recorded herdr JSON
  fixtures live next to the tests.
- No mocks of herdr where the real one is cheap to run. One `Exec` fake is fine for pacing
  tests.
