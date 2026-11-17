"""Compare the real read-only space preview with an already measured transfer.

Uses the same private million-book shape, two tiny carriers and two retained
caches as the completed transfer benchmark. It does not repeat file movement.
Observed allocation is sampled file allocation, not an exact volume/quota peak.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

from benchmark_native_collection_transfer import MemoryJob, footprint, process_memory
from pack_collection import reserve_space


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def run(args):
    if os.name != 'nt' or args.rows < 1:
        raise ValueError('Windows and positive rows are required')
    for name in ('stage', 'binary', 'sqlite', 'sevenzip', 'previous'):
        if Path(getattr(args, name)).resolve().drive.casefold() != 'g:':
            raise ValueError(name+' must be on G:')
    stage=Path(args.stage).resolve(); reserve_space(stage.parent,0); stage.mkdir()
    os.environ.update(HL_TRANSFER_STAGE=str(stage),HL_TRANSFER_CATALOGUE=args.binary,
                      HL_TRANSFER_SQLITE=args.sqlite,HL_TRANSFER_7ZIP=args.sevenzip,
                      TEMP=str(stage),TMP=str(stage))
    import test_native_collection_transfer_catalogue as fixture
    import test_native_collection_transfer_completion as completion
    from benchmark_native_collection_transfer_completion import data_guard
    old_path=Path(args.previous); previous=json.loads(old_path.read_text(encoding='utf-8'))
    assert previous['status']=='PASS' and previous['private_runtime_removed']
    old_inputs=json.loads((old_path.parent/'inputs.json').read_text(encoding='utf-8'))
    core={name:digest for name,digest in old_inputs.items() if
          name.startswith('Program/Units/unit_CollectionTransfer') or
          name.startswith('Program/DAO/SQLite/') or 'SQLiteWrap' in name or
          'SQLiteProfile' in name or name.endswith('unit_BookCompressionPlanStore.pas')}
    assert core
    for name,digest in core.items():
        assert sha(fixture.REPO/name)==digest,name
    report=dict(status='RUNNING',rows=args.rows,platform=args.platform,
                native_sha256=sha(args.binary),script_sha256=sha(__file__),
                previous_report=str(old_path),previous_report_sha256=sha(old_path),
                unchanged_transfer_sqlite_inputs=core,samples=0,phase='setup',
                peak=dict(logical=0,allocated=0),native_memory_peak={},
                minimum_system_free=shutil.disk_usage('C:/').free,private_runtime_removed=False)
    def save():
        temporary=stage/'progress.new'
        temporary.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
        temporary.replace(stage/'progress.json')
    save(); case=completion.TransferCompletionTests('runTest'); home=None
    process=job=None
    try:
        case.setUp(); home=case.home
        report['private_runtime']=str(home); save()
        def rows():
            for i in range(args.rows):
                if i%5000==0:reserve_space(stage,0)
                yield (1000+i,str(1000+i),'Scale row '+str(i),'same.zip','101','.fb2',800+i,'',0)
        with fixture.connect(case.catalogue) as db:
            db.executemany('INSERT INTO Books(BookID,LibID,Title,Folder,FileName,Ext,BookSize,UpdateDate,InsideNo) VALUES(?,?,?,?,?,?,?,?,?)',rows())
        with fixture.connect(case.catalogue) as source,fixture.connect(case.cache_a/'catalog.hlc2') as target:
            source.backup(target)
        report['book_guard']=data_guard(case.catalogue)['Books']
        assert report['book_guard']['rows']==args.rows+3
        if args.rows==previous['extra_rows']:
            assert report['book_guard']==previous['before']['catalogue']['Books']
            report['same_nonlocator_book_rows_as_measured_transfer']=True
        paths=[case.catalogue,case.personal,case.external_index,case.neighbor]
        for root in (case.a,case.b,case.cache_a,case.cache_b):
            paths.extend(p for p in root.rglob('*') if p.is_file())
        protected={str(p):sha(p) for p in paths}
        report['protected_inputs']=protected;report['baseline']=footprint(home)
        case.config.update(mode='create',space_preview=True,prepare=False,cache_prepare_only=False,
                           register_operation=False,probe_prepared_cache_guards=False)
        command=case.command(); job=MemoryJob(2*1024**3); report['phase']='native_preview'; save()
        tick=time.monotonic()
        with (stage/'native.log').open('wb') as log,(stage/'samples.jsonl').open('w',encoding='utf-8') as samples:
            process=subprocess.Popen(command,cwd=home,stdout=log,stderr=subprocess.STDOUT,
                creationflags=subprocess.CREATE_NO_WINDOW|subprocess.BELOW_NORMAL_PRIORITY_CLASS,
                env={**os.environ,'TEMP':str(home),'TMP':str(home)})
            job.attach(process);report['pid']=process.pid;save()
            while True:
                terminal=process.poll();reserve_space(stage,0)
                current=footprint(home);memory=process_memory(process) or {}
                for key,value in current.items():report['peak'][key]=max(report['peak'][key],value)
                for key,value in memory.items():report['native_memory_peak'][key]=max(report['native_memory_peak'].get(key,0),value)
                report['minimum_system_free']=min(report['minimum_system_free'],shutil.disk_usage('C:/').free)
                report['seconds']=round(time.monotonic()-tick,3);report['job_peak_commit']=job.peak();report['samples']+=1
                samples.write(json.dumps(dict(seconds=report['seconds'],runtime=current,memory=memory))+'\n');samples.flush();save()
                if terminal is not None:break
                if report['seconds']>args.timeout:raise TimeoutError('Read-only native preview timed out')
                time.sleep(.5)
        report['returncode']=process.returncode
        assert process.returncode==0,(stage/'native.log').read_text(encoding='utf-8',errors='replace')[-4000:]
        result=json.loads(case.result.read_text(encoding='utf-8-sig'));report['result']=result;save()
        assert result['status']=='PASS'
        assert result['preview_bindings']==args.rows+5 and result['preview_files']==2
        assert result['preview_references']>=args.rows+3
        assert len({row['key'] for row in result['space']})==len(result['space'])
        for row in result['space']:
            assert row['required']==sum(row[key] for key in ('books','working','caches','catalogues','reserve'))
        work=next(row for row in result['space'] if row['books']>0)
        assert work['books']==sum(p.stat().st_size for p in (case.a/'same.zip',case.b/'same.zip'))
        assert work['reserve']==512*1024**2
        assert any(row['reserve']==8*1024**3 for row in result['space'])
        assert {str(p):sha(p) for p in paths}==protected
        assert not case.control.exists() and not list(case.destination.iterdir())
        assert not list(case.work.glob('collection-transfer-*')) and not list(case.work.glob('collection-plan-*'))
        report['protected_inputs_unchanged']=True;report['no_destination_or_registered_move']=True
        report['preview_extra_allocated']=max(0,report['peak']['allocated']-report['baseline']['allocated'])
        report['forecast_additional_without_reserve']=work['required']-work['reserve']
        if args.rows==previous['extra_rows']:
            observed=max(phase['peak']['allocated'] for phase in previous['phases'])-previous['baseline']['allocated']
            report['previous_observed_extra_allocated']=observed
            report['forecast_minus_observed']=report['forecast_additional_without_reserve']-observed
            assert report['forecast_minus_observed']>=0,'Forecast is below the same-shape measured transfer allocation'
        assert report['forecast_additional_without_reserve']>=report['preview_extra_allocated']
        report['status']='PASS_NATIVE_SPACE_PREVIEW_VS_MEASURED_TRANSFER';report['phase']='done';save()
    except Exception as error:
        report.update(status='FAIL',error=str(error));save();raise
    finally:
        if process is not None and process.poll() is None:process.kill();process.wait(timeout=15)
        if job:job.close()
        if home is not None:
            case.tearDown();report['private_runtime_removed']=not home.exists()
        save();(stage/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({key:report[key] for key in ('status','rows','seconds','private_runtime_removed','forecast_additional_without_reserve','preview_extra_allocated')}),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('stage','binary','sqlite','sevenzip','previous','platform'):parser.add_argument('--'+name,required=True)
    parser.add_argument('--rows',type=int,default=1_000_000)
    parser.add_argument('--timeout',type=float,default=1200)
    run(parser.parse_args())
