"""A second real interruption during ordinary native update recovery."""
import json

from supervised_test_process import run_owned


def restart(root, command, *, env, log, startup, deadline, creationflags, point=None):
    arguments = dict(cwd=root, env=env, stdout=log, stderr=log,
                     startupinfo=startup, timeout=deadline, creationflags=creationflags)
    if not point:
        return run_owned(command, **arguments)
    job, = (root / 'Data/LibraryUpdateRecovery').glob('update-*')
    journal_bytes = (job / 'job.json').read_bytes()
    payload = b'Preserve unrelated recovery data.\x00\xff'
    foreign = job / 'unrelated-recovery-note.bin'
    sibling = job.parent / 'unrelated-recovery-sibling.bin'
    assert not foreign.exists() and not sibling.exists()
    foreign.write_bytes(payload)
    sibling.write_bytes(payload)
    arm = root / 'library-recovery-interrupt-arm.json'
    arm.write_text(json.dumps(dict(phase=point)), encoding='utf-8')
    interrupted = run_owned(command, **arguments)
    assert interrupted.returncode == 74, 'Recovery did not terminate at its requested actual stage'
    proof = json.loads((root / 'library-recovery-interrupt-crash.json').read_text(encoding='utf-8-sig'))
    assert proof['phase'] == point
    if point == 'recovery-restore-step':
        assert 0 < proof['copied'] < proof['total'], 'Recovery did not stop inside multi-step SQLite restoration'
    arm.unlink()
    result = run_owned(command, **arguments)
    completed = job.parent / 'completed' / job.name
    assert not job.exists(), 'Resumed recovery did not finish its journal move'
    for path in (completed / foreign.name, sibling):
        assert path.read_bytes() == payload, 'Recovery lost unrelated data'
    assert (completed / 'job.json').read_bytes() == journal_bytes, 'Recovery changed its immutable journal'
    return result
