// Run sequentially with Nix Node and fixture drivers from two revisions.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawnSync} = require('node:child_process');
const [before, after, output, ...sizes] = process.argv.slice(2);
assert.ok(before && after && output, 'Pass BEFORE_DRIVER AFTER_DRIVER OUTPUT_JSON [SIZES...].');
const digest = binary => crypto.createHash('sha256').update(fs.readFileSync(binary)).digest('hex');
const report = {created:new Date().toISOString(),platform:os.platform(),arch:os.arch(),cpu:os.cpus()[0]?.model,memory_gib:os.totalmem()/2**30,samples:5,driver_sha256:{before:digest(before),after:digest(after)},profiles:[]};
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'akyuu-locks-'));
const save = () => fs.writeFileSync(output, JSON.stringify(report,null,2)+'\n');
function run(binary,args) {
  const process = spawnSync(binary,[...args,'+RTS','-N2','-M2G','-RTS'],{encoding:'utf8',timeout:125000,maxBuffer:32*1024*1024});
  assert.ifError(process.error);
  assert.equal(process.status,0,process.stderr||process.stdout);
  return JSON.parse(process.stdout);
}
try {
  for(const size of (sizes.length?sizes:['100','1000','5000']).map(Number)) {
    assert.ok(Number.isInteger(size)&&size>=40&&size<=10000);
    console.log(`Profile ${size}`);
    const profile={seed_entries:size,before:{races:[]},after:{races:[]}};
    report.profiles.push(profile);save();
    const roots={before:path.join(temporary,`${size}-before`),after:path.join(temporary,`${size}-after`)};
    const binaries={before,after};
    try {
      for(const label of ['before','after']) {
        profile.stage=`${label}_seed`;save();
        profile[label].inventory=run(binaries[label],['seed',roots[label],String(size)]);save();
        profile.stage=`${label}_direct_commit`;save();
        profile[label].direct_commit=run(binaries[label],['metric',roots[label],'commit_uncontended','5']);save();
      }
      assert.equal(profile.before.inventory.fixture_checkpoint,profile.after.inventory.fixture_checkpoint);
      for(let trial=0;trial<5;trial++) {
        // Alternate first position; each invocation contains two simultaneous writers.
        for(const label of (trial%2?['after','before']:['before','after'])) {
          profile.stage=`${label}_race_${trial+1}`;save();
          console.log(`  ${profile.stage}`);
          profile[label].races.push(run(binaries[label],['race',roots[label]]));save();
        }
      }
      profile.stage='complete';
    } catch(error) {
      profile.stage='failed';profile.error=error.message;process.exitCode=1;
    }
    save();
  }
} finally {
  fs.rmSync(temporary,{recursive:true,force:true});
}
