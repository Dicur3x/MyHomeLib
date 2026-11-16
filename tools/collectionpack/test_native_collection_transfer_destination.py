"""Surviving-destination verification with an independently retained proof."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest

import test_native_collection_transfer_copy as fixture


@unittest.skipUnless(os.name=='nt' and fixture.BINARY and fixture.BINARY.is_file() and
                     fixture.SQLITE and fixture.SQLITE.is_file() and fixture.STAGE,
                     'requires native copy host and private stage')
class TransferDestinationTests(unittest.TestCase):
    setUp=fixture.TransferCopyTests.setUp
    tearDown=fixture.TransferCopyTests.tearDown
    case=fixture.TransferCopyTests.case
    command=fixture.TransferCopyTests.command
    attempt=fixture.TransferCopyTests.attempt
    state=fixture.TransferCopyTests.state
    attempts=0

    def run_case(self,expected=0):
        target=Path(self.config['destination'])
        before_source=fixture.sha(self.source) if self.source.is_file() else None
        before_target=fixture.sha(target) if target.is_file() else None
        process=subprocess.run(self.command(self.config),cwd=self.root,capture_output=True,timeout=60,
            creationflags=subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS,
            env={**os.environ,'TEMP':str(self.root),'TMP':str(self.root)})
        item=dict(test=self.id(),request=dict(self.config),expected=expected,returncode=process.returncode,
                  output=(process.stdout+process.stderr).decode('utf-8',errors='replace'))
        if Path(self.config['result']).exists():item['result']=json.loads(Path(self.config['result']).read_text(encoding='utf-8-sig'))
        with (fixture.STAGE/'invocations.jsonl').open('a',encoding='utf-8') as log:log.write(json.dumps(item,ensure_ascii=False)+'\n')
        if self.config.get('verify_destination'):
            self.assertEqual(fixture.sha(self.source) if self.source.is_file() else None,before_source)
            self.assertEqual(fixture.sha(target) if target.is_file() else None,before_target)
        if expected=='fail':self.assertNotEqual(process.returncode,0,item['output']);return item['output']
        self.assertEqual(process.returncode,expected,item['output'])
        if expected==97:return item
        self.assertEqual(item['result']['status'],'PASS');return item['result']

    def prepared(self,named=False):
        if named:
            with open(str(self.source)+':HomeLibreNote','wb') as stream:stream.write(b'original named data')
        result=self.run_case();self.assertTrue(result['source_held'])
        self.proof=Path(self.config['attempt']).with_name('independent-proof.json')
        self.proof.write_text(json.dumps({k:result[k] for k in ('identity','sha256','streams')}),encoding='utf-8')
        self.config.update(resume=True,verify_destination=True,proof=str(self.proof))
        self.source.unlink()
        return result

    def journal_bytes(self):
        return {p.name:p.read_bytes() for p in Path(self.attempt()['directory']).glob('*.json')}

    def test_missing_source_verifies_without_copying_or_journal_changes(self):
        prepared=self.prepared();before=self.journal_bytes()
        result=self.run_case()
        self.assertFalse(result['source_held']);self.assertEqual(result['copy_streams'],0)
        self.assertEqual(result['sha256'],prepared['sha256']);self.assertEqual(self.journal_bytes(),before)

    def test_missing_source_parent_is_not_recreated(self):
        self.prepared();self.source.parent.rmdir()
        self.run_case();self.assertFalse(self.source.parent.exists())

    def test_reused_original_name_is_not_read_or_changed(self):
        self.prepared();self.source.write_bytes(b'new unrelated file at the old name')
        self.run_case();self.assertEqual(self.source.read_bytes(),b'new unrelated file at the old name')

    def test_normal_prepare_does_not_silently_accept_an_absent_source(self):
        self.prepared();self.config['verify_destination']=False
        self.run_case('fail');self.assertTrue(Path(self.config['destination']).is_file())

    def test_recovered_result_cannot_claim_a_source_lease(self):
        self.prepared();self.config['require_source_check']=True
        self.assertIn('удерживаемой',self.run_case('fail'))

    def test_wrong_independent_hash_is_rejected(self):
        self.prepared();proof=json.loads(self.proof.read_text());proof['sha256']='0'*64
        self.proof.write_text(json.dumps(proof),encoding='utf-8')
        self.run_case('fail')

    def test_rehashed_child_state_cannot_replace_the_independent_proof(self):
        self.prepared();record=sorted(Path(self.attempt()['directory']).glob('state-*.json'))[-1]
        wrapped=json.loads(record.read_text(encoding='utf-8'));payload=json.loads(wrapped['payload'])
        payload['identity']='0'*59
        wrapped['payload']=json.dumps(payload,ensure_ascii=False)
        wrapped['sha256']=hashlib.sha256(wrapped['payload'].encode('utf-8')).hexdigest()
        record.write_text(json.dumps(wrapped,ensure_ascii=False),encoding='utf-8')
        before=self.journal_bytes();self.run_case('fail');self.assertEqual(self.journal_bytes(),before)

    def test_changed_content_with_preserved_size_and_time_is_rejected(self):
        self.prepared();target=Path(self.config['destination']);stamp=target.stat()
        with target.open('r+b') as stream:first=stream.read(1);stream.seek(0);stream.write(bytes([first[0]^1]))
        os.utime(target,ns=(stamp.st_atime_ns,stamp.st_mtime_ns))
        self.assertIn('Контрольные суммы',self.run_case('fail'))

    def test_changed_named_stream_with_preserved_main_time_is_rejected(self):
        self.prepared(named=True);target=Path(self.config['destination']);stamp=target.stat()
        with open(str(target)+':HomeLibreNote','wb') as stream:stream.write(b'modified named data')
        os.utime(target,ns=(stamp.st_atime_ns,stamp.st_mtime_ns))
        self.assertIn('Контрольные суммы',self.run_case('fail'))

    def test_named_stream_proof_survives_without_the_original(self):
        self.prepared(named=True);result=self.run_case()
        self.assertEqual(len(json.loads(result['streams'])),2)
        with open(self.config['destination']+':HomeLibreNote','rb') as stream:self.assertEqual(stream.read(),b'original named data')

    def test_replaced_destination_with_identical_bytes_is_rejected(self):
        self.prepared();target=Path(self.config['destination']);replacement=target.with_name('replacement.zip')
        shutil.copy2(target,replacement)
        self.assertTrue(replacement.resolve().is_relative_to(self.root.resolve()))
        self.assertTrue(target.resolve().is_relative_to(self.root.resolve()))
        os.replace(replacement,target);self.run_case('fail')

    def test_missing_destination_parent_is_not_created(self):
        self.prepared();target=Path(self.config['destination']);target.unlink();target.parent.rmdir()
        self.run_case('fail');self.assertFalse(target.parent.exists())

    def test_cancelled_verification_keeps_the_journal_and_copy(self):
        self.prepared();before=self.journal_bytes();self.config['cancel_verify']=True
        self.assertIn('остановлена',self.run_case('fail'));self.assertEqual(self.journal_bytes(),before)
        self.config['cancel_verify']=False;self.assertEqual(self.run_case()['copy_streams'],0)

    def test_repeated_process_interruption_does_not_acknowledge_or_recopy(self):
        self.prepared();before=self.journal_bytes();self.config['crash']='destination-verified'
        self.run_case(97);self.run_case(97);self.assertEqual(self.journal_bytes(),before)
        self.config['crash']='';self.assertEqual(self.run_case()['copy_streams'],0)


if __name__=='__main__':unittest.main(verbosity=2)
