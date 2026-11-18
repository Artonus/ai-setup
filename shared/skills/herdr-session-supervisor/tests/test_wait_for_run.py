"""Behavioral CLI tests. The fake replaces only the external Herdr process."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'wait_for_run.py'
FAKE = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['FAKE_ROOT'])
with (root / 'calls').open('a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\\n')
queue = json.loads((root / 'queue').read_text())
if not queue:
    print('Unexpected Herdr call', file=sys.stderr)
    sys.exit(9)
item = queue.pop(0)
(root / 'queue').write_text(json.dumps(queue))
assert sys.argv[1:3] == ['agent', item['op']], sys.argv
if 'run_status' in item:
    (root / 'run.md').write_text('status: ' + item['run_status'] + '\\n')
if 'raw' in item:
    print(item['raw'])
else:
    print(json.dumps({'result': {'agent': {
        'agent_status': item.get('state', 'done'),
        'agent_session': {'value': item.get('session', 'session-original')}
    }}}))
sys.exit(item.get('rc', 0))
'''


def event(op, state='done', **kwargs):
    return dict(op=op, state=state, **kwargs)


class WaitForRunTests(unittest.TestCase):
    def run_waiter(self, queue, status='in_progress', managed=True, extra=()):
        with tempfile.TemporaryDirectory(prefix='herdr waiter ') as tmp:
            root = Path(tmp)
            (root / 'herdr').write_text(FAKE)
            (root / 'herdr').chmod(0o755)
            (root / 'run.md').write_text('status: ' + status + '\n')
            (root / 'queue').write_text(json.dumps(queue))
            env = dict(os.environ, FAKE_ROOT=tmp, HERDR_ENV='1' if managed else '0')
            env['PATH'] = tmp + os.pathsep + env['PATH']
            p = subprocess.run(
                [sys.executable, str(SCRIPT), '--agent', 'worker',
                 '--expected-session', 'session-original', '--run-file', str(root / 'run.md'),
                 '--timeout-seconds', '5', *extra],
                env=env, capture_output=True, text=True, timeout=12,
            )
            self.assertTrue(p.stdout.strip(), p.stderr)
            try:
                result = json.loads(p.stdout)
            except ValueError:
                self.fail(f'Expected one JSON object: {p.stdout!r}; stderr={p.stderr!r}')
            calls = [json.loads(line) for line in (root / 'calls').read_text().splitlines()] if (root / 'calls').exists() else []
            return p.returncode, result, calls

    def test_already_passed_exits_without_waiting(self):
        rc, out, calls = self.run_waiter([event('get')], status='passed')
        self.assertEqual((rc, out['outcome']), (0, 'passed'))
        self.assertEqual(len(calls), 1)

    def test_stopped_is_not_success(self):
        rc, out, _ = self.run_waiter([event('get')], status='stopped')
        self.assertEqual((rc, out['outcome']), (3, 'stopped'))

    def test_idle_dispatch_awaits_new_activity_and_then_settlement(self):
        rc, out, calls = self.run_waiter([
            event('get'), event('wait', 'working'), event('get', 'working'),
            event('wait', 'done', run_status='passed'), event('get'),
        ])
        self.assertEqual((rc, out['outcome']), (0, 'passed'))
        self.assertIn('working', calls[1])
        self.assertNotIn('working', calls[3])
        self.assertTrue(all(c[0] == 'agent' and c[1] in ('get', 'wait') for c in calls))

    def test_working_run_waits_for_settlement_even_if_run_is_passed(self):
        rc, out, calls = self.run_waiter([
            event('get', 'working'), event('wait', run_status='passed'), event('get'),
        ], status='passed')
        self.assertEqual((rc, out['outcome']), (0, 'passed'))
        self.assertEqual(len(calls), 3)

    def test_changed_identity_wins_over_terminal_run(self):
        rc, out, calls = self.run_waiter([event('get', session='another-session')], status='passed')
        self.assertEqual((rc, out['reason']), (2, 'session_changed'))
        self.assertEqual(len(calls), 1)

    def test_identity_checked_in_wait_response(self):
        rc, out, calls = self.run_waiter([
            event('get', 'working'), event('wait', session='another-session'),
        ])
        self.assertEqual((rc, out['reason']), (2, 'session_changed'))
        self.assertEqual(len(calls), 2)

    def test_fresh_snapshot_prevents_success_on_reused_target(self):
        rc, out, _ = self.run_waiter([
            event('get', 'working'), event('wait', run_status='passed'),
            event('get', session='another-session'),
        ])
        self.assertEqual((rc, out['reason']), (2, 'session_changed'))

    def test_blocked_or_unknown_requires_inspection(self):
        for state in ('blocked', 'unknown'):
            with self.subTest(state=state):
                rc, out, calls = self.run_waiter([event('get', state)], status='passed')
                self.assertEqual((rc, out['reason']), (2, 'agent_' + state))
                self.assertEqual(len(calls), 1)

    def test_wait_detects_blocked_background_resume(self):
        rc, out, _ = self.run_waiter([event('get'), event('wait', 'blocked')])
        self.assertEqual((rc, out['reason']), (2, 'agent_blocked'))

    def test_timeout_reconciles_once_then_stops_without_resubmission(self):
        rc, out, calls = self.run_waiter([
            event('get'), event('wait', raw='{"error":{"code":"timeout"}}', rc=1), event('get'),
        ])
        self.assertEqual((rc, out['reason']), (2, 'wait_timeout'))
        self.assertEqual(len(calls), 3)

    def test_terminal_state_reached_during_get_wait_gap_is_found_on_timeout(self):
        rc, out, calls = self.run_waiter([
            event('get'), event('wait', raw='{"error":{"code":"timeout"}}', rc=1, run_status='passed'), event('get'),
        ])
        self.assertEqual((rc, out['outcome']), (0, 'passed'))
        self.assertEqual(len(calls), 3)

    def test_malformed_cli_and_cli_error_fail_closed_without_raw_output(self):
        for reply in ({'raw': 'sensitive invalid json'}, {'raw': '{"error":{"code":"gone","message":"secret"}}', 'rc': 1}):
            with self.subTest(reply=reply):
                rc, out, calls = self.run_waiter([event('get', **reply)])
                self.assertEqual((rc, out['outcome']), (2, 'inspection_required'))
                self.assertNotIn('sensitive', json.dumps(out))
                self.assertNotIn('secret', json.dumps(out))
                self.assertEqual(len(calls), 1)

    def test_invalid_or_ambiguous_run_status_does_not_wait(self):
        for status in ('pending', 'passed\nstatus: in_progress', '\npassed', '\n  passed'):
            with self.subTest(status=status):
                rc, out, calls = self.run_waiter([event('get')], status=status)
                self.assertEqual((rc, out['reason']), (2, 'invalid_run_file'))
                self.assertEqual(len(calls), 1)

    def test_snapshot_timeout_also_reconciles_once(self):
        for prefix in ([], [event('get', 'working'), event('wait')]):
            with self.subTest(prefix=prefix):
                rc, out, calls = self.run_waiter([
                    *prefix, event('get', raw='{"error":{"code":"timeout"}}', rc=1),
                    event('get', run_status='passed'),
                ])
                self.assertEqual((rc, out['outcome']), (0, 'passed'))
                self.assertEqual(len(calls), len(prefix) + 2)

    def test_requires_herdr_environment_before_any_cli_call(self):
        rc, out, calls = self.run_waiter([], managed=False)
        self.assertEqual((rc, out['reason']), (2, 'not_in_herdr'))
        self.assertEqual(calls, [])

    def test_event_limit_avoids_unbounded_repeated_immediate_waits(self):
        rc, out, calls = self.run_waiter([
            event('get'), event('wait', 'working'), event('get', 'working'),
        ], extra=('--max-events', '1'))
        self.assertEqual((rc, out['reason']), (2, 'event_limit'))
        self.assertEqual(len(calls), 3)


if __name__ == '__main__':
    unittest.main()
