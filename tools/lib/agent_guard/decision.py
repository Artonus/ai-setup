"""Shared decision entry used by every adapter: decide, log, report the mode."""
from __future__ import annotations

import os
import time

from agent_guard import log
from agent_guard.rules import Ctx, decide_bash, decide_path, load_policy

_MODES = ("shadow", "enforce")


def make_ctx(cwd: str = "", project_dir: str = "") -> Ctx:
    cwd = cwd or os.getcwd()
    tmp = os.environ.get("TMPDIR", "/tmp")
    return Ctx(cwd, project_dir or os.environ.get("CLAUDE_PROJECT_DIR") or cwd, os.path.expanduser("~"), [tmp, "/tmp"])


def run_decision(request: dict, policy_path: str, log_path: str) -> dict:
    mode = "shadow"
    decision, rule, reason = "ask", "guard-error", "agent-guard failed; asking to be safe"
    req = request if isinstance(request, dict) else {}
    try:
        try:
            policy = load_policy(policy_path)
            if not isinstance(policy.get("mode"), str) or policy["mode"] not in _MODES:
                raise ValueError("policy mode must be shadow or enforce")
            mode = policy["mode"]
        except Exception:
            last = log.last_mode(log_path)
            mode = "enforce" if last == "enforce" else "shadow"
            raise
        if not isinstance(request, dict):
            raise ValueError("request is not a JSON object")
        ctx = make_ctx(str(req.get("cwd") or ""), str(req.get("project_dir") or ""))
        tool = str(req.get("tool") or "").lower()
        if tool == "bash":
            d = decide_bash(str(req.get("command") or ""), policy, ctx)
        else:
            d = decide_path(tool, str(req.get("path") or ""), policy, ctx)
        decision, rule, reason = d.decision, d.rule, d.reason
        if tool == "bash" and decision != "none":
            command = str(req.get("command") or "")
            if command not in reason:
                reason = "%s: %s" % (reason, command[:200])
    except Exception:
        pass
    try:
        tool = str(req.get("tool") or "").lower()
        subject = req.get("command") if tool == "bash" else req.get("path")
        def text(key: str):
            v = req.get(key, "")
            return v if v is None or isinstance(v, str) else str(v)

        log.append(log_path, {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "source": text("source"),
            "session_id": text("session_id"),
            "agent_id": text("agent_id"),
            "agent_type": text("agent_type"),
            "permission_mode": text("permission_mode"),
            "tool": tool,
            "decision": decision,
            "rule": rule,
            "mode": mode,
            "command": log.mask(str(subject or "")),
        })
    except Exception:
        pass
    return {"decision": decision, "rule": rule, "reason": reason, "mode": mode, "enforced": mode == "enforce"}
