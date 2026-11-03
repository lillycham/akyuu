// Opt-in two-machine experiment. Pass an authorised SSH alias and both binaries.
// Every store and the bare remote live below fresh temporary directories.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {spawnSync}=require('node:child_process');
const {performance}=require('node:perf_hooks');
const [host,binary,remoteBinary,output]=process.argv.slice(2);
assert.ok(host&&binary&&remoteBinary&&output,'Pass SSH_HOST LOCAL_BINARY REMOTE_BINARY OUTPUT_JSON.');
assert.match(host,/^[A-Za-z0-9_.@-]+$/);
assert.ok(path.isAbsolute(binary)&&path.isAbsolute(remoteBinary));
const temporary=fs.mkdtempSync(path.join(os.tmpdir(),'akyuu-ssh-experiment-'));
const env=Object.fromEntries(Object.entries(process.env).filter(([key])=>!key.startsWith('AKYUU_')&&!key.startsWith('GIT_')));
env.AKYUU_CONFIG=path.join(temporary,'absent.toml');
const report={created:new Date().toISOString(),transport:'ssh',checks:[],timings_ms:[]};
let remoteRoot,hidden=false;
const quote=s=>"'"+s.replaceAll("'","'\\''")+"'";
function run(program,args,expected=0){
  const start=performance.now();
  const p=spawnSync(program,args,{env,encoding:'utf8',timeout:70000,maxBuffer:16*1024*1024});
  assert.ifError(p.error);assert.equal(p.status,expected,p.stderr||p.stdout);
  return {text:p.stdout,ms:performance.now()-start};
}
function remote(args,expected=0){return run('ssh',['-oBatchMode=yes','-oConnectTimeout=10',host,args.map(quote).join(' ')],expected);}
function cli(where,args,expected=0){
  const p=where==='a'?run(binary,['--root',path.join(temporary,'a'),'replica',...args,'--json'],expected):remote(['env',`AKYUU_CONFIG=${remoteRoot}/absent.toml`,remoteBinary,'--root',`${remoteRoot}/b`,'replica',...args,'--json'],expected);
  report.timings_ms.push({side:where,operation:args[0],ms:p.ms});
  return JSON.parse(p.text);
}
function check(label,action){console.log(label);action();report.checks.push(label);fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n');}
const read=(where,ref='test/topic')=>cli(where,['read',ref]);
const sync=where=>cli(where,['sync']);
function replace(where,body){return cli(where,['replace','test/topic','--expected',read(where).version,'--kind','fact','--agent','experiment','--body',body]);}
function append(where,body){return cli(where,['append','test/log','--expected',read(where,'test/log').version,'--kind','note','--agent','experiment','--body',body]);}
try{
  const created=remote(['mktemp','-d','/tmp/akyuu-ssh-experiment.XXXXXX']).text.trim();
  assert.match(created,/^\/tmp\/akyuu-ssh-experiment\.[A-Za-z0-9]+$/);
  remoteRoot=created;
  const bare=`${remoteRoot}/remote.git`;
  remote(['git','init','--bare','--quiet',bare]);
  remote(['git','-C',bare,'config','core.hooksPath','/dev/null']);
  let firstId,base,left,right,joined;
  check('SSH publication and distinct Linux join',()=>{
    cli('a',['init','--label','Local experiment replica']);
    firstId=cli('a',['create','test/topic','--kind','fact','--agent','experiment','--body','initial fact']).heads[0].memory;
    cli('a',['sync-config','--remote',`${host}:${bare}`]);
    assert.equal(sync('a').pending_events,0);
    cli('b',['join','--remote',bare,'--label','Remote experiment replica']);
    assert.equal(read('b').heads[0].memory,firstId);
    const localId=fs.readFileSync(path.join(temporary,'a','REPLICA'),'utf8');
    assert.notEqual(localId,remote(['cat',`${remoteRoot}/b/REPLICA`]).text);
    sync('b');sync('a');
  });
  check('Offline topic conflict and explicit resolution converge',()=>{
    replace('a','local alternative');replace('b','remote alternative');
    sync('a');sync('b');sync('a');
    const a=read('a'),b=read('b');assert.equal(a.status,'conflict');assert.equal(a.heads.length,2);
    assert.deepEqual(a.heads.map(h=>h.memory).sort(),b.heads.map(h=>h.memory).sort());
    cli('a',['resolve','test/topic','--expected',a.version,'--select',a.heads[0].memory]);
    sync('a');sync('b');assert.equal(read('a').version,read('b').version);
  });
  check('Cross-device DAG branches, join and summary evidence converge',()=>{
    base=append('a','shared episode').heads[0].memory;sync('a');sync('b');
    left=append('a','local episode').heads[0].memory;right=append('b','remote episode').heads[0].memory;
    sync('a');sync('b');sync('a');
    const entries=cli('b',['log','test/log']).entries;
    assert.deepEqual(entries.map(e=>e.memory).sort(),[base,left,right].sort());
    joined=append('a','joined branches').heads[0].memory;sync('a');sync('b');
    const levels=cli('a',['log-levels','test/log']);
    const summary=cli('a',['summarise','test/log','--expected',levels.version,'--level','1',...[base,left,right].flatMap(id=>['--source',id]),'--kind','summary','--agent','experiment','--body','Both branches retain the shared episode.']);
    sync('a');sync('b');
    const cover=cli('b',['log-resolution','test/log','--keep','1']).view.entries;
    assert.deepEqual(cover.map(e=>e.memory),[joined,summary.heads[0].memory]);
    assert.deepEqual(cover[1].sources.sort(),[base,left,right].sort());
    const evidence=cli('b',['unfold',summary.heads[0].memory]).entries;
    assert.deepEqual(evidence.map(e=>e.body).sort(),['shared episode','local episode','remote episode'].sort());
  });
  check('Missing remote refuses publication and preserves pending work',()=>{
    replace('a','pending during remote outage');
    const current=fs.readFileSync(path.join(temporary,'a','CURRENT'),'utf8');
    remote(['mv',bare,`${bare}.offline`]);hidden=true;
    assert.equal(cli('a',['sync'],1).error,'sync-error');
    assert.equal(fs.readFileSync(path.join(temporary,'a','CURRENT'),'utf8'),current);
    assert.ok(cli('a',['sync-status']).pending_events>0);
    remote(['mv',`${bare}.offline`,bare]);hidden=false;
    assert.equal(sync('a').pending_events,0);sync('b');
    assert.equal(read('b').heads[0].body,'pending during remote outage');
  });
  check('GC eviction and archived pin restoration cross SSH',()=>{
    for(const side of ['a','b']){
      const plan=cli(side,['gc','--dry-run','--keep-generations','1']);assert.ok(plan.candidates.includes(firstId));
      cli(side,['gc','--expected',plan.checkpoint,'--keep-generations','1']);
    }
    assert.equal(fs.existsSync(path.join(temporary,'a','objects',firstId)),false);
    remote(['test','-e',`${remoteRoot}/b/objects/${firstId}`],1);
    const state=cli('a',['pin-state',firstId]);cli('a',['pin',firstId,'--expected',state.version]);sync('a');sync('b');
    assert.equal(fs.existsSync(path.join(temporary,'a','objects',firstId)),true);
    remote(['test','-e',`${remoteRoot}/b/objects/${firstId}`]);
    assert.equal(cli('b',['pin-state',firstId]).pinned,true);
    sync('a');
    for(const side of ['a','b'])assert.equal(cli(side,['sync-status']).pending_events,0);
  });
  report.status='passed';console.log('Two-machine SSH sync experiment passed.');
}catch(error){report.status='failed';report.error=error.message;console.error(error);process.exitCode=1;}
finally{
  fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n');
  if(remoteRoot){
    if(hidden)try{remote(['mv',`${remoteRoot}/remote.git.offline`,`${remoteRoot}/remote.git`]);}catch{}
    try{remote(['rm','-rf','--',remoteRoot]);}catch(error){console.error(`Temporary remote cleanup failed: ${error.message}`);}
  }
  fs.rmSync(temporary,{recursive:true,force:true});
}
