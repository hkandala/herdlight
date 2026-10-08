'use client';
import { type ReactNode, useCallback, useEffect, useRef, useState } from 'react';
import {
  AgentChat,
  DiffBody,
  HistBody,
  Ico,
  Pane,
  Seg,
  T,
  Term,
  Web,
  type Icon,
} from './panes';

type Leaf = {
  kind: 'term' | 'web' | 'chat' | 'diff' | 'hist';
  title: string;
  icon: Icon;
  body?: string;
  w?: number;
  dim?: boolean;
};
type Split = { dir: 'row' | 'col'; kids: Node[]; w?: number };
type Node = Leaf | Split;
type St = 'w' | 'b' | 'd'; // ◔ working · ▲ needs you · ✓ finished
type Tab = { label: string; icon: Icon; badge?: St; layout: Node };
type Agent = [Icon, string, string, St | ''];
type Host = { name: string; ws: { n: string; sel?: boolean; ag?: Agent[] }[]; tabs: Tab[] };

const GLYPH: Record<St, string> = { w: '◔', b: '▲', d: '✓' };
const p = (kind: Leaf['kind'], title: string, icon: Icon, o: Partial<Leaf> = {}): Leaf => ({ kind, title, icon, ...o });
const CL: Icon = ['claude', '✳'], SH: Icon = ['sh', '>_'], PI: Icon = ['pi', 'π'], WEB: Icon = ['web', '◍'];
const CX: Icon = ['codex', '>_'], DF: Icon = ['codex', '±'], GH: Icon = ['codex', '⑂'];

// One pane lives in one tab. The sidebar, tab glyphs, status area and the pills demo tell the same story:
// claude works, pi finished (not seen), codex needs you.
const HOSTS: Host[] = [
  {
    name: 'This Mac',
    ws: [
      {
        n: 'api-server',
        sel: true,
        ag: [[CL, 'claude', '◔ working', 'w'], [PI, 'pi', '✓ finished', 'd'], [WEB, 'Dashboard', '', ''], [DF, 'Diff', '', ''], [GH, 'Git history', '', ''], [SH, 'Terminals (4)', '', '']],
      },
      { n: 'web-app' },
      { n: 'infra' },
    ],
    tabs: [
      { label: 'fix-auth', icon: CL, badge: 'w', layout: { dir: 'row', kids: [p('term', 'claude · fix-auth', CL, { body: T.claude, w: 1.4 }), { dir: 'col', kids: [p('term', 'zsh', SH, { body: T.zsh, dim: true }), p('term', 'logs', SH, { body: T.logs, dim: true })] }] } },
      { label: 'docs', icon: PI, badge: 'd', layout: p('chat', 'pi · docs', PI) },
      { label: 'preview', icon: WEB, layout: p('web', 'Dashboard · localhost:3000', WEB) },
      { label: 'diff', icon: DF, layout: { dir: 'row', kids: [p('diff', 'Diff · base=main', DF, { w: 1.5 }), p('term', 'npm test', SH, { body: T.zsh, dim: true })] } },
      { label: 'history', icon: GH, layout: p('hist', 'Git history · main', GH) },
    ],
  },
  {
    name: 'devbox',
    ws: [{ n: 'infra', sel: true, ag: [[CX, 'codex', '▲ needs you', 'b'], [WEB, 'staging.internal', '', ''], [SH, 'Terminals (1)', '', '']] }, { n: 'ml-pipeline' }],
    tabs: [
      { label: 'terraform', icon: CX, badge: 'b', layout: { dir: 'row', kids: [p('term', 'codex · migrate', CX, { body: T.codex, w: 1.3 }), p('term', 'zsh', SH, { body: T.zsh, dim: true })] } },
      { label: 'staging', icon: WEB, layout: p('web', 'staging.internal', WEB) },
    ],
  },
  {
    name: 'gpu-01',
    ws: [{ n: 'training', sel: true, ag: [[CL, 'claude', 'idle', ''], [SH, 'Terminals (2)', '', '']] }],
    tabs: [
      { label: 'train', icon: SH, layout: { dir: 'col', kids: [p('term', 'train.py', SH, { body: T.train }), p('term', 'nvidia-smi', SH, { body: T.gpu, dim: true })] } },
      { label: 'eval', icon: CL, layout: p('term', 'claude · eval', CL, { body: T.claude }) },
    ],
  },
];

