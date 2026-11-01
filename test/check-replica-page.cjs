// DOM logic tests only. This does not launch a browser or perform network I/O.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const html = fs.readFileSync(process.argv[2], 'utf8');
const script = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)][0][1];
class Element {
  constructor(tag, text = '') { this.tag = tag; this.textContent = text; this.children = []; this.events = {}; this.attrs = {}; this.value = ''; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; this.textContent = ''; }
  addEventListener(event, run) { this.events[event] = run; }
  setAttribute(key, value) { this.attrs[key] = value; }
  set innerHTML(_) { throw new Error('Untrusted data must not enter innerHTML.'); }
}
function fixture(checkpoint = 'sha256-aaaaaaaaaaaa') {
  const topic = { topic: 'me/topic', checkpoint, version: 'version', status: 'conflict', heads: [
    { body: 'local branch <img onerror=bad()>', event: 'event-a', memory: 'memory-a', kind: 'fact', agent: 'a', about_refs: [] },
    { body: 'remote branch', event: 'event-b', memory: 'memory-b', kind: 'fact', agent: 'b', about_refs: [] }
  ] };
  return { checkpoint, topics: [topic], context: {checkpoint, tier:'always',ready:false,maintenance_ready:true,issues:['Context topic has concurrent heads.'],topics:[topic]}, search:null };
}
function setup(embedded, fetch) {
  const nodes = Object.fromEntries(['refresh','snapshot','topics','search-form','query','search-submit','clear','error','results','detail','context'].map(id => [id,new Element('div')]));
  if (embedded) nodes['akyuu-data'] = new Element('script', JSON.stringify(embedded));
  const context = { document: {getElementById:id=>nodes[id]||null,createElement:tag=>new Element(tag)}, URL, location:{href:'https://example.invalid/'}, fetch };
  vm.runInNewContext(script, context);
  return {nodes,context};
}
function text(node) { return node.textContent + node.children.map(text).join('\n'); }
function count(node, tag) { return Number(node.tag === tag) + node.children.reduce((sum,child)=>sum+count(child,tag),0); }
async function settle() { for(let n=0;n<8;n++) await Promise.resolve(); }
async function main() {
  const staticView = setup(fixture(), () => {throw new Error('Static export attempted network I/O.');});
  await settle();
  assert.match(text(staticView.nodes.detail), /No version is selected/);
  assert.match(text(staticView.nodes.detail), /local branch <img/);
  assert.match(text(staticView.nodes.detail), /remote branch/);
  assert.equal(count(staticView.nodes.detail,'article'),2);
  assert.equal(count(staticView.nodes.detail,'img'),0);
  staticView.nodes.query.value='local';
  staticView.nodes['search-form'].events.submit({preventDefault(){}});
  await settle();
  assert.match(text(staticView.nodes.results), /Filter: local/);
  assert.equal(count(staticView.nodes.detail,'article'),2);

  const requests=[];
  const live=setup(null, ()=>new Promise((resolve,reject)=>requests.push({resolve,reject})));
  live.nodes.query.value='remote';
  live.nodes['search-form'].events.submit({preventDefault(){}});
  assert.equal(requests.length,2);
  requests[1].resolve({ok:true,json:async()=>fixture('sha256-bbbbbbbbbbbb')});
  await settle();
  assert.match(live.nodes.snapshot.textContent,/bbbbbbbbbbbb/);
  requests[0].resolve({ok:true,json:async()=>fixture('sha256-aaaaaaaaaaaa')});
  await settle();
  assert.match(live.nodes.snapshot.textContent,/bbbbbbbbbbbb/);
  live.nodes.refresh.events.click();
  requests[2].resolve({ok:false,json:async()=>({message:'Repository is damaged.'})});
  await settle();
  assert.match(live.nodes.error.textContent,/Repository is damaged/);
  console.log('Replica page DOM checks passed.');
}
main().catch(error=>{console.error(error);process.exitCode=1;});
