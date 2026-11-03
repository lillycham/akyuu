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
function find(node, label) { if(node.tag==='button'&&node.textContent.startsWith(label))return node;for(const child of node.children){const found=find(child,label);if(found)return found;} }
function logFixture(page=1) {
  const bundle=fixture();
  const topic={topic:'me/log',status:'log',heads:[]};
  const report={topic,checkpoint:bundle.checkpoint,page,has_more:page===1,total:3,entries:[{memory:'sha256-summary',body:'summary <img onerror=bad()>',level:1,sources:['sha256-base-a','sha256-base-b'],direct_sources:['sha256-direct-a','sha256-direct-b']}]};
  bundle.topics=[topic];bundle.logs=[report];bundle.context={...bundle.context,topics:[topic],logs:[report]};return bundle;
}
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

  const staticLog=setup(logFixture(),()=>{throw new Error('Static log attempted network I/O.');});
  await settle();
  assert.match(text(staticLog.nodes.detail),/Summary · level 1/);
  assert.match(text(staticLog.nodes.detail),/sha256-direct-a/);
  assert.match(text(staticLog.nodes.detail),/snapshot contains this page only/);
  assert.equal(count(staticLog.nodes.detail,'img'),0);
  assert.equal(find(staticLog.nodes.detail,'Older'),undefined);

  const logRequests=[];
  const liveLog=setup(null,url=>new Promise(resolve=>logRequests.push({url,resolve})));
  logRequests[0].resolve({ok:true,json:async()=>logFixture()});await settle();
  find(liveLog.nodes.detail,'Read source').events.click();
  assert.equal(logRequests[1].url.pathname,'/api/source');
  assert.equal(logRequests[1].url.searchParams.get('checkpoint'),logFixture().checkpoint);
  logRequests[1].resolve({ok:true,json:async()=>({memory:'sha256-direct-a',body:'exact source <script>bad()</script>',sources:[]})});await settle();
  assert.match(text(liveLog.nodes.detail),/exact source <script>/);
  assert.equal(count(liveLog.nodes.detail,'script'),0);
  find(liveLog.nodes.detail,'Older').events.click();
  assert.equal(logRequests[2].url.searchParams.get('log_page'),'2');
  assert.equal(logRequests[2].url.searchParams.get('checkpoint'),logFixture().checkpoint);
  logRequests[2].resolve({ok:false,status:409,json:async()=>({})});await settle();
  assert.match(liveLog.nodes.error.textContent,/snapshot changed/);
  assert.match(text(liveLog.nodes.detail),/page 1/);
  console.log('Replica page DOM checks passed.');
}
main().catch(error=>{console.error(error);process.exitCode=1;});