function Ctl({ n }: { n: Leaf }) {
  const plugin = n.kind === 'diff' || n.kind === 'hist';
  return (
    <>
      {plugin ? (
        <>
          <span className="chip-plugin">plugin</span> <Seg a="plugin" b="term" on={0} />
        </>
      ) : n.kind === 'web' ? (
        '‹ ↻ ↗'
      ) : (
        <Seg a="chat" b="term" on={n.kind === 'chat' ? 0 : 1} />
      )}{' '}
      ⤢ ✕
    </>
  );
}

function RenderNode({ n }: { n: Node }) {
  if ('dir' in n)
    return (
      <div className="col" style={{ flex: n.w ?? 1, flexDirection: n.dir === 'row' ? 'row' : 'column' }}>
        {n.kids.map((k, i) => (
          <RenderNode key={i} n={k} />
        ))}
      </div>
    );
  return (
    <Pane icon={n.icon} title={n.title} ctl={<Ctl n={n} />} dim={n.dim} style={{ flex: n.w ?? 1 }}>
      {n.kind === 'term' && <Term body={n.body!} />}
      {n.kind === 'web' && <Web title={n.title.includes('staging') ? 'Staging' : 'Dashboard'} />}
      {n.kind === 'chat' && <AgentChat agent={n.icon[0] === 'pi' ? 'pi' : 'claude'} />}
      {n.kind === 'diff' && <DiffBody />}
      {n.kind === 'hist' && <HistBody />}
    </Pane>
  );
}

const tryIt = (
  <>
    <b>Try:</b>{" "}scroll the main area sideways (trackpad or shift+wheel): every tab whose page is visible lights up
    and the glass marker follows. Scroll the sidebar sideways, or click the dots, to switch machines. <b>⧉ 1</b>{' '}
    shows a floating scratch terminal: drag its header, resize from its corner. The <b>diff</b> and{' '}
    <b>history</b> tabs are plugin panes.
  </>
);

