# Plugin system v2: Herdlight's own plugins (TypeScript + React, Raycast style)

Research for Herdlight, after DESIGN.md revision 4. It replaces §10.4 of
DESIGN.md and `research/plugin-architecture.md` (host-side web plugins inside
herdr plugins), which the user rejected.

The user's direction (not up for debate):
- "herdr plugins are very generic and can be anything ... they may open
  floating panes or something else." So we do not build on herdr plugins.
- "lets make everything a plugin, and use typescript and react components,
  maybe taking inspiration from how raycast extensions work, i think we can
  provide some default components etc to make them look similar in style and
  look native enough."
- Every plugin pane is backed by a real herdr terminal pane with a
  placeholder. On a fresh start the app finds every plugin pane only from what
  herdr holds, and draws it. Keep app-side data to a minimum (§5).

Evidence tags: **[verified]** I ran it on this Mac today (2026-10-08, macOS
27.0.1). **[docs]** official documentation (URL given). **[source]** code or
README. **[secondary]** a third-party article. **[inference]** I concluded it
from the sources. **[guess]** my estimate, not checked.

---

## 0. The answer

1. **Plugins are TypeScript + React, written against our own component kit**
   (`@herdlight/api`): `List`, `Detail`, `Markdown`, `Diff`, `Code`, `Form`,
   `ActionPanel`/`Action`, navigation, toasts. This is the Raycast model.
2. **The kit renders as real SwiftUI (option B, Raycast 1.x style).** Each
   plugin card runs React in its own `JSContext` (JavaScriptCore, built into
   both OSes). A ~60-line `react-reconciler` host config turns each commit
   into a JSON view tree. Swift decodes the tree and draws native views. I ran
   this today: React 19 in plain JSC costs ~3 MB per card. A 500-row list
   update takes ~2 ms, even with the JIT off as on iOS (§2.6). A web view costs
   50 MB when empty and 120–200 MB in use.
3. **Escape hatch later (makes it option C):** a `<WebView>` kit component for
   custom drawing (commit graph, charts). It is a sandboxed page from the
   plugin's own files, with no API and data in and out only. Build it when the
   first plugin needs it. v1's diff, Markdown and git history need only native
   components.
4. **Everything is a plugin, honestly:** one registry, one manifest shape and
   one picker. Terminal, Agent and Web page are *core plugins* whose UI is a
   native host component (`Terminal`, `WebPage`). They run no JavaScript.
   Git history, Diff and Markdown are *core JS plugins* bundled in the app.
   They use the same API as third parties and act as the SDK's reference code.
5. **Plugin code lives in the app**
   (`~/Library/Application Support/Herdlight/plugins/<id>/`). You install a
   plugin from a git URL or link a local folder (dev mode with hot reload). A
   tiny CLI (`hl-plugin build|dev`, esbuild) builds it.
6. **herdr holds the pane, its kind, its instance id and its arg** in the
   pane label: `hl:<plugin>[/<pane>]#<iid> <arg>`. Bigger per-instance state
   lives in a JSON file on the pane's host, keyed by the instance id. The app
   stores no per-pane data. Restore = parse labels (§5).
7. **API:** `exec` on the pane's host (through the existing `Exec` and base64
   envelope), `usePane()` context, `setArg`, `useInstanceState`,
   `useSnapshot`, preferences, toasts, `open(url)`, navigation, actions with
   shortcuts, plus `usePromise`/`useExec`. No network, no fetch and no
   LocalStorage in v1.
8. **Security:** one VM per card, so a card can only touch its own pane's
   host. Without the `exec` permission a plugin cannot reach a host at all.
   There is no DOM and no HTML, so the XSS→exec path from revision 4 is gone.
   The user consents at install and again when an update adds a permission. A
   watchdog marks hung plugins.
9. **iOS:** core plugins only in v1 (they ship in the binary). Third-party
   plugins show their placeholder with "Open on Mac". Later, behind a setting:
   fetch them from a Mac host over the SSH the app already has. Apple's
   developer agreement (DPLA) §3.3.1(B) allows downloaded interpreted code
   under conditions, but the 2026 crackdown under guideline 2.5.2 makes this
   a real risk (§4.8).

What we skip is in §8.

---

## 1. Raycast extensions, end to end

