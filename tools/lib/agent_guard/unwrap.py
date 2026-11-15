"""Strip command wrappers and follow nested shells to find inner commands."""
from __future__ import annotations

import os
import re
from typing import Callable, Dict, List, Optional, Set

from .parse import MAX_DEPTH, Invocation, parse_command

_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_SHELLS = {"sh", "bash", "zsh"}


def _clone(inv: Invocation, argv: List[str], dyn: List[bool], **kw: bool) -> Invocation:
    return Invocation(
        argv=argv,
        dynamic=dyn,
        redirects=list(inv.redirects),
        raw=inv.raw,
        opaque=kw.get("opaque", inv.opaque),
        via_xargs=kw.get("via_xargs", inv.via_xargs),
    )


def _skip_opts(args: List[str], with_arg: Set[str], stop_assign: bool = False) -> int:
    """Index of the first non-option word in args."""
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            return i + 1
        if stop_assign and _ASSIGN.match(a):
            i += 1
            continue
        if not a.startswith("-") or a == "-":
            return i
        i += 2 if a in with_arg else 1
    return i


def _rest(inv: Invocation, start: int) -> List[Invocation]:
    if start >= len(inv.argv):
        return []
    return [_clone(inv, inv.argv[start:], inv.dynamic[start:])]


def _wrapper_offset(name: str, args: List[str]) -> Optional[int]:
    """Offset into args where the wrapped command starts, or None if name is no wrapper."""
    if name == "env":
        return _skip_opts(args, {"-u", "-C", "-S"}, stop_assign=True)
    if name == "timeout":
        i = _skip_opts(args, {"-s", "-k", "--signal", "--kill-after"})
        return i + 1  # the duration
    if name in ("nohup", "builtin"):
        return 0
    if name == "time":
        return _skip_opts(args, set())
    if name == "command":
        if any(a in ("-v", "-V") for a in args[:2]):
            return len(args)  # lookup only, nothing runs
        return _skip_opts(args, set())
    if name == "exec":
        return _skip_opts(args, {"-a"})
    if name == "sudo":
        return _skip_opts(args, {"-u", "-g", "-h", "-C", "-D", "-p", "-r", "-t", "-T", "-U"}, stop_assign=True)
    return None


def _shell_script(args: List[str]) -> Optional[str]:
    for i, a in enumerate(args):
        if a.startswith("--") or not a.startswith("-"):
            return None
        if "c" in a[1:]:
            return args[i + 1] if i + 1 < len(args) else None
    return None


def _xargs_offset(args: List[str]) -> int:
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            return i + 1
        if not a.startswith("-") or a == "-":
            return i
        i += 2 if a in {"-I", "-n", "-P", "-L", "-s", "-d", "-E", "-a", "-l"} else 1
    return i


def _ssh_command(args: List[str]) -> List[str]:
    with_arg = {"-p", "-l", "-i", "-o", "-F", "-J", "-L", "-R", "-D", "-b", "-c", "-e", "-m", "-O", "-S", "-w", "-W", "-E", "-B", "-I"}
    i = _skip_opts(args, with_arg)
    return args[i + 1 :]  # skip HOST


def _step(inv: Invocation) -> List[Invocation]:
    argv = inv.argv
    if not argv:
        return []
    k = 0
    while k < len(argv) and _ASSIGN.match(argv[k]):
        k += 1
    if k:
        return _rest(inv, k)
    name, args = os.path.basename(argv[0]), argv[1:]

    off = _wrapper_offset(name, args)
    if off is not None:
        return _rest(inv, 1 + off)
    if name in _SHELLS:
        script = _shell_script(args)
        return parse_command(script) if script is not None else []
    if name == "xargs":
        off = _xargs_offset(args)
        if 1 + off >= len(argv):
            return [Invocation(["echo"], [False], list(inv.redirects), inv.raw, inv.opaque, True)]
        return [_clone(inv, argv[1 + off :], inv.dynamic[1 + off :], via_xargs=True)]
    if name == "ssh":
        cmd = _ssh_command(args)
        return parse_command(" ".join(cmd)) if cmd else []
    if name == "kubectl" and "exec" in args and "--" in args:
        idx = argv.index("--")
        if argv.index("exec") < idx:
            return _rest(inv, idx + 1)
    return []


def _expand(inv: Invocation, depth: int) -> List[Invocation]:
    if depth > MAX_DEPTH:
        return []
    res: List[Invocation] = []
    for nxt in _step(inv):
        res.append(nxt)
        res.extend(_expand(nxt, depth + 1))
    return res


def unwrap(invs: List[Invocation]) -> List[Invocation]:
    out: List[Invocation] = []
    for inv in invs:
        out.append(inv)
        out.extend(_expand(inv, 0))
    return out
