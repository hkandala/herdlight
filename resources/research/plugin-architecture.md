# Plugin architecture for custom pane types

Research for Herdlight (DESIGN.md revision 3). Question: how do other people
add pane types (a diff view, a Markdown reader, git history) and how does the
built-in web page pane become a plugin shipped by default?

Evidence tags: **[verified]** I ran it on herdr 0.9.3 on this Mac today
(2026-10-08), in throwaway sessions `hnspike` and `hnspike2`, both deleted
after. **[docs]** official documentation (URL given). **[source]** code or a
repository README. **[recall]** from memory, not re-checked today. **[guess]**
my inference.

---

## 0. The answer

Three layers. Each layer is used only when the layer before it cannot do the job.

| Layer | What | Who writes it | macOS | iOS | App work |
|---|---|---|---|---|---|
| **L0** | herdr's own TUI plugin panes (reviewr, file viewer, sidebar, gitview) | anyone, today | free | free | about 20 lines: list them in the "new pane" picker |
| **L1** | **web plugins**: an HTML/JS folder drawn in a `WebPage` card, with a small `hl` JS bridge (exec on the pane's host, a few herdr calls, theme) | anyone | yes | yes | one generic card plus the bridge |
| **L2** | native SwiftUI panes compiled into the app | us only | yes | yes | one `case` in an enum per kind |

- **The web page pane is the built-in reference plugin.** It goes through the
  same registry, picker, label, placeholder and card as every L1 plugin. The
  one difference is its renderer: it loads the URL in the label and gets no
  bridge, because its content is the open internet.
- **Third-party plugins live on each host, inside a normal herdr plugin
  folder**, with one extra file `herdlight.json` and a `ui/` folder. They are
  installed with `herdr plugin install owner/repo`. The app finds them with
  `plugin.list`. The app stores no plugin code, and iOS gets plugins with no
  download step of its own.
- **Label format:** `hl:<plugin-id>:<arg>`. `web:<url>` keeps working as the
  web plugin's short form.
- **Security boundary = the host.** A plugin found on host A can run commands
  only on host A, and only drive herdr on host A. It already has that power as a
  herdr plugin. So v1 needs no per-plugin permission system. It needs one trust
  prompt per (host, plugin), a sandboxed web view with no network, and a strict
  CSP.
- **v1 does not include** native dylib plugins, ExtensionKit, a Raycast-style
  React-to-native renderer, WASM runtimes, a plugin store, streaming exec,
  network access, or a storage API (§9).

Simpler choice: L2 has no protocol yet. It is an enum with one case (`web`). Add
a protocol when there is a second native kind.

---

## 1. Facts this design rests on

### 1.1 Labels, cwd and restarts [verified]
| Fact | Evidence |
|---|---|
| A pane `label` has no length cap, survives `pane.move` and survives a cold restart. Metadata tokens are capped at 80 characters, are not saved, and are lost on restart. | `research/herdr-core.md` §3, §7.1 |
| `hl:git-diff:main...feature` (colons inside the arg) survived a cold server restart intact. | today, `hnspike`: `pane.rename`, then `herdr --session hnspike server stop` and start, then `session.snapshot` |
| After a cold restart, the pane's process is gone and a login shell takes its place (`foreground_processes: [{"name":"zsh","argv":["-zsh"]}]`). | same test |
| **`terminal_id` changes on a cold restart** (`term_65d594deecb4b2` became `term_65d594ea352ba2`). `pane_id` stayed `w1:p2`. | same test. This affects the PaneViewRegistry key in DESIGN §6. After a restart every card is rebuilt anyway. |
| `pane.split` gives the new pane the target pane's **current** cwd. After `cd /tmp` in `w1:p1`, a split of it had `cwd: /private/tmp`. | today, `hnspike2` |
| A pane's `cwd` is kept across a cold restart. | `hnspike` test, pane `w1:p2` |
| `pane.rename` sends no event. Token changes and terminal-title (OSC 0/2) changes send `pane.updated`. | `research/herdr-core.md` §1.4, §7.2 |

So a git or diff plugin pane split from an agent's pane starts in the agent's
repository. Its arg and its cwd both survive restarts and moves.

### 1.2 herdr's plugin system [docs + verified]
Source: https://herdr.dev/docs/plugins/ (0.9.3 docs:
`github.com/herdrdev/herdr/blob/master/docs/versions/0.9.3/website/src/content/docs/plugins.mdx`).
- A plugin is a folder with `herdr-plugin.toml`. It can declare `[[actions]]`,
  `[[events]]`, `[[startup]]`, `[[panes]]`, `[[link_handlers]]` and
  `[[build]]`. Commands are argv arrays. herdr runs them as the user with
  `HERDR_BIN_PATH`, `HERDR_PLUGIN_ROOT`, `HERDR_PLUGIN_CONFIG_DIR`,
  `HERDR_PLUGIN_STATE_DIR`, `HERDR_PANE_ID` and other variables.
- "There is no separate plugin SDK or restricted command set. The entire Herdr
  CLI is the plugin API."
- "Runtime action registration and native non-terminal plugin UI are not part
  of plugin v1." Pane entrypoints are terminal only.
- Trust: "it does not review or sandbox plugin code". `herdr plugin install`
  shows a preview of the source and the commands it will run before it
  installs.
- Install: `herdr plugin install owner/repo[/subdir]` (GitHub only, runs
  `[[build]]`). Local development: `herdr plugin link <dir>`. Plugins are
  global to the user and work in every session.
