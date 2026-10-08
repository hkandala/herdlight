import Reconciler from "react-reconciler";
import { DefaultEventPriority, DiscreteEventPriority } from "react-reconciler/constants";
let prio = DefaultEventPriority, nextId = 1;
const handlers = new Map(); // id -> props (functions stay in JS)
function inst(type, props) { const { children, ...p } = props; return { id: nextId++, type, props: p, children: [] }; }
function json(n) {
  if (n.text !== undefined) return n.text;
  const props = {};
  for (const [k, v] of Object.entries(n.props)) props[k] = typeof v === "function" ? { $fn: `${n.id}.${k}` } : v;
  handlers.set(n.id, n.props);
  return { id: n.id, type: n.type, props, children: n.children.map(json) };
}
const ins = (arr, c, before) => { const i = arr.indexOf(c); if (i >= 0) arr.splice(i, 1); arr.splice(before ? arr.indexOf(before) : arr.length, 0, c); };
const rm = (arr, c) => arr.splice(arr.indexOf(c), 1);
const host = {
  supportsMutation: true, supportsPersistence: false, supportsHydration: false, isPrimaryRenderer: true,
  noTimeout: -1, scheduleTimeout: setTimeout, cancelTimeout: clearTimeout,
  getRootHostContext: () => ({}), getChildHostContext: (c) => c, getPublicInstance: (i) => i,
  prepareForCommit: () => null, resetAfterCommit: (root) => root.onCommit(),
  createInstance: (type, props) => inst(type, props),
  createTextInstance: (text) => ({ id: nextId++, text }),
  appendInitialChild: (p, c) => p.children.push(c), finalizeInitialChildren: () => false,
  shouldSetTextContent: () => false,
  appendChild: (p, c) => ins(p.children, c), appendChildToContainer: (r, c) => ins(r.children, c),
  insertBefore: (p, c, b) => ins(p.children, c, b), insertInContainerBefore: (r, c, b) => ins(r.children, c, b),
  removeChild: (p, c) => rm(p.children, c), removeChildFromContainer: (r, c) => rm(r.children, c),
  commitUpdate: (i, type, oldP, newP) => { const { children, ...p } = newP; i.props = p; },
  commitTextUpdate: (t, o, n) => { t.text = n; }, clearContainer: (r) => { r.children = []; },
  detachDeletedInstance: (i) => handlers.delete(i.id),
  setCurrentUpdatePriority: (p) => { prio = p; }, getCurrentUpdatePriority: () => prio,
  resolveUpdatePriority: () => prio || DefaultEventPriority,
  maySuspendCommit: () => false, preloadInstance: () => true, startSuspendingCommit() {}, suspendInstance() {},
  waitForCommitToBeReady: () => null, NotPendingTransition: null, HostTransitionContext: { $$typeof: Symbol.for("react.context"), _currentValue: null },
  resetFormInstance() {}, requestPostPaintCallback() {}, shouldAttemptEagerTransition: () => false,
  trackSchedulerEvent() {}, resolveEventType: () => null, resolveEventTimeStamp: () => -1.1,
  prepareScopeUpdate() {}, getInstanceFromScope: () => null, hideInstance() {}, unhideInstance() {}, hideTextInstance() {}, unhideTextInstance() {},
};
const R = Reconciler(host);
export function render(el, onTree) {
  const root = { children: [], onCommit: () => onTree(root.children.map(json)) };
  const c = R.createContainer(root, 1, null, false, null, "", console.error, console.error, console.error, () => {}, null);
  R.updateContainer(el, c, null, null);
}
export function dispatch(fn, ...args) { const [id, k] = fn.split("."); prio = DiscreteEventPriority; R.flushSyncWork?.(); handlers.get(+id)[k](...args); prio = DefaultEventPriority; }