/** The interactive macOS window: machine pages, lit tabs, the strip and a floating card. */
export function MacWindow({ floating = false, caption = tryIt }: { floating?: boolean; caption?: ReactNode }) {
  const [host, setHost] = useState(0);
  const [float, setFloat] = useState(floating);
  const pager = useRef<HTMLDivElement>(null);
  const strip = useRef<HTMLDivElement>(null);
  const tabs = useRef<HTMLDivElement>(null);
  const marker = useRef<HTMLDivElement>(null);
  const fcard = useRef<HTMLDivElement>(null);
  const h = HOSTS[host];

  // Light every tab whose page is visible; the marker interpolates between tabs.
  const update = useCallback(() => {
    const s = strip.current, m = marker.current;
    if (!s || !m || !tabs.current) return;
    const els = [...tabs.current.querySelectorAll<HTMLElement>('.tab')];
    if (!els.length) return;
    const w = s.clientWidth || 1, x = s.scrollLeft, pos = x / w, a = Math.floor(pos);
    els.forEach((t, i) => t.classList.toggle('lit', i >= a && (i === a || x + w - i * w > 2)));
    const i0 = Math.min(a, els.length - 1), i1 = Math.min(a + 1, els.length - 1), f = pos - a;
    m.style.left = els[i0].offsetLeft + (els[i1].offsetLeft - els[i0].offsetLeft) * f + 'px';
    m.style.width = els[i0].offsetWidth + (els[i1].offsetWidth - els[i0].offsetWidth) * f + 'px';
  }, []);

  useEffect(() => {
    if (strip.current) strip.current.scrollLeft = 0;
    update();
    addEventListener('resize', update);
    return () => removeEventListener('resize', update);
  }, [host, update]);

  // Switch machine once the sidebar pager settles.
  useEffect(() => {
    const el = pager.current;
    if (!el) return;
    let t: ReturnType<typeof setTimeout>;
    const on = () => {
      clearTimeout(t);
      t = setTimeout(() => setHost(Math.round(el.scrollLeft / el.clientWidth)), 120);
    };
    el.addEventListener('scroll', on, { passive: true });
    return () => el.removeEventListener('scroll', on);
  }, []);

  // Drag the floating card by its header; CSS `resize` handles the corner.
  const startDrag = (e: React.PointerEvent) => {
    const fc = fcard.current!;
    if ((e.target as HTMLElement).closest('.x')) return;
    const r = fc.getBoundingClientRect(), par = fc.parentElement!.getBoundingClientRect();
    const dx = e.clientX - r.left, dy = e.clientY - r.top;
    e.preventDefault();
    const move = (ev: PointerEvent) => {
      fc.style.left = Math.max(0, Math.min(ev.clientX - par.left - dx, par.width - 60)) + 'px';
      fc.style.top = Math.max(40, Math.min(ev.clientY - par.top - dy, par.height - 40)) + 'px';
    };
    const up = () => {
      removeEventListener('pointermove', move);
      removeEventListener('pointerup', up);
    };
    addEventListener('pointermove', move);
    addEventListener('pointerup', up);
  };

  return (
    <figure className="hl not-prose">
      <div className="win">
        <aside className="side">
          <div className="lights">
            <i />
            <i />
            <i />
          </div>
          <div className="hostname">{h.name}</div>
          <div className="hostpager" ref={pager}>
            {HOSTS.map((hh) => (
              <div className="hostpage" key={hh.name}>
                {hh.ws.map((w) => (
                  <div key={w.n}>
                    <div className={`ws${w.sel ? ' sel' : ''}`}>
                      <span>
                        {w.ag ? '▾' : '▸'} {w.n}
                      </span>
                    </div>
                    {w.ag?.map(([ic, name, st, c]) => (
                      <div className="ag" key={name}>
                        <Ico icon={ic} />
                        {name}
                        <span className={`st ${c}`}>{st}</span>
                      </div>
                    ))}
                  </div>
                ))}
              </div>
            ))}
          </div>
          <div className="dots">
            {HOSTS.map((hh, i) => (
              <b
                key={hh.name}
                className={i === host ? 'on' : ''}
                title={hh.name}
                onClick={() => pager.current?.scrollTo({ left: i * pager.current.clientWidth, behavior: 'smooth' })}
              />
            ))}
            <span className="plus" title="Add machine">
              +
            </span>
          </div>
          <div className="status">
            <div className="sum">1 working · 1 needs you · 1 finished</div>
            <div><span className="st b">▲</span> codex needs you · devbox/infra</div>
            <div><span className="st d">✓</span> pi finished · This Mac/api-server</div>
          </div>
        </aside>
        <div className="main">
          <div className="tabbar">
            <div className="tabs" ref={tabs}>
              <div className="marker" ref={marker} />
              {h.tabs.map((t, i) => (
                <div
                  key={h.name + t.label}
                  className="tab"
                  onClick={() => strip.current?.scrollTo({ left: i * strip.current.clientWidth, behavior: 'smooth' })}
                >
                  <Ico icon={t.icon} />
                  <span>{t.label}</span>
                  {t.badge && <span className={`badge ${t.badge}`}>{GLYPH[t.badge]}</span>}
                  <span className="x">×</span>
                </div>
              ))}
            </div>
            <span className="add">+</span>
            <span
              className={`floatbtn${float ? ' on' : ''}`}
              title="Show or hide floating panes (⌥⌘F)"
              onClick={() => setFloat(!float)}
            >
              ⧉ 1
            </span>
          </div>
          <div className="strip" ref={strip} onScroll={update}>
            {h.tabs.map((t) => (
              <div className="tpage" key={h.name + t.label}>
                <RenderNode n={'dir' in t.layout ? t.layout : { ...t.layout, w: 1 }} />
              </div>
            ))}
          </div>
          <div className={`fcard${float ? ' show' : ''}`} ref={fcard}>
            <div className="ph fhead" onPointerDown={startDrag}>
              <Ico icon={['sh', '>_']} /> scratch
              <span className="ctl">
                <Seg a="chat" b="term" on={1} /> <span title="Dock">⤓</span> ⤢{' '}
                <span className="x" onClick={() => setFloat(false)}>
                  ✕
                </span>
              </span>
            </div>
            <Term body={T.scratch} />
          </div>
        </div>
      </div>
      {caption && <figcaption className="cap">{caption}</figcaption>}
    </figure>
  );
}
