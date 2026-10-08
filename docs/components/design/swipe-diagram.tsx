'use client';
import { useState } from 'react';

const MACHINES = ['This Mac', 'devbox', 'gpu-01'];
const TABS = ['api', 'fix-auth', 'docs', 'preview'];
const TINT = ['#1d2433', '#2a2119', '#182a1f', '#2a1a2a'];

/** Two sliders: machine pages in the sidebar, tab pages in the strip with lit tabs. */
export function SwipeDiagram() {
  const [m, setM] = useState(0);
  const [t, setT] = useState(1.4);
  const a = Math.floor(t);
  const lit = (i: number) => i === a || (i === a + 1 && t - a > 0.01);
  return (
    <figure className="hl not-prose">
      <div className="swipe">
        <div className="panel">
          <div className="t">Sidebar · machine pages</div>
          <div className="vp">
            <div className="track" style={{ transform: `translateX(${-m * 100}%)` }}>
              {MACHINES.map((n, i) => (
                <div key={n} className="pg" style={{ background: TINT[i] }}>
                  {n}
                </div>
              ))}
            </div>
          </div>
          <div className="dots">
            {MACHINES.map((n, i) => (
              <b key={n} className={Math.round(m) === i ? 'on' : ''} onClick={() => setM(i)} />
            ))}
          </div>
          <input type="range" min={0} max={2} step={0.01} value={m} onChange={(e) => setM(+e.target.value)} aria-label="Swipe machines" />
          <div className="note">Changes the machine; the strip shows that machine&apos;s workspace.</div>
        </div>
        <div className="panel">
          <div className="t">Strip · tabs of the selected workspace</div>
          <div className="caps">
            <div className="marker" style={{ left: `${(t / TABS.length) * 100}%`, width: `${100 / TABS.length}%` }} />
            {TABS.map((n, i) => (
              <span key={n} className={lit(i) ? 'lit' : ''}>
                {n}
              </span>
            ))}
          </div>
          <div className="vp">
            <div className="track" style={{ transform: `translateX(${-t * 100}%)` }}>
              {TABS.map((n, i) => (
                <div key={n} className="pg" style={{ background: TINT[i] }}>
                  tab {i + 1} · {n}
                </div>
              ))}
            </div>
          </div>
          <input type="range" min={0} max={3} step={0.01} value={t} onChange={(e) => setT(+e.target.value)} aria-label="Swipe tabs" />
          <div className="note">While you swipe, every tab whose page is visible is lit and the glass marker follows. When the scroll stops, that tab is selected.</div>
        </div>
      </div>
      <figcaption className="cap">
        <b>Try:</b>{" "}drag the sliders; they stand in for a two-finger swipe.
      </figcaption>
    </figure>
  );
}
