# Spike: React 19 + react-reconciler in plain JavaScriptCore

Proves option B (React in JSC, JSON tree out) works and measures cost.

```sh
npm i
npx esbuild plugin.jsx --bundle --format=iife --minify --define:process.env.NODE_ENV='"production"' --outfile=out.js
cat poly.js out.js drive.js > all.js
J=/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc
$J all.js                  # with JIT (macOS JSContext)
$J --useJIT=false all.js   # no JIT (like a JSContext inside an iOS app)
swiftc -O mem.swift -o mem && ./mem   # footprint of N JSContexts, one JSVirtualMachine each
```

Results on an Apple Silicon Mac, macOS 27.0.1, react 19.3.0, react-reconciler 0.34.0,
2026-10-08 (500-row list + detail, full JSON tree per commit = 80 KB):

| | JIT | no JIT |
|---|---|---|
| bundle (React + reconciler + plugin), minified / gzip | 143 KB / 45 KB | same |
| select a row (setState → commit → JSON.stringify) | ~2–3 ms | ~2 ms |
| 20 consecutive updates | 12–16 ms | 41–47 ms |
| footprint, 1 context | 8.6 MB process (2.0 MB base) | |
| footprint, 10 contexts | 31.7 MB process (~3 MB per context) | |

`renderer.js` is the whole host config (~60 lines). `poly.js` is the only polyfill
needed (setTimeout/clearTimeout/queueMicrotask/console).
