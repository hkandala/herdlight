import React, { useState } from "react";
import { render, dispatch } from "./renderer.js";
const commits = Array.from({ length: 500 }, (_, i) => ({ sha: (i * 2654435761 >>> 0).toString(16), subject: `commit number ${i} fixes a thing` }));
function GitHistory() {
  const [sel, setSel] = useState(0);
  return <list title="History">{commits.map((c, i) =>
    <item key={c.sha} title={c.subject} subtitle={c.sha} selected={i === sel} onSelect={() => setSel(i)} />)}
    <detail markdown={`# ${commits[sel].subject}`} />
  </list>;
}
globalThis.__start = (host) => {
  let n = 0, last;
  const t0 = Date.now();
  render(<GitHistory />, (tree) => { n++; last = JSON.stringify(tree); host.commit(n, last.length, Date.now() - t0); });
  globalThis.__dispatch = dispatch;
  globalThis.__last = () => last;
};
