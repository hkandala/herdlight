# Herdlight v0 plan

**Status: v0 is done** (phases 1–6 merged): the v0 subset of build-order step 1, This Mac only. See the root
`README.md` for how to build, run and test.

Deferred past v0 (in the design, not built): remote machines over SSH, the iOS app (the target only builds and
shows an empty state), plugins and plugin cards, the chat view, floating panes, notifications, the status area
and pills, drag and drop, divider drag, more machines in the sidebar ("Add Remote Host" is a placeholder), a
text size setting, the "seen" state for finished agents, IME composition tests, and trackpad gestures in e2e
(checked by hand).

The working plan for the first app code. The design lives in `docs/content/docs/` and wins
on any conflict, except where this file narrows the scope for v0.

## The request (from the user, structured)

Build the first, very basic version of the Herdlight app:

1. **Scaffold.** A standard Xcode project (created the way Xcode creates it), one
   multiplatform SwiftUI app target. macOS is the real target. iOS is boilerplate only: it
   builds, launches and shows an empty state. No iOS backend, no simulator work in v0.
2. **Terminal panes with libghostty.** Use the official `Lakr233/libghostty-spm`
   (`GhosttyTerminal`). Switch to uHerdr's patched build only if tests show double replies
   to terminal queries.
3. **Interface like herdr.** Sidebar, tabs, panes, horizontal and vertical splits, laid out
   exactly as herdr lays them out (its split tree and ratios).
4. **First backend: herdr on This Mac.** Follow the design
   ([talking-to-herdr](../docs/content/docs/talking-to-herdr.mdx)): `remote-api-bridge` per
   call, one `events.subscribe` stream, paced `session.snapshot` reads, and
   `herdr terminal session control` per visible pane.
5. **Live panes.** As soon as the app opens, the selected tab's panes attach and fit their
   card (cols × rows from the card size). Typing, clicks, Nerd Font glyphs and scrolling
   work.
6. **Horizontal scrolling across tabs.** One tab = one page in a horizontal strip. A
   sideways trackpad swipe pages between tabs.
7. **Session picker.** The sidebar lets the user pick a herdr session
   (`herdr session list`). Default: `default`.
8. **Liquid Glass**, dark theme, and the look of the reference screenshots in
   `resources/inspirations/ui-target/` (frosted window, glass sidebar with filter, session
   picker with filter, title-bar tabs, frosted pane cards). See phase 3b.
9. **Clear modules**, easy to extend later (machines, iOS, plugins come after v0).
10. **Ponytail, strictly.** The simplest thing that works. No speculative code.
11. **End-to-end tests first.** The app must be testable end to end, by agents too: launch
    it, see the GUI, drive it, fix what breaks. Unit tests only where logic is non-trivial.
12. **CI.** GitHub Actions runs lint, builds and the e2e suite.
13. **Lint and format** on every commit (pre-commit hook) and in CI.
14. **Small atomic commits**, pushed regularly.
15. **`AGENTS.md`**, concise. Anything a tool can check goes in a tool, not in prose.

## Confirmed decisions

| Topic | Decision |
|---|---|
| Transport | The design: `herdr --session S remote-api-bridge` (one call per request, 10 s timeout), events on one long-lived bridge run, terminals via `herdr --session S terminal session control <terminal_id>` |
| Scope | This Mac only. Read the layout, show it live, type, click, scroll, resize to fit, swipe tabs, pick a session. No divider drag, drag and drop, close/split UI, plugins, chat, floating panes, zoom, remote machines, notifications |
| iOS | Boilerplate: the same target builds for iOS and shows an empty state |
| Terminal | Official `libghostty-spm`, exact pin |
| Project | A committed `Herdlight.xcodeproj` in Xcode's own format (file-system synchronized groups), plus a local Swift package `HerdrKit` |
| Lint / format | SwiftFormat (formatting) + SwiftLint (lint), the most common pair in the Swift community |
| CI | GitHub Actions, `runs-on: xcode-27`. Repo is public |
| herdr safety | Existing sessions: read only. Every write goes to throwaway sessions named `hl-e2e-*` / `hl-dev-*`, cleaned up afterwards |
| Bundle id | `dev.hkandala.herdlight`, signed to run locally, no team. App Sandbox off, Hardened Runtime on |
| Minimum OS | macOS 26, iOS 26 |

## Modules

```
Herdlight.xcodeproj
Herdlight/                 the app target (SwiftUI, macOS + iOS)
  App/                     @main, scenes, launch arguments
  Store/                   HostStore: the live @Observable model of one herdr session
  Terminal/                libghostty glue, TerminalStream wiring, PaneViewRegistry
  Views/                   Sidebar, TabBar, Strip, SplitLayout, PaneCard
HerdlightUITests/          XCUITest end-to-end suite (macOS)
Packages/HerdrKit/         Swift package, no UI: Exec, ProcessExec, HerdrClient (call,
                           events, pacing), lenient models, split-tree rebuild,
                           TerminalStream (control NDJSON). Tests: `swift test`
scripts/                   e2e session setup/teardown, helpers
```

`HerdrKit` knows nothing about SwiftUI or libghostty. The app knows nothing about argv or
JSON. That seam is where remote machines and iOS plug in later.

## Phases

| # | Phase | File |
|---|---|---|
| 1 | Scaffold, tooling, CI, e2e harness | [phases/01-scaffold.md](phases/01-scaffold.md) |
| 2 | HerdrKit control plane | [phases/02-herdrkit.md](phases/02-herdrkit.md) |
| 3 | App shell: sidebar, tabs, strip, splits | [phases/03-app-shell.md](phases/03-app-shell.md) |
| 3b | UI style: match the reference look | [phases/03b-ui-style.md](phases/03b-ui-style.md) |
| 4 | Live terminals | [phases/04-terminals.md](phases/04-terminals.md) |
| 4b | Actions: close, zoom, new tab/workspace/session, palette | [phases/04b-actions.md](phases/04b-actions.md) |
| 5 | Swipe across tabs, tab pills, chrome polish | [phases/05-strip-and-glass.md](phases/05-strip-and-glass.md) |
| 6 | Hardening and v0 wrap-up | [phases/06-hardening.md](phases/06-hardening.md) |

Rules for working: [rules.md](rules.md). Coding standards: [standards.md](standards.md).

## Known risks (check early)

- **Key encoding.** herdr frames carry none of the inner app's modes (application cursor
  keys, kitty keyboard, bracketed paste). libghostty encodes keys from its own state, which
  may be wrong. herdr-web solved it by sending special keys as herdr logical keys
  (`pane.send_keys`). Phase 4 tests arrows in `less`/`vim` and Shift+Enter, and picks the
  simplest path that works.
- **Session resolution for `terminal session`.** herdr-web had to set `HERDR_SOCKET_PATH`;
  the design uses `--session S`. Phase 2 checks which one herdr 0.9.3 honors.
- **Scroll routing.** Terminal views eat scroll events; horizontal swipes must page the
  strip (design: one `NSEvent` monitor with an axis lock). Phase 5.
- **XCUITest drives the real mouse and keyboard** on this Mac. Local e2e runs interrupt
  the user; keep them short and scoped.

## References

- herdr-web (`~/code/herdr-web`, the user's working web client): stream handling, input,
  mouse and sizing notes in its README and `server/terminal-stream.ts`, `src/lib/keys.ts`.
- `resources/research/herdr-core.md`, `resources/research/macos-clients.md`,
  `resources/research/gorex.md` (tab bar behavior).
- libghostty-spm README and its `Example/GhosttyTerminalApp/`.
