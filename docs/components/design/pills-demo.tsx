'use client';
import { useEffect, useRef, useState } from 'react';
import { Ico, type Icon } from './panes';

type St = 'work' | 'blk' | 'done' | 'idle';
type Agent = { id: string; icon: Icon; name: string; ws: string; host: string; st: St };

const START: Agent[] = [
  { id: 'claude', icon: ['claude', '✳'], name: 'claude', ws: 'api-server', host: 'This Mac', st: 'work' },
  { id: 'pi', icon: ['pi', 'π'], name: 'pi', ws: 'docs', host: 'This Mac', st: 'work' },
  { id: 'codex', icon: ['codex', '>_'], name: 'codex', ws: 'infra', host: 'devbox', st: 'work' },
  { id: 'opencode', icon: ['sh', '◇'], name: 'opencode', ws: 'ml-pipeline', host: 'devbox', st: 'idle' },
];
const word: Record<St, string> = { work: 'working', blk: 'needs you', done: 'finished', idle: 'idle' };
const glyph: Record<St, string> = { work: '', blk: '▲', done: '✓', idle: '' };
const status: Record<St, string> = {
  work: '◔ Working',
  blk: '▲ Needs you: waiting for an answer',
  done: '✓ Finished just now',
  idle: 'Idle',
};

const Dot = ({ st, title }: { st: St; title?: string }) => (
  <span className={`dot ${st}`} title={title}>
    {glyph[st]}
  </span>
);

const PROMPT = `? Allow command? terraform apply
  1. Yes
  2. Yes, and don't ask again
  3. No, tell codex what to do`;

/** The body of one agent's pill card. Used live in the demo and on its own. */
export function PillCardBody({
  a,
  onKey,
  onClose,
  msg,
}: {
  a: Agent;
  onKey?: (k: string) => void;
  onClose?: () => void;
  msg?: string | null;
}) {
  return (
    <>
      <div className="hd">
        <Ico icon={a.icon} />
        {a.name}{' '}
        <span className="where">
          · {a.ws} · {a.host}
        </span>
        <span className="x" onClick={onClose}>
          ✕
        </span>
      </div>
      <div className="sub">{status[a.st]}</div>
      {a.st === 'blk' ? (
        <>
          <div className="scr">{PROMPT}</div>
          <div className="opts">
            {['1', '2', '3', '↑', '↓', 'Enter', 'Esc'].map((k) => (
              <button key={k} onClick={() => onKey?.(k)}>
                {k}
              </button>
            ))}
          </div>
        </>
      ) : (
        <div className="scr prose-ish">
          <span style={{ color: '#8fd3ff' }}>you:</span>{' '}
          {a.id === 'pi' ? 'write the API guide' : 'fix the failing auth tests'}
          <br />
          <span style={{ color: '#9fe6b2' }}>{a.name}:</span>{' '}
          {a.st === 'done'
            ? 'Wrote docs/api.md (214 lines). Covered auth, pagination and errors.'
            : 'Running the test suite… 40 passing, 2 failing.'}
        </div>
      )}
      <div className="reply">Reply to {a.name}…</div>
      <div className="acts">
        <span>Mark seen</span>
        <span>Open in app ⌘↩</span>
      </div>
      {msg && <div className="undo">{msg}</div>}
    </>
  );
}

/** A pill card on its own, e.g. <PillCard state="blk" />. */
export function PillCard({ state = 'blk' }: { state?: St }) {
  const a = state === 'done' ? { ...START[1], st: state } : { ...START[2], st: state };
  return (
    <div className="hl not-prose">
      <div className="pcard static">
        <PillCardBody a={a} />
      </div>
    </div>
  );
}

