// Check the edge routing of web/index.html with no browser.
//
//   nix shell nixpkgs#nodejs -c node test/check-routing.js web/index.html [GRAPH.json | EXPORT.html ...]
//
// It runs the pure functions (layout, planRoutes, columnGeometry, routeEdges)
// on synthetic graphs of 300, 961 and 3000 nodes, on each graph that you
// name, and checks the routes:
//
// - every segment is horizontal or vertical;
// - no route runs through a node box or a ref tag;
// - a route starts on the bottom edge of its source and ends on the top edge
//   of its target;
// - two routes never share a collinear run;
// - every edge points down, one node per cell, a chain stays in one column;
// - the time limits (961 nodes: 300 ms, 3000 nodes: 1500 ms).
//
// It prints the numbers of the old drawing (a curve from port to port) and of
// the routing, with and without the column order.
'use strict';
const fs = require('fs');
const vm = require('vm');

const html = fs.readFileSync(process.argv[2], 'utf8');
const src = html.slice(html.lastIndexOf('<script>') + 8, html.lastIndexOf('</script>'));
const mod = { exports: null };
vm.runInNewContext(src, { module: mod, console, Math, Date, Map, Set, JSON, Object, Array, String, Number, RegExp, isNaN, Infinity });
const A = mod.exports;
for (const f of ['layout', 'columnGeometry', 'planRoutes', 'routeEdges', 'roundedPath']) {
  if (typeof A[f] !== 'function') throw new Error('the page does not export ' + f);
}
const { NODE_W, NODE_H } = A;
const OLD_ROW_H = 60, OLD_TOP = 28;

// ---- graphs ----------------------------------------------------------------

function rng(seed) {
  let s = seed >>> 0;
  return () => { s = (Math.imul(s, 1664525) + 1013904223) >>> 0; return s / 4294967296; };
}

// Chains, forks, notes that point at older memories, and one memory with
// 25 edges that arrive at it.
function synthetic(n, seed) {
  const rand = rng(seed || 7);
  const id = (i) => 'sha256-' + i.toString(16).padStart(64, '0');
  const nodes = [], edges = [], seen = new Set();
  const add = (s, d, kind) => {
    const k = s + d + kind;
    if (s === d || seen.has(k)) return;
    seen.add(k);
    edges.push({ src: id(s), dst: id(d), kind: kind });
  };
  // About 14 topics are open at one time. A new memory supersedes the last
  // one of a topic, so chains overlap in time and need many columns.
  const topics = [];
  for (let i = 0; i < n; i++) {
    nodes.push({ id: id(i), kind: 'k' + (i % 4), agent: 'a' + (i % 3), created: new Date(1.7e12 + i * 60000).toISOString(), status: 'head', line: 'memory ' + i });
    const t = Math.floor(rand() * 14);
    if (topics[t] !== undefined && rand() < 0.85) {
      add(i, topics[t], 'supersedes');
      if (rand() < 0.07 && i > 8) add(i, Math.max(0, topics[t] - 1 - Math.floor(rand() * 5)), 'supersedes'); // a fork
    }
    topics[t] = i;
    if (i > 10 && rand() < 0.55) add(i, Math.floor(rand() * (i - 1)), 'about');
    if (i > 20 && rand() < 0.08) add(i, Math.floor(rand() * (i - 1)), 'derived-from');
    if (i > 20 && rand() < 0.04) add(i, Math.floor(rand() * (i - 1)), 'refines');
    if (i > 30 && i % 11 === 0 && i < 30 + 11 * 25) add(i, 5, 'about'); // the hub: 25 edges arrive
  }
  const sup = new Set(edges.filter(e => e.kind === 'supersedes').map(e => e.dst));
  for (const x of nodes) if (sup.has(x.id)) x.status = 'superseded';
  return { nodes: nodes, edges: edges };
}

function fromFile(file) {
  const text = fs.readFileSync(file, 'utf8');
  if (/\.html?$/.test(file)) {
    const m = text.match(/<script type="application\/json" id="akyuu-data">([\s\S]*?)<\/script>/);
    if (!m) throw new Error(file + ': no data in the export');
    return JSON.parse(m[1]).graph;
  }
  return JSON.parse(text);
}

// ---- geometry helpers --------------------------------------------------------

