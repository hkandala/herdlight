// Pane cards shared by the window, chat card and phone mocks.
import type { CSSProperties, ReactNode } from 'react';

export type IconKind = 'claude' | 'pi' | 'codex' | 'web' | 'sh';
export type Icon = [IconKind, string];

export const Ico = ({ icon: [k, t] }: { icon: Icon }) => <span className={`ico ${k}`}>{t}</span>;

/** Terminal text with color spans (trusted, static strings). */
export const Term = ({ body }: { body: string }) => (
  <div className="term" dangerouslySetInnerHTML={{ __html: body }} />
);

export const T = {
  claude: `<span class="b">✳ Claude Code</span>
<span class="d">────────────────────────────────</span>
<span class="m">&gt;</span> fix the failing auth tests

<span class="y">●</span> Reading src/auth.ts
<span class="y">●</span> Bash(npm test)
  <span class="g">✓</span> 40 passing  <span class="y">✗</span> 2 failing
<span class="y">●</span> Edit(src/auth.ts)
  <span class="g">+ if (!token) return null</span>
<span class="d">⠋ Working… (esc to interrupt)</span>`,
  zsh: `<span class="g">~/api</span> $ npm test
<span class="g">✓</span> 42 passing (1.2s)
<span class="g">~/api</span> $ ▌`,
  pi: `<span class="b">π pi</span>  <span class="d">docs · gpt</span>
<span class="m">&gt;</span> write the API guide
<span class="d">Wrote docs/api.md (214 lines)</span>
<span class="g">✓ done</span>`,
  logs: `<span class="d">12:01:03</span> GET /api/users 200 12ms
<span class="d">12:01:04</span> GET /api/health 200 1ms
<span class="d">12:01:07</span> POST /api/login <span class="y">401</span> 4ms
<span class="d">12:01:09</span> POST /api/login 200 9ms`,
  codex: `<span class="b">&gt;_ codex</span>
<span class="m">&gt;</span> migrate the terraform state
<span class="y">Allow command?</span> terraform apply
<span class="y">› 1. Yes</span>   2. No   3. Always`,
  gpu: `<span class="g">gpu-01</span> $ nvidia-smi
  GPU0  A100  <span class="y">78%</span>  61C  31GB/80GB
  GPU1  A100  <span class="y">81%</span>  63C  30GB/80GB
<span class="g">gpu-01</span> $ ▌`,
  train: `epoch 12/40  loss <span class="g">0.412</span>  acc 0.871
epoch 13/40  loss <span class="g">0.398</span>  acc 0.876
<span class="d">█████████████░░░░░░░░ 33%</span>`,
  scratch: `<span class="g">~/api</span> $ git log --oneline -3
a1b2c3d fix auth null token
9f8e7d6 add pricing page
5c4b3a2 bump deps
<span class="g">~/api</span> $ ▌`,
};

export const Seg = ({ a, b, on }: { a: string; b: string; on: 0 | 1 }) => (
  <span className="seg">
    <span className={on === 0 ? 'on' : ''}>{a}</span>
    <span className={on === 1 ? 'on' : ''}>{b}</span>
  </span>
);

export function Pane({
  icon,
  title,
  ctl,
  children,
  dim,
  style,
}: {
  icon: Icon;
  title: ReactNode;
  ctl: ReactNode;
  children: ReactNode;
  dim?: boolean;
  style?: CSSProperties;
}) {
  return (
    <div className={`pane${dim ? ' dimmed' : ''}`} style={style}>
      <div className="ph">
        <Ico icon={icon} /> {title}
        <span className="ctl">{ctl}</span>
      </div>
      {children}
    </div>
  );
}

export const Web = ({ title }: { title: string }) => (
  <div className="webv">
    <h5>{title}</h5>
    <div className="bar" style={{ width: '70%' }} />
    <div className="bar" style={{ width: '45%' }} />
    <div className="bar" style={{ width: '60%' }} />
    <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
      <div style={{ flex: 1, height: 60, background: '#e9eefb', borderRadius: 6 }} />
      <div style={{ flex: 1, height: 60, background: '#eaf6ee', borderRadius: 6 }} />
    </div>
  </div>
);

const CHATS = {
  claude: ['fix the failing auth tests', <>Two tests fail in <code>auth.spec.ts</code>. The token check runs before the null guard.</>, '▸ Bash npm test · ▸ Edit src/auth.ts', 'Fixed. 42 passing ✓'],
  pi: ['write the API guide', <>Reading <code>src/routes/</code> to list the endpoints.</>, '▸ read src/routes/users.ts · ▸ write docs/api.md', 'Wrote docs/api.md (214 lines). Covered auth, pagination and errors.'],
} as const;

export const AgentChat = ({ agent = 'claude' }: { agent?: keyof typeof CHATS }) => {
  const [ask, first, tools, last] = CHATS[agent];
  return (
    <div className="chat">
      <div className="msg u">
        <div className="who">you</div>
        <span className="txt">{ask}</span>
      </div>
      <div className="msg">
        <div className="who">{agent}</div>
        {first}
      </div>
      <div className="tool">{tools}</div>
      <div className="msg">
        <div className="who">{agent}</div>
        {last}
      </div>
      <div className="composer">message…</div>
    </div>
  );
};

export const DiffBody = () => (
  <div className="diff">
    <div className="h">src/auth.ts +3 −1</div>
    <div>{'  export function check(token) {'}</div>
    <div className="r">{'-   return verify(token)'}</div>
    <div className="a">{'+   if (!token) return null'}</div>
    <div className="a">{'+   return verify(token)'}</div>
    <div>{'  }'}</div>
    <div className="h">src/auth.spec.ts +6</div>
    <div className="a">{'+ it("returns null without a token", () => {'}</div>
    <div className="a">{'+   expect(check(undefined)).toBeNull()'}</div>
    <div className="a">{'+ })'}</div>
  </div>
);

const commits: [string, string][] = [
  ['fix auth null token', 'a1b2c3d · 2h ago · hk'],
  ['add pricing page', '9f8e7d6 · 5h ago · hk'],
  ['bump deps', '5c4b3a2 · 1d ago · bot'],
  ['refactor session store', '4d3c2b1 · 2d ago · hk'],
  ['initial api', '0a9b8c7 · 9d ago · hk'],
];

export const HistBody = () => (
  <div className="hist">
    <div className="lst">
      {commits.map(([t, s], i) => (
        <div key={s} className={`row${i === 0 ? ' sel' : ''}`}>
          {t}
          <small>{s}</small>
        </div>
      ))}
    </div>
    <div className="det">
      <b>fix auth null token</b>
      <div className="meta">a1b2c3d · hk · 2 hours ago · 2 files</div>
      <div className="diff" style={{ padding: 0 }}>
        <div className="h">src/auth.ts</div>
        <div className="r">{'-   return verify(token)'}</div>
        <div className="a">{'+   if (!token) return null'}</div>
        <div className="a">{'+   return verify(token)'}</div>
      </div>
    </div>
  </div>
);
