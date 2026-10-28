"""Run tests with the distributed embedded Python, whose ._pth omits this folder."""
from pathlib import Path
import re
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
names=sys.argv[1:]
if not names or any(not re.fullmatch(r'test_[a-z0-9_]+', name) for name in names):
    raise SystemExit('Pass test module names, without .py')
suite=unittest.defaultTestLoader.loadTestsFromNames(names)
if suite.countTestCases() == 0:
    raise SystemExit('No tests discovered')
result=unittest.TextTestRunner(verbosity=2).run(suite)
raise SystemExit(0 if result.wasSuccessful() else 1)