// Cross points of two segments, counted when they cross inside both.
function segCross(p, q) {
  const d1x = p.x1 - p.x0, d1y = p.y1 - p.y0, d2x = q.x1 - q.x0, d2y = q.y1 - q.y0;
  const den = d1x * d2y - d1y * d2x;
  if (Math.abs(den) < 1e-9) return null; // parallel: a shared run is checked on its own
  const t = ((q.x0 - p.x0) * d2y - (q.y0 - p.y0) * d2x) / den;
  const u = ((q.x0 - p.x0) * d1y - (q.y0 - p.y0) * d1x) / den;
  const e = 1e-6;
  if (!(t > e && t < 1 - e && u > e && u < 1 - e)) return null;
  return { x: p.x0 + t * d1x, y: p.y0 + t * d1y };
}

// The number of crossings between segments of different edges.
// A segment is {x0,y0,x1,y1,e}. A grid keeps it fast.
function countCrossings(segs) {
  const CELL = 120, grid = new Map();
  segs.forEach((s, i) => {
    const cx0 = Math.floor(Math.min(s.x0, s.x1) / CELL), cx1 = Math.floor(Math.max(s.x0, s.x1) / CELL);
    const cy0 = Math.floor(Math.min(s.y0, s.y1) / CELL), cy1 = Math.floor(Math.max(s.y0, s.y1) / CELL);
    for (let cx = cx0; cx <= cx1; cx++) for (let cy = cy0; cy <= cy1; cy++) {
      const k = cx + ',' + cy;
      if (!grid.has(k)) grid.set(k, []);
      grid.get(k).push(i);
    }
  });
  let n = 0;
  for (const [cell, list] of grid) {
    for (let a = 0; a < list.length; a++) for (let b = a + 1; b < list.length; b++) {
      const i = list[a], j = list[b];
      if (segs[i].e === segs[j].e) continue;
      // count the crossing only in the grid cell that holds it
      const x = segCross(segs[i], segs[j]);
      if (x && Math.floor(x.x / CELL) + ',' + Math.floor(x.y / CELL) === cell) n++;
    }
  }
  return n;
}

// The old drawing: one cubic curve from the bottom middle of the source to
// the top middle of the target (a line in one column), rows 60 px apart.
function oldDrawing(g, lay) {
  const geo = A.columnGeometry(g, lay, new Map());
  const xy = (id) => { const p = lay.pos.get(id); return { x: geo.colX[p.col], y: OLD_TOP + p.row * OLD_ROW_H }; };
  const boxes = g.nodes.map(n => ({ id: n.id, ...xy(n.id) }));
  const segs = [];
  let through = 0, nodeHits = 0, ei = 0;
  for (const e of g.edges) {
    if (!lay.pos.has(e.src) || !lay.pos.has(e.dst)) continue;
    ei++;
    const a = xy(e.src), b = xy(e.dst);
    const sx = a.x + NODE_W / 2, sy = a.y + NODE_H, tx = b.x + NODE_W / 2, ty = b.y;
    const straight = Math.abs(sx - tx) < 1, hit = new Set();
    let px = sx, py = sy;
    for (let i = 1; i <= 24; i++) {
      const t = i / 24, u = 1 - t, my = (ty - sy) / 2;
      const x = straight ? sx : u * u * u * sx + 3 * u * u * t * sx + 3 * u * t * t * tx + t * t * t * tx;
      const y = straight ? sy + (ty - sy) * t : u * u * u * sy + 3 * u * u * t * (sy + my) + 3 * u * t * t * (ty - my) + t * t * t * ty;
      segs.push({ x0: px, y0: py, x1: x, y1: y, e: ei });
      px = x; py = y;
    }
    for (let i = 0; i <= 40; i++) {
      const t = i / 40, u = 1 - t, my = (ty - sy) / 2;
      const x = straight ? sx : u * u * u * sx + 3 * u * u * t * sx + 3 * u * t * t * tx + t * t * t * tx;
      const y = straight ? sy + (ty - sy) * t : u * u * u * sy + 3 * u * u * t * (sy + my) + 3 * u * t * t * (ty - my) + t * t * t * ty;
      for (const o of boxes) {
        if (o.id === e.src || o.id === e.dst) continue;
        if (x > o.x + 1 && x < o.x + NODE_W - 1 && y > o.y + 1 && y < o.y + NODE_H - 1) hit.add(o.id);
      }
    }
    if (hit.size) { through++; nodeHits += hit.size; }
  }
  return { through, nodeHits, edges: ei, crossings: countCrossings(segs) };
}

