# AGENTS.md

Herdlight: a native SwiftUI client for herdr (macOS now, iOS later).

## Read first

- `plan/README.md` (scope, modules, phases), `plan/standards.md`, `plan/rules.md`.
- The design in `docs/content/docs/` wins on any conflict.

## Rules

- Ponytail: the simplest code that works; no speculative abstractions or "for later" code.
- `make lint build test e2e` before you push. Never `git commit --no-verify`.
- Small atomic commits.
- e2e tests (XCUITest against a real herdr) over unit tests. Unit tests only for logic
  with branches.
- herdr: existing sessions are read only. Never run the app or a `control` stream against
  them. Write only to throwaway sessions `hl-e2e-*` / `hl-dev-*`, and delete them after.
- Never call herdr focus methods. Every herdr argv carries `--session`.
- Add a lint rule or a script instead of a line here when a tool can check it.
