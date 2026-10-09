# Working rules

## Roles

- **Orchestrator** (the main agent): writes the plan, starts implementers and reviewers,
  relays review comments, checks the GUI, decides when a phase is done. Does not write app
  code.
- **Implementer** (one per phase, one at a time): writes code, tests and commits. Answers
  every review comment with a fix or a one-line reason.
- **Reviewers** (2–3 per round, read only): never edit files or commit. They report findings
  as a numbered list with file:line, severity (blocker / should / nit) and a concrete fix.

## Phase loop

1. Implementer reads `plan/README.md`, `plan/standards.md`, this file, the phase file and
   the design pages the phase links. Then builds the phase, commits as it goes, and reports
   what it did, how it tested, and screenshots of the GUI (paths).
2. Reviewers check in parallel:
   - **Spec**: does the code match the phase file and the design? Bugs, races, leaks,
     error paths, herdr safety rules.
   - **Ponytail**: what can be deleted or simplified? Unneeded types, files, abstractions,
     dependencies. Uses the ponytail-review skill
     (`/Users/hkandala/code/pi-hkandala/extensions/pi-ponytail/skills/ponytail-review/SKILL.md`).
   - **E2E / GUI** (from phase 3): builds and runs the app against a throwaway session,
     drives it, takes screenshots, tries to break it. Runs the e2e suite.
3. Orchestrator merges the findings and sends them to the implementer.
4. Repeat until no blockers and no "should" items remain. Then the implementer pushes and
   CI must be green.

## Commits

- Small and atomic: one logical change per commit, with its tests. Commit as soon as a
  step builds and passes checks. Push after each green step that builds.
- Conventional subject line: `feat(herdrkit): …`, `fix(app): …`, `chore(ci): …`,
  `test(e2e): …`, `docs: …`. Imperative, ≤ 72 chars.
- The pre-commit hook (`.githooks/pre-commit`) must pass. Never `--no-verify`.
- Never commit build output, DerivedData, `.xcresult`, screenshots outside
  `plan/screenshots/`, or secrets.

## Building and running

- Use the `Makefile` targets (`make lint`, `make format`, `make build`, `make test`,
  `make e2e`, `make run`). If you need a new command, add a target.
- Concurrent agents must not share DerivedData: pass `DERIVED_DATA=/tmp/hl-dd-<agent-name>`
  (the Makefile honors it).
- Only one agent drives the GUI at a time (XCUITest and manual runs take over the real
  mouse and keyboard). Take the GUI lock before any GUI driving (running the app and
  clicking, screenshots that need the app frontmost, `make e2e`), and release it right
  after: `until mkdir /tmp/hl-gui.lock 2>/dev/null; do sleep 20; done; echo "$NAME" >
  /tmp/hl-gui.lock/owner` … `rm -rf /tmp/hl-gui.lock`. Hold it for minutes, not hours.
  If a lock is older than 30 minutes, ask the orchestrator before removing it.
- Screenshots: `screencapture -x -l <windowid> <file>` for the app window, or the
  attachments in the `.xcresult`. Put the ones you report in `/tmp/hl-shots/`.

## herdr safety

- Existing sessions (`default` and any other listed by `herdr session list`): read only.
  No writes, no `control` streams, no `--takeover`. Use `observe` or `pane.read` to look.
- Writes, `control` streams and layout changes go only to throwaway sessions named
  `hl-e2e-<id>` (tests) or `hl-dev-<agent>` (manual work). Stop and delete them when done
  (`herdr session stop`, `herdr session delete`). `scripts/` has helpers.
- When running the app by hand against a real session, launch it with the throwaway session
  selected (`-session hl-dev-<agent>` launch argument), never `default`.