// ---- the check of one graph ---------------------------------------------------

function markFor(g, heavy) {
  const marks = new Map();
  g.nodes.forEach((n, i) => {
    if (heavy ? i % 2 === 0 : i % 5 === 0) {
      const list = [{ name: 'agent/some-long-topic-name', gen: 0, kept: true }];
      if (heavy) for (let k = 1; k <= 4; k++) list.push({ name: 'agent/some-long-topic-name', gen: k, kept: k < 3 });
      marks.set(n.id, list);
    }
  });
  return marks;
}

function build(g, opts, marks) {
  const t0 = process.hrtime.bigint();
  const lay = opts ? A.layout(g, opts) : A.layout(g);
  const plan = A.planRoutes(g, lay);
  const geo = A.columnGeometry(g, lay, marks, plan.gutterTracks);
  const R = A.routeEdges(g, lay, geo, plan);
  const ms = Number(process.hrtime.bigint() - t0) / 1e6;
  return { lay, plan, geo, R, ms };
}

function routeSegs(R) {
  const segs = [];
  let ei = 0;
  for (const r of R.routes.values()) {
    ei++;
    for (let i = 1; i < r.points.length; i++) {
      const a = r.points[i - 1], b = r.points[i];
      segs.push({ x0: a.x, y0: a.y, x1: b.x, y1: b.y, e: ei, key: r.key });
    }
  }
  return segs;
}

function checkRoutes(g, b, label) {
  const { lay, geo, R } = b;
  let bad = 0;
  const fail = (msg) => { bad++; if (bad <= 8) console.log('  FAIL ' + msg); };
  // layout invariants
  const cell = new Set();
  for (const [, p] of lay.pos) {
    const k = p.col + ',' + p.row;
    if (cell.has(k)) fail('two nodes in cell ' + k);
    cell.add(k);
  }
  if (lay.pos.size !== g.nodes.length) fail('not every node is placed');
  for (const e of g.edges) {
    const a = lay.pos.get(e.src), c = lay.pos.get(e.dst);
    if (a && c && !(a.row < c.row)) fail('edge does not point down');
  }
  for (const ch of lay.chains) for (let i = 1; i < ch.length; i++) {
    if (lay.pos.get(ch[i - 1]).col !== lay.pos.get(ch[i]).col) fail('a chain changes column');
  }
  // boxes: node box, and the tags to the right of it
  const rows = new Map();
  for (const n of g.nodes) {
    const p = lay.pos.get(n.id);
    const t = geo.tagsOf.get(n.id);
    const w = Math.max(A.rowWidth(t[0]), A.rowWidth(t[1]));
    const x = geo.colX[p.col];
    if (!rows.has(p.row)) rows.set(p.row, []);
    rows.get(p.row).push({ id: n.id, x0: x, x1: x + NODE_W + (w > 0 ? 6 + w : 0), y0: R.rowY[p.row], y1: R.rowY[p.row] + NODE_H, nodeX1: x + NODE_W });
  }
  const rowAt = (y) => { // the row whose band contains y, or -1
    let lo = 0, hi = R.rowY.length - 1;
    while (lo <= hi) {
      const m = (lo + hi) >> 1;
      if (y < R.rowY[m]) hi = m - 1; else if (y > R.rowY[m] + NODE_H) lo = m + 1; else return m;
    }
    return -1;
  };
  const firstRowBelow = (y) => { let lo = 0, hi = R.rowY.length; while (lo < hi) { const m = (lo + hi) >> 1; if (R.rowY[m] + NODE_H < y) lo = m + 1; else hi = m; } return lo; };
  let checked = 0, through = 0;
  for (const r of R.routes.values()) {
    checked++;
    const pts = r.points, s = lay.pos.get(r.edge.src), d = lay.pos.get(r.edge.dst);
    // axis aligned
    for (let i = 1; i < pts.length; i++) {
      if (pts[i].x !== pts[i - 1].x && pts[i].y !== pts[i - 1].y) { fail('a diagonal segment in ' + r.key.slice(0, 30)); break; }
    }
    // the ends
    const p0 = pts[0], pn = pts[pts.length - 1];
    const sb = rows.get(s.row).find(o => o.id === r.edge.src), tb = rows.get(d.row).find(o => o.id === r.edge.dst);
    if (!(p0.y === sb.y1 && p0.x >= sb.x0 && p0.x <= sb.nodeX1)) fail('a route does not start on the bottom edge of its source');
    if (!(pn.y === tb.y0 && pn.x >= tb.x0 && pn.x <= tb.nodeX1)) fail('a route does not end on the top edge of its target');
    // through boxes: only the rows that the route's y range holds
    let hit = false;
    for (let i = 1; i < pts.length && !hit; i++) {
      const xa = Math.min(pts[i - 1].x, pts[i].x), xb = Math.max(pts[i - 1].x, pts[i].x);
      const ya = Math.min(pts[i - 1].y, pts[i].y), yb = Math.max(pts[i - 1].y, pts[i].y);
      for (let row = firstRowBelow(ya); row < R.rowY.length && R.rowY[row] <= yb && !hit; row++) {
        for (const o of rows.get(row) || []) {
          // the open interior of the box (and its tags) must not meet the segment
          if (xb > o.x0 && xa < o.x1 && yb > o.y0 && ya < o.y1) {
            // the first and last segment touch their own box edge only
            hit = true;
            break;
          }
        }
      }
    }
    if (hit) { through++; fail('a route runs through a box or a tag: ' + r.key.slice(0, 30)); }
  }
  // collinear shared runs, per line
  const H = new Map(), V = new Map();
  for (const s of routeSegs(R)) {
    if (s.y0 === s.y1 && s.x0 !== s.x1) { if (!H.has(s.y0)) H.set(s.y0, []); H.get(s.y0).push([Math.min(s.x0, s.x1), Math.max(s.x0, s.x1), s.e]); }
    else if (s.x0 === s.x1 && s.y0 !== s.y1) { if (!V.has(s.x0)) V.set(s.x0, []); V.get(s.x0).push([Math.min(s.y0, s.y1), Math.max(s.y0, s.y1), s.e]); }
  }
  let shared = 0;
  for (const m of [H, V]) for (const list of m.values()) {
    list.sort((p, q) => p[0] - q[0]);
    let reach = -Infinity, owner = -1;
    for (const [lo, hi, e] of list) {
      if (lo < reach - 1e-6 && e !== owner) shared++;
      if (hi > reach) { reach = hi; owner = e; }
    }
  }
  if (shared) fail(shared + ' shared collinear runs');
  // a path string for every route
  for (const r of R.routes.values()) {
    const d = A.roundedPath(r.points, 6);
    if (!/^M[-\d.,]+( [LQ][-\d.,]+( [-\d.,]+)?)*$/.test(d) || /NaN|undefined/.test(d)) { fail('bad path ' + d.slice(0, 60)); break; }
  }
  return { bad, checked, through, shared };
}

