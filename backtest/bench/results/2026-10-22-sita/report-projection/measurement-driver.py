from pathlib import Path
import subprocess,random,time,json,statistics
root=next(p for p in Path(__file__).resolve().parents if (p/'bt.rfl').exists());tmp=Path('/tmp/backtest-projection-perf')
cases=[(x,True) for x in ['baseline','project']]
rest=[(x,False) for x in ['baseline','project'] for _ in range(3)];random.Random(22).shuffle(rest);cases+=rest
records=[]
for name,warmup in cases:
 rss=tmp/'rss.txt';start=time.perf_counter()
 p=subprocess.run(['/usr/bin/time','-f','%M','-o',str(rss),'/usr/sbin/rayforce',str(tmp/f'{name}-bench.rfl'),'--','-data','data/synth-1h-100','-mode','xsmomf','-per_day','24','-kernel','bt.rfl'],cwd=root,capture_output=True,text=True,check=True)
 row=json.loads(next(line for line in p.stdout.splitlines() if line.startswith('{')))
 row.update(variant=name,warmup=warmup,wall_s=time.perf_counter()-start,rss_kb=int(rss.read_text().strip()));records.append(row);print(name,warmup,round(row['wall_s'],3),row['check_ms'],row['rss_kb'],flush=True)
(tmp/'samples.json').write_text(json.dumps(records,indent=2)+'\n')
for name in ['baseline','project']:
 rows=[r for r in records if r['variant']==name and not r['warmup']]
 print(name,{key:statistics.median(r[key] for r in rows) for key in ['wall_s','check_ms','rss_kb']},flush=True)
