const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const assert = require('node:assert/strict');
const [seedDriver,profileDriver,output, sizeText = '5000',onlyMode] = process.argv.slice(2);
assert.ok(seedDriver && profileDriver && output, 'Pass SEED_DRIVER PROFILE_DRIVER OUTPUT [SIZE] [MODE].');
const size = Number(sizeText);
assert.ok(Number.isInteger(size) && size>=40 && size<=10000);
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'akyuu-profile-'));
const crypto = require('node:crypto');
const hash = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const report = {size, platform:os.platform(), cpu:os.cpus()[0].model, driver_sha256:{seed:hash(seedDriver),profile:hash(profileDriver)},runs:[]};
const save = () => fs.writeFileSync(output, JSON.stringify(report,null,2)+'\n');
function run(binary,args,rts) {
  const p = spawnSync(binary,[...args,'+RTS','-T','-s','-M2G',...rts,'-RTS'],{encoding:'utf8',timeout:125000,maxBuffer:32*1024*1024});
  assert.ifError(p.error); assert.equal(p.status,0,p.stderr);
  return {result:JSON.parse(p.stdout),stderr:p.stderr};
}
try {
  report.seed=run(seedDriver,['seed',path.join(root,'base'),String(size)],['-N2']); save();
  const modes=size===100 ? [['N2',['-N2']]] : [['N2',['-N2']],['N1',['-N1']],['N2-A16m',['-N2','-A16m']],['N2-serialGC',['-N2','-qg']]];
  for(const [mode,rts] of modes) {
    if(onlyMode && mode!==onlyMode) continue;
    const fixture=path.join(root,mode); fs.cpSync(path.join(root,'base'),fixture,{recursive:true});
    console.log(mode,'direct');
    report.runs.push({mode,operation:'direct',...run(profileDriver,['metric',fixture,'commit_uncontended','3'],rts)}); save();
    for(let n=0;n<(size===100?1:3);n++) {
      console.log(mode,'race',n+1);
      report.runs.push({mode,operation:'race',trial:n+1,...run(profileDriver,['race',fixture],rts)});save();
    }
  }
} finally { fs.rmSync(root,{recursive:true,force:true}); }
