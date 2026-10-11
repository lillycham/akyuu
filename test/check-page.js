// Check the script of the akyuu page without a browser: the syntax, the pure
// functions, and the whole page in a small fake DOM (no runtime error, no
// innerHTML, the highlight on hover).
//
//   nix shell nixpkgs#nodejs -c node test/check-page.js web/index.html EXPORT.html
//
// EXPORT.html is the output of `akyuu viz`: its data and its (same) page.
'use strict';
const fs = require('fs');
const vm = require('vm');

function scriptOf(html) {
  const start = html.lastIndexOf('<script>');
  const end = html.lastIndexOf('</script>');
  if (start < 0 || end < start) throw new Error('no script');
  return html.slice(start + '<script>'.length, end);
}
function dataOf(html) {
  const m = html.match(/<script type="application\/json" id="akyuu-data">([\s\S]*?)<\/script>/);
  return m ? m[1] : null;
}

const page = fs.readFileSync(process.argv[2], 'utf8');
const src = scriptOf(page);
new vm.Script(src, { filename: 'page.js' }); // syntax
console.log('syntax: ok (' + src.length + ' chars)');
// Data from a store is text only. The page must not build HTML from it.
if (/innerHTML|outerHTML|insertAdjacentHTML|document\.write/.test(src)) throw new Error('the page script uses an HTML sink');
console.log('no innerHTML, outerHTML, insertAdjacentHTML or document.write in the script');

// ---- the pure part, with no document -----------------------------------
const mod = { exports: null };
vm.runInNewContext(src, { module: mod, console: console, Math, Date, Map, Set, JSON, Object, Array, String, Number, RegExp, isNaN, Infinity });
const A = mod.exports;
for (const f of ['layout', 'windowGraph', 'staticSearch', 'snippetParts', 'shortId']) if (typeof A[f] !== 'function') throw new Error('missing ' + f);
console.log('pure functions: ' + Object.keys(A).join(', '));

function checkLayout(g, label) {
  const t0 = Date.now();
  const lay = A.layout(g);
  const ms = Date.now() - t0;
  const ids = new Set(g.nodes.map(n => n.id));
  let bad = 0;
  if (lay.pos.size !== g.nodes.length) { console.log('  not every node placed'); bad++; }
  const cell = new Set();
  for (const [id, p] of lay.pos) {
    const k = p.col + ',' + p.row;
    if (cell.has(k)) { console.log('  two nodes in one cell ' + k); bad++; }
    cell.add(k);
  }
  for (const e of g.edges) {
    if (!ids.has(e.src) || !ids.has(e.dst)) continue;
    const a = lay.pos.get(e.src), b = lay.pos.get(e.dst);
    if (!(a.row < b.row)) { console.log('  edge does not point down: ' + e.kind + ' ' + e.src.slice(7, 15) + ' -> ' + e.dst.slice(7, 15)); bad++; }
  }
  // A chain step (supersedes inside one chain) stays in one column.
  let chainSteps = 0;
  for (const c of lay.chains) for (let i = 1; i < c.length; i++) {
    chainSteps++;
    if (lay.pos.get(c[i - 1]).col !== lay.pos.get(c[i]).col) { console.log('  chain changes column'); bad++; }
  }
  console.log(label + ': ' + g.nodes.length + ' nodes, ' + g.edges.length + ' edges -> ' + lay.columns + ' columns, ' + lay.rows + ' rows, ' +
    lay.chains.length + ' chains (' + chainSteps + ' steps), ' + ms + ' ms, problems: ' + bad);
  return bad;
}

