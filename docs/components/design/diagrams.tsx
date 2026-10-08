// Diagram blocks that follow the docs theme: flows, the architecture layers, control ownership.
import type { ReactNode } from 'react';

const Cap = ({ children }: { children?: ReactNode }) =>
  children ? <figcaption className="cap">{children}</figcaption> : null;

/** <Flow steps={[['title', 'note'], …]} />; pass several rows as `rows` for parallel paths. */
export function Flow({
  steps,
  rows,
  caption,
}: {
  steps?: [string, string?][];
  rows?: [string, string?][][];
  caption?: ReactNode;
}) {
  return (
    <figure className="hl not-prose">
      {(rows ?? [steps!]).map((row, r) => (
        <div className="flow" key={r}>
          {row.map(([b, s], i) => (
            <div key={b} style={{ display: 'contents' }}>
              {i > 0 && <div className="a">→</div>}
              <div className="n">
                <b>{b}</b>
                {s && <small>{s}</small>}
              </div>
            </div>
          ))}
        </div>
      ))}
      <Cap>{caption}</Cap>
    </figure>
  );
}

const Chips = ({ items }: { items: ReactNode[] }) => (
  <div className="chips">
    {items.map((c, i) => (
      <span className="chip" key={i}>
        {c}
      </span>
    ))}
  </div>
);

/** The app, the two Exec implementations, and what runs on each machine. */
export function Architecture({ caption }: { caption?: ReactNode }) {
  return (
    <figure className="hl not-prose">
      <div className="arch">
        <div className="layer app">
          <h5>App · SwiftUI · macOS + iOS</h5>
          <Chips items={[<>HostStore × machines <small>call(), the event stream, terminal streams</small></>]} />
        </div>
        <div className="down">
          ↓ <code>Exec.run(argv)</code> → stdin / stdout
        </div>
        <div className="twocol">
          <div className="layer app">
            <h5>macOS · ProcessExec(prefix)</h5>
            <Chips items={[<>this Mac: <code>[]</code></>, <>remote: <code>[ssh -F /dev/null … -S ctl target --]</code></>]} />
          </div>
          <div className="layer app">
            <h5>iOS · CitadelExec</h5>
            <Chips items={['one SSH connection per machine', 'one exec channel per run']} />
          </div>
        </div>
        <div className="down">↓ on the machine</div>
        <div className="layer host">
          <h5>Machine · herdr + standard tools</h5>
          <Chips
            items={[
              <><code>herdr remote-api-bridge</code> → herdr.sock (JSON, 1 request each)</>,
              <><code>herdr terminal session control</code> → live frames for one pane</>,
              <><code>tail -c +N -F</code> → chat view</>,
              <><code>git</code>, <code>cat</code>, … (plugin exec) → plugin data</>,
            ]}
          />
        </div>
      </div>
      <Cap>{caption}</Cap>
    </figure>
  );
}

/** Who controls a terminal pane, and what moves control. */
export function Ownership() {
  return (
    <figure className="hl not-prose">
      <div className="own">
        <div className="st">
          <b>Mac controls</b>
          <br />
          <span>opens as control, types and resizes; iPhone and iPad open as observe, or use chat</span>
        </div>
        <div className="arrows">
          first key press, paste or tap in the card
          <br />
          on iPhone or iPad (<code>--takeover</code>) →
          <br />
          <br />← first key press, paste or click on the Mac, or Take back
        </div>
        <div className="st">
          <b>iPhone or iPad controls</b>
          <br />
          <span>the Mac watches: &quot;In use elsewhere · Take back&quot;</span>
        </div>
      </div>
    </figure>
  );
}