/** The desk demo: the edge pill, its list, and peeking cards. */
export function PillsDemo() {
  const [agents, setAgents] = useState(START);
  const [list, setList] = useState(false);
  const [cardId, setCardId] = useState<string | null>(null);
  const [cardOpen, setCardOpen] = useState(false); // cardId stays set so the card can animate out
  const [msg, setMsg] = useState<string | null>(null);
  const armed = useRef(true), hover = useRef(false);
  const peekT = useRef<ReturnType<typeof setTimeout>>(undefined);
  useEffect(() => () => clearTimeout(peekT.current), []);

  const card = agents.find((a) => a.id === cardId);
  const setSt = (id: string, st: St) => setAgents((as) => as.map((a) => (a.id === id ? { ...a, st } : a)));
  const close = () => {
    setCardOpen(false);
    clearTimeout(peekT.current);
  };
  const open = (id: string, peek: boolean) => {
    setCardId(id);
    setCardOpen(true);
    setMsg(null);
    setList(false);
    armed.current = !peek; // a peek's first click only activates it
    clearTimeout(peekT.current);
    if (peek) peekT.current = setTimeout(() => !hover.current && close(), 8000);
  };
  const send = (k: string) => {
    if (!card || !cardOpen) return;
    if (!armed.current) {
      armed.current = true;
      return setMsg('Card active · click again to send');
    }
    if (card.st !== 'blk') return setMsg(`Not sent: ${card.name} is no longer blocked`);
    setMsg(`✓ Sent “${k}” to ${card.name}`);
    clearTimeout(peekT.current);
    setSt(card.id, 'work');
    setTimeout(close, 1200);
  };
  const simulate = (id: string, st: St) => {
    setSt(id, st);
    open(id, true);
  };

  const vis = agents.filter((a) => a.st !== 'idle');
  const hosts = [...new Set(agents.map((a) => a.host))];

  return (
    <figure className="hl not-prose">
      <div
        className={`desk${list ? ' listopen' : ''}`}
        onClick={(e) => !(e.target as HTMLElement).closest('.plist,.notch,.pcard,.ctrls') && setList(false)}
      >
        <div className="menubar"> Ghostty File Edit View</div>
        <div className="otherapp">
          <div className="tl">
            <i />
            <i />
            <i />
          </div>
          {'~/notes $ vim todo.md\n- review PR #412\n- ship pricing page\n'}
          <span style={{ color: '#888' }}>-- INSERT --</span>
          {'\n(you are working in another app)'}
        </div>
        <button className="notch" onClick={() => setList(true)} aria-label="Agents">
          {(vis.length ? vis : [{ id: 'none', st: 'idle' as St, name: '' }]).map((a) => (
            <Dot key={a.id} st={a.st} title={`${a.name} ${word[a.st]}`} />
          ))}
        </button>
        <div className="plist">
          {hosts.map((h) => (
            <div key={h}>
              <div className="grp">{h}</div>
              {agents
                .filter((a) => a.host === h)
                .map((a) => (
                  <div className="row" key={a.id} onClick={() => open(a.id, false)}>
                    <Dot st={a.st} />
                    <Ico icon={a.icon} />
                    <span>
                      {a.name}
                      <span className="ws2">{a.ws}</span>
                    </span>
                    <span className="w">{word[a.st]}</span>
                  </div>
                ))}
            </div>
          ))}
        </div>
        <div
          className={`pcard${cardOpen ? ' open' : ''}`}
          onMouseEnter={() => {
            hover.current = true;
            clearTimeout(peekT.current);
          }}
          onMouseLeave={() => (hover.current = false)}
        >
          {card && <PillCardBody a={card} onKey={send} onClose={close} msg={msg} />}
        </div>
        <div className="ctrls">
          <button onClick={() => simulate('codex', 'blk')}>Simulate: codex needs you</button>
          <button onClick={() => simulate('pi', 'done')}>Simulate: pi finished</button>
          <button
            onClick={() => {
              setAgents(START);
              close();
              setList(false);
            }}
          >
            Reset
          </button>
        </div>
      </div>
      <figcaption className="cap">
        <b>Try:</b>{" "}click the pill on the right edge to open the list, then a row to open that agent&apos;s card.
        Press a simulate button: the card peeks out without taking focus and shrinks back after 8 s if the
        pointer never enters it. On a peeked card the first click only activates it; the next click sends the
        key.
      </figcaption>
    </figure>
  );
}