// A synthetic graph: chains, forks, and notes about them.
function synthetic(n) {
  const nodes = [], edges = [];
  const id = (i) => 'sha256-' + i.toString(16).padStart(64, '0');
  for (let i = 0; i < n; i++) {
    nodes.push({ id: id(i), kind: 'k' + (i % 4), agent: 'a' + (i % 3), created: new Date(1.7e12 + i * 60000).toISOString(), status: 'head' });
    if (i % 3 !== 0) edges.push({ src: id(i), dst: id(i - 1), kind: 'supersedes' });
    if (i % 7 === 0 && i > 10) edges.push({ src: id(i), dst: id(i - 10), kind: 'about' });
    if (i % 11 === 0 && i > 3) edges.push({ src: id(i), dst: id(i - 2), kind: 'supersedes' }); // a fork or a merge
  }
  const sup = new Set(edges.filter(e => e.kind === 'supersedes').map(e => e.dst));
  for (const x of nodes) if (sup.has(x.id)) x.status = 'superseded';
  return { nodes, edges };
}
let problems = 0;
problems += checkLayout(synthetic(300), 'synthetic 300');
problems += checkLayout(synthetic(3000), 'synthetic 3000');
const w = A.windowGraph(synthetic(3000), { hops: 2, limit: 50 });
console.log('window of synthetic 3000: ' + w.shown.nodes + ' nodes, truncated ' + w.truncated);
problems += checkLayout(w, 'window');
const O = '\u0001', C = '\u0002';
const parts = A.snippetParts('a ' + O + 'b' + C + ' c ' + O + 'd' + C);
if (JSON.stringify(parts) !== JSON.stringify([{ text: 'a ', mark: false }, { text: 'b', mark: true }, { text: ' c ', mark: false }, { text: 'd', mark: true }])) { console.log('snippetParts wrong'); problems++; }
// A square bracket in a body is text, and not a mark.
const brackets = A.snippetParts('see [x] and ' + O + 'Haskell' + C + ' [y]');
if (JSON.stringify(brackets) !== JSON.stringify([{ text: 'see [x] and ', mark: false }, { text: 'Haskell', mark: true }, { text: ' [y]', mark: false }])) { console.log('snippetParts: a bracket is taken for a mark'); problems++; }
if (A.snippetParts('only [x] here').some(p => p.mark)) { console.log('snippetParts: [x] is a mark'); problems++; }
// The static search marks with the control characters, and takes a mark character of a body for text.
const found = A.staticSearch({
  s1: { body: 'see [x] and Haskell [y]', edges: [], created: '2026-01-01T00:00:00Z' },
  s2: { body: 'a ' + O + 'fake' + C + ' mark and Haskell', edges: [], created: '2026-01-02T00:00:00Z' },
}, 'haskell', 10);
const snips = Object.fromEntries(found.matches.map(m => [m.id, m.snippet]));
if (snips.s1 !== 'see [x] and ' + O + 'Haskell' + C + ' [y]') { console.log('staticSearch snippet of s1 wrong: ' + JSON.stringify(snips.s1)); problems++; }
if (snips.s2 !== 'a �fake� mark and ' + O + 'Haskell' + C) { console.log('staticSearch snippet of s2 wrong: ' + JSON.stringify(snips.s2)); problems++; }
// Two words, one inside the other: each position is marked once.
const two = A.staticSearch({ s: { body: 'ab abc', edges: [], created: '2026-01-01T00:00:00Z' } }, 'ab abc', 10);
if (two.matches[0].snippet !== O + 'ab' + C + ' ' + O + 'abc' + C) { console.log('staticSearch two words wrong: ' + JSON.stringify(two.matches[0].snippet)); problems++; }

// ---- the export ------------------------------------------------------------
const vizPath = process.argv[3];
let viz = null;
if (vizPath) {
  const vhtml = fs.readFileSync(vizPath, 'utf8');
  const raw = dataOf(vhtml);
  if (!raw) throw new Error('no data in the export');
  viz = JSON.parse(raw);
  for (const k of ['stats', 'graph', 'refs', 'plan', 'trash', 'verify', 'memories', 'explain']) {
    if (viz[k] && viz[k].error) { console.log('export part ' + k + ' has an error: ' + viz[k].error); problems++; }
  }
  problems += checkLayout(viz.graph, 'export graph');
  problems += checkLayout(A.windowGraph(viz.graph, {}), 'export default window');
  const words = Object.values(viz.memories).map(m => (m.body.match(/[A-Za-z]{5,}/) || [])[0]).filter(Boolean);
  if (words.length) {
    const r = A.staticSearch(viz.memories, words[0], 10);
    console.log('static search "' + words[0] + '": ' + r.matches.length + ' hits; first snippet: ' + (r.matches[0] && r.matches[0].snippet));
  }
}