let problems = 0;
const results = [];

function run(label, g, limitMs) {
  const marks = markFor(g, false);
  const lay0 = A.layout(g, { reorder: false });
  const old = oldDrawing(g, lay0);
  const noOrder = build(g, { reorder: false }, marks);
  const withOrder = build(g, null, marks);
  // time without the extra work of the check: best of three
  let ms = withOrder.ms;
  for (let i = 0; i < 2; i++) ms = Math.min(ms, build(g, null, marks).ms);
  const c = checkRoutes(g, withOrder, label);
  const c0 = checkRoutes(g, noOrder, label + ' (no column order)');
  const heavy = build(g, null, markFor(g, true));
  const ch = checkRoutes(g, heavy, label + ' (heavy tags)');
  const xNo = countCrossings(routeSegs(noOrder.R)), xYes = countCrossings(routeSegs(withOrder.R));
  const R = withOrder.R;
  const types = { straight: 0, z: 0, gutter: 0 };
  for (const r of R.routes.values()) types[r.type] = (types[r.type] || 0) + 1;
  const rowsTall = R.rowY[R.rowY.length - 1] - (R.rowY.length - 1) * A.ROW_H;
  console.log(label + ': ' + g.nodes.length + ' nodes, ' + old.edges + ' edges, ' + withOrder.lay.columns + ' columns, ' + withOrder.lay.rows + ' rows');
  console.log('  old drawing: ' + old.through + ' edges run through a node (' + old.nodeHits + ' hits), ' + old.crossings + ' crossings');
  console.log('  routing: ' + types.straight + ' straight, ' + types.z + ' z, ' + types.gutter + ' gutter; through nodes: ' + c.through +
    ' (no column order: ' + c0.through + ', heavy tags: ' + ch.through + '); shared runs: ' + c.shared);
  console.log('  crossings: old ' + old.crossings + ' -> routed, columns in time order ' + xNo + ' -> columns ordered ' + xYes);
  console.log('  height: +' + Math.round(rowsTall) + ' px over the 60 px grid, width ' + Math.round(withOrder.geo.width) + ' px; widest gutter ' + Math.max(0, ...withOrder.plan.gutterTracks) + ' tracks; layout + routing ' + ms.toFixed(1) + ' ms' + (limitMs ? ' (limit ' + limitMs + ')' : ''));
  let bad = c.bad + c0.bad + ch.bad;
  // compact layouts: the chains stacked in at most K columns
  for (const K of [3, 5, 8]) {
    if (K >= withOrder.lay.columns) continue;
    const cb = build(g, { maxColumns: K }, marks);
    const cc = checkRoutes(g, cb, label + ' (compact ' + K + ')');
    bad += cc.bad;
    const h = cb.R.height;
    console.log('  compact ' + K + ': ' + cb.lay.columns + ' columns x ' + cb.lay.rows + ' rows, ' + Math.round(cb.geo.width) + ' x ' + Math.round(h) + ' px (by time: ' +
      Math.round(withOrder.geo.width) + ' x ' + Math.round(withOrder.R.height) + '), ' + cb.ms.toFixed(1) + ' ms');
    // a chain stays whole: each memory and the one that it supersedes are in one column
    for (const e of g.edges) {
      if (e.kind !== 'supersedes') continue;
      const a = cb.lay.pos.get(e.src), b = cb.lay.pos.get(e.dst);
      if (a && b && lay0.chains.some(ch => ch.indexOf(e.src) >= 0 && ch.indexOf(e.dst) >= 0) && a.col !== b.col) { console.log('  FAIL compact ' + K + ': a chain changes column'); bad++; break; }
    }
    if (cb.lay.columns > Math.max(K, 1) + 4) { console.log('  NOTE compact ' + K + ': ' + cb.lay.columns + ' columns, because chains point at each other'); }
  }
  if (limitMs && ms > limitMs) { console.log('  FAIL too slow'); bad++; }
  problems += bad;
  results.push({ label, old: old.crossings, xNo, xYes, through: c.through });
}