### 1.1 Package and manifest
- `package.json` is the manifest, "a superset of npm's `package.json`"
  ([docs](https://developers.raycast.com/information/manifest)).
- Extension fields: `name` (store slug), `title`, `description`, `icon`
  (512×512 PNG, optional `@dark` variant), `author`, `platforms`
  (`"macOS"`, `"Windows"`), `categories`, `commands`, `tools` (AI),
  `preferences`, `owner`/`access` (private org stores), `external`
  (not bundled).
- Command fields: `name` (maps to `src/<name>.tsx`), `title`, `subtitle`,
  `description`, `icon`, `mode` (`view` | `no-view` | `menu-bar`),
  `interval` (background refresh, at least 1m), `keywords`, `arguments`
  (`text`/`password`/`dropdown`), `preferences`, `disabledByDefault`.
- Preference fields: `name`, `title`, `description`, `type` (`textfield`,
  `password`, `checkbox`, `dropdown`, `appPicker`, `file`, `directory`),
  `required`, `placeholder`, `default` (can differ per platform).
  Commands inherit extension preferences.

### 1.2 Components and APIs
- UI ([docs](https://developers.raycast.com/api-reference/user-interface)):
  "Raycast uses React for its user interface declaration and renders the
  supported elements to our native UI ... Think of it as a design system."
  The top-level components are `List`, `Grid`, `Detail` (CommonMark Markdown
  plus a metadata panel, [docs](https://developers.raycast.com/api-reference/user-interface/detail))
  and `Form`. `MenuBarExtra` serves `menu-bar` commands. Every view takes
  `isLoading` and `actions`.
- `ActionPanel` holds `Action`s. Each action can have a `Keyboard.Shortcut`.
  The first action is the primary one (↵). The panel is the ⌘K menu
  ([docs](https://developers.raycast.com/api-reference/user-interface/actions)).
  Built-in actions include `CopyToClipboard`, `OpenInBrowser`, `Push` and
  `Paste`.
- Navigation: `useNavigation()` returns `push(<View/>)` and `pop()`. Esc pops
  ([docs](https://developers.raycast.com/api-reference/user-interface/navigation)).
- Feedback: `showToast` (animated, success, failure; can be updated while
  shown), `showHUD`, `confirmAlert`
  ([docs](https://developers.raycast.com/api-reference/feedback/toast)).
- Data: `LocalStorage` (async KV in Raycast's encrypted database, private
  to each extension, "not meant to store large amounts of data",
  [docs](https://developers.raycast.com/api-reference/storage)). `Cache`
  (synchronous LRU on disk in the support folder, string values, with
  `subscribe`, [docs](https://developers.raycast.com/api-reference/cache)).
  `getPreferenceValues()`.
- `environment`: `raycastVersion`, `extensionName`, `entryPointName`/`Mode`,
  `assetsPath`, `supportPath`, `isDevelopment`, `appearance`, `textSize`,
  `launchType`, `canAccess()`
  ([docs](https://developers.raycast.com/api-reference/environment)).
- `@raycast/utils` hooks: `usePromise`, `useCachedPromise`, `useFetch`,
  `useExec` (stale-while-revalidate, argv form "don't have to be escaped",
  [docs](https://developers.raycast.com/utilities/react-hooks/useexec)),
  `useCachedState`, `useLocalStorage`, `useForm`, `useSQL`, `useAI`,
  `useStreamJSON`, `useFrecencySorting`
  ([index](https://developers.raycast.com/llms.txt)).

### 1.3 Lifecycle, tooling, store
- A command runs when launched. Its default export is rendered. When the
  user pops back to root, the whole command is unloaded. "There are memory
  limits for commands, and if those limits are exceeded, the command gets
  terminated"
  ([docs](https://developers.raycast.com/information/lifecycle)).
- CLI ([docs](https://developers.raycast.com/information/developer-tools/cli)):
  - It ships inside `@raycast/api`.
  - `ray develop`: auto-reload on save, error overlays with stack traces,
    logs in the terminal, and "the last successful command keeps running" when
    a build fails.
  - `ray build` (CI uses it), `ray bundle` (`.rayext` zip), `ray lint`,
    `ray migrate` (codemods), `ray publish`.
- How it works inside (blog, below):
  - The CLI is Go with esbuild as a library.
  - `npm run dev` watches, rebuilds and "hot deploys". The CLI and Raycast
    talk over URL schemes and a pid file.
  - Logs come back to the CLI through an OS log stream.
- Versioning:
  - Raycast publishes one latest version only.
  - Extensions declare only the API version (the npm dependency).
  - The app, API and CLI versions are synchronised.
  - "The Raycast app version needs to be greater or equal to the API version."
- Store: an open GitHub monorepo with a PR workflow, CI checks (manifest
  schema, lint, assets, build), and human plus community review. Every
  extension is open source
  ([security](https://developers.raycast.com/information/security)).
  Extensions update automatically.

### 1.4 Runtime and sandboxing
Source: [How the Raycast API and extensions work](https://www.raycast.com/blog/how-raycast-api-extensions-work), 2023-05-31.
- **First attempt:** "one JavaScriptCore instance per extension", in an
  XPC extension-host process. The UI was a JSON component tree rendered by
  custom AppKit components. Developers wanted npm packages and familiar React
  state, and polyfilling Node and web APIs became "an endless work stream".
- **Shipped:** React on **Node.js**. Raycast downloads and manages Node and
  checks its integrity. It runs one child Node process, and each extension
  gets a **worker thread** (a V8 isolate with a heap limit). The app talks to
  Node over **JSON-RPC on stdio** (DispatchIO), and only registered messages
  are allowed.
- **Rendering:**
  - A custom **react-reconciler** builds a JSON "render tree" on every pass.
  - Each tree is diffed against the last one as **JSON Patch**, and gzipped
    above a size threshold.
  - Swift view models (with bitsets of what changed) drive custom **AppKit**
    components (not SwiftUI).
  - "v = f(s) across process boundaries."
- **Sandboxing "considered ... but rejected":** a process per extension is
  too expensive, `sandbox-exec` is unsupported, and an engine-level sandbox
  is slow. Their aside: "Ironically, using JavaScriptCore like we did in the
  first attempt we discarded, would have given us a sandbox for free."
  Security comes from open source plus review, and "extensions are not
  further sandboxed" ([security](https://developers.raycast.com/information/security)).

### 1.5 Raycast 2.0
Source: [A Technical Deep Dive Into the New Raycast](https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast), 2026-05-14.
- **Structure:**
  - Swift/AppKit and C#/WPF host shells.
  - One React + TypeScript **web frontend** in WKWebView or WebView2.
  - One long-lived **Node backend** that "owns ... the extension runtime".
  - A Rust core.
- **Memory:**
  - WebContent ~120–200 MB, Node 150–200 MB.
  - An empty WebView is "about 50 MB", and a bare Node process ~12 MB.
  - v1 used 200–300 MB in total; v2 uses 350–450 MB.
- **Native feel took deliberate work:**
  - no `cursor: pointer` and no hover highlights;
  - popovers and tooltips are native windows;
  - workarounds for WebKit throttling, blank frames and flicker
    (`_doAfterNextPresentationUpdate`).
  - "Some native niceties are harder ... accessibility behaviors, drag and
    drop edge cases, or IME handling."
- **How extension UI renders in 2.0 [inference]:**
  - The developer changelog says "Raycast 2.0 brings the extension API to the
    new Raycast desktop app". In 2.3.0: "Reduced memory usage and the amount
    of data sent when updating extension views"
    ([changelog](https://developers.raycast.com/misc/changelog.md)).
  - The API (List, Detail, ...) did not change, and all UI now lives in the
    web frontend. So the same JSON render tree is now drawn by DOM components
    instead of AppKit.
  - **Lesson for us:** a fixed component vocabulary outlived a full renderer
    rewrite. Extension code did not change.
- Raycast for iOS has no third-party extensions (AI, Notes, Snippets,
  Quicklinks; [manual](https://manual.raycast.com/ios)).

### 1.6 What we take, what we leave
| Take | Leave |
|---|---|
| `package.json` as the manifest, with one extra field | Store, categories, owners, AI tools |
| A fixed, small component kit; `ActionPanel` with shortcuts; push/pop; toasts; `isLoading` | `Grid`, `MenuBarExtra`, `no-view` and background `interval` commands |
| A reconciler that emits a JSON tree, rendered natively | Node.js as the runtime (no iOS, 150–200 MB, no sandbox) |
| Manifest-declared preferences shown by the app | `LocalStorage`/`Cache` (our state lives in herdr and on the host, §5) |
| `usePromise`/`useExec`-style hooks | `useFetch` (no network in v1) |
| CLI inside the API package; esbuild; watch + reload; logs through the OS log | Go CLI, URL scheme + pid file handshake |
| Only the API version matters; the app ships React and the API | SemVer ranges, engines |

---

## 2. Rendering options for our app

### 2.1 (A) React in a WebView with our own DOM component kit
How: each plugin card is a `WebPage`. The page loads the plugin bundle from a
custom scheme. Our kit draws `List`, `Detail` and the rest as DOM and CSS that
look like the app (dark, SF fonts, ANSI palette). Native chrome surrounds it.
Revision 4 already designed the scheme handler, CSP, content rules and bridge
(DESIGN §10.4.7, §14.5).
- **Pros:**
  - Any DOM library works (react-markdown, react-diff-view, d3).
  - Custom drawing is free (SVG, canvas).
  - WebKit text layout is excellent (Raycast credits it for chat and
    Markdown).
  - Safari Web Inspector.
  - The JIT works on iOS too, because WebContent runs out of process.
  - About 1k fewer lines for us than B [guess].
- **Cons:**
  - **Memory:** one WebContent process per live card, ~50 MB empty and
    120–200 MB in use (Raycast's numbers). Six live cards can reach ~1 GB.
    Revision 4 had to cap live pages at 6 on Mac and 2 on iPhone.
  - **Nativeness is imitation.** Raycast spent a team-year on throttling,
    flicker, popovers and hover. Text selection, accessibility, focus and IME
    all differ from the rest of our SwiftUI app.
  - **Authors can skip the kit.** Arbitrary DOM means looks drift, unless
    every plugin is reviewed.
  - **Security:** repository content (a Markdown file) rendered as HTML is
    the top risk. XSS reaches the bridge, and the bridge reaches `exec`.
    Revision 4 needed CSP on every response, no inline script, content rules,
    a WebRTC removal script, navigation rules and per-origin data stores.
  - Two input stacks (DOM focus versus app shortcuts) inside one card.

### 2.2 (B) React in JavaScriptCore, JSON tree to native SwiftUI
How: one `JSVirtualMachine` + `JSContext` per card. The app first evaluates a
prelude (React, our reconciler, the API runtime, ~140 KB), then the plugin's
bundle. Each commit calls `__host.commit(json)`. Swift decodes it into a
`Node` tree and draws it with our SwiftUI components. Events go back as
`__dispatch("<nodeId>.<prop>", args)`.
- **react-reconciler in plain JSC works [verified]:**
  - React 19.3 + react-reconciler 0.34 run in the system `jsc`, with and
    without the JIT.
  - The host config is ~60 lines (`research/plugin-system-v2-spike/renderer.js`).
  - The only polyfills needed are `setTimeout`/`clearTimeout`,
    `queueMicrotask` and `console` (`poly.js`). React's scheduler falls back
    to `setTimeout`.
- **JIT:**
  - A `JSContext` inside an iOS app has no JIT ("disabled when we use JSC
    inside iOS apps", a 7.5× slowdown on a CPU benchmark,
    [Coote 2020](https://dev.to/alastaircoote/to-jsc-or-not-to-jsc-running-javascript-on-ios-in-2020-44ba)).
    It runs on the LLInt interpreter.
  - For UI-sized work it does not matter: no JIT, 500 rows, ~2 ms per update
    (§2.6).
  - On macOS the JIT works in-process (measured with the system JSC). Whether
    our Hardened Runtime build needs `com.apple.security.cs.allow-jit` for the
    JIT is unchecked [guess: JSC falls back to the interpreter without it,
    which is fast enough either way].
- **Threading:**
  - "all other threads attempting to use the same virtual machine must wait.
    To run JavaScript concurrently on multiple threads, use a separate
    JSVirtualMachine instance for each thread"
    ([docs](https://developer.apple.com/documentation/javascriptcore/jsvirtualmachine)).
  - So: one VM and one serial `DispatchQueue` per card. Decode on that queue,
    publish to `@MainActor`.
  - Suspending the queue pauses all timers and events while the card is off
    screen (one line).
- **Debugging:** `JSContext.isInspectable` (macOS 13.3+, iOS 16.4+,
  [docs](https://developer.apple.com/documentation/javascriptcore/jscontext/isinspectable))
  gives Safari Web Inspector with breakpoints and console.
- **No hard kill:** `JSContextGroupSetExecutionTimeLimit` exists only in
  WebKit's `JSContextRefPrivate.h`
  ([source](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/JSContextRefPrivate.h)).
  It is not in the SDK headers [verified: the macOS SDK's
  `JavaScriptCore.framework/Headers` has no such file]. DPLA §3.3.1(A):
  "must not use or call any private APIs". So a runaway loop cannot be
  interrupted, and there is no public heap limit either (§7.4).
- **Prior art:**
  - Raycast 1.x (AppKit, Node).
  - [react-watchos](https://github.com/emindeniz99/react-watchos/blob/main/docs/research.md):
    React 19 + reconciler 0.33 in QuickJS, JSON tree, SwiftUI interpreter,
    full-tree commits ("our trees are tens of nodes"). It notes that 2.5.2
    allows bundled interpreted JS.
  - react-tvml, Ink and react-three-fiber (custom reconcilers).
  - [Valdi](https://github.com/Snapchat/valdi) (Snap's TSX-to-native views,
    not React).
  - [LiveView Native](https://github.com/liveview-native) (a server-sent tree
    rendered by SwiftUI).
- **Pros:**
  - **Really native:** SwiftUI `List`, text selection, VoiceOver, Dynamic
    Type, context menus and keyboard. It is the same Markdown renderer as the
    chat view (DESIGN §11.1) and the same palette as the terminal.
  - **~3 MB per card** [verified].
  - **The sandbox comes free.** The context has no DOM, network, file system
    or `require`, only what we inject. There is no HTML anywhere, so
    repository text cannot become script.
  - One look by construction, which is what the user asked for: "default
    components ... look similar in style".
  - Same engine on both OSes. No JavaScript code needs `#if`.
- **Cons:**
  - Plugins get **only our components**. A commit graph or chart needs the
    escape hatch (C) or a new kit component from us.
  - npm packages that touch the DOM or Node do not work (react-markdown,
    react-diff-view). Pure JS does (`diff`, `parse-diff`, `date-fns`, a
    Markdown lexer).
  - We own a versioned component vocabulary forever. Raycast has done it
    since 2021 and kept it through a renderer rewrite.
  - Controlled text fields would make a round trip per key. So text fields
    are native-owned: JS gets `onChange` and its `value` is applied only when
    it differs from what JS last saw.
  - In-process: a bug in our bridge can crash the app (Raycast moved
    extensions to another process; we cannot on iOS).
  - Heavy compute is slow without the JIT. Rule: heavy work runs on the host
    (`git` does the diff), and `Diff` parses unified diff text natively.

### 2.3 (C) Hybrid: B plus a `<WebView>` escape hatch
`<WebView source="graph.html" data={json} onMessage={fn} />`:
- It loads a file from the plugin's own `dist/` over
  `hl-plugin://<plugin-id>/`.
- CSP: `default-src 'self'; script-src 'self'`. No network. No `exec` and no
  API inside the page.
- The page gets only the `data` JSON (re-sent on change) and may
  `postMessage` back. The JS treats those messages as untrusted.
- XSS inside it gains nothing beyond what the page can already do.
- It counts toward the live-web-page cap (6 on Mac, 2 on iPhone). It reuses
  the web page plugin's `WebPage` code and revision 4's scheme handler and
  CSP.

So nativeness is the default, and arbitrary drawing is possible without
giving web content any power.

### 2.4 (D) React Native embedded (iOS + react-native-macos)
- **What it is:** two forks to keep in step: facebook/react-native for iOS
  and [microsoft/react-native-macos](https://github.com/microsoft/react-native-macos),
  "a working fork of facebook/react-native" that trails upstream.
- **Cost:** a large native dependency (Hermes, Yoga, Fabric, CocoaPods)
  [guess: tens of MB]. Each plugin needs either its own RN host (heavy) or a
  shared one (no isolation).
- **Look:** RN components (`View`, `Text`, `FlatList`) are not our design
  system. We would still write the kit on top, and RN views are UIKit/AppKit
  inside a SwiftUI app.
- **What it adds over B:** Yoga layout, which we do not need for a fixed kit.
- **Verdict:** reject. Everything good about it (React to native) is B's ~60
  lines plus our SwiftUI kit, without the dependency.

### 2.5 Comparison
| | A WebView kit | **B JSC → SwiftUI** | **C = B + WebView hatch** | D React Native |
|---|---|---|---|---|
| Looks native | close, with effort (Raycast 2.0) | **native** | **native**, hatch looks web | RN views, still need a kit |
| Memory per live card | 50 MB empty, 120–200 MB in use | **~3 MB** [verified] | ~3 MB, hatch +50–200 MB | [guess] 10–30 MB |
| Custom drawing (diff, commit graph) | free | diff yes (kit `Diff`); graph no | **yes** | needs native modules |
| iOS speed | JIT (WebContent) | no JIT, fast enough (§2.6) | same | Hermes bytecode |
| Security | XSS → bridge → exec; many web locks | **no HTML; only injected API** | same, hatch has no API | in-process, no isolation |
| npm reach | everything | pure JS only | pure JS; DOM libs inside hatch | RN ecosystem |
| Our effort | lower [guess ~2k lines] | [guess ~3k lines] | +~300 lines when needed | high plus a dependency |
| DX | Web Inspector, Vite | Web Inspector on JSContext, esbuild | same | Metro, RN tooling |
| Renderer can change later | — | yes: the same JSON tree could drive a DOM kit (Raycast 2.0) | yes | no |

**Pick C, built as B first.** The user asked for "default components ... look
similar in style and look native enough". B gives that at a fraction of A's
memory, and removes revision 4's worst risk. The hatch keeps open-ended pane
kinds possible. Because plugins target a component vocabulary, not a DOM, we
can still switch the renderer to A later without breaking plugins.

### 2.6 Spike numbers [verified]
Files and a README are in `research/plugin-system-v2-spike/`. Test plugin: a
git-history-like `list` with 500 `item`s plus a `detail`. Every commit
serialises the full JSON tree (80 KB). Run on an Apple Silicon Mac, system
`jsc`.

| | JIT | `--useJIT=false` (like iOS) |
|---|---|---|
| Bundle: React + reconciler + plugin | 143 KB min, 45 KB gzip | same |
| One row selection (setState → commit → stringify) | 2–3 ms | ~2 ms |
| 20 updates in a row | 12–16 ms | 41–47 ms |
| Process footprint: 1 / 10 live JSContexts (Swift, one VM each) | 8.6 / 31.7 MB (base 2.0) | — |

- Full-tree commits are fine at this size. Add JSON Patch (Raycast) only if
  a profile shows big trees hurting.
- iPhone CPUs are slower than this Mac [guess 2–3×], which is still under
  one frame.

---

## 3. Everything is a plugin

One registry, one picker, one manifest shape. Being honest about what runs
where:

| Plugin | Kind | UI | JS at run time | herdr pane | Label marker |
|---|---|---|---|---|---|
| `terminal` | core | `Terminal` host component (libghostty, §7.6) | none | the pane itself | none (the default) |
| `agent` | core | `Terminal` + chat view (§10.2, §11) | none | the pane itself (`pane.agent` set) | none |
| `web` | core | `WebPage` host component (§10.3) | none (the page's own JS only) | placeholder | `web:<url>` |
| `git-history`, `diff`, `markdown` | core JS, bundled | kit | yes, same API as third parties | placeholder | `hl:…` |
| third-party | user | kit (+ hatch later) | yes | placeholder | `hl:…` |

- Core native plugins have a manifest JSON in the app bundle with
  `"host": "terminal" | "agent" | "web"` instead of `panes[].entry`. The
  picker reads title, icon and arg prompt from it like any plugin. There is no
  JavaScript cost per terminal.
- `Terminal` and `WebPage` are **not** kit components for third parties in
  v1. A terminal inside a plugin would need its own herdr pane and stream, and
  a web page inside a plugin is the hatch (C).
- Revision 4's L0 (listing herdr's own TUI plugin panes in the picker) is
  dropped, per the user. A herdr TUI plugin pane opened elsewhere still shows
  as a terminal, because it is one.
- Picker:
  ```
  New pane on devbox
    Terminal · Agent ▸ · Web page · Git history · Diff · Markdown · <installed plugins>
  ```

---

## 4. Plugin package and lifecycle

### 4.1 Manifest (`package.json` with one `herdlight` field)
```jsonc
{
  "name": "git-history",                 // plugin id: ^[a-z0-9][a-z0-9._-]{0,63}$, unique
  "version": "0.3.0",                    // informational, shown in Settings
  "description": "Commits, diffs and blame for the pane's repo",
  "repository": "https://github.com/me/hl-git-history",
  "herdlight": {
    "api": 1,                            // highest API version used; the app must support it
    "title": "Git history",
    "icon": "arrow.triangle.branch",     // SF Symbol name, or "assets/icon.png" (template-tinted)
    "platforms": ["macos", "ios"],
    "permissions": ["exec"],             // v1: only "exec" exists (§7)
    "panes": [
      { "name": "history", "title": "Git history", "entry": "src/history.tsx",
        "arg": { "title": "Ref or path", "placeholder": "HEAD", "required": false } }
    ],
    "preferences": [
      { "name": "maxCommits", "type": "textfield", "title": "Commits to load", "default": "500" },
      { "name": "diffStyle", "type": "dropdown", "title": "Diff style", "default": "unified",
        "data": [{ "title": "Unified", "value": "unified" }, { "title": "Split", "value": "split" }] }
    ]
  }
}
```
- One plugin can declare several pane kinds (Raycast's "commands"). With one
  pane, its label omits `/<pane>`.
- `arg.required` means the picker asks for the arg before it creates the
  pane. Otherwise the plugin starts with an empty arg and can call `setArg`
  itself.
- Preference types for v1: `textfield`, `password` (Keychain), `checkbox`,
  `dropdown`. No `appPicker`, `file` or `directory`: they would name Mac
  paths, and the plugin runs against a host.

### 4.2 Build tool
`@herdlight/api` ships types, hooks and a bin `hl-plugin`, like Raycast's
CLI inside `@raycast/api`:
- `hl-plugin build`:
  - validates the manifest (zod schema);
  - runs esbuild once per pane entry, writing `dist/<pane>.js` (IIFE, ES2022,
    minified);
  - marks `react`, `react/jsx-runtime` and `@herdlight/api` as externals
    mapped to globals the prelude defines. Bundles stay small, and there is
    one React per app release.
  - copies `assets/`.
- `hl-plugin dev` = `build --watch`, plus it tails
  `log stream --predicate 'subsystem == "herdlight.plugin.<id>"'`
  (Raycast streams logs the same way).
- About 150 lines of TypeScript [guess]. No templates, lint or publish
  commands in v1.

### 4.3 Where plugins live and how they get there (macOS)
```
~/Library/Application Support/Herdlight/plugins/<plugin-id>/
  package.json
  dist/<pane>.js
  assets/…
  .hl-source.json      {"url":"https://github.com/me/hl-git-history","ref":"main","commit":"<sha>","installedAt":"…"}
```
- **Install from a git URL** (Settings › Plugins › Add):
  1. `git clone --depth 1 --branch <ref> <url>` into a temp folder (local
     `ProcessExec`).
  2. Require `package.json` + `dist/`. **The app never runs npm or node.**
     Authors commit `dist/` or tag a release with it.
  3. Validate the manifest. Show the consent sheet (§7.2), which shows the
     URL and commit.
  4. Move the folder into place.
- **Install from a local folder (dev mode):** the app stores a security-scoped
  bookmark (the app is not sandboxed, so a path in `UserDefaults` is enough)
  and loads straight from that folder.
  - An FSEvents watch on `dist/` reloads every live card of that plugin when
    the folder changes.
  - Cards come back seamlessly, because their arg and instance state live
    outside JS (§5). Only React's in-memory state is lost.
  - Dev plugins get `isInspectable = true` and a red "DEV" badge.
- **Updates:**
  - On launch, at most once a day, run `git ls-remote <url> <ref>` per plugin
    and show "Update available" in Settings. The user presses Update; nothing
    updates by itself.
  - The update sheet links to the compare URL for GitHub repos. If the new
    manifest adds a permission, the user consents again.
  - Simpler choice: no auto-update. Raycast auto-updates because it reviews
    every change; we do not.
- **Versioning:**
  - `herdlight.api` must be ≤ the app's API version. Otherwise the card
    says "needs a newer Herdlight".
  - The app ships React, the reconciler and the API runtime (the prelude).
    The API version goes up with app releases (Raycast's synchronised model).
  - API changes are additive within version 1.

### 4.4 Lifecycle of a card
1. A pane with an `hl:` label enters the selected tab. The card is created,
   keyed by `(host, plugin, iid)` (§5.3).
2. Create the VM, context and serial queue. Inject `__host`. Evaluate the
   prelude, then `dist/<pane>.js`. Render the default export inside the
   app's root (navigation stack, toast host).
3. The card leaves the selected tab: suspend its queue. Timers, events and
   `exec` pause. The last tree stays drawn. On return, resume the queue.
4. Least recently used eviction at 12 live contexts, or on a memory warning.
   An evicted card tears down its VM, keeps its last tree as an image, and
   rebuilds on next show.
5. The pane leaves the snapshot: destroy the card.

### 4.5 How a plugin pane is created
This is DESIGN §10.4.4 with the new label:
1. Picker → arg prompt if `required` → generate `iid` (6 chars of
   `[a-z0-9]`, retry if any label in the snapshot already has it).
2. `pane.split {target_pane_id, direction, cwd: <source pane cwd>}` or
   `tab.create`.
3. `pane.rename {pane_id, label: "hl:<plugin>[/<pane>]#<iid> <arg>"}`.
4. `pane.send_input` with the placeholder (§5.4), through the base64
   envelope.
5. `pane.report_metadata {pane_id, source:"user:herdlight",
   tokens:{hl_rev:"<ms>"}}`. A rename sends no event; a token change sends
   `pane.updated` [verified in revision 4].
6. Re-read the snapshot.

### 4.6 Preferences
Preferences are app-side and per device:
- values in `UserDefaults` under `plugin.<id>.<name>`;
- `password` values in the Keychain;
- a form generated from the manifest in Settings › Plugins and in the card's
  "…" menu.

A required preference with no value shows a native "Set up ‹title›" view
instead of running the plugin (Raycast does the same). Why not on the host or
synced: preferences are about the viewer (diff style, page size), and the
phone may want different ones. Host-wide config belongs to the host's own
files, which the plugin can read with `exec`. Not synced: add
`NSUbiquitousKeyValueStore` if users ask.

### 4.7 iOS: where plugins come from
- **v1: core plugins only.** Git history, Diff, Markdown, Web, Terminal and
  Agent are compiled into the binary as JS resources. That is normal bundled
  interpreted code, which react-watchos and every RN app rely on.
- A label naming a third-party plugin shows the missing-plugin card (§5.6):
  "‹id› is a Mac plugin · Show placeholder". The placeholder shows the arg.
- **Later, behind Settings › "Load plugins from my Mac" (off by default):**
  - The phone already reaches the Mac as an SSH host (DESIGN §8.2). It reads
    `~/Library/Application Support/Herdlight/plugins/` there with one
    `tar` exec, using revision 4's tar reader (no `..`, no links, size cap),
    and keeps it in memory.
  - No iCloud entitlement, no new transport.
  - [guess] An iCloud container shared between a Developer ID Mac app and an
    App Store iOS app also works (same team, Developer ID provisioning
    profile). Check this in a spike only if SSH to the Mac is not good enough.
  - Consent is asked again on the phone.

### 4.8 App Store analysis (iOS)
- **The rule texts:**
  - Guideline 2.5.2: apps may not "download, install, or execute code which
    introduces or changes features or functionality of the app"
    ([guidelines](https://developer.apple.com/app-store/review/guidelines/)).
  - 4.7 allows "HTML5 and JavaScript mini apps ... and plug-ins". It requires
    4.7.2 (no native platform APIs without permission), 4.7.3 (consent before
    sharing data), 4.7.4 (an **index with universal links** of software
    offered in the app) and 4.7.5 (age gating).
  - DPLA §3.3.1(B): "Interpreted code may be downloaded to an Application but
    only so long as such code: (a) does not change the primary purpose ...
    (b) does not bypass signing, sandbox, or other security features of the
    OS; and (c) ... does not create a store or storefront" [docs: Apple
    Developer Program License Agreement PDF, read today].
- **Climate:**
  - In early 2026 Apple pulled "Anything" and blocked Replit and Vibecode
    updates under 2.5.2. Commentary lists "plugin systems adding post-review
    functionality" as at risk
    ([appcompliance.io](https://appcompliance.io/blog/apple-vibe-coding-crackdown-guideline-2-5-2/),
    [secondary]).
  - Obsidian still ships community JS plugins on iOS, with an in-app
    catalogue ([help](https://obsidian.md/help/community-plugins)).
- **Our position for the later setting:**
  - The code is the user's own, copied from their own Mac.
  - The app offers no catalogue or storefront (so 4.7.4 does not apply).
  - The primary purpose is unchanged: plugin panes are views of the user's
    own servers.
  - The API exposes no iOS platform API beyond clipboard write and opening a
    URL after a confirm.
  - The JS runs inside JavaScriptCore and bypasses nothing.
- Risk [guess]: medium. That is why v1 ships without it, and why the
  fallback is simply to remove the setting.

---

## 5. Plugin state and restore from herdr

Goal: after a fresh app start, on any device, the app rebuilds every plugin
pane from herdr alone. It stores nothing per pane.

### 5.1 Where each piece of state lives
| State | Example | Where | Who sees it | Survives |
|---|---|---|---|---|
| Pane exists, its place in the layout | — | herdr pane (split tree) | every device, herdr TUI | moves, cold restart |
| Which plugin and pane kind | `git-history` | **label** | every device | moves, cold restart |
| Instance id | `k3f9q2` | **label** | every device | moves, cold restart |
| The arg: what the pane shows | `main`, `docs/DESIGN.md`, `base=main` | **label** | every device, TUI border | moves, cold restart |
| Bigger instance state | selected commit, filters, scroll anchor, review comments | **host file**, keyed by iid (§5.5) | every device that reaches the host | everything except deleting the file |
| Change signal for other devices | `hl_rev=1791492…` | metadata token | every device (`pane.updated`) | not persisted, and does not need to be |
| Preferences | diff style | app, per device (§4.6) | this device | app reinstall: no |
| Installed plugin code, consent | — | app | this device | — |
| React in-memory state | hover, expanded rows | JS heap | this card | nothing (rebuilt from the rows above) |

Rule for authors (SDK README): "If losing it on a reload would annoy the user,
put it in `setArg` (small, defines the pane) or `useInstanceState` (bigger).
Everything else is React state."

### 5.2 Label format
```
label     = "web:" url
          | "hl:" plugin-id [ "/" pane-name ] "#" iid [ " " arg ]
plugin-id = [a-z0-9][a-z0-9._-]{0,63}
pane-name = [a-z0-9][a-z0-9-]{0,31}
iid       = [a-z0-9]{6}
arg       = the rest (any text, no control characters, ≤ 1024 chars, enforced by setArg)
regex     = ^hl:([a-z0-9][a-z0-9._-]{0,63})(?:/([a-z0-9][a-z0-9-]{0,31}))?#([a-z0-9]{6})(?: (.*))?$
```
Examples, as they look in the herdr TUI border:
```
hl:git-history#k3f9q2 main
hl:markdown#q2m0zd docs/DESIGN.md
hl:diff#a81xw0 base=main
hl:kanban/board#7tt1qe
web:http://localhost:3000/dashboard
```
- **Why the label:** it is the only free-form pane field that has no length
  limit, survives moves (also across workspaces) and survives a cold restart
  [verified, `research/herdr-core.md` §3, §7.1]. Tokens are capped at 80
  characters and lost on restart. Env, argv and title are lost or invisible.
- **Readable:** `#` and a space keep it short and scannable. The herdr TUI
  shows the label as the border title when the metadata `title` is empty
  (`state.rs border_label`). The arg goes last, so the useful part is what a
  TUI user reads. Revision 4's `hl:<id>:<arg>` is replaced; nothing shipped,
  so nothing needs to stay compatible.
- **Trimmed:** herdr trims labels, so an arg cannot start or end with a space.
  `setArg` trims too, so the app's idea of the arg matches herdr's.
- **Size:** every snapshot carries every label to every device. So `setArg`
  rejects args over 1024 characters, and the SDK advises under ~200. Bigger
  state goes to §5.5.
- `web:` stays as it is. The web plugin has no instance state, and the URL
  is the most readable label there is.

### 5.3 Instance identity
- **Why an iid is needed:**
  - `pane_id` changes on a move to another workspace.
  - `terminal_id` changes on a herdr cold restart [verified].
  - The label is the only stable carrier, so the instance id lives in it.
- **Generated by the device that creates the pane:** 6 characters of
  `[a-z0-9]` (2.2 billion values). It is checked against the current
  snapshot's labels. It never changes, and `setArg` keeps it.
- **Card identity in the PaneViewRegistry is `(host, plugin-id, iid)`**,
  not `terminal_id`. Plugin cards therefore survive moves *and* cold restarts
  without a reload.
- **Duplicate iids** can happen if someone copies a label by hand or
  `layout.apply` replays one [guess]. Both panes then share one state file.
  That is harmless, and the app does nothing special. Simpler choice: no
  re-keying.

### 5.4 The placeholder process
It is sent with `pane.send_input` through the base64 envelope (DESIGN §7.1):
```sh
 clear; exec sh -c 'eval "$(printf %s "$1" | base64 -d)"' sh <BASE64>
```
It decodes to:
```sh
printf '\033]2;%s\007' 'Git history · main'                    # outer window title only
printf '◆ %s\n  %s\n  arg: %s\n\n  Shown by Herdlight. Open it there to use it.\n  state: %s\n' \
  'Git history' 'hl:git-history#k3f9q2' 'main' '~/.local/state/herdlight/default/git-history/k3f9q2.json'
stty raw -echo; exec cat >/dev/null
```
- **What it carries:** nothing the app relies on. After a cold restart herdr
  brings the pane back as a plain shell, keeps the label, and does **not**
  re-run the placeholder [verified in revision 4]. The label is the truth.
  The placeholder exists so that:
  - herdr keeps a slot that moves and resizes like any pane;
  - herdr TUI users and the phone without the plugin see what the pane is;
  - Ctrl-C and Ctrl-D cannot end it by accident (`stty raw`).
- After a herdr restart the card works anyway. Its menu offers **Restore
  placeholder**. The app never types into a shell by itself (DESIGN §10.3).
- If the placeholder process is killed, herdr closes the pane, and the card
  goes with it.

### 5.5 Bigger instance state: a file on the pane's host
```
${XDG_STATE_HOME:-$HOME/.local/state}/herdlight/<herdr-session>/<plugin-id>/<iid>.json
```
- **Why the host:**
  - It is next to herdr and the data.
  - It is shared by every device that reaches that host (Mac and iPhone see
    the same state).
  - It survives an app reinstall.
  - It needs no sync service.
  - `<herdr-session>` is in the path because iids are unique only within one
    herdr session.
- **API:** `const [state, setState] = useInstanceState(initial)` (§6).
- **Read:** one `cat` exec when the card is built. Simpler choice: one exec
  per card. Batch every visible card's file on a host into one exec if a
  profile shows connect-time cost.
- **Write:** `setState` is debounced 500 ms. The JSON comes over stdin:
  `sh -c 'umask 077; mkdir -p "${1%/*}" && cat >"$1.tmp" && mv "$1.tmp" "$1"' sh <path>`.
  The rename is atomic. Cap 256 KiB. After the write, the app sends
  `report_metadata tokens:{hl_rev:"<ms>"}` on that pane.
- **Other devices:** a changed `hl_rev` on a pane whose card uses state means
  "re-read the file". Then the hook's value updates and the component
  re-renders.
- **Conflicts:** last writer wins for the whole object. Plugins keep state
  small and idempotent, and store their own `v` for schema changes. Devices
  may run different plugin versions.
- **Cost:** one exec per read or write (18–130 ms locally plus the round
  trip, DESIGN §7.3). Reads happen once per card build, and writes are
  debounced, so this is acceptable.
- **Plugin record:** at create time the app also writes
  `…/<plugin-id>/plugin.json` = `{title, source, version}`, only if it is
  missing. It is used only when another device lacks the plugin (§5.6).
  Simpler choice: nothing else is written.
- **Why not the label for everything:** JSON in a label is unreadable in the
  TUI border and travels in every snapshot. **Why not app KV:** it is not
  shared between Mac and iPhone, and it is lost on reinstall, which goes
  against "restore from herdr".

### 5.6 A label for a plugin this device does not have
Common case: the Mac created the pane, and the phone lacks the plugin.
1. The card shows the plugin icon placeholder, `hl:<id>`, the arg, and "Not
   installed on this ‹device›". Actions: **Show placeholder** (the terminal
   view of the pane) and **Close pane**.
2. On macOS, if `plugin.json` exists on the host (one `cat`, only for missing
   plugins), the card adds **Install from ‹source›…**. That opens the normal
   install sheet with the URL shown. A host could plant a hostile URL, so it
   is never installed without the user's click and the consent sheet.
3. The label is never changed, so the pane comes back to life when the
   plugin is installed. The registry re-resolves on install.

### 5.7 Restore algorithm (fresh app start, any device)
1. Connect each host. Read `session.snapshot` (DESIGN §8.5, unchanged).
2. For each pane in the snapshot, classify it:
   - label matches `^web:https?://` → `web` plugin, arg = the URL
     (§10.3 load rules apply);
   - label matches the `hl:` regex → `(plugin, pane, iid, arg)`;
   - otherwise → `agent` if `pane.agent` is set, else `terminal`.
3. Resolve the plugin in the local registry: core, installed, or dev.
   - Missing → the §5.6 card.
   - Unknown pane name → "‹plugin› has no pane ‹name›" plus Show placeholder.
   - `api` too new → "needs a newer Herdlight".
   - A required preference is unset → the "Set up" view.
4. Key the card `(host, plugin, iid)`. If a card with that key is already
   alive (for example after a move or a cold restart), keep it, and update
   only `paneId`, `cwd` and `arg`.
5. When the card is first shown (§4.4):
   - build the JSContext;
   - inject the pane context `{host, paneId, cwd, arg, iid, plugin, device}`;
   - if the plugin calls `useInstanceState`, `cat` the state file (a missing
     file means `initial`);
   - render.
6. On every later snapshot:
   - changed label arg → new `arg` in `usePane()` (re-render, no reload);
   - changed `hl_rev` → re-read the state file if the card uses state;
   - changed `cwd` → update the context;
   - pane gone → destroy the card.
7. Garbage collection, at most once a day per host and session, after the
   first snapshot (§5.8).

No step reads app storage, except the plugin code, consent and preferences.

### 5.8 Cleanup of orphan state files
- **The problem:** a closed pane takes its label with it. The state file
  stays. herdr has no hook we can use, since we do not build on herdr plugins.
- **GC step** (whichever device connects; it is idempotent):
  1. List `…/herdlight/<session>/*/*.json` files older than 24 hours
     (`find … -mtime +0`).
  2. Delete those whose `<plugin>/<iid>` is not in any current label.
- **Why 24 hours:** it covers a device that creates a pane and writes its
  state while another device holds an older snapshot. Labels survive herdr
  restarts, so a live pane never loses its file.
- A pane renamed by hand into a non-plugin label becomes a terminal, and its
  file is collected the next day.
- Simpler choice: folders of herdr sessions that no longer exist are left
  alone (a few KB). Add a 30-day sweep if anyone notices.

---

## 6. Plugin API (all of it, v1)

```ts
// @herdlight/api  (types; runtime is the app's prelude)
export function usePane(): {
  host: { id: string; label: string };      // the pane's host; exec goes only there
  paneId: string;                            // not durable (changes on cross-workspace move); do not store
  cwd: string; arg: string; iid: string;
  plugin: { id: string; version: string; pane: string };
  device: "macos" | "ios"; apiVersion: number; isDevelopment: boolean;
};
export function exec(argv: string[], opts?: { cwd?: string; stdin?: string; timeoutMs?: number }):
  Promise<{ code: number; stdout: string; stderr: string; truncated: boolean }>;   // needs "exec"
export function setArg(arg: string): Promise<void>;
export function useInstanceState<T>(initial: T): [T, (next: T | ((prev: T) => T)) => void, { loading: boolean }];
export function useSnapshot(): HerdrSnapshot | undefined;           // herdr's session.snapshot, debounced
export function getPreferenceValues<T>(): T;
export function showToast(t: { style?: "success" | "failure" | "animated"; title: string; message?: string }): Promise<Toast>;
export function open(url: string): Promise<boolean>;                 // http(s) only, native confirm sheet
export const Clipboard: { copy(text: string): Promise<void> };
export function useNavigation(): { push(view: ReactNode): void; pop(): void };
// @herdlight/api/utils
export function usePromise<T>(fn: (...a: any[]) => Promise<T>, args?: any[]): { data?: T; error?: Error; isLoading: boolean; revalidate(): void };
export function useExec(argv: string[], opts?: { cwd?: string; parse?: (stdout: string) => any; refreshOnSnapshot?: boolean }): ReturnType<typeof usePromise>;
// components
export { List, Detail, Markdown, Diff, Code, Form, ActionPanel, Action, Icon, Color };
```

| API | Why it exists | How |
|---|---|---|
| `exec` | Every data need is on the pane's host: `git`, `cat`, `gh`, `rg`, and the herdr CLI (read panes, `agent prompt`). `argv[0] === "herdr"` is replaced with the resolved herdr path plus `--session <s>` | `Exec.run` on **that card's host only**, through the base64 envelope (DESIGN §7.1). Default cwd is the pane's cwd. 30 s timeout, 4 MiB per stream. One queue per host, 2 at a time (DESIGN §8.4). Refused while the card's queue is suspended |
| `usePane` | Every plugin needs its arg and cwd. Raycast's `environment` folded in | Injected. Re-renders on arg or cwd change |
| `setArg` | The durable "what this pane shows" (§5) | `pane.rename` of its **own** pane only, keeping `hl:<id>#<iid>`, then the `hl_rev` token |
| `useInstanceState` | Bigger durable state shared across devices (§5.5) | Host file plus the `hl_rev` signal |
| `useSnapshot` | Refresh when an agent finishes (redraw the diff) | The HostStore forwards the snapshot it already has, debounced, only while the card is visible. No new channel |
| preferences | Per-device config (§4.6) | Read-only for the plugin |
| `showToast` | Errors and progress without custom UI | A native toast at the card's bottom edge. `animated` shows a spinner. The returned handle can update or hide it |
| `open` | Links in commits, PR URLs | `http`/`https` only. A sheet shows the full URL before opening, because a URL can carry data out |
| `Clipboard.copy` | "Copy SHA" | Write only. No clipboard read |
| navigation | Commit list → commit detail | A native `NavigationStack` inside the card. Back in the header, Esc, ⌘[ |
| `ActionPanel`/`Action` | Every interaction, with shortcuts | Below |
| `usePromise`, `useExec` | Raycast proved these cut boilerplate. `useExec` = `exec` + `usePromise`, with optional re-run on snapshot change | ~60 lines in the prelude |

**Components (v1).** They map to SwiftUI. Props follow Raycast's names where
there is an equivalent.
| Component | Native rendering | Notes |
|---|---|---|
| `List`, `List.Section`, `List.Item` (`title`, `subtitle`, `icon`, `accessories`, `keywords`, `detail`), `List.EmptyView` | `List` with selection; `searchable` if `searchBarPlaceholder`; split with detail when `isShowingDetail` | Native-side virtualisation; filtering is native unless `filtering={false}` + `onSearchTextChange` |
| `Detail` (`markdown`, `metadata`) | ScrollView: Markdown blocks + a metadata grid | |
| `Markdown` | the chat view's renderer (`AttributedString(markdown:)`, blocks) | No HTML. Remote images show alt text with "Load image" (no tracking pixels). Relative images later |
| `Diff` (`patch: string`, `mode: "unified" \| "split"`, `onLineAction?`) | A native unified-diff parser + LazyVStack of monospaced lines, ANSI palette | The diff view, git history and review all use it |
| `Code` (`text`, `language?`, `tokens?`) | Monospaced, selectable, horizontal scroll | `tokens` = pre-coloured spans from a pure-JS highlighter, mapped to ANSI or palette colours |
| `Form`, `Form.TextField`, `Form.TextArea`, `Form.Dropdown`, `Form.Checkbox` | SwiftUI `Form` | Native-owned editing state; `onChange` debounced to JS; `onSubmit` via the primary action. Used for "comment on line → send to agent" |
| `ActionPanel`, `ActionPanel.Section`, `Action` (`title`, `icon`, `shortcut`, `style: "destructive"`, `confirm?`, `onAction`), `Action.CopyToClipboard`, `Action.OpenURL`, `Action.Push` | Card header overflow menu + row context menus + ⌘K popover; first action = ↵ / double-click, second = ⌘↵ | Shortcuts work only while the card has focus. Shortcuts the app reserves (⌘T/W/D/N, ⌘0–9, ⌘,, ⌘[, ⌘]) are ignored, with a dev warning. iOS: context menu (long press), `.keyboardShortcut` for hardware keyboards |
| `Icon` (SF Symbol names, `{source:"assets/x.png"}`), `Color` (semantic tokens + the 16 ANSI names) | `Image(systemName:)`, template images | No arbitrary hex in v1, so plugins keep the app's palette |
| `isLoading` on every view | A thin progress bar under the card header | |

Not in the API (each with "when" in §8): network/fetch, LocalStorage/Cache,
`Grid`, `MenuBarExtra`, background commands, layout primitives
(`Stack`/`Text`), HUD and alerts beyond `Action.confirm`, opening another
plugin pane, clipboard read, file pickers, AI, OAuth.

How the three example plugins use it (proof the set is enough):
- **Diff:**
  - arg `base=main`;
  - `useExec(["git","diff","--no-color",base])` with
    `refreshOnSnapshot`;
  - `<Diff patch>` with `List` per file;
  - an `Action` "Send comment to agent" → `Form.TextArea` →
    `exec(["herdr","agent","prompt",paneOfAgent,text])` (the agent is found
    via `useSnapshot`).
- **Markdown:**
  - arg = path;
  - `exec(["cat",path])` → `<Detail markdown>`;
  - `useInstanceState({anchor})` for the reading position;
  - an action "Open in browser" when a URL is set.
- **Git history:**
  - `useExec(["git","log","--format=%H%x00%s%x00%an%x00%ar","-n",max])` →
    `List` of commits, with `isShowingDetail`;
  - `Action.Push` → a `Detail` with metadata plus `<Diff>` from
    `git show --no-color`;
  - `setArg(ref)` from a ref `Form.Dropdown`;
  - the selected commit in `useInstanceState`.
  - The lane graph waits for the hatch.

---

## 7. Security and permissions

### 7.1 What changed since revision 4
Plugins now come from the user (installed in the app), not from each host.
They run inside the app and could, in principle, reach **any** host the app
reaches. The answers:
1. **One VM per card, and a card is bound to one pane.** `exec` goes only to
   that pane's host. Cards share no JS memory. The plugin gets no writable
   storage that spans hosts (instance state is on the same host; preferences
   are read-only). There is no network. So a plugin cannot carry data from
   host A to host B in v1. The remaining exits are user-confirmed `open(url)`
   (the sheet shows the full URL) and `Clipboard.copy`, which needs a user
   click on an action.
2. **No background execution.** JS runs only while one of the plugin's
   cards is alive. A plugin's reach is the set of hosts where the user has
   its panes.
3. **No HTML and no DOM.** Repository content (Markdown, diffs, commit
   messages) is drawn by native components as text. Revision 4's top risk
   ("XSS turns into host commands") is gone, and so are its CSP, content
   rules and WebRTC removal, except for the later hatch, which has no API.
4. **The arg and host content are untrusted.** They reach a host only as
   argv through the envelope, never as a shell string. A plugin that
   builds `sh -c` from them is the author's bug. The SDK README says so, and
   `exec` has no `shell` option (unlike Raycast's `useExec`).
5. **A hostile host can write labels**, and so can instantiate any
   *installed* plugin on itself. That gives it only what the plugin does on
   that same host, which it already owns. A plugin's first `exec` on This Mac
   is the exception (§7.2).

### 7.2 Permissions and consent
- **Manifest `permissions`:** v1 has exactly one, `"exec"`. Without it the
  plugin can render, read its arg, snapshot and preferences, and keep
  instance state (the app does the file I/O with fixed commands).
- **Why no finer grains:** within a host, a list like "only `git`" is no
  barrier (`git -c alias.x='!sh'`, revision 4 §10.4.7). A herdr method
  allowlist is no barrier while `exec` can run the herdr CLI. We do not show
  the user rules that do not hold.
- **Consent at install, per device.** The sheet shows title, source URL,
  commit and permissions in plain words:
  "‹Title› can run any command as you on the host of each pane you open with
  it, including typing into panes and prompting agents there. On This Mac
  that includes your files, SSH keys and the app's connections to your other
  hosts."
  Host-supplied strings are cleaned of control and bidi characters.
- **Again on an update** that adds a permission.
- **This Mac gets one extra confirm**, on the first `exec` from a plugin
  card there ("Allow ‹title› on This Mac?"). It is remembered per plugin and
  revocable in Settings, because a plugin running locally can reach every
  other host.
- **Core plugins** (bundled, reviewed with the app) ask nothing.
- Settings › Plugins lists each plugin with its source, commit, permissions
  and This Mac answer, with **Disable** and **Remove**.

### 7.3 Isolation
- A separate `JSVirtualMachine`, `JSContext` and serial queue per card. No
  shared objects. `__host` is a frozen object with only the functions in §6.
  Every call checks the card's permissions and pane binding in Swift.
- No `fetch`, `XMLHttpRequest`, `WebSocket`, `require`, `process` or
  file-system objects exist. `eval` exists, but evaluates inside the same
  empty sandbox.
- Size caps: commit tree 4 MB, exec output 4 MiB per stream, state 256 KiB,
  arg 1024 characters, toast text 500 characters.

### 7.4 Watchdog (no hard kill exists)
- Every host-to-JS call (event, timer, exec result, snapshot) records a start
  time on the card's queue. A main-thread timer at 1 Hz flags any call still
  running after 3 s.
- A flagged card stops getting events and shows "‹title› is not responding ·
  Reload". Reload builds a fresh VM on a new queue.
- The old thread cannot be stopped without private API (§2.2). A
  `while(true){}` keeps one core busy until the app quits.
  `ponytail:` hung VMs are abandoned, not killed. After 2 hangs, the plugin
  is disabled until relaunch. Use QuickJS-ng with `JS_SetInterruptHandler` +
  `JS_SetMemoryLimit` if this ever bites. It costs the Safari inspector and
  ~half of JSC's no-JIT speed (Coote 2020).
- No public heap limit either. The caps in §7.3 bound what the bridge
  accepts. A runaway heap shows up as app memory, and Reload drops it.

### 7.5 Review story
- No store and no review in v1. Plugins come from URLs the user picks.
  Consent shows the exact commit. Updates are manual, with a compare link.
- That is weaker than Raycast's review. The protections that hold anyway:
  host binding, no network, no background execution, This Mac confirm.
- A curated list (a JSON file in our repo) can come later. Never inside the
  iOS app (4.7.4).

---

## 8. What we skip (and when to add it)

| Skipped | Add when |
|---|---|
| `<WebView>` escape hatch (C) | The first plugin needs custom drawing (git lane graph, charts) |
| Network / `fetch` (manifest origins + URLSession) | A plugin needs a web API it cannot reach with `curl`/`gh` on the host. It also needs a per-origin consent |
| `LocalStorage`/`Cache`/`useCachedState` | A plugin needs device-local data that is neither pref nor instance state |
| Layout primitives (`Stack`, `Text`, `Badge`) | Several plugins misuse `List`/`Detail` for layouts. Until then they keep the look consistent |
| `Grid`, `MenuBarExtra`, background or no-view commands, plugin contributions outside panes (sidebar, status area, pills) | Someone needs a plugin outside a pane |
| `openPane(plugin, arg)` from a plugin | The diff wants to open a file in Markdown |
| JSON Patch diffs of the tree | A profile shows big trees (thousands of rows) hurting |
| Finer permissions | Network exists (then: origins) |
| User plugins on iOS | After v1, behind a setting, read from the Mac host (§4.7) |
| Preference sync between devices | Users ask; `NSUbiquitousKeyValueStore` |
| Auto-update, store, review, codemods, templates, lint | Plugins have users other than their authors |
| herdr TUI plugin panes in the picker (old L0) | Never, per the user |
| QuickJS instead of JSC | Hung plugins are a real problem (§7.4) |

---

## 9. Changes to DESIGN.md if adopted

- **§0 item 10, §10 intro, picker:** replace with §0 and §3 of this file.
  Drop L0 and host web plugins.
- **§10.4 rewritten:**
  - registry and core plugins (§3);
  - manifest, CLI, install and update (§4);
  - state and restore (§5);
  - API and components (§6);
  - security (§7).
- **§6 architecture:**
  - add `PluginHost` (one VM, context and queue per card; the bridge) and
    `PluginRegistry` (core plus installed plus dev; manifests; consent);
  - the PaneViewRegistry keys plugin cards by `(host, plugin, iid)`.
- **§13 storage:**
  - remove "third-party plugin code: the host" and "plugin web storage";
  - add plugin code + `.hl-source.json` (Application Support), consent and
    This Mac answers (`UserDefaults`), preferences (`UserDefaults` +
    Keychain), instance state (host file, §5.5).
- **§14.5:** a `JSContext` bridge replaces `URLSchemeHandler` + content rules
  + `WKScriptMessageHandlerWithReply`, until the hatch.
- **§14.6 tests:**
  - the label parser (`web:`, `hl:` with and without `/pane`, an arg with
    spaces and `#`);
  - the reconciler tree round trip (JS commit → Swift `Node` decode) on
    recorded trees;
  - the state-write command through the envelope (bash, zsh, fish);
  - the GC selection logic;
  - the bridge refusing `exec` to another host or without permission.
  - Drop the network canary page and the tar reader (until iOS user plugins).
- **Decisions:** D34–D38 are replaced by:
  - kit + JSC → SwiftUI (C, built as B);
  - plugins live in the app, installed from git or a folder;
  - label `hl:<plugin>[/<pane>]#<iid> <arg>`, with state in a host file keyed
    by iid;
  - API §6;
  - security §7 (per-card host binding, install consent, This Mac confirm,
    no network).
- **§17 build order, step 3:** plugin host + reconciler prelude → `List`,
  `Detail`, `Markdown`, `ActionPanel` → `Diff`, `Code`, `Form` → git history,
  diff and Markdown core plugins → install and dev mode → CLI.
- **New spike S6:**
  - JSC in the Hardened Runtime build (is the JIT on? does it matter?);
  - 12 live plugin cards plus 9 terminals in the strip (frame time);
  - a `List` of 5,000 commits through the full-tree commit;
  - Safari inspector on iOS.

---

## Sources
- Raycast: [How the Raycast API and extensions work](https://www.raycast.com/blog/how-raycast-api-extensions-work) (2023-05-31) ·
  [A Technical Deep Dive Into the New Raycast](https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast) (2026-05-14) ·
  [Manifest](https://developers.raycast.com/information/manifest) · [UI](https://developers.raycast.com/api-reference/user-interface) ·
  [Detail](https://developers.raycast.com/api-reference/user-interface/detail) · [Actions](https://developers.raycast.com/api-reference/user-interface/actions) ·
  [Navigation](https://developers.raycast.com/api-reference/user-interface/navigation) · [Toast](https://developers.raycast.com/api-reference/feedback/toast) ·
  [Storage](https://developers.raycast.com/api-reference/storage) · [Cache](https://developers.raycast.com/api-reference/cache) ·
  [Environment](https://developers.raycast.com/api-reference/environment) · [Preferences](https://developers.raycast.com/api-reference/preferences) ·
  [useExec](https://developers.raycast.com/utilities/react-hooks/useexec) · [usePromise](https://developers.raycast.com/utilities/react-hooks/usepromise) ·
  [Lifecycle](https://developers.raycast.com/information/lifecycle) · [CLI](https://developers.raycast.com/information/developer-tools/cli) ·
  [Security](https://developers.raycast.com/information/security) · [Changelog](https://developers.raycast.com/misc/changelog.md) · [iOS manual](https://manual.raycast.com/ios)
- Apple: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) (2.5.2, 4.7) ·
  [Apple Developer Program License Agreement](https://developer.apple.com/support/downloads/terms/apple-developer-program/Apple-Developer-Program-License-Agreement-English.pdf) (§3.3.1 A, B) ·
  [JSVirtualMachine](https://developer.apple.com/documentation/javascriptcore/jsvirtualmachine) ·
  [JSContext.isInspectable](https://developer.apple.com/documentation/javascriptcore/jscontext/isinspectable) ·
  [JSContextRefPrivate.h](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/JSContextRefPrivate.h)
- JS on iOS: [To JSC or not to JSC (Coote, 2020)](https://dev.to/alastaircoote/to-jsc-or-not-to-jsc-running-javascript-on-ios-in-2020-44ba) ·
  [react-watchos research](https://github.com/emindeniz99/react-watchos/blob/main/docs/research.md) ·
  [react-reconciler](https://github.com/facebook/react/blob/main/packages/react-reconciler/README.md) ·
  [react-native-macos](https://github.com/microsoft/react-native-macos) · [Valdi](https://github.com/Snapchat/valdi) · [LiveView Native](https://github.com/liveview-native)
- App Store climate: [appcompliance.io on 2.5.2 (2026-03-02)](https://appcompliance.io/blog/apple-vibe-coding-crackdown-guideline-2-5-2/) [secondary] ·
  [Obsidian community plugins](https://obsidian.md/help/community-plugins)
- herdr facts: `research/herdr-core.md` §3, §7.1–7.2; DESIGN.md §7.1, §7.3, §8.4, §10.3, §10.4.4
- Spike: `research/plugin-system-v2-spike/` (run 2026-10-08)
