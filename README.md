# Herdlight

Herdlight is a native SwiftUI app for macOS and iOS. It is a graphical client for
[herdr](https://github.com/herdrdev/herdr), the terminal multiplexer for AI coding agents.
herdr keeps the workspaces, tabs and panes; Herdlight shows them as native windows, cards and
chat views, on this Mac or on remote machines over SSH.

The project is in the design phase. This repository holds the design only. There is no app code yet.

## Layout

```
docs/                     the documentation site
  content/docs/           the design, one MDX page per topic
  app/ lib/ components/   the site itself
resources/
  design.html             an interactive one-page overview of the design
  research/               research notes and evidence behind the design decisions
  inspirations/           write-ups of UI inspirations
    selected/             the chosen frames from the inspiration videos
```

The raw inspiration videos and frames (`resources/inspirations/a/`, `b/`, `c/`, `one/`) are kept
locally only. They are not in git.

## Read the design

Every design page is an MDX file under `docs/content/docs/`. Read them there, or run the site:

```
cd docs
pnpm install
pnpm dev
```

The site needs pnpm 10 or newer (`docs/package.json` pins it). With an older global pnpm, run
`npx pnpm@10 install` and `npx pnpm@10 dev` instead.

## Open the overview

`resources/design.html` is a single file with no build step. Open it in a browser:

```
open resources/design.html
```