// small hand-made cases for the rules
{
  const id = (i) => 'sha256-' + String(i).padStart(64, '0');
  const mk = (n, edges) => ({ nodes: Array.from({ length: n }, (_, i) => ({ id: id(i), kind: 'k', agent: 'a', created: new Date(1.7e12 + i * 1000).toISOString(), status: 'head' })), edges: edges.map(([s, d, k]) => ({ src: id(s), dst: id(d), kind: k || 'about' })) });
  const chain = mk(4, [[0, 1, 'supersedes'], [1, 2, 'supersedes'], [2, 3, 'supersedes']]);
  const b = build(chain, null, new Map());
  const types = Array.from(b.R.routes.values()).map(r => r.type).join(',');
  if (types !== 'straight,straight,straight') { console.log('FAIL a chain must be straight: ' + types); problems++; }
  const hasPath = A.roundedPath([{ x: 0, y: 0 }, { x: 0, y: 20 }, { x: 20, y: 20 }, { x: 20, y: 40 }], 6);
  if (hasPath !== 'M0,0 L0,14 Q0,20 6,20 L14,20 Q20,20 20,26 L20,40') { console.log('FAIL roundedPath: ' + hasPath); problems++; }
  const dup = mk(2, [[0, 1, 'supersedes'], [0, 1, 'about']]);
  const c = checkRoutes(dup, build(dup, null, new Map()), 'two edges between one pair');
  problems += c.bad;
  console.log('small cases: chain straight, rounded path, parallel edges: ' + (c.bad ? 'FAIL' : 'ok'));
}

run('synthetic 300', synthetic(300, 3));
run('synthetic 961', synthetic(961, 11), 300);
run('synthetic 3000', synthetic(3000, 5), 1500);
for (const f of process.argv.slice(3)) {
  const g = fromFile(f);
  run(f.split('/').pop(), g, g.nodes.length <= 1000 ? 300 : 1500);
}
const regress = results.filter(r => r.xYes > r.xNo);
for (const r of regress) { console.log('NOTE: column order gives more crossings on ' + r.label); }
console.log(problems ? 'PROBLEMS: ' + problems : 'all routing checks passed');
process.exit(problems ? 1 : 0);
