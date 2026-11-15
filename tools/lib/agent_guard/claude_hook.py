"""Claude Code PreToolUse hook adapter: translates hook JSON to a decision request."""
from __future__ import annotations

import json
import os

from agent_guard.decision import run_decision

_BASH = "Bash"
_PATH_TOOLS = {"Write": "write", "Edit": "edit", "MultiEdit": "edit", "NotebookEdit": "edit"}


def _s(value) -> str:
    return value if isinstance(value, str) else ""


def _request(data: dict):
    """Build a decision request, or None when the tool is not one we guard."""
    name = data.get("tool_name")
    tool_input = data.get("tool_input")
    if name == _BASH and not (isinstance(tool_input, dict) and isinstance(tool_input.get("command"), str)
                              and tool_input["command"].strip()):
        return "bash call without a command"  # not a request: run_decision treats it as a guard error
    if not isinstance(tool_input, dict):
        tool_input = {}
    cwd = _s(data.get("cwd"))
    req = {
        "source": "claude",
        "cwd": cwd,
        "project_dir": os.environ.get("CLAUDE_PROJECT_DIR") or cwd,
        "session_id": data.get("session_id"),
        "agent_id": data.get("agent_id"),
        "agent_type": data.get("agent_type"),
        "permission_mode": data.get("permission_mode"),
    }
    if name == _BASH:
        req["tool"] = "bash"
        req["command"] = _s(tool_input.get("command"))
    elif name in _PATH_TOOLS:
        req["tool"] = _PATH_TOOLS[name]
        req["path"] = _s(tool_input.get("notebook_path") if name == "NotebookEdit" else tool_input.get("file_path"))
    else:
        return None
    return req


def run_claude_hook(stdin_text: str, policy_path: str, log_path: str) -> tuple:
    """Return (exit_code, stdout). Exit code is always 0; never prints allow."""
    try:
        try:
            data = json.loads(stdin_text)
        except Exception:
            data = None
        if isinstance(data, dict):
            request = _request(data)
            if request is None:
                return 0, ""
        else:
            request = "not an object"  # guard error path
        result = run_decision(request, policy_path, log_path)
        if not result.get("enforced") or result.get("decision") not in ("ask", "deny"):
            return 0, ""
        subject = "Path" if isinstance(request, dict) and request.get("tool") != "bash" else "Command"
        value = request.get("path" if subject == "Path" else "command", "") if isinstance(request, dict) else ""
        out = {"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": result["decision"],
            "permissionDecisionReason": "agent-guard: %s. %s: %s" % (result.get("reason", ""), subject, value),
        }}
        return 0, json.dumps(out)
    except Exception:
        return 0, ""