// ---- the whole page in a small fake DOM ----------------------------------------
function makeDom() {
  const all = [];
  class Node {
    constructor(tag) { this.tagName = tag; this.attrs = {}; this.children = []; this.listeners = {}; this._text = ''; this.dataset = {}; this.hidden = false;
      this.scrollLeft = 0; this.scrollTop = 0; this.value = ''; this.checked = false; this.selected = false; this.parent = null; all.push(this); }
    setAttribute(k, v) { this.attrs[k] = String(v); if (k === 'id') this.id = String(v); if (k.startsWith('data-')) this.dataset[k.slice(5).replace(/-(.)/g, (_, c) => c.toUpperCase())] = String(v); }
    getAttribute(k) { return this.attrs[k]; }
    set className(v) { this.attrs.class = v; } get className() { return this.attrs.class || ''; }
    set textContent(v) { this.children = []; this._text = String(v); } get textContent() { return this._text + this.children.map(c => c.textContent).join(''); }
    set innerHTML(v) { throw new Error('innerHTML was used'); }
    appendChild(c) { if (c == null || typeof c !== 'object') throw new Error('appendChild of ' + typeof c); c.parent = this; this.children.push(c); return c; }
    replaceChildren(...cs) { this.children = []; this._text = ''; for (const c of cs) this.appendChild(c); }
    addEventListener(t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); }
    fire(t, ev) { for (const f of this.listeners[t] || []) f(Object.assign({ preventDefault() {}, target: this }, ev || {})); }
    scrollTo() {}
  }
  class Text { constructor(t) { this.textContent = String(t); } }
  const byId = {};
  const document = {
    createElement: (t) => new Node(t),
    createElementNS: (ns, t) => { if (ns !== 'http://www.w3.org/2000/svg') throw new Error('bad ns'); return new Node(t); },
    createTextNode: (t) => new Text(t),
    getElementById: (id) => byId[id] || null,
    querySelectorAll: (q) => {
      if (q === '#tabs button') return tabs;
      if (q === '.view') return views;
      throw new Error('querySelectorAll ' + q);
    },
    addEventListener: () => {},
  };
  const ids = ['status', 'f-kind', 'f-agent', 'f-ref', 'w-hops', 'w-limit', 'w-all', 'w-focus', 'graph-notice', 'legend', 'graph-canvas',
    'refs-notice', 'refs-list', 'search-form', 's-q', 's-limit', 's-hops', 's-show', 'search-notice', 'search-results',
    'gc-summary', 'gc-notice', 'gc-legend', 'gc-canvas', 'gc-lists', 'h-run', 'h-note', 'health', 'panel'];
  for (const id of ids) { const n = new Node('div'); n.setAttribute('id', id); byId[id] = n; }
  byId['s-limit'].value = '10'; byId['s-hops'].value = '1'; byId['w-hops'].value = '2'; byId['w-limit'].value = '200';
  const tabs = ['graph', 'refs', 'search', 'gc', 'health'].map(t => { const b = new Node('button'); b.dataset.tab = t; return b; });
  const views = ['graph', 'refs', 'search', 'gc', 'health'].map(t => { const v = new Node('section'); v.id = 'view-' + t; return v; });
  return { document, all, byId, tabs, Node };
}