- Marketplace: https://herdr.dev/plugins/ indexes GitHub repositories tagged
  `herdr-plugin`. A third-party survey counts 1,625 plugins
  (https://herdrplugins.dev/, search snippet).
- "There is no Herdr-managed plugin storage API in v1."

What I checked live today:
- **`plugin.list` returns `plugin_root` and `manifest_path`** for each plugin,
  plus its `panes[]` with `command`, `placement`, `title`. [verified]
- **herdr 0.9.3 accepts an unknown top-level table** (`[native]`) in
  `herdr-plugin.toml` at `plugin link`, but `plugin.list` does not return it.
  [verified] Reading it would need a TOML parser in Swift, and a future herdr
  could turn strict. So the app's data goes in a separate JSON file (§4.1).
- `herdr plugin pane open --plugin P --entrypoint E --placement split
  --target-pane w1:p1 --direction down --env HL_ARG=x --no-focus` makes a normal
  pane. Its label is the entrypoint `title`. Its cwd is the plugin root unless
  `--cwd` is given. The snapshot has **no field that says a pane belongs to a
  plugin**. [verified] In the raw JSON request the field is `entrypoint`
  (`missing field 'entrypoint'` when I sent `entrypoint_id`). [verified]
- `placement = "popup"` is "a singleton session resource rather than a Herdr
  pane: it has no pane ID". [docs] So the app can never show a popup. Only
  `split` and `tab` placements belong in the app.

---

## 2. The seven options

### 2.1 Native Swift plugins loaded at runtime (bundles, dylibs)
How: `Bundle(url:).load()` on a `.bundle` that links a shared
`HerdlightPluginKit` framework and returns a SwiftUI view.
- **macOS signing.** The app ships with Hardened Runtime (DESIGN §14.1).
  Library validation "prevents a program from loading frameworks, plug-ins, or
  libraries unless they're either signed by Apple or signed with the same Team
  ID as the main executable." Third-party bundles need
  `com.apple.security.cs.disable-library-validation`, and then "Gatekeeper runs
  extra security checks on programs that have it disabled." [docs]
  https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation
  Downloaded bundles are also quarantined, so each author must sign and
  notarize them. [recall]
- **ABI.** The Swift standard library ABI has been stable on Apple platforms
  since Swift 5.0. A plugin API framework also needs module stability (built
  with `BUILD_LIBRARY_FOR_DISTRIBUTION`), and every API change must follow
  library-evolution rules. Otherwise plugins break on each Xcode update.
  [recall]
- **Security:** the plugin runs in the app's process with the user's full
  rights and access to the app's SSH connections. A plugin crash crashes the
  app.
- **iOS: impossible.** Guideline 2.5.2 bans downloading or running code that
  "introduces or changes features or functionality of the app", and iOS does
  not load code signed by another team. [docs]
  https://developer.apple.com/app-store/review/guidelines/
- **Precedent:** Xcode stopped loading third-party in-process plugins in
  Xcode 8 (the end of Alcatraz) and moved to out-of-process Source Editor
  Extensions. [recall]
- **Remote hosts:** a native plugin still cannot run `git` on a remote host. It
  needs the same exec bridge as every other option.
- Verdict: **reject.** It works on macOS only, needs a signing hole, gives
  plugins full power in our process, and has the worst ABI story.

### 2.2 First-party native only (compiled in)
How: each kind is Swift code in the app, chosen by the label prefix.
- Pros: the most native result (SwiftUI, Liquid Glass, accessibility, AppKit
  text). The fastest. Works on iOS. One codebase. No security surface.
- Cons: no third parties. Every new kind needs an app release, and on iOS an
  App Review.
- Verdict: **keep it as L2** for the few kinds that must be native. Today that
  is only the web page (it needs `WebPage`, per-host data stores and SSH port
  forwards, DESIGN §10.3). It is not a plugin *system*.

### 2.3 Apple ExtensionKit (remote SwiftUI views)
API (exact names):
- Host side: `EXHostViewController` ("hosts remote views provided by an app
  extension"): **macOS 13.0+, iOS/iPadOS 26.0+, Mac Catalyst 26.0+**, with
  `EXHostViewController.Configuration`, `makeXPCConnection()` and
  `EXHostViewControllerDelegate`. [docs]
  https://developer.apple.com/documentation/extensionkit/exhostviewcontroller
  There is no SwiftUI host view, so it needs a `UIViewControllerRepresentable`
  or `NSViewControllerRepresentable`. [guess, none found in the docs]
- `EXAppExtensionBrowserViewController` lets the user turn extensions on or off.
  "App extensions you include inside your host app's bundle are enabled by
  default, but extensions that ship in separate apps are disabled by default."
  [docs]
  https://developer.apple.com/documentation/extensionkit/exappextensionbrowserviewcontroller
- Discovery: `AppExtensionIdentity` and its matching sequence. Extension side:
  `AppExtension` with an `AppExtensionScene`. `AppExtensionPoint` is
  documented from iOS 26 (Apple forums thread 802846, search snippet).
  [recall + snippet]
- I found **no API named `EXAppExtensionBrandedHostView`** in the docs or by
  search.

Facts that decide it:
- **iOS 26: "an app can only host extensions that it contains"** (Apple DTS on
  forums thread 802846, search snippet; the page itself was behind a
  verification wall). KhaosT/UIExtensionExample: "iOS 26 enables ExtensionKit
  for third party apps... to host custom UIs from the bundled extension."
  [source] So on iOS, third-party extensions are not possible today.
- macOS: "ExtensionKit will refuse to load any extensions that do not have the
  sandbox entitlement set." Extensions "must be bundled and delivered within a
  .app." Each one needs user approval, and approval state lives in System
  Settings › Login Items & Extensions. (Matt Massicotte,
  https://www.massicotte.org/extensionkit-intro/, who built ChimeKit on it.)
  [source]
- So a third-party author must ship and notarize a Mac **app** that holds a
  sandboxed extension, and the user must approve it. The extension still has to
  call back to our app over XPC to run `git` on a remote host.
- Precedents: Chime / ChimeKit; Final Cut Pro workflow extensions (shipped
  inside container apps); Audio Unit v3 remote views in Logic. Xcode Source
  Editor Extensions use the older NSExtension with no UI. [recall]
- Pros: real SwiftUI out of process, crash isolation, Apple-supported
  sandboxing.
- Verdict: **reject for v1.** Third parties cannot use it on iOS. On macOS the
  cost per author (a containing app, sandbox, notarization, approval) and the
  XPC API surface are high, and the result has the same remote-exec bridge as
  web plugins. Revisit only if Apple allows cross-app hosting on iOS.

### 2.4 Web plugins (HTML/JS in WebKit plus a message bridge)
How: the plugin is a folder (`index.html` plus assets) built with any web
stack. The app shows it in SwiftUI `WebView`/`WebPage` (macOS 26, iOS 26, the
same type the web pane uses). It serves the files through a custom scheme and
injects a small `hl` object that posts messages to Swift.
- **Platform APIs** (all [docs]):
  - `WebPage.Configuration.urlSchemeHandlers: [URLScheme: any URLSchemeHandler]`,
    where `URLSchemeHandler.reply(for:)` returns an async sequence of response
    and data.
  - `WebPage.Configuration.userContentController` (a `WKUserContentController`):
    `WKUserScript` and `WKScriptMessageHandlerWithReply` give promise-style
    calls from JS.
  - `WebPage.callJavaScript(_:arguments:in:contentWorld:)` pushes events into
    the page.
  - `WebPage.NavigationDeciding.decidePolicy(for:preferences:)` controls
    navigation.
  - `WebPage.isInspectable` turns on Safari Web Inspector.
  - `webViewContentBackground(.hidden)` lets the SwiftUI background show
    through the page.
  - `WKContentRuleListStore` compiles block rules that apply to every load.
- **Precedents:**
  - VS Code webviews (https://code.visualstudio.com/api/extension-guides/webview):
    `acquireVsCodeApi()` plus `postMessage`, theme CSS variables such as
    `--vscode-editor-foreground` and body classes `vscode-dark`/`vscode-light`,
    `localResourceRoots`, a CSP the docs recommend, `getState`/`setState`. The
    docs warn that `retainContextWhenHidden` "has high memory overhead".
  - Figma: plugin UI in an `<iframe>` that talks only by message passing. "The
    security properties of the sandbox are guaranteed by browser vendors."
    (https://www.figma.com/blog/how-we-built-the-figma-plugin-system/)
  - Obsidian: plugins are JS. Its manifest has `isDesktopOnly`
    (https://docs.obsidian.md/Reference/Manifest), so **community JS plugins
    run in the Obsidian iOS app**. That is an App Store precedent. Obsidian
    admits it "cannot reliably restrict plugins to specific permissions"
    (https://obsidian.md/help/plugin-security), because its plugins run in the
    app's own context. Ours run in an isolated web view.
  - **Raycast v2 moved its own UI to React in WKWebView** inside a Swift shell:
    "a native app that uses web for its UI". Its numbers: an empty WebView costs
    about 50 MB, and WebContent uses 120–200 MB in use.
    (https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast)
  - VS Code **deprecated its Webview UI Toolkit** on 2025-01-01 and archived it
    (https://github.com/microsoft/vscode-webview-ui-toolkit/issues/561). Lesson:
    ship CSS variables and a base stylesheet, not a component library.
- **Looking native:**
  - `font: -apple-system-body` or `system-ui` gives SF Pro and follows Dynamic
    Type on iOS. `ui-monospace` gives SF Mono.
  - `color-scheme: light dark` and injected `--hl-*` variables (§6.4) supply
    the app's card colours, ANSI palette, terminal font and radius.
  - No real vibrancy inside the page. That matches DESIGN D25: cards are
    opaque, and glass is for chrome only. The app draws the card header and
    toolbar natively, so only the body is web.
- **Sandboxing:** WebKit's WebContent process sandbox; a custom scheme origin per
  (host, plugin); a CSP header from the scheme handler; a content rule list that
  blocks `http(s)`/`ws(s)`; a navigation decider that keeps the page on its own
  scheme. No network at all.
- **Remote data:** every host access goes through the bridge to the existing
  `Exec`. The plugin never sees SSH.
- **iOS:** works. App Store analysis is in §8.
- **DX:** any bundler (Vite, esbuild). Safari Web Inspector. `herdr plugin link`
  plus the card's Reload button. A small `hl.d.ts`.
- **Performance:** one WebContent process per live plugin page (about 50 MB
  each, from Raycast's numbers). Cap the live pages (§7).
- Verdict: **choose for third parties (L1).** One mechanism covers macOS and
  iOS, the sandbox is the browser's, every web skill and library works, and the
  card reuses the web pane's `WebPage` code.

### 2.5 React rendered to native views (Raycast model and its relatives)
**Raycast v1, concretely** (https://www.raycast.com/blog/how-raycast-api-extensions-work):
- It first tried one JavaScriptCore per extension in an XPC service with a JSON
  component tree. Developers wanted npm packages, so it moved to **Node.js**
  (downloaded and managed by Raycast, with integrity checks). Extensions run in
  **worker threads** (V8 isolates with heap limits).
- It talks to the Swift app over **JSON-RPC on stdio** (DispatchIO).
- A **custom React reconciler** builds a JSON "render tree". It diffs each
  render with **JSON Patch**, gzips above a threshold, and turns patches into
  Swift view models that drive custom **AppKit** components (not SwiftUI).
- Sandboxing was "considered... but rejected". Security comes from review:
  every extension is open source and reviewed in a GitHub monorepo.
- The UI is a fixed set of components: List, Detail (Markdown), Form, Grid,
  ActionPanel, MenuBarExtra.
- **v2 renders through a WebView**, and Node is now bundled (deep-dive post
  above). Raycast itself moved from native rendering to web rendering.

Relatives:
- React Native macOS (Microsoft) runs a whole RN runtime beside SwiftUI and has
  no plugin isolation. [recall]
- Nova extensions run in JavaScriptCore with native-only UI pieces (sidebars,
  tree views, commands; https://docs.nova.app/extensions/). [docs, list only]
- Server-driven JSON UI (Airbnb's Ghost Platform, Microsoft Adaptive Cards).
  [recall]
- Apple's App Intents snippets are compiled SwiftUI views, not a remote schema.
  [recall]

Fit for pane types:
- Raycast works because a launcher is a few fixed shapes: lists, details,
  forms. Pane types are open-ended: a side-by-side diff with syntax highlighting,
  a commit graph, rendered Markdown with images. Each new kind would need a new
  native component from **us**, which defeats the point of third-party
  plugins.
- It needs a JS runtime outside WebKit. On iOS, JavaScriptCore outside WebKit
  has no JIT. [recall]
- It needs a reconciler, a component vocabulary we version forever, and a
  sandbox story (Raycast gave up on that).
- Verdict: **reject for v1.** Revisit a tiny "list + detail" kit only if many
  web plugins end up drawing the same shapes.

### 2.6 herdr's own TUI plugin panes
Real examples, all installed with `herdr plugin install`:
- `persiyanov/herdr-reviewr`: diff review with line comments sent back to
  Claude, Codex, OpenCode or Pi. A Rust binary.
- `smarzban/herdr-file-viewer`: tree, diffs, rendered Markdown through
  glow, delta and bat.
- `alexarthurs/herdr-sidebar`: file explorer and source control.
- `ChmaraX/herdr-gitview`.
- plannotator, which opens its UI in "Herdr Browser panes"
  (`research/web-clients.md` §8).

What the app gets for free:
- They are normal herdr panes. They already draw in terminal cards through
  `terminal session` frames.
- They run on the host next to the data, on every host, on iOS too, with mouse
  support through `terminal.mouse`.
- libghostty's theme recolours their ANSI palette to match the app.
- herdr TUI users see the same pane.
- Install, update, trust preview and marketplace are herdr's.

Limits:
- A monospace cell grid. No real images (herdr removed `pane.graphics` in 0.9;
  `design.html`).
- Keyboard-first. Poor on touch. On iPhone, an observer gets a fixed 160×50
  screen (DESIGN §7.6).
- One PTY size and one controller per pane.
- No native text selection, scrolling or accessibility.
- `popup` entrypoints cannot be shown at all (no pane id).
- After a herdr restart the pane becomes a shell, because plugin `launch_argv`
  is not re-run [verified today]. Its label stays as the entrypoint title.

Verdict: **L0, always on.** The only app work is to list the host's
`split`/`tab` pane entrypoints in the "new pane" picker (§5.3).

### 2.7 WASM components (Zed model)
- Zed extensions are Rust compiled to WASM components, with WIT interfaces run
  by Wasmtime (https://zed.dev/blog/zed-decoded-extensions).
- **They provide no UI:** "languages, themes, debuggers, snippets, and MCP
  servers" (https://zed.dev/docs/extensions/developing-extensions).
- Zed has a good **capability model** to copy later: `process:exec` with
  command and args patterns, `download_file` by host, and a user setting
  `granted_extension_capabilities` (https://zed.dev/docs/extensions/capabilities).
- For us, WASM handles logic only, so we would still need option 2.4 or 2.5 for
  the UI.
- On iOS a WASM runtime outside WebKit must be an interpreter, such as
  swiftwasm/WasmKit. [recall]
- WebKit already runs WASM inside a web plugin. A plugin can bundle a
  WASM diff engine or syntax highlighter today. That needs `'wasm-unsafe-eval'`
  in the CSP (§6.5).
- Verdict: **reject as a separate system.** It is free inside L1.

### 2.8 Comparison

| | 2.1 dylib | 2.2 compiled-in | 2.3 ExtensionKit | 2.4 web | 2.5 React→native | 2.6 herdr TUI | 2.7 WASM |
|---|---|---|---|---|---|---|---|
| Third parties | yes | no | macOS only | **yes** | yes | **yes** | yes (logic) |
| iOS | no | yes | own extensions only | **yes** (§8) | yes (no JIT) | **yes** | interpreter |
| Isolation | none, in-process | n/a | process + sandbox | **WebContent sandbox** | worker or JSC | runs as user on host | strong |
| Signing burden | sign and notarize, disable library validation | none | container app, sandbox, notarize, approve | **none** | none | none | none |
| Distribution | our own | app release | App Store or notarized app | **herdr plugin install** | our own store | herdr plugin install | our own |
| Look and feel | native | **native** | native | close (native chrome, web body) | native, limited set | terminal | needs a UI layer |
| Any UI shape | yes | yes | yes | **yes** | only our components | grid only | no |
| Remote host data | needs bridge | needs bridge | bridge over XPC | **bridge** | bridge | **native, on the host** | bridge |
| App work | high | per kind | high | **medium, once** | very high | **~0** | high |
| Memory per pane | low | low | one process each | ~50 MB+ | low to medium | ~0 (a frame stream) | low |

---

## 3. Recommended design

```
"new pane" picker on host H
 ├─ Terminal · Agent                                   (DESIGN §10.1–10.2)
 ├─ App plugins:  Web page (built-in) · Markdown (built-in) · <host plugins with herdlight.json>
 └─ herdr panes:  <plugin.list panes[] with placement split|tab>   → plugin.pane.open (L0)

App plugin pane  =  herdr pane with label "hl:<id>:<arg>"  (or "web:<url>")
                    + placeholder process typed into its shell
card             =  native header (icon, title, arg, Reload, Terminal, Restore placeholder)
                    + WebPage body:
                        renderer "url"     → load arg as a page (web plugin, no bridge)
                        renderer "bundle"  → hl-plugin://<h8>.<id>/index.html + hl bridge
bridge           →  Exec on the pane's host only · herdr allowlist on that host · theme · setArg
```

There is no separate plugin process, plugin daemon, JS runtime or plugin
store. Pieces reused from DESIGN: `Exec` (§7.1), `call()` (§7.3), the snapshot
event stream (§7.4), the `WebPage` card and PaneViewRegistry (§10.3, §14.3),
the label scheme (§10.3) and the argv quoting function (§7.1).

---

## 4. Where plugins live, and the manifest

### 4.1 Third-party plugins: on each host, inside a herdr plugin
```
persiyanov-reviewr/            (any herdr plugin folder)
  herdr-plugin.toml            herdr's manifest: id, name, version, panes, actions…
  herdlight.json            ← the only new file
  native/ui/index.html         ← built web bundle (any bundler's dist/)
  native/ui/assets/…
  bin/reviewr                  ← optional host-side helper the UI can exec
```
`herdlight.json`:
```json
{
  "ui": "native/ui",
  "icon": "arrow.triangle.branch",
  "title": "Review"
}
```
| Field | Required | Why |
|---|---|---|
| `ui` | yes | the folder to fetch, relative to `plugin_root`; it must contain `index.html` |
| `icon` | no | an SF Symbol name for the picker and header. Native look with no asset pipeline. Default `puzzlepiece.extension`. |
| `title` | no | picker and header text. Default: herdr's `name`. |

Left out on purpose:
- `id`, `version`, `description`, `platforms`: herdr's manifest already has
  them, and `plugin.list` returns them.
- Permissions: the host is the boundary (§6).
- An arg schema: the plugin asks the user itself, then calls `setArg`.
- A minimum app version: the plugin reads `hl.version`.

**The plugin id is the herdr plugin id.** It must match
`^[a-z0-9][a-z0-9._-]{0,63}$`. herdr also allows `:` in ids, but the label
parser cannot accept it. Plugins whose ids do not match are skipped and logged.
The `hl.` prefix and the id `web` are reserved for built-ins.

Why the host, and not a plugins folder in the app:
1. herdr already does install, preview, build, update, uninstall, config and
   state folders, and the marketplace. The app writes none of that.
2. The data and helper tools are on the host. A plugin's helper binary
   (`bin/reviewr --json`) runs next to the repository.
3. iOS gets plugins by reading them from the host, like every other host
   fact. It needs no download feature and no App Store "index" (§8).
4. The app stores no plugin code. The UI version always matches the helper
   version on that host.
5. An existing TUI plugin can add a GUI by adding two things, and herdr TUI
   users keep the TUI.

The cost is one `herdr plugin install` per host. The app can offer an
**Install on this host** button. It runs the command in a terminal card, the
same way DESIGN §5.7 runs `herdr machine add`, so herdr's own preview and
confirm screen appears.

### 4.2 Built-in plugins: in the app bundle
A Swift array, not JSON:
```swift
enum Renderer { case url, bundle(String) }               // bundle = folder in the app bundle
struct AppPlugin { let id, title, icon: String; let renderer: Renderer }

let builtIns = [
  AppPlugin(id: "web",         title: "Web page", icon: "globe",            renderer: .url),
  AppPlugin(id: "hl.markdown", title: "Markdown", icon: "doc.richtext",     renderer: .bundle("Plugins/markdown")),
]
```
- `web` is the reference built-in. It is the existing §10.3 code. `renderer:
  .url` means the arg is the page and there is no bridge.
- `hl.markdown` is the **reference bundle plugin**. It is the smallest useful
  test of the bridge: `exec cat`, `setArg`, theme, and refresh on snapshot.
  The arg is a file path; an empty arg makes it list `*.md` in the cwd.
  Built-ins work on every host with nothing installed, iOS included.
- Diff and git history are good first **host** plugins, for example a GUI added
  to reviewr or gitview. Or they become built-ins later if users want them with
  no install.

### 4.3 Discovery (per host, on connect, two round trips)
1. `plugin.list` (one `call()`): gives `plugin_id`, `name`, `version`,
   `plugin_root` and `panes[]`. This already covers L0.
2. One exec for every root at once:
   `sh -c 'for r; do [ -f "$r/herdlight.json" ] && printf "%s\0" "$r" && cat "$r/herdlight.json" && printf "\0"; done' sh <root1> <root2> …`
3. The result is held in memory per host and re-read on reconnect. Bundles are
   fetched only when a card first opens (§6.3).

---

## 5. How a plugin pane is created and stored in herdr

### 5.1 Label format
```
web:<http(s)-url>              built-in web plugin (unchanged; DESIGN §10.3)
hl:<plugin-id>:<arg>           every other app plugin
```
Parser (the one function the test target checks):
- The prefix is `hl:`. The id runs up to the next `:` and must match
  `^[a-z0-9][a-z0-9._-]{0,63}$`. The arg is everything after that colon. It may
  be empty and may contain `:`.
- `web:` followed by an http or https URL is the plugin `web` with arg = URL.
- An id not installed on this host and not built in gives a card that says
  "‹id› is not installed on ‹host›", with **Install on this host** (if known)
  and **Show terminal**. Nothing is loaded.
- Anything else is a normal terminal pane.

Rules for the arg:
- One line. The app strips control characters, because herdr trims labels and
  the placeholder prints it.
- Treat it as **untrusted input**. Anything that can reach the host's herdr
  socket can set a label (DESIGN D15).
- Keep it readable, because the herdr TUI shows the label as the pane border
  title. A short path or a query-string style is best:
  `hl:hl.markdown:docs/DESIGN.md`, `hl:persiyanov.reviewr:base=main`.
- There is no length cap (§1.1). Tokens and their 80-character cap are not
  used.

Why `hl:` and not `<id>:` like `web:`: a user label such as `todo: fix login`
must never turn into a plugin. `web:` is safe only because a valid URL must
follow it.

### 5.2 Create (same steps as the web pane)
1. The user picks the plugin in the picker on host H.
2. `pane.split {target_pane_id, direction, focus:false}` or `tab.create`. The new
   pane gets the source pane's cwd [verified].
3. `pane.rename {pane_id, label: "hl:<id>:<arg>"}`. The arg is usually empty;
   the plugin asks the user and calls `setArg`.
4. `pane.send_input` sends the placeholder, which is the §10.3 one with an
   **OSC 2 title** added:
   ```sh
    clear; exec sh -c 'printf "\033]2;%s\007%s\n(shown by Herdlight)\n" "$1" "$1"; stty raw -echo; exec cat >/dev/null' sh '<label>'
   ```
   The title change makes herdr send `pane.updated` (`research/herdr-core.md`
   §1.4). **Every other device** then re-reads the snapshot and sees the new
   label. Today a rename sends no event, so a second device can see the pane
   from `pane.created` as a shell and keep showing a terminal. This also fixes
   that gap for web panes. [guess that this closes the race; the event itself is
   verified in herdr-core]
   - The printed `<label>` is only for display. The real arg lives in the
     label, so the app drops every `'` from this copy. A label with no quote
     inside single quotes is safe in bash, zsh and fish, the same rule as
     §10.3's percent-encoding. Fish treats `\'` inside single quotes as an
     escape, so `'\''` quoting is not safe there.
5. Re-read the snapshot.

Restore after a herdr restart, moves, sizes and close all work exactly as for
web panes (DESIGN §10.3). The label survives; "Restore placeholder" sends step 4
again.

### 5.3 L0: herdr TUI panes in the picker
- Entries come from `plugin.list` `panes[]`. Show only entries where
  `placement` is not `popup`. Open each one with `placement` set to `split` or
  `tab`, never `overlay` or `zoomed`, because those change herdr's zoom (DESIGN
  D10).
- The call is `plugin.pane.open {plugin_id, entrypoint, placement:"split",
  target_pane_id, direction, focus:false}`, or the CLI flags verified in §1.2.
  It is one call, and the result is a normal terminal card. Simpler choice: an
  entry that needs `--env` arguments is opened without them.

---

## 6. The bridge, security, theming

### 6.1 API (all of it)
Injected at document start into the page world as a global `hl`. It is
delivered as `hl.d.ts`, with no npm runtime.
```ts
declare const hl: {
  version: 1;
  readonly context: {                    // live: re-read fields on every use
    host: { id: string; label: string };
    pane: { paneId: string; terminalId: string; cwd: string };
    plugin: { id: string; version: string | null; root: string | null }; // root = plugin_root on the host
    arg: string;
    platform: "macos" | "ios";
  };
  exec(argv: string[], opts?: { cwd?: string; stdin?: string; timeoutMs?: number; base64?: boolean }):
    Promise<{ code: number; stdout: string; stderr: string; truncated: boolean }>;
  herdr(method: string, params?: object): Promise<unknown>;   // allowlist below
  setArg(arg: string): Promise<void>;                          // renames own pane to hl:<id>:<arg>
  on(event: "snapshot" | "arg" | "theme", cb: (data: any) => void): () => void;
};
```
| Call | Why it exists | How the app does it |
|---|---|---|
| `exec` | Every data need (git, cat, ls, gh, the plugin's own helper) runs on the pane's host. It replaces readFile, writeFile, network and storage APIs. | `Exec.run` on that host, with argv quoted (§7.1): `sh -c 'PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; cd "$1" \|\| exit 127; shift; exec "$@"' sh <cwd> <argv…>`. Default cwd = the pane's cwd. Limits: 30 s timeout, 4 MiB per stream (`truncated`), at most 3 running per card (OpenSSH `MaxSessions`, DESIGN §8.4). `base64` is for binary output such as images. |
| `herdr` | Read panes, send input, prompt an agent (for example, reviewr sends comments back). | `call()` on the same host. **Allowlist:** `session.snapshot`, `pane.get`, `pane.read`, `pane.process_info`, `pane.send_input`, `pane.send_keys`, `agent.prompt`, `agent.send_keys`. The allowlist protects the app's own rules (no `*.focus`, no `pane.zoom`, D10 and D12; renames only through `setArg`). It is **not** a security boundary: `exec("herdr", …)` can do anything, and a host plugin already can. |
| `setArg` | The plugin's one durable per-pane state, owned by herdr. It survives restarts and moves, and other devices see it. | `pane.rename` of its **own** pane only. Control characters are stripped. |
| `on("snapshot")` | Live updates (for example, refresh the diff when an agent finishes a turn) with **no extra SSH channel**. | The HostStore already re-reads the snapshot on every event (§7.4). It forwards that JSON, debounced, only while the card is on screen. |
| `on("arg")` | Another device or a herdr TUI user changed the label. | Comes from the same snapshot diff. |
| `on("theme")` | For canvas or WASM renderers that cannot use CSS variables. | Sent when the theme changes. CSS variables update by themselves. |

Not in the API:
- `openURL`: link clicks and `window.open` to http or https open in the system
  browser through the navigation decider.
- Clipboard: WebKit's own.
- Storage: `setArg`, or files on the host through `exec`.
- Streaming spawn and network: not in v1 (§9).

### 6.2 Trust and security model
**The boundary is the host.**
- A host plugin's bridge reaches only the host it was found on. Its `exec` and
  `herdr` calls go to that host.
- It cannot reach the Mac, other hosts or the app's state.
- As a herdr plugin it can already run any command on that host as the user
  (herdr: "does not review or sandbox plugin code").
- So showing its UI in the app adds **no new power on the host**.

What is new is code from a host running inside our app. Defences:
1. **One trust prompt per (host, plugin id)**, the first time a card for it
   opens. Text: "Show ‹title› from ‹host›? It can run commands on ‹host› as
   ‹user› and control panes there. Source: ‹herdr `source`, for example
   github owner/repo›." The answer is saved as a set of `"<hostUUID>|<plugin
   id>"` strings in `UserDefaults`. That adds one row to DESIGN §13.
   - Updates do not prompt again. `herdr plugin install` is where updates are
     reviewed, and repeated prompts lead to blind clicking (Raycast's
     "fatigue" point).
   - Built-ins never prompt.
2. **No network.**
   - A `WKContentRuleList` blocks `^(https?|wss?|ftp):` for every load.
   - The CSP has `connect-src 'none'`.
   - The navigation decider cancels any main-frame navigation off
     `hl-plugin:`. A link the user clicks opens in the browser.
   - So a plugin cannot leak data from the device. It can leak only from its
     own host, which it already could.
3. **One origin per (host, plugin):** `hl-plugin://<h8>.<plugin-id>/`, where
   `<h8>` is the host hash DESIGN §8.1 already uses. Each pair gets one
   in-memory `WKWebsiteDataStore.nonPersistent()`, kept for the app run. The
   app stores nothing on disk, and plugins cannot read each other's storage.
4. **Strict CSP to stop XSS from turning into remote code execution.** This is
   the real risk. A Markdown or diff plugin draws content from the repository.
   An injected `<img onerror=…>` that reached `hl.exec` would run commands on
   the host. The scheme handler sends:
   ```
   Content-Security-Policy: default-src 'none'; script-src 'self' 'wasm-unsafe-eval';
     style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:;
     connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'
   ```
   With no `'unsafe-inline'` for scripts, injected handlers and inline scripts
   do not run. That is why bundles are folders served from `'self'`, not single
   inlined HTML files. Plugin authors must still render untrusted HTML through a
   sanitiser or as `textContent` (stated in the SDK README).
5. **The bridge checks the sender.** It handles a message only from the main
   frame whose origin is the card's own `hl-plugin://` origin, and only for that
   card's pane.
6. **Arg and repository content are untrusted.** Authors pass them as argv
   (never through `sh -c`) and put `--` before paths, so an arg like
   `--upload-pack=…` cannot inject options. The SDK README carries this rule.
7. **The web plugin (`web`)** gets no bridge at all and keeps its own per-host
   data store (DESIGN D15).

Why there are no per-plugin capabilities in v1:
- A capability like "exec only `git`" is no barrier. `git -c
  core.sshCommand=…` or `git -c alias.x='!sh'` runs anything. [recall]
- Within one host, capabilities would only guard against accidents.
- Capabilities become worth it when a plugin can reach **beyond** its host
  (§9, cross-host plugins). Then copy Zed's `{kind:"process:exec", command,
  args}` model.

### 6.3 Loading a bundle
- On the first card open per (host, plugin, version) per app run:
  `exec ["sh","-c","COPYFILE_DISABLE=1 exec tar -cf - -C \"$1\" .", "sh", "<plugin_root>/<ui>"]`.
  That is one channel, binary-safe stdout, capped at 16 MiB. A ustar reader of
  about 40 lines keeps the files in memory. It skips pax, GNU and `._` entries
  and rejects `..` and absolute paths. Both BSD and GNU tar produce this.
- A built-in bundle is read from `Bundle.main`. It is the same scheme handler
  with a different file source.
- The scheme handler serves `index.html` and its assets with a `Content-Type`
  picked from a small extension map (html, js, mjs, css, json, svg, png, jpg,
  webp, woff2, wasm).
- **Reload** in the card header fetches again. A `plugin.list` version change
  on reconnect drops the cache. Nothing is written to disk on either platform.

### 6.4 Theming
The app injects a stylesheet at document start, and updates it when the theme
or appearance changes:
```css
:root {
  color-scheme: light dark;
  --hl-bg; --hl-fg; --hl-muted; --hl-accent; --hl-border; --hl-selection;
  --hl-radius; --hl-font: -apple-system-body;            /* SF Pro, Dynamic Type on iOS */
  --hl-font-mono: <terminal font family>, ui-monospace;  --hl-font-mono-size;
  --hl-ansi-0 … --hl-ansi-15;                            /* the libghostty palette, for diff colours */
}
```
- The app also adds a ~60-line base `hl.css` for body, buttons, inputs, lists,
  code, tables and scrollbars, so a plugin with no CSS of its own looks like the
  app. There is no component library (the VS Code toolkit lesson, §2.4).
- `html` gets the class `hl-macos` or `hl-ios` for small platform tweaks.
- The card uses `webViewContentBackground(.hidden)` over the card's opaque
  background, so there is never a white flash while the page loads.
- The native card header draws the icon, `document.title` (falling back to the
  manifest title) and the arg, so the chrome is truly native.

### 6.5 WASM
Allowed through `'wasm-unsafe-eval'`. This is how a plugin gets a fast diff or
highlighter (§2.7) with no WASM runtime from us.

---

## 7. Performance and lifecycle
- A plugin page is one `WebPage` held by the PaneViewRegistry under the same
  key as web pages. It is **not reloaded** when it scrolls off screen.
- Cap the live web and plugin pages at about 8, least recently used first out.
  Each one costs about 50 MB or more of WebContent memory (Raycast's numbers).
  An evicted plugin reloads on return. That is cheap, because its state is the
  arg and the host's files.
- `document.visibilityState` already tells a plugin when it is hidden. The
  snapshot event is sent only to visible cards.
- Exec costs one process or SSH channel per call: 18–130 ms locally (DESIGN
  §7.3) plus the round trip. Guidance for authors: batch work in one `sh -c`
  script or one helper call (`bin/tool --json`), and refresh on `snapshot`
  events, not timers.
- Gestures and keys need no new code. The strip's scroll monitor and the
  menu-first key routing (DESIGN §14.3) already cover web views.
- Plugin cards get no chat view. The chat|terminal switch becomes
  "plugin|terminal".

## 8. iOS
- **What loads:** built-in bundles from the app, and host plugins read over the
  Citadel exec channel with the same `tar`. Both show in the same `WebPage`
  card. It is the same code as macOS, with no `#if` beyond `context.platform`.
- **App Store [guess, medium-low risk]:**
  - Guideline 2.5.2 bans downloading code that "introduces or changes
    features or functionality".
  - Guideline 4.7 allows "HTML5 and JavaScript mini apps... and plug-ins" under
    4.7.1–4.7.5. Those rules include "you must provide an index of software
    and metadata available in your app... with universal links" (4.7.4) and
    age gating (4.7.5).
  - 4.7.2: "may not extend or expose native platform APIs or technologies to
    the software without prior permission". Our bridge exposes only the user's
    own remote shell and herdr, with no iOS APIs, sensors or files.
  - Our plugins are **not offered by the app**. The user installs them on
    their own server, and the app shows them the way an SSH client or browser
    shows that server's content.
  - Obsidian ships community JS plugins on iOS (§2.4).
  - Keep it that way: **no in-app catalogue, store or install-from-URL on
    iOS.** If App Review objects, the fallback is a switch: on iOS, host plugins
    open as their terminal (L0) or show "Open on Mac", and built-ins keep
    working.
- **Memory:** iOS kills big WebContent processes sooner. Keep fewer live pages
  on iPhone (about 3). The phone shows one pane at a time anyway (DESIGN §5.6).

---

## 9. Not in v1 (and when to add each)

| Not built | Add when |
|---|---|
| Native dylib or bundle plugins; ExtensionKit | Never for dylibs. ExtensionKit if iOS allows hosting extensions from other apps. |
| A Raycast-style React→native renderer or JSON UI schema | Many web plugins draw the same list or detail shapes, and users notice they are not native. |
| A separate JS or WASM runtime | Never. WebKit has both. |
| A plugin store, catalogue, search or install-from-URL in the app | Never on iOS (4.7.4). On macOS: the herdr marketplace and a terminal card are enough. |
| Per-plugin capabilities and permission UI | Cross-host plugins exist (next row). |
| **Cross-host plugins** (one plugin on This Mac used for every host's panes) | Users complain about installing on each host. Then add explicit per-host consent and Zed-style capabilities. |
| A streaming `hl.spawn` (`tail -F`, watchers) | A real plugin cannot work with snapshot-driven refresh. It costs a long-lived channel per card. |
| Network access for plugins | A plugin needs a web API it cannot reach through `exec` (for example `gh api`, `curl` on the host). |
| A storage API, or persistent web data stores | A plugin needs device-local preferences that are not per pane (arg) or per host (files). |
| A TUI fallback for app plugins (`plugin.pane.open` with `HL_ARG`, so herdr TUI users see the plugin's TUI instead of the placeholder) | A popular host plugin ships both a TUI and a GUI. It is a second creation path. |
| Plugin commands, menus, keybindings, sidebar or status contributions | Someone needs a plugin outside a pane. herdr's `[[actions]]` could be listed in a command palette. |
| `hl.openPane(id, arg)` (a plugin opens another plugin pane) | A diff plugin wants to open a file in the Markdown plugin. |
| A disk cache of bundles; a file watcher for hot reload | Bundle fetches show up in a profile. Authors ask for more than Reload. |
| A Swift protocol for native kinds | A second native kind (L2) exists. Until then, an enum case. |
| `herdlight.json` fields beyond `ui`, `icon`, `title` | A real plugin needs one. |

---

## 10. Changes to DESIGN.md if adopted
- §0 item 6 and §10 intro: the picker shows Terminal, Agent, app plugins and
  herdr panes. "Web page" becomes the first built-in app plugin.
- §10.3:
  - Label parsing becomes the §5.1 table.
  - The placeholder gains the OSC 2 title (§5.2 step 4), which fixes rename
    propagation to other devices.
  - Note that `terminal_id` changes on a cold restart (§1.1).
- New §10.4 "App plugins": §4–§7 of this file, in short.
- §13: add rows for "plugin trust set (host|plugin) in `UserDefaults`" and
  "plugin bundles: memory only".
- §14.6 tests: the label parser, the ustar reader, the bridge allowlist and
  argv building for `exec`.
- Appendix A: add `plugin.list` and `plugin.pane.open`.
- New decision rows:
  - **D30:** third-party pane types are web plugins that live on the host
    inside herdr plugins, scoped to that host. Rejected: dylibs, ExtensionKit,
    React→native, WASM.
  - **D31:** label `hl:<id>:<arg>`, with `web:` kept.
  - **D32:** herdr TUI panes are listed in the picker, `split` and `tab` only.
- §17 build order: in step 3 (web panes), add the generic plugin card, the
  bridge and `hl.markdown`.
