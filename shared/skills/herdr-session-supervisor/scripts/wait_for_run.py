#!/usr/bin/env python3
"""Read-only Herdr lifecycle waiter; Python 3.10+, standard library only."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time


STATES = {'working', 'idle', 'done', 'blocked', 'unknown'}
SETTLED = {'idle', 'done'}


class InspectionRequired(Exception):
    """A value-free reason safe to return without leaking CLI output."""


def positive_int(text):
    value = int(text)
    if value <= 0:
        raise argparse.ArgumentTypeError('must be a positive integer')
    return value


def get_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--agent', required=True, help='Explicit live agent name or pane ID')
    parser.add_argument('--expected-session', required=True, help='Previously verified agent_session.value')
    parser.add_argument('--run-file', required=True, type=Path, help='Durable Markdown run file on this machine')
    parser.add_argument('--timeout-seconds', type=positive_int, default=1800, help='Total wait budget (default 1800); final inspection can add 5 seconds')
    parser.add_argument('--max-events', type=positive_int, default=80, help='Maximum lifecycle waits before inspection (default 80)')
    return parser.parse_args()


def herdr(args, budget_seconds):
    try:
        proc = subprocess.run(
            ['herdr', 'agent', *args], capture_output=True, text=True,
            timeout=max(0.001, budget_seconds), check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise InspectionRequired('wait_timeout') from exc
    except OSError as exc:
        raise InspectionRequired('herdr_unavailable') from exc
    try:
        # CLI server errors may be on stderr rather than stdout.
        payload = json.loads(proc.stdout if proc.stdout.strip() else proc.stderr)
        if not isinstance(payload, dict):
            raise ValueError('invalid payload')
        if proc.returncode or 'error' in payload:
            error = payload.get('error')
            reason = 'wait_timeout' if isinstance(error, dict) and error.get('code') == 'timeout' else 'herdr_command_failed'
            raise InspectionRequired(reason)
        agent = payload['result']['agent']
        if not isinstance(agent, dict) or agent.get('agent_status') not in STATES:
            raise ValueError('invalid agent')
        return agent
    except (ValueError, KeyError, TypeError) as exc:
        raise InspectionRequired('invalid_herdr_response') from exc


def check_identity(agent, expected):
    session = agent.get('agent_session')
    if not isinstance(session, dict) or session.get('value') != expected:
        raise InspectionRequired('session_changed')
    state = agent['agent_status']
    if state in {'blocked', 'unknown'}:
        raise InspectionRequired('agent_' + state)


def read_status(path):
    try:
        text = path.read_text(encoding='utf-8')
    except (OSError, UnicodeError) as exc:
        raise InspectionRequired('invalid_run_file') from exc
    matches = re.findall(r'^status:[ \t]*([^\r\n]*)', text, re.MULTILINE)
    if len(matches) != 1:
        raise InspectionRequired('invalid_run_file')
    status = matches[0].split('#', 1)[0].strip()
    if status not in {'in_progress', 'passed', 'stopped'}:
        raise InspectionRequired('invalid_run_file')
    return status


def snapshot(args, budget):
    agent = herdr(['get', args.agent], budget)
    check_identity(agent, args.expected_session)
    return agent['agent_status'], read_status(args.run_file)


def supervise(args):
    if os.environ.get('HERDR_ENV') != '1':
        raise InspectionRequired('not_in_herdr')
    try:
        return watch(args)
    except InspectionRequired as exc:
        if str(exc) != 'wait_timeout':
            raise
        # No cursor bridges get/wait. A whole turn may have happened between
        # them. Reconcile once on any Herdr/deadline timeout, then return.
        state, status = snapshot(args, 5)
        if status in {'passed', 'stopped'} and state in SETTLED:
            return status
        raise


def watch(args):
    end = time.monotonic() + args.timeout_seconds
    state, status = snapshot(args, min(5, args.timeout_seconds))
    events = 0
    while True:
        # A terminal run is not evidence that the orchestrator has stopped writing.
        if status in {'passed', 'stopped'} and state in SETTLED:
            return status
        if events >= args.max_events:
            raise InspectionRequired('event_limit')
        remaining = end - time.monotonic()
        if remaining <= 0:
            raise InspectionRequired('wait_timeout')
        until = ('idle', 'done', 'blocked', 'unknown') if state == 'working' else ('working', 'blocked', 'unknown')
        command = ['wait', args.agent]
        for target in until:
            command.extend(['--until', target])
        command.extend(['--timeout', str(max(1, int(remaining * 1000)))])
        agent = herdr(command, remaining)
        check_identity(agent, args.expected_session)
        events += 1
        state, status = snapshot(args, max(0.001, min(5, end - time.monotonic())))


def main():
    args = get_args()
    result = {'agent': args.agent, 'run_file': str(args.run_file)}
    try:
        outcome = supervise(args)
        result['outcome'] = outcome
        code = 0 if outcome == 'passed' else 3
    except InspectionRequired as exc:
        result.update(outcome='inspection_required', reason=str(exc))
        code = 2
    except KeyboardInterrupt:
        result.update(outcome='inspection_required', reason='interrupted')
        code = 2
    print(json.dumps(result))
    return code


if __name__ == '__main__':
    raise SystemExit(main())
