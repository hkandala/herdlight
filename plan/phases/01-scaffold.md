# Phase 1: scaffold, tooling, CI, e2e harness

Goal: an empty app that builds for macOS and iOS, a HerdrKit package that tests, lint and
format on every commit, CI green, and an e2e harness that launches the app against a
throwaway herdr session.

## Build

1. **Xcode project** `Herdlight.xcodeproj` at the repo root, as Xcode 27's
   *Multiplatform → App* template makes it: one app target `Herdlight` (macOS + iOS),
   SwiftUI lifecycle, file-system synchronized groups (`objectVersion` 77), Swift 6
   language mode, strict concurrency complete, warnings as errors.
   - Create it with Xcode itself if you can drive it; otherwise write the project in
     exactly that format, then open it in Xcode once (`open Herdlight.xcodeproj`, take a
     screenshot) and confirm Xcode loads it without changes or upgrade prompts.
   - Bundle id `dev.hkandala.herdlight`, deployment macOS 26.0 / iOS 26.0, sign to run
     locally (`CODE_SIGN_IDENTITY = "-"`, no team), App Sandbox off, Hardened Runtime on.
   - A shared scheme `Herdlight` (committed under `xcshareddata`) with the UI test target.
   - Main window: one `Window` scene on macOS (design D34), `WindowGroup` on iOS. Content:
     a placeholder `NavigationSplitView` with "Herdlight" in the sidebar. iOS shows a
     "Herdlight for iOS is coming" empty state, and stays that way in v0.
2. **`Packages/HerdrKit`**: a local Swift package (macOS 26, iOS 26), library `HerdrKit`,
   test target `HerdrKitTests` using Swift Testing. Linked into the app. One trivial
   public symbol and one test, enough to prove the wiring. Phase 2 fills it.
3. **UI test target** `HerdlightUITests` (macOS only), XCUITest. One test: launch the app
   with `-session <name>` and assert the main window and the sidebar exist.
   - Find out if the macOS UI test runner can run `Process` (needed to set up herdr state
     from the test). If not, set up state in a script before `xcodebuild test` and pass the
     session name in through the environment. Write down which one works in this file.
4. **Throwaway herdr sessions**: `scripts/herdr-session.sh up|down <name>` starts a
   headless herdr server for a named session and stops and deletes it. Find out how herdr
   0.9.3 starts a session without a TUI (`herdr --session X server`, or similar). The
   e2e target uses `hl-e2e-<random>`. Never touch existing sessions.
5. **Lint and format**: SwiftFormat (`.swiftformat`) and SwiftLint (`.swiftlint.yml`,
   `--strict`), configured with mostly defaults; turn off only rules that fight each other
   or Swift 6. Exclude `docs/`, `resources/`, DerivedData. Install via Homebrew; pin
   versions in a `Brewfile`.
6. **`Makefile`** targets: `setup` (brew bundle, `git config core.hooksPath .githooks`),
   `format`, `lint`, `build` (macOS + iOS generic, `CODE_SIGNING_ALLOWED=NO` for iOS),
   `test` (`swift test` in HerdrKit), `e2e` (session up → `xcodebuild test` on
   `HerdlightUITests` → session down, even on failure), `run` (build and open the app,
   optional `SESSION=`). Honor `DERIVED_DATA` (default `.build/DerivedData`, gitignored).
   Pipe `xcodebuild` through `xcbeautify` if installed, plain otherwise.
7. **`.githooks/pre-commit`**: `swiftformat --lint` and `swiftlint --strict` on staged Swift
   files. Fast (seconds). Fails the commit on any finding.
8. **CI** `.github/workflows/ci.yml`, `runs-on: xcode-27`, on push and pull request:
   - `lint`: SwiftFormat lint + SwiftLint strict.
   - `build-test`: `make build` (macOS + iOS) and `make test`.
   - `e2e`: install herdr 0.9.3 (official installer, pinned version), `make e2e`, upload
     the `.xcresult` on failure.
   - Cache SwiftPM packages. Cancel superseded runs.
   - The docs-deploy workflow stays as it is.
9. `.gitignore` additions for Xcode/SwiftPM (DerivedData, `.build/`, `xcuserdata`,
   `*.xcresult`).

## Done when

- `make lint build test e2e` pass locally; Xcode opens the project cleanly.
- CI is green on `main`, all three jobs.
- A commit with a formatting error is refused by the hook.
- Screenshot of the running placeholder app.
- This file records: how the project was created, how the throwaway session starts, and
  whether the UI test runner can spawn processes.

## Out of scope

Any herdr calls from the app, libghostty, real UI.

## Findings

- **Project.** Xcode has no command line way to run its project templates, and driving the
  New Project sheet by GUI scripting takes over the user's screen. So the project was
  written by hand from Xcode 27's *Multiplatform → App* template definitions (the
  `TemplateInfo.plist` chain under `Xcode.app/.../Project Templates/MultiPlatform`):
  objectVersion 77, file-system synchronized groups, the template's build settings, with
  only these changes: visionOS removed, deployment 26.0, Swift 6 + strict concurrency
  complete + warnings as errors, sandbox off, Hardened Runtime on, `CODE_SIGN_IDENTITY = "-"`,
  a local package reference to `Packages/HerdrKit`. Xcode 27 opened it with no prompt, no
  issues and no file changes (`git status` clean after open and quit).
- Xcode turns Hardened Runtime off for ad-hoc signed builds ("Disabling hardened runtime
  with ad-hoc codesigning"); it applies once the app is signed with a real identity.
- **Throwaway session.** `herdr --session <name> server` runs a headless server in the
  foreground; `herdr session stop <name>` then `herdr session delete <name>` removes it.
  `--session` wins over `HERDR_SOCKET_PATH`, but `scripts/herdr-session.sh` still unsets
  the `HERDR_*` variables so a server started from inside a herdr pane does not inherit
  them. The script refuses names outside `hl-e2e-*` / `hl-dev-*` and names that exist.
- **UI test runner and processes.** The macOS UI test runner (`*-Runner.app`) is always
  sandboxed by Xcode (app-sandbox, read-only file access, `network.client`; the test
  target's `ENABLE_APP_SANDBOX` does not change it). `Process` runs, but the child is
  sandboxed too: `HOME` is the runner's container, and it cannot connect to herdr's
  sockets (`herdr session list` with the real `HOME` shows every session as stopped). So
  herdr state is set up by `make e2e` before `xcodebuild test`, and the session name
  reaches the test as `TEST_RUNNER_HL_SESSION` (read as `HL_SESSION`). Asserting through
  herdr from inside a test (`pane.read`, `session.snapshot`) needs another path; phase 3
  decides.
- **Tool versions.** Homebrew cannot pin versions, so the `Brewfile` notes the versions in
  use and `.swiftformat` sets `--min-version`. CI installs herdr 0.9.3 from its GitHub
  release with the checksum from `herdr.dev/latest.json`, because the official installer
  always installs the latest release.
