# Shared brief for research agents

Goal of the overall project: design a native Swift macOS + iOS app (one codebase if possible) that is a GUI
front-end for **herdr** (https://github.com/herdrdev/herdr, agent-aware terminal multiplexer, v0.9.3 installed
locally at ~/.local/bin/herdr, live socket at ~/.config/herdr/herdr.sock — we are running INSIDE herdr right now,
so NEVER kill/restart the server, never close workspaces/panes you did not create; read-only queries are fine).

The app relies on herdr as the backend (herdr owns workspaces/tabs/panes/agents/PTYs). The app provides:
- Liquid-glass style UI, sidebar of workspaces expandable to show agents (with agent icons), status/notification area.
- Multiple hosts (local + remote machines); sidebar swipes horizontally between hosts (like Arc spaces).
- Main area: horizontally scrolling strip of panes across tabs (swipe through panes; tab bar switches as you scroll).
- Resizable panes, zoom a pane fullscreen, move panes between tabs/workspaces.
- Pane types: terminal, agent (claude/codex/pi/opencode...), and WEB PAGE (herdr can't render web pages, so a
  placeholder pane in herdr must encode the URL so the UI can render a WKWebView in its place, app stores nothing).
- Any terminal/agent pane can switch to a CHAT view (like herdr-web-ui does).
- Design must follow "ponytail" principles: simplest thing that works, reuse herdr/platform features, no speculative
  abstractions, app stores as little as possible.

Output rules:
- Clone repos into /tmp/herdr-research/<repo-name> (shallow clone `git clone --depth 1`).
- Write findings to the markdown file path you were given. Be concrete: cite file paths + short code snippets,
  exact socket method names / JSON shapes, transport details. Facts over opinions; mark guesses as guesses.
- End your report with "Lessons for our app" (what to copy, what to avoid).
