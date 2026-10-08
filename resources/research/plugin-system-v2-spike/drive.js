const host = { commit: (n, bytes, ms) => print(`commit ${n}: ${bytes} bytes JSON, +${ms} ms since start`) };
let t = Date.now(); __start(host); __drain(); print("initial render+drain ms", Date.now() - t);
const tree = JSON.parse(__last()); const fn = tree[0].children[42].props.onSelect.$fn;
t = Date.now(); __dispatch(fn); __drain(); print("select-row update ms", Date.now() - t);
t = Date.now(); for (let i = 0; i < 20; i++) { __dispatch(JSON.parse(__last())[0].children[i].props.onSelect.$fn); __drain(); } print("20 updates ms", Date.now() - t);
