# Phase 4: live terminals

Goal: the selected tab's pane cards are live libghostty terminals attached through
`herdr terminal session control`, sized to their card, with typing, clicks, scrolling and
Nerd Font glyphs working.

Read first: [talking-to-herdr: terminal plane](../../docs/content/docs/talking-to-herdr.mdx),
[platform: making the strip work](../../docs/content/docs/platform.mdx), the libghostty-spm
README and `Example/GhosttyTerminalApp/`, herdr-web `server/terminal-stream.ts`,
`src/lib/keys.ts`, `src/components/TerminalView.tsx` and its README sections on input,
mouse and pane size.

## Build

1. **Dependency**: `Lakr233/libghostty-spm`, product `GhosttyTerminal`, exact version pin
   (latest release). App target only; HerdrKit stays UI-free.
2. **`TerminalStream`** (HerdrKit): runs `herdr --session S terminal session control
   <terminal_id> --cols C --rows R [--takeover]` (or the session resolution found in
   phase 2). Parses `terminal.frame` (base64 ANSI bytes) and `terminal.closed`, writes
   `terminal.input`, `terminal.resize`, `terminal.scroll`, `terminal.mouse`,
   `terminal.release` as NDJSON. Unit test the frame parsing and command encoding.
3. **Control rule** (design D8, Mac): open `control` without takeover; if refused
   (`already has an attached client`), open `observe` and show "In use elsewhere · Take
   back". A key press, paste or click in a watching card reopens with `--takeover`; keys
   typed before the first frame are queued. Handle the closed reasons table from the
   design (not found/exited → wait for snapshot; detached → nothing).
4. **Terminal card**: a libghostty surface with the host-managed (in-memory) backend.
   Frames from the stream are written into the surface. Card size ÷ cell size → cols ×
   rows, sent as `terminal.resize` when the size settles; keep the old frame until herdr's
   full frame at the new size arrives. `keybind = clear` so app shortcuts keep working;
   dark palette; transparent or translucent terminal background so the frosted card from
   phase 3b shows through (text stays crisp and readable).
5. **Input**: decide the simplest correct path and record it here. Test at least: plain
   typing, Enter, Backspace, Ctrl+C, arrows in a shell and in `less`/`vim`, Tab
   completion, Shift+Enter, paste, IME/dead keys. If libghostty's own key encoding is
   wrong because frames carry no input modes, follow herdr-web: special keys as herdr
   logical keys via `pane.send_keys`, the rest as `terminal.input` text.
6. **Mouse and scroll**: clicks and drags → `terminal.mouse` (0-based cells, crossterm
   modifier bits); wheel → `terminal.scroll`. Vertical scroll inside a card must reach
   the terminal.
7. **Glyphs**: Nerd Font icons and box drawing render (Ghostty ships symbol fallback;
   verify with a prompt or `echo` of a few Nerd Font code points).
8. **`PaneViewRegistry`**: owns terminal views keyed by `(session, terminal_id)` so
   SwiftUI never destroys them while the strip scrolls; the newest container adopts the
   view. Streams run for the selected tab only; leaving the tab sends `terminal.release`
   and closes the stream (design: what streams). Neighbor pages keep their last image.
   Release everything on session switch and on quit.
9. **Double replies**: check `printf '\e[c'`, `printf '\e[6n'` and an OSC 11 query in a
   pane. If libghostty answers a second time (junk typed into the shell), record it and
   tell the orchestrator; the fallback is uHerdr's patched build.
10. **e2e**: against a throwaway session:
    - opening the app attaches the selected tab's panes (each card shows the shell prompt:
      check via `pane.read` that the PTY size equals the card's cols × rows);
    - typing `echo hl-$RANDOM` + Enter in a card: `pane.read` shows the output;
    - resizing the window changes the PTY size (`stty size` / `pane.read`);
    - clicking a card focuses it and keys go there, not to the other card;
    - scrolling in a card with long output scrolls (herdr viewport moves, `pane.read`
      differs or a mouse app receives wheel events);
    - switching tabs releases the old tab's panes (a second `control` from the test can
      attach without takeover) and attaches the new one.

## Done when

- e2e green locally and in CI; orchestrator has typed in the app, run `htop`/`vim`,
  resized, clicked, scrolled, and seen Nerd Font glyphs in screenshots.

## Out of scope

