# Herdr GUI / remote client ecosystem (collected 2026-10-08)

Sources: GitHub topics `herdr` / `herdr-plugin` (by language), awesome-herdr, r/herdr, web search.

## Given by user
- **penso/herdr-gpui** — macOS/Linux/Win (Rust, GPUI) — native desktop client via local daemon
- **devswha/herdr-web-ui** — Web / phone — chat + live terminal per agent pane, remote PCs over SSH, web push
- **jerryfane/herdrup** — iOS (SwiftUI) — needs the jerryfane/herdr fork
- **domenkozar/agentaps** — GPUI + WASM — iroh p2p; does NOT use herdr (ACP client running its own agents)

## Native macOS (Swift)
- **missuo/herdrm** — SwiftUI console, sidebar rows for spaces/agents
- **v1k45/bigtty** — Ghostty-rendered terminals, spaces sidebar, browser + file panes
- **MrMySQL/uherdr** — native, local + remote over SSH, image paste, Cmd+1..0
- **YogevKr/rai** — native window: who's working/stuck/needs approval
- **adarshzpatel/paca** — Slack-style window + menu bar panel
- **joshuaswarren/allward** — native terminal for agents across machines
- **ventz/moo-mac-terminal** — native terminal, herdr agents sidebar, browser tabs, ⌘K
- **menu-bar monitors (out of scope)** — InsaneArts/herdrbar, hmu332233/herdr-menu-bar, pavel-snyk/herdry, bigbug16/herdr-topbar, jirathip-dev/corral

## Mobile
- **ZingerLittleBee/Heeler** — iOS, libghostty, SSH, QR pairing, push
- **Tomyail/herdr-connect** — iPhone companion over LAN/Tailscale
- **kosumic/whip** — agent-native SSH mobile client
- **multiplex-term/Multiplex** — SSH/tmux/herdr for Vision Pro, iPad, iPhone
- **patricio0312rev/anyssh** — SSH client iOS w/ herdr support
- **arronKler/pairfob** — phone surface, computer dials out, no inbound ports
- **Getterbetter/Kelpie** — real herdr TUI over SSH on iPad/iPhone (fork of Heeler)
- **leekt/pdx** — Android launcher for remote herdr agents
- **commercial** — Moshi (App Store), SSHHIP

## Web / PWA / bridges
- **AltanS/collie** — self-hosted PWA, push alerts
- **powerfooI/roamgate (ex herdr-studio)** — web client, desktop + mobile, files/diffs
- **alecuba16/herdr-webui** — local browser UI, worktrees, git, files
- **lamngockhuong/termote** — Go binary, streams sessions to xterm.js
- **dcolinmorgan/herdr-remote** — menu bar + phone + Telegram, free tunnel
- **IvoryHeart/herdr-world** — visualisations, local + SSH hosts (fork of roamgate)
- **alexei-led/ccgram** — Telegram bridge

## Relevant plugins
- **ogulcancelik/herdr-browser** — real Chromium view inside a herdr pane via CDP
- **plannotator/herdr-plannotator** — opens reviews in "Herdr Browser panes"
- **furkankly/zoetrope** — session as live flow graph (terminal/browser)
