# Phase 4b: actions (close, zoom, new tab/workspace/session, palette)

Goal: the placeholder controls from 3b work, plus the actions the user asked for after
testing. Everything is a herdr call followed by a snapshot read (never patch state by hand),
creates pass `focus:false`, and closes ask first.

Read first: `docs/content/docs/talking-to-herdr.mdx` ("Writes are herdr calls"),
`docs/content/docs/ui/window.mdx` (zoom), `docs/content/docs/layout.mdx` (zoom is the
app's own), decisions D11, D39, D41.

## Build

1. **Close pane** (card header ×, ⌘W): `pane.close`. Ask first unless the pane's only
   foreground process is its shell (`pane.process_info`, D41).
2. **Zoom pane** (card header button, ⇧⌘↩, double-click the header): the app's own zoom
   (D11): the card fills the whole strip page as if it were the only pane; same button or
   keys restore. Its terminal resizes to the zoomed size; the others keep theirs. Never
   `pane.zoom`.
3. **New tab**: the title-bar `+` and ⌘T: `tab.create {workspace_id, cwd}` with the cwd of
   the keyboard card; select the new tab once the snapshot shows it.
4. **Close tab**: an × on hover on each tab row in the sidebar and each title-bar capsule
   (it takes the capsule's single status slot while hovered, gorex order). Always asks,
   with the pane count (D41). `tab.close`.
5. **New workspace**: a `+` in the sidebar (e.g. at the right of the bottom bar or the
   top): `workspace.create {cwd: $HOME}`; select it once it appears.
6. **Session picker**:
   - show running sessions only by default, with a small toggle ("Show stopped") that
     reveals stopped ones (dimmed, not selectable, or selectable = starts them, see 7);
   - **New Session** (row and ⇧⌘N) and "Filter or create…" + Enter with a name that does
     not exist create a session and switch to it. A name is required for the row: generate
     a readable two-word name (like the references: `lunar-ridge`) when none is typed.
7. **Starting a session server** (amends D39). D39 forbade starting herdr from the app
   because the app would become the macOS "responsible process" for every agent (privacy
   prompts would name Herdlight) and share its process group. Start it so launchd, not
   the app, is the parent and responsible process: research the simplest reliable way
   (e.g. `launchctl` with a one-shot job, no KeepAlive) and verify with a throwaway
   session that the server's parent is launchd and that it survives the app quitting.
   If nothing clean works, open a Terminal window running `herdr --session <name>` and
   record why. Record the outcome as a new decision amending D39.
8. **Command palette** (the title-bar ⌘ button and ⌘K): a centered floating glass panel
   with a search field listing sessions, workspaces and tabs (and later actions);
   type to filter, arrows to move, Enter to jump, Esc to close. Reuse the session picker's
   filter and row styles.
9. **e2e** for each: close pane (shell-only, no prompt) removes the card; close tab asks and
   removes it; + makes a tab and selects it; + workspace appears and is selected; zoom
   fills the page and restores; new session appears in the picker and is selected (then
   deleted by the test); the palette filters and jumps to a tab; "Show stopped" toggles.

## Done when

- e2e green locally and in CI; screenshots of the confirmation dialogs, zoom, palette.
- Decisions recorded (D39 amendment, palette shortcut).
