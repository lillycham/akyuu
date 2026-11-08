const fs=require('node:fs');
const assert=require('node:assert/strict');
const r=JSON.parse(fs.readFileSync(process.argv[2]));
const median=a=>a.sort((x,y)=>x-y)[Math.floor(a.length/2)];
const results=[];
for(const run of r.runs) {
  const rows=run.stderr.split('\n').filter(s=>s.startsWith('PROFILE\t')).map(s=>{
    const fields=s.split('\t');
    assert.equal(fields.length,7,'Malformed or interleaved trace line');
    const [,thread,label,start,end,gc,allocation]=fields;
    assert.ok([start,end,gc,allocation].every(x=>Number.isFinite(Number(x))));
    return {thread,label,start:Number(start),end:Number(end),ms:(Number(end)-Number(start))/1e6,gc_ms:Number(gc)/1e6,allocation:Number(allocation)};
  });
  const preflight=rows.filter(x=>x.label.startsWith('preflight.'));
  const tx=rows.filter(x=>preflight.some(p=>p.thread===x.thread&&x.start>=p.start&&x.end<=p.end)||['lock.total','lock.held','advance','checkpoint.retention','objects.save','events.save','checkpoint.save','current.publish','payload.revalidate'].includes(x.label));
  const phases={};
  for(const name of new Set(tx.map(x=>x.label))) {
    const xs=tx.filter(x=>x.label===name);
    phases[name]={median_ms:median(xs.map(x=>x.ms)),median_gc_ms:median(xs.map(x=>x.gc_ms)),median_allocated_bytes:median(xs.map(x=>x.allocation)),count:xs.length};
  }
  const stats=run.stderr.slice(run.stderr.indexOf('bytes allocated in the heap')-20);
  results.push({mode:run.mode,operation:run.operation,trial:run.trial,result:run.result,phases,rts:stats.slice(-1800)});
}
console.log(JSON.stringify(results,null,2));
