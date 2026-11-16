#!/usr/bin/env python3
"""Opt-in benchmark; modifies only disposable test copies and emits raw measurements."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import uuid
from large_pdf_benchmark_support import fixture_identity

ROOT = Path(__file__).resolve().parents[1]
def validate(fixture, runs):
    if not Path(fixture).is_file(): raise ValueError('fixture missing')
    if not 1 <= runs <= 20: raise ValueError('runs must be 1–20')

def percentile(values, q):
    values = sorted(values)
    p = (len(values)-1)*q
    lower = int(p); upper = min(lower+1,len(values)-1)
    return values[lower]+(values[upper]-values[lower])*(p-lower)

def summarize(records):
    required = ['open_ms', 'model_ms', 'turns', 'frame_ms', 'before_bytes', 'open_bytes', 'peak_bytes', 'idle_bytes', 'close_bytes']
    for record in records:
        if any(key not in record for key in required): raise ValueError('missing performance field')
        if record['open_ms'] < 0 or len(record['turns']) != 100 or any(t['tile_ms'] < 0 for t in record['turns']):
            raise ValueError('incomplete visible-page measurements')
    result = {}
    for key in ['open_ms','model_ms','before_bytes','open_bytes','peak_bytes','idle_bytes','close_bytes']:
        values = [r[key] for r in records]
        result[key] = dict(median=statistics.median(values), minimum=min(values), maximum=max(values))
    for key in ['state_ms','tile_ms']:
        values = [t[key] for r in records for t in r['turns']]
        result['turn_'+key] = dict(p50=percentile(values,.5), p95=percentile(values,.95), maximum=max(values))
    frames = [v for r in records for v in r['frame_ms']]
    result['frame_ms'] = dict(p50=percentile(frames,.5),p95=percentile(frames,.95),maximum=max(frames),over_33ms=sum(v>33.4 for v in frames),samples=len(frames))
    return result

def hashes(root):
    return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for folder in ['Percuscore','Sources'] for p in (root/folder).rglob('*') if p.is_file()}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-root',type=Path,default=ROOT)
    parser.add_argument('--fixture',required=True,type=Path)
    parser.add_argument('--simulator',required=True)
    parser.add_argument('--runs',type=int,default=5)
    parser.add_argument('--glass',choices=['on','off'],default='on')
    parser.add_argument('--output',required=True,type=Path)
    args = parser.parse_args(); validate(args.fixture,args.runs)
    env = dict(os.environ)
    env.setdefault('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer')
    devices = json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','-j'],env=env))
    if not any(d['udid']==args.simulator for ds in devices['devices'].values() for d in ds): raise ValueError('unknown simulator')
    identity = fixture_identity(args.fixture)
    before = hashes(args.source_root)
    args.output.mkdir(parents=True,exist_ok=True)
    runset = uuid.uuid4().hex
    env.update(PERFORMANCE_SOURCE_ROOT=str(args.source_root),PERFORMANCE_WORK=os.environ.get('PERFORMANCE_WORK','/private/tmp/Percuscore-large-pdf-testhost'),
        PERFORMANCE_FIXTURE=str(args.fixture),PERFORMANCE_GLASS=args.glass,LARGE_PDF_BENCHMARK='1',
        TEST_RUNNER_LARGE_PDF_BENCHMARK='1',TEST_RUNNER_PERFORMANCE_RUNSET=runset)
    log = args.output/'test.log'
    with log.open('w') as output:
        subprocess.run(['python3',str(ROOT/'scripts/run_toolbar_ui_checks.py'),args.simulator,
            '-only-testing:ToolbarUITests/LargePDFPerformanceUITests', *(['-test-iterations',str(args.runs)] if args.runs > 1 else [])],env=env,stdout=output,stderr=subprocess.STDOUT,check=True)
    if before != hashes(args.source_root): raise RuntimeError('shipping source changed during benchmark')
    container = Path(subprocess.check_output(['xcrun','simctl','get_app_container',args.simulator,'com.percuscore.reader.toolbar-testhost','data'],env=env,text=True).strip())
    records = [json.loads(p.read_text()) for p in sorted((container/'Documents'/('metrics-'+runset)).glob('*.json'))]
    if len(records)!=args.runs: raise RuntimeError(f'expected {args.runs} records, got {len(records)}; inspect {log}')
    if fixture_identity(args.fixture) != identity or any(r.get('fixture_sha256') != identity for r in records):
        raise RuntimeError('fixture identity mismatch')
    (args.output/'raw.jsonl').write_text(''.join(json.dumps(r,sort_keys=True)+'\n' for r in records))
    summary = dict(glass=args.glass,runs=args.runs,fixture_bytes=args.fixture.stat().st_size,fixture_sha256=identity,simulator=args.simulator,metrics=summarize(records))
    (args.output/'summary.json').write_text(json.dumps(summary,indent=2,sort_keys=True))
    print(json.dumps(summary,indent=2))

if __name__=='__main__': main()
