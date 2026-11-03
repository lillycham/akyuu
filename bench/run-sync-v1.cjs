// Explicit executable paths; synthetic temporary stores only. Run with Nix Node.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {performance} = require('node:perf_hooks');
const [fixture, binary, output, ...sizes] = process.argv.slice(2);
assert.ok(fixture && binary && output, 'Pass FIXTURE_BINARY AKYUU_BINARY OUTPUT_JSON [SIZES...].');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'akyuu-perf-'));
const bodyProfile=process.env.AKYUU_BENCH_BODY||'compressible';
const split=process.env.AKYUU_BENCH_SPLIT==='1';
assert.ok(['compressible','varied'].includes(bodyProfile));
const env = Object.fromEntries(Object.entries(process.env).filter(([key])=>!key.startsWith('AKYUU_')&&!key.startsWith('GIT_')));
Object.assign(env,{AKYUU_CONFIG:path.join(temporary,'absent.toml'),GIT_CONFIG_GLOBAL:'/dev/null',GIT_CONFIG_NOSYSTEM:'1'});
const report={created:new Date().toISOString(),platform:os.platform(),arch:os.arch(),cpu:os.cpus()[0]?.model,memory_gib:os.totalmem()/2**30,body_profile:bodyProfile,measurement_mode:split?'process_per_metric':'one_process',samples:5,profiles:[]};
function save(){fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n');}
function run(program,args,timeout=65000){
  const start=performance.now();
  const p=spawnSync(program,args,{env,encoding:'utf8',timeout,maxBuffer:32*1024*1024});
  if(p.error)throw p.error;
  assert.equal(p.status,0,p.stderr||p.stdout);
  return {ms:performance.now()-start,value:JSON.parse(p.stdout)};
}
function cli(root,args){return run(binary,['--root',root,'replica',...args,'--json']);}
try{
  for(const count of (sizes.length?sizes:['100','1000','5000']).map(Number)){
    assert.ok(Number.isInteger(count)&&count>=40&&count<=10000);
    console.log(`Profile ${count}`);
    const profile={seed_entries:count};report.profiles.push(profile);save();
    const root=path.join(temporary,`replica-${count}`),remote=path.join(temporary,`remote-${count}.git`),joined=path.join(temporary,`joined-${count}`);
    try{
      console.log('  seed');
      profile.stage='seed';save();
      const seed=run(fixture,['seed',root,String(count),bodyProfile,'+RTS','-N2','-M2G','-RTS'],125000);
      Object.assign(profile,{seed_ms:seed.ms,inventory:seed.value});save();
      console.log('  measure');
      profile.stage='measure';save();
      if(split){
        profile.local={samples:5,metrics:[]};
        for(const operation of ['snapshot','context','search','topic_replace','archive','commit_uncontended']){
          console.log(`    ${operation}`);
          profile.local.metrics.push(...run(fixture,['metric',root,operation,'5','+RTS','-N2','-M2G','-RTS'],125000).value.metrics);save();
        }
      }else profile.local=run(fixture,['measure',root,'5','+RTS','-N2','-M2G','-RTS'],125000).value;
      save();
      console.log('  concurrent commits');
      profile.stage='concurrent_commits';save();
      profile.concurrent_commits=run(fixture,['race',root,'+RTS','-N2','-M2G','-RTS'],125000).value;save();
      const init=spawnSync('git',['init','--bare','--quiet',remote],{env,encoding:'utf8',timeout:5000});
      assert.equal(init.status,0,init.stderr);
      cli(root,['sync-config','--remote',remote]);
      console.log('  initial publication');
      profile.stage='initial_publication';save();
      const publication=cli(root,['sync']);assert.equal(publication.value.pending_events,0);
      profile.initial_sync_ms=publication.ms;save();
      profile.stage='pre_join_noop';save();
      profile.pre_join_noop_ms=cli(root,['sync']).ms;save();
      console.log('  fresh join');
      profile.stage='join';save();
      const join=cli(joined,['join','--remote',remote,'--label','Joined benchmark replica']);
      profile.join_ms=join.ms;save();
      assert.ok(cli(joined,['read','bench/topic-0']).value.heads[0].body.startsWith('benchmark marker changed'));
      cli(joined,['sync']);cli(root,['sync']);
      profile.noop_sync_ms=[];
      profile.stage='noop_sync';save();
      for(let n=0;n<3;n++){const sample=cli(root,['sync']);assert.equal(sample.value.pending_events,0);profile.noop_sync_ms.push(sample.ms);save();}
      profile.status='complete';
      profile.stage='complete';
    }catch(error){profile.status='failed';profile.error=error.message;console.error(error.message);}
    save();
  }
  console.log(output);
  if(report.profiles.some(profile=>profile.status!=='complete'))process.exitCode=1;
}finally{
  if(process.env.AKYUU_BENCH_KEEP==='1')console.log(`Retained temporary fixtures: ${temporary}`);
  else fs.rmSync(temporary,{recursive:true,force:true});
}