Zoom, chat, observe-only iOS mode, the 24-surface LRU (note a `ponytail:` ceiling).

## Findings

Stage A (stream level, against throwaway sessions; no GUI yet).

- **Session resolution.** Phase 2's answer holds: `herdr --session S terminal session
  control|observe <terminal_id> --cols C --rows R [--takeover]`, no socket variable.
- **Frames carry no input modes.** After `printf '\e[?1h\e[?2004h\e[>1u\e[?1000h'` in a pane
  the next frames hold only drawing (`?2026h/l`, `?25h/l`, cursor moves, SGR). herdr draws
  frames from its own cell buffer (`server/render_stream.rs`), so libghostty never learns the
  app's cursor-key, paste, kitty or mouse modes.
- **Key encoding: libghostty's own is wrong for those modes.** With `cat -v` in a pane:
  DECCKM on → `pane.send_keys up` gives `^[OA`, libghostty would send `^[[A`. Kitty flags on →
  `shift+enter` gives `^[[13;2u` and `ctrl+c` gives `^[[99;5u`; libghostty would send `\r`
  and `^C`. `terminal.input` writes bytes to the PTY unchanged (herdr
  `apply_terminal_attach_input`).
- **Input path (decision).** herdr-web's split. These go to `pane.send_keys` by herdr name
  (`PaneSurfaceView.herdrKey`):
  - arrows, Esc and F1–F12, with or without modifiers (Shift+Esc is Esc);
  - Enter, Tab and Backspace with a modifier;
  - Ctrl chords, named by the layout's letter (Dvorak, AZERTY), or by the key's US character
    when the layout's letters are not Latin (Ctrl+С on a Russian layout is Ctrl+C). Shift is
    dropped, as xterm does: Ctrl+Shift+C is Ctrl+C. Trade-off: an app with the kitty keyboard
    cannot tell the two apart;
  - macOS line editing that `keybind = clear` took from libghostty: Cmd+←/→/⌫ → Ctrl+A/E/U,
    Option+←/→ → Alt+B/F.

  Everything else goes through libghostty as text on `terminal.input`: typing, IME, dead keys,
  Option characters (Ghostty's default), and plain Enter, Tab and Backspace (same bytes in every
  mode but kitty's report-all flag; kept off the slower path). Home/End/PgUp/PgDn/Delete have no
  herdr names; libghostty sends them as xterm does. Other Cmd keys stay with the menu.
  Sizes go to herdr 100 ms after the last change, so a window drag does not make the app
  repaint at every step. Input goes out in order through one queue per card, only while the
  stream is live (a failed card drops it); a bridge call takes about 60 ms here (median of 20, max 170), more than a held key's repeat, so keys
  that pile up meanwhile go as one `send_keys` call. Every key name the mapping makes is
  accepted by herdr 0.9.3.
- **Paste.** A whole `ESC[200~…ESC[201~` on `terminal.input` is unwrapped by herdr and framed
  again for the app's own paste mode (checked both ways with `cat -v`). The surface gets
  `ESC[?2004h` once, so libghostty frames every paste (and keeps its file-URL → path handling).
  For an app without paste mode herdr writes the text as is, so line breaks arrive as LF where
  a terminal would send CR. Harmless: shells and the tty treat LF as Enter. libghostty writes a
  paste in three pieces (start mark, text, end mark); the card joins them into one
  `terminal.input`, else herdr sees no whole paste and `cat -v` showed the marks (seen in the
  app).
- **Double replies: none possible at the stream level.** `printf '\e[c\e[6n\e]11;?\a'` in a
  pane: herdr's own terminal answers (the shell then shows `^[[?62;22c`, as in any terminal);
  the frames hold only the drawn result, never the queries, so libghostty has nothing to
  answer. Re-checked with the app attached: the same output as the baseline, and libghostty
  wrote nothing that starts with ESC besides pastes.
- **Closed reasons** (herdr 0.9.3, exact): `terminal attach failed: terminal <id> already has
  an attached client; retry with --takeover`, `terminal attach taken over`, `terminal session
  control failed: terminal target <id> not found`, `terminal <id> exited`, `detached`, `live
  update in progress; reconnect after handoff completes`. A failed connect exits 1 with the
  reason on stderr and no closed line.
- **A killed controller is released.** SIGKILL a `control` run, and a new `control` without
  `--takeover` attaches 50 ms later (herdr removes a disconnected client). So the app does not
  send `terminal.release` on quit: `ProcessExec`'s exit handler kills the children, which frees
  the panes (the design page now says so). Leaving a tab and switching sessions do send
  `terminal.release`; a run that has not answered `detached` within 500 ms is killed.
- **Writes.** `ProcessExec` writes stdin on a serial queue per child, so a full pipe never
  blocks the main actor.
- **Mouse.** Left, right and middle clicks and drags go to herdr as cells (`terminal.mouse`);
  herdr drops them when the app has no mouse mode. libghostty gets left and right too, for local
  selection and Copy (not middle, which it could paste as input). The wheel goes to
  `terminal.scroll` (trackpad points ÷ cell height); libghostty keeps no scrollback. Sideways
  scrolls pass to the strip (phase 5 adds the axis lock).
- **Cell size.** The in-memory session's resize callback carries cols, rows and pixel sizes,
  but no cell size (0). The cell size for the pointer comes from the surface's
  `TerminalSurfaceGridResizeDelegate`; the PTY size still follows the session's callback,
  which libghostty sends from its IO thread after the grid reflowed.
- **Keyboard.** A tab shown for the first time since it was selected gives the keyboard to
  herdr's focused pane in it (`HostStore.showTerminals`); later snapshots leave it where the
  user clicked. The lit card follows the keyboard (`PaneTerminal.hasKeyboard`), not herdr's
  focus, so the bright card is the one keys go to.
- **Checked in the app** (hl-dev-term, synthetic CGEvents): typing, Enter, Backspace, Ctrl+C,
  Up for history, Tab completion, arrows in `less` and `vim`, Shift+Enter / Esc / Option+←
  under kitty flags (`^[[13;2u`, `^[[27u`, `^[[98;3u`), paste in a shell and in `cat -v`,
  clicks moving the keyboard between cards, a click in `vim` with `mouse=a` landing on the
  right line, the wheel in long output (herdr's viewport moved) and in `vim`, window resize
  (`stty size` 27 73 → 33 102 and back), Nerd Font icons and box drawing, `top`, tab switch
  release, a split button making a live card, take over by another client then Take back by
  typing. htop is not installed on this Mac; `top` stood in.
- **e2e.** Each card's terminal view is an accessibility element `terminal.<pane_id>` whose
  value is its grid as `stty size` prints it, so tests compare it with the PTY. The helper's
  `POST /<session>/control` opens a second `control` (released at once) to tell a held pane
  from a released one. The resize test hides the sidebar to widen the cards: under XCUITest a
  drag on the window corner does not resize the window (it does with real events), and CI's
  window already fills its 1024×768 screen, so Window ▸ Zoom changes nothing there. The window
  resize itself was checked by hand. `scroll(byDeltaX:deltaY:)` scrolls where the pointer is
  (hover first) and up for a negative `deltaY`.

## User feedback round (after Stage B hand test)

Fix on the `terminals` branch before merge:

1. **Flicker when a tab becomes active**, worst for full-screen agent TUIs and only while a
   herdr TUI client is also attached. Cause to confirm: on leaving a tab the app releases,
   the herdr TUI lays the panes out at its own size, and on return the app resizes them
   back (two SIGWINCH redraws), possibly plus a first frame at a stale size. Fix:
   - keep control streams of recently shown tabs (herdr-web keeps the last 8 tabs mounted):
     an LRU of tabs, bounded by the design's ~24 live surfaces; off-screen surfaces stop
     drawing (`isSurfaceVisible = false`) but keep reading their stream; release on LRU
     eviction, session switch, pane close, quit;
   - open each stream with the card's exact cols × rows so the first frame is already at
     our size (no resize right after attach);
   - verify with a herdr TUI attached to a throwaway session showing the same tab.
   Update `docs/content/docs/talking-to-herdr.mdx` "What streams" and add a decision.
2. **Remember the active pane per tab.** The keyboard card is the app's own selection per
   tab: coming back to a tab restores the card the user last clicked there. herdr's focused
   pane is used only the first time a tab is shown (layout.mdx rule).
3. **Hover must not look active.** Hovering an unfocused card lightens it a little, clearly
   less than the keyboard card.
4. The held GUI checks: dead key, IME, htop.
