"""Decision log: one JSON line per guard decision, with secrets masked."""
from __future__ import annotations

import json
import os
import re

_HEREDOC = re.compile(r"<<-?[ \t]*(['\"]?)(\w+)\1([^\n]*)\n.*?(?:\n[ \t]*\2[ \t]*(?=\n|$)|\Z)", re.DOTALL)
_VAL = r"(?:\"[^\"]*\"|'[^']*'|[^\s&'\"]+)"
_BEARER = re.compile(r"(?i)\b(bearer)\s+" + _VAL)
_LONGOPT = re.compile(r"(?i)(--(?:password|passwd|token|secret|api-?key))[ =]" + _VAL)
_SECRET = re.compile(r"(?i)\b(\w*(?:password|passwd|token|secret|api[_-]?key|key))[ \t]*([:=])[ \t]*" + _VAL)
_USERPASS = re.compile(r"(?i)((?:^|\s)(?:-u|--user)[ =]['\"]?[^\s:'\"]+):[^\s'\"]+")
_CAP = 300


def mask(text: str) -> str:
    text = _HEREDOC.sub(lambda m: "<<heredoc>>" + m.group(3), text)
    text = _BEARER.sub(lambda m: m.group(1) + " ***", text)
    text = _LONGOPT.sub(lambda m: m.group(1) + " ***", text)
    text = _SECRET.sub(lambda m: m.group(1) + m.group(2) + "***", text)
    text = _USERPASS.sub(lambda m: m.group(1) + ":***", text)
    return text[:_CAP]


def append(path: str, entry: dict) -> None:
    try:
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        line = json.dumps(entry, ensure_ascii=False) + "\n"
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8", errors="replace") as fh:
            fh.write(line)
    except Exception:
        pass


def last_mode(path: str) -> str:
    """Mode recorded on the last log line, or "" when unreadable."""
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            fh.seek(max(0, fh.tell() - 65536))
            lines = fh.read().decode("utf-8", "replace").splitlines()
        return str(json.loads(lines[-1]).get("mode", "")) if lines else ""
    except Exception:
        return ""