async function runPage(html, label) {
  const dom = makeDom();
  const raw = dataOf(html);
  if (raw) { const d = new dom.Node('script'); d.setAttribute('id', 'akyuu-data'); d.textContent = raw; dom.byId['akyuu-data'] = d; }
  const errors = [];
  const ctx = {
    document: dom.document, window: { matchMedia: () => ({ matches: false }) }, location: { hash: '' },
    history: { replaceState: () => {} }, console, setInterval: () => 0, URLSearchParams,
    fetch: () => Promise.reject(new Error('no network in this check')),
    Math, Date, Map, Set, JSON, Object, Array, String, Number, RegExp, isNaN, Infinity, Promise, Error,
  };
  process.removeAllListeners('unhandledRejection');
  process.on('unhandledRejection', (e) => errors.push(e));
  vm.runInNewContext(scriptOf(html), ctx, { filename: label });
  const tick = () => new Promise(r => setTimeout(r, 30));
  await tick(); await tick();
  const svgNodes = () => dom.all.filter(n => n.tagName === 'g' && n.dataset && n.dataset.id);
  const drawn = svgNodes().length;
  for (const t of dom.tabs) { t.fire('click'); await tick(); await tick(); }
  // click a node of the graph, then the GC tab and a node there
  dom.tabs[0].fire('click'); await tick();
  // hover: the edges of the node become hot, the rest is faint, and it ends on leave
  {
    const canvas = dom.byId['graph-canvas'].children[0];
    const hasClass = (n, c) => (n.attrs.class || '').split(' ').indexOf(c) >= 0;
    const paths = dom.all.filter(n => n.tagName === 'path' && hasClass(n, 'edge') && n.parent && n.parent.parent === canvas);
    const nodes = canvas && canvas.children ? canvas.children.filter(c => c.dataset && c.dataset.id) : [];
    let tried = 0, lit = 0;
    for (const n of nodes) {
      n.fire('mouseenter');
      const hot = paths.filter(p => hasClass(p, 'hot')).length;
      if (hot) { lit = hot; tried = 1; if (!hasClass(canvas, 'hl')) { errors.push('no hl class on hover'); } n.fire('mouseleave'); break; }
      n.fire('mouseleave');
    }
    const after = paths.filter(p => hasClass(p, 'hot')).length;
    if (after) errors.push('edges stay hot after the mouse leaves');
    if (paths.length && !tried) errors.push('no node lit any edge');
    console.log('  hover: ' + paths.length + ' edges drawn, ' + lit + ' hot on hover, ' + after + ' after leave');
  }
  const g = svgNodes();
  if (g.length) { g[0].fire('click'); await tick(); await tick(); }
  const panelText = dom.byId['panel'].textContent.slice(0, 120).replace(/\s+/g, ' ');
  dom.tabs[3].fire('click'); await tick(); await tick();
  const g2 = svgNodes();
  if (g2.length) { g2[g2.length - 1].fire('click'); await tick(); await tick(); }
  const explainText = dom.byId['panel'].textContent.slice(0, 160).replace(/\s+/g, ' ');
  // a search
  dom.tabs[2].fire('click');
  dom.byId['s-q'].value = 'haskell';
  dom.byId['search-form'].fire('submit'); await tick(); await tick();
  const searchText = dom.byId['search-results'].textContent.slice(0, 160).replace(/\s+/g, ' ');
  dom.byId['s-show'].fire('click'); await tick(); await tick();
  // filters and the window controls
  dom.tabs[0].fire('click');
  dom.byId['w-all'].checked = true; dom.byId['w-all'].fire('change'); await tick();
  dom.byId['f-kind'].fire('change', { target: { value: 'fact' } }); await tick();
  console.log(label + ': drew ' + drawn + ' nodes at start; status "' + dom.byId['status'].textContent + '"');
  console.log('  panel: ' + panelText);
  console.log('  explain: ' + explainText);
  console.log('  search: ' + searchText);
  console.log('  health: ' + dom.byId['health'].textContent.slice(0, 160).replace(/\s+/g, ' '));
  console.log('  gc: ' + dom.byId['gc-summary'].textContent.replace(/\s+/g, ' '));
  console.log('  errors: ' + errors.length + (errors.length ? ' ' + errors.map(e => e && e.stack || e).join('\n') : ''));
  return errors.length;
}

(async () => {
  if (vizPath) problems += await runPage(fs.readFileSync(vizPath, 'utf8'), 'static page');
  console.log(problems ? 'PROBLEMS: ' + problems : 'all checks passed');
  process.exit(problems ? 1 : 0);
})().catch((e) => { console.log('FAILED: ' + (e.stack || e)); process.exit(1); });
