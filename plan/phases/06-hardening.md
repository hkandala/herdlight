# Phase 6: hardening and v0 wrap-up

Goal: v0 is solid end to end and documented; CI green; nothing extra.

## Build

1. **Failure paths, each with an e2e test or a recorded manual check**:
   - herdr session stopped while the app runs → clear state, recovers when restarted;
   - a pane closed in herdr while streaming → card disappears, no crash, no zombie
     `herdr` children (`pgrep -f "terminal session"` after quit is empty);
   - another client takes over a pane → card shows "In use elsewhere · Take back"; Take
     back works;
   - switching sessions repeatedly leaks no processes.
2. **Ponytail audit** of the whole app with the ponytail-audit skill; delete what is not
   needed.
3. **Docs**: update the root `README.md` (how to build, run, test; layout of the code),
   `AGENTS.md` (only if a rule changed), and mark build-order step 1's v0 subset done in
   `plan/README.md` with what was deferred.
4. **CI**: all jobs green on `main`; e2e time reasonable (note it).

## Done when

- The orchestrator runs the full e2e suite, plays with the app against a throwaway session
  (and looks at `default` read only), and finds nothing broken.

## Known issues carried in (fix or record)

- **Window restored in full screen** loses the whole title row (no session button,
  sidebar toggle or pills; hovering shows an empty gray bar) until ⌃⌘F twice. Appears
  after quitting while in full screen. `.windowToolbarFullScreenVisibility(.onHover)` only
  takes effect on an enter transition. Fix it (e.g. leave and re-enter full screen once on
  restore, or don't restore full screen) and add a check. See phase 5 findings.
- **IME composition** (marked text, e.g. Japanese kana) was not tested; only committed
  text (Character Viewer) was. Test with an input source if it can be added and removed
  cleanly, otherwise record.
- **Phased trackpad gestures** are covered by hand checks only (e2e covers the wheel path).
- `Package.resolved` `originHash` churns when Xcode resolves in another checkout; make
  sure builds don't leave the tree dirty (or document it).
