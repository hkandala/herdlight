'use client';
import { useRef, useState } from 'react';

const clamp = (v: number) => Math.min(0.9, Math.max(0.1, v));

/** herdr's flat layout, the rebuilt tree, and a canvas whose dividers drag. */
export function SplitDemo() {
  const [r, setR] = useState<[number, number]>([0.55, 0.5]);
  const [drag, setDrag] = useState<0 | 1 | null>(null);
  const [call, setCall] = useState('drag a divider…');
  const canvas = useRef<HTMLDivElement>(null);
  const [r0, r1] = r;

  const start = (s: 0 | 1) => (e: React.PointerEvent) => {
    e.preventDefault();
    setDrag(s);
    setCall('dragging… (view only, nothing sent yet)');
    let last = r;
    const move = (ev: PointerEvent) => {
      const b = canvas.current!.getBoundingClientRect();
      last = s === 0 ? [clamp((ev.clientX - b.left) / b.width), last[1]] : [last[0], clamp((ev.clientY - b.top) / b.height)];
      setR(last);
    };
    const up = () => {
      removeEventListener('pointermove', move);
      removeEventListener('pointerup', up);
      setDrag(null);
      setCall(
        `layout.set_split_ratio {\n  "tab_id":"w1:t1",\n  "path":${s === 0 ? '[]' : '[true]'},\n  "ratio":${last[s].toFixed(2)}\n}`,
      );
    };
    addEventListener('pointermove', move);
    addEventListener('pointerup', up);
  };

  const pc = (v: number) => `${v * 100}%`;
  const f0 = r0.toFixed(2), f1 = r1.toFixed(2);

  return (
    <figure className="hl not-prose">
      <div className="splitdemo">
        <div>
          <div className="sd-label">1 · herdr sends a flat list</div>
          <pre className="sd-code">{`"panes":[ p1, p3, p2 ],  // depth-first
"splits":[
 {"id":"split_0_root","direction":"right",
  "ratio":${f0}},
 {"id":"split_1_1","direction":"down",
  "ratio":${f1}}]`}</pre>
        </div>
        <div>
          <div className="sd-label">2 · the app rebuilds the tree</div>
          <pre className="sd-code">{`split right ${f0}
├─ p1
└─ split down ${f1}
   ├─ p3
   └─ p2`}</pre>
          <div className="sd-label" style={{ marginTop: 8 }}>
            The id encodes the path: <code>root</code>, then <code>0</code> = first child, <code>1</code> = second.
          </div>
        </div>
        <div className="wide">
          <div className="sd-label">3 · draw it, drag a divider</div>
          <div className="splitdemo">
            <div className="sd-canvas" ref={canvas}>
              <div className="sd-pane" style={{ left: 6, top: 6, width: `calc(${pc(r0)} - 9px)`, height: 'calc(100% - 12px)' }}>
                p1
              </div>
              <div
                className="sd-pane"
                style={{ left: `calc(${pc(r0)} + 3px)`, top: 6, width: `calc(${pc(1 - r0)} - 9px)`, height: `calc(${pc(r1)} - 9px)` }}
              >
                p3
              </div>
              <div
                className="sd-pane"
                style={{
                  left: `calc(${pc(r0)} + 3px)`,
                  top: `calc(${pc(r1)} + 3px)`,
                  width: `calc(${pc(1 - r0)} - 9px)`,
                  height: `calc(${pc(1 - r1)} - 9px)`,
                }}
              >
                p2
              </div>
              <div
                className={`sd-div v${drag === 0 ? ' drag' : ''}`}
                style={{ left: `calc(${pc(r0)} - 4px)`, top: 0, width: 8, height: '100%' }}
                onPointerDown={start(0)}
              />
              <div
                className={`sd-div h${drag === 1 ? ' drag' : ''}`}
                style={{ left: pc(r0), top: `calc(${pc(r1)} - 4px)`, width: pc(1 - r0), height: 8 }}
                onPointerDown={start(1)}
              />
            </div>
            <pre className="sd-code">{call}</pre>
          </div>
        </div>
      </div>
      <figcaption className="cap">
        <b>Try:</b>{" "}drag a divider. The view moves at once; the ratio goes to herdr only on release.
      </figcaption>
    </figure>
  );
}
