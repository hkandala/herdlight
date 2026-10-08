// Static UI mocks: chat card, iPhone, pane picker, add-machine sheet, drop zones.
import { Ico, Pane, Seg, Term, type Icon } from './panes';

const Cap = ({ children }: { children?: React.ReactNode }) =>
  children ? <figcaption className="cap">{children}</figcaption> : null;

/** An agent card in chat view, with the blocked panel and the reply box. */
export function ChatCard({ caption }: { caption?: React.ReactNode }) {
  return (
    <figure className="hl not-prose">
      <Pane
        icon={['claude', '✳']}
        title="claude · fix-auth"
        ctl={
          <>
            <Seg a="chat" b="term" on={0} /> ⤢ ✕
          </>
        }
        style={{ height: 320, maxWidth: 560 }}
      >
        <div className="chat">
          <div className="msg u">
            <div className="who">you</div>
            <span className="txt">run the tests and fix what fails</span>
          </div>
          <div className="msg">
            <div className="who">claude</div>
            Running the test suite.
          </div>
          <div className="tool">▸ Bash npm test</div>
          <div className="msg">2 tests fail in auth.spec.ts. Fixing…</div>
          <div className="blocked">
            ▲ claude needs you: Allow Bash(rm -rf dist)? 1 Yes 2 No
            <div className="keys">
              {['↑', '↓', 'Enter', 'Esc', '1', '2', '3'].map((k) => (
                <span key={k}>{k}</span>
              ))}{' '}
              <span>Open terminal</span>
            </div>
          </div>
          <div className="composer">
            message… <span>↑</span>
          </div>
        </div>
      </Pane>
      <Cap>{caption}</Cap>
    </figure>
  );
}

const Chips = ({ on }: { on: number }) => (
  <div className="chipsrow">
    {['✳ claude', '>_ zsh', '|', 'π docs'].map((c, i) =>
      c === '|' ? (
        <span key={c} className="sep">
          |
        </span>
      ) : (
        <span key={c} className={i === on ? 'on' : ''}>
          {c}
        </span>
      ),
    )}
  </div>
);

/** Two iPhone screens: an agent in chat and a terminal with the key bar. */
export function Phones({ caption }: { caption?: React.ReactNode }) {
  return (
    <figure className="hl not-prose">
      <div className="phones">
        <div className="phone">
          <div className="nb">‹ devbox · api-server</div>
          <Chips on={0} />
          <Pane icon={['claude', '✳']} title="claude" ctl={<Seg a="chat" b="term" on={0} />}>
            <div className="chat">
              <div className="msg u">
                <div className="who">you</div>
                <span className="txt">run the tests</span>
              </div>
              <div className="msg">
                <div className="who">claude</div>
                42 passing ✓
              </div>
              <div className="tool">▸ Bash npm test</div>
              <div className="composer">
                message… <span>↑</span>
              </div>
            </div>
          </Pane>
        </div>
        <div className="phone">
          <div className="nb">‹ devbox · api-server</div>
          <Chips on={1} />
          <Pane icon={['sh', '>_']} title="zsh" ctl={<Seg a="chat" b="term" on={1} />}>
            <Term body={`<span class="g">$</span> npm test\n<span class="g">✓</span> 42 passing\n<span class="g">$</span> ▌`} />
            <div className="keybar">esc ctrl tab ↑ ↓ ← →</div>
          </Pane>
        </div>
      </div>
      <Cap>{caption}</Cap>
    </figure>
  );
}

const PICK: [Icon, string, string][] = [
  [['sh', '>_'], 'Terminal', 'core'],
  [['claude', '✳'], 'Agent', 'claude · codex · pi ▸'],
  [['web', '◍'], 'Web page', 'core'],
  [['codex', '⑂'], 'Git history', 'core plugin'],
  [['codex', '±'], 'Diff', 'core plugin'],
  [['pi', '¶'], 'Markdown', 'core plugin'],
  [['sh', '▦'], 'Kanban', 'installed'],
];

/** The new-pane picker. */
export function PanePicker({ caption }: { caption?: React.ReactNode }) {
  return (
    <figure className="hl not-prose">
      <div className="picker">
        <div className="h">New pane on devbox</div>
        {PICK.map(([ic, name, note], i) => (
          <div key={name}>
            {i === 6 && <hr />}
            <div className="it">
              <Ico icon={ic} />
              {name} <small>{note}</small>
            </div>
          </div>
        ))}
      </div>
      <Cap>{caption}</Cap>
    </figure>
  );
}

/** The add-machine sheet (the public key row is iOS only). */
export function AddMachineSheet({ caption }: { caption?: React.ReactNode }) {
  return (
    <figure className="hl not-prose">
      <div className="sheet">
        <h4>Add machine</h4>
        <div className="f">
          <label>SSH target</label>
          <div className="in">devbox</div>
          <small>devbox, me@10.0.0.5, a Tailscale name</small>
        </div>
        <div className="f">
          <label>Session</label>
          <div className="in ph">default</div>
          <small>herdr session name (optional)</small>
        </div>
        <div className="f">
          <label>Label</label>
          <div className="in">Dev box</div>
        </div>
        <div className="f">
          <label>
            Public key<span className="ios">iOS</span>
          </label>
          <div className="key">
            <span>ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAI…</span>
            <span className="btn">Copy</span>
          </div>
          <small>copy into authorized_keys on the machine</small>
        </div>
        <div className="btns">
          <span className="btn">Cancel</span>
          <span className="btn pri">Add</span>
        </div>
      </div>
      <Cap>{caption}</Cap>
    </figure>
  );
}

/** Where a dragged card can land on another card. */
export function DropZones({ caption }: { caption?: React.ReactNode }) {
  return (
    <figure className="hl not-prose">
      <div className="drop">
        <div className="dz-card">
          <div className="dz l">split left</div>
          <div className="dz r">split right</div>
          <div className="dz t">split up</div>
          <div className="dz b">split down</div>
          <div className="dz c">swap</div>
        </div>
        <div className="dz-list">
          <div>
            <i className="c" /> centre, same tab: swap the two panes
          </div>
          <div>
            <i /> edge, another tab: split there
          </div>
          <div>
            <Ico icon={['sh', '>_']} /> a tab capsule: move into that tab
          </div>
          <div>
            <Ico icon={['codex', '▸']} /> sidebar workspace or empty space: new tab or workspace
          </div>
          <div>
            <Ico icon={['codex', '⧉']} /> the ⧉ button: float the pane
          </div>
        </div>
      </div>
      <Cap>{caption}</Cap>
    </figure>
  );
}
