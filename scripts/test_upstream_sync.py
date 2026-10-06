import os
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).parent / 'upstream-sync.sh'
SAFE = 'd86d00b5dbab9066384422159712c5b74335937e'

GIT = r'''#!/usr/bin/env python3
import os, sys
a = sys.argv[1:]
s = os.environ['CASE']
with open(os.environ['TRACE'], 'a') as f: f.write('git ' + ' '.join(a) + '\n')
if a[0] == 'rev-parse':
    print('baseline' if s == 'unchanged' else os.environ['SAFE'] if s in ('safe', 'race', 'push_reject') else 'unreviewed')
elif a[0] == 'log':
    commit = os.environ['SAFE'] if s in ('safe', 'race', 'push_reject') else 'unreviewed'
    print(commit + ('\tchange' if '--reverse' in a else ''))
elif a[0] == 'diff': sys.exit(1)
elif a[0] == 'merge-base': sys.exit(1 if s == 'race' else 0)
elif a[0] == 'push': sys.exit(1 if s == 'push_reject' else 0)
'''
GH = r'''#!/usr/bin/env python3
import os, sys
with open(os.environ['TRACE'], 'a') as f: f.write('gh ' + ' '.join(sys.argv[1:3]) + '\n')
if sys.argv[1:3] == ['issue', 'list'] and os.environ['CASE'] == 'existing': print('75')
if sys.argv[1:3] == ['issue', 'create'] and os.environ['CASE'] == 'denied': sys.exit(1)
'''

class SyncTests(unittest.TestCase):
    def run_case(self, case):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            (root / 'scripts').mkdir()
            (root / '.github').mkdir()
            (root / 'bin').mkdir()
            state = root / '.github/upstream-sync-state'
            if case != 'missing': state.write_text('baseline\n')
            (root / 'scripts/upstream-sync.sh').write_text(SCRIPT.read_text())
            for name in ('check.sh', 'upstream-adapt-mips-pipe.sh'):
                (root / 'scripts' / name).write_text('#!/bin/sh\nexit 0\n')
            (root / 'scripts/upstream-diff-report.sh').write_text('#!/bin/sh\nprintf "fixture diff report\\n"\n')
            for name, text in [('git', GIT), ('gh', GH)]:
                path = root / 'bin' / name
                path.write_text(text)
                path.chmod(0o755)
            trace = root / 'trace'
            report = root / 'retained.md'
            env = dict(os.environ, CASE=case, SAFE=SAFE, TRACE=str(trace), UPSTREAM_SYNC_REPORT=str(report))
            env['PATH'] = str(root / 'bin') + os.pathsep + env['PATH']
            result = subprocess.run(['sh', 'scripts/upstream-sync.sh'], cwd=root, env=env, capture_output=True, text=True)
            return result.returncode, result.stdout + result.stderr, state.read_text() if state.exists() else None, trace.read_text() if trace.exists() else '', report.read_text() if report.exists() else None

    def test_missing_baseline_blocks(self):
        code, _, state, trace, report = self.run_case('missing')
        self.assertNotEqual(code, 0)
        self.assertIsNone(state)
        self.assertNotIn('git push', trace)
        self.assertIsNone(report)

    def test_unchanged_no_mutation(self):
        code, _, state, trace, report = self.run_case('unchanged')
        self.assertEqual(code, 0)
        self.assertEqual(state, 'baseline\n')
        self.assertNotIn('gh ', trace)
        self.assertIsNone(report)

    def test_denied_issue_retains_report_and_blocks(self):
        code, output, state, trace, report = self.run_case('denied')
        self.assertNotEqual(code, 0)
        self.assertIn('Could not create', output)
        self.assertIn('Stopping:', output)
        self.assertEqual(state, 'baseline\n')
        self.assertEqual(report, 'fixture diff report\n')
        self.assertNotIn('git push', trace)

    def test_existing_issue_does_not_duplicate(self):
        code, _, state, trace, report = self.run_case('existing')
        self.assertNotEqual(code, 0)
        self.assertNotIn('gh issue create', trace)
        self.assertEqual(state, 'baseline\n')
        self.assertIsNotNone(report)

    def test_concurrent_main_blocks_push_and_ack(self):
        code, output, state, trace, _ = self.run_case('race')
        self.assertNotEqual(code, 0)
        self.assertIn('Main advanced', output)
        self.assertEqual(state, 'baseline\n')
        self.assertNotIn('git push', trace)

    def test_push_rejection_blocks_ack(self):
        code, _, state, trace, _ = self.run_case('push_reject')
        self.assertNotEqual(code, 0)
        self.assertEqual(state, 'baseline\n')
        self.assertNotIn('--force', trace)

    def test_safe_sync_uses_normal_push(self):
        code, _, state, trace, _ = self.run_case('safe')
        self.assertEqual(code, 0)
        self.assertEqual(state, SAFE + '\n')
        self.assertIn('git push origin HEAD:main', trace)
        self.assertNotIn('--force', trace)

if __name__ == '__main__': unittest.main()
