var __q = [], __tid = 0;
globalThis.setTimeout = (f, ms, ...a) => { const id = ++__tid; __q.push({ id, f, a }); return id; };
globalThis.clearTimeout = (id) => { __q = __q.filter((t) => t.id !== id); };
globalThis.queueMicrotask ??= (f) => Promise.resolve().then(f);
globalThis.console ??= { log: (...a) => print(...a), error: (...a) => print("ERR", ...a), warn: (...a) => print("WARN", ...a) };
globalThis.__drain = () => { let k = 0; while (__q.length && k++ < 10000) { const t = __q.shift(); t.f(...t.a); } };
