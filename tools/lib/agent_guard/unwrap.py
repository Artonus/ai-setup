"""Strip command wrappers and follow nested shells to find inner commands.

The wrapper, shell, ssh and container tables below are parser knowledge about
how other tools take a command line; they are code on purpose, not policy.
"""
from __future__ import annotations

import os
import re
from typing import Callable, Dict, List, Optional, Set

from .parse import MAX_DEPTH, Invocation, parse_command

_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}


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
    if name == "nice":
        return _skip_opts(args, {"-n", "--adjustment"})
    if name == "ionice":
        return _skip_opts(args, {"-c", "-n", "-p", "-P", "-u", "--class", "--classdata"})
    if name == "watch":
        return _skip_opts(args, {"-n", "--interval"})
    if name == "stdbuf":
        return _skip_opts(args, {"-i", "-o", "-e"})
    if name == "setsid":
        return _skip_opts(args, set())
    if name == "doas":
        return _skip_opts(args, {"-u", "-C"})
    if name == "sudo":
        return _skip_opts(args, {"-u", "-g", "-h", "-C", "-D", "-p", "-r", "-t", "-T", "-U"}, stop_assign=True)
    return None


def shell_script_index(args: List[str]) -> Optional[int]:
    """Index in args of the -c script of a shell invocation, or None."""
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-o", "-O", "+o", "+O"):  # option with a separate argument
            i += 2
            continue
        if a.startswith("--"):  # --norc, --login, --posix, ...
            i += 1
            continue
        if not a.startswith("-"):
            return None  # script file
        if "c" in a[1:]:
            return i + 1 if i + 1 < len(args) else None
        i += 1
    return None


def _shell_script(args: List[str]) -> Optional[str]:
    """The -c script of a shell invocation, or None when it has none."""
    idx = shell_script_index(args)
    return args[idx] if idx is not None else None


def _env_split_string(args: List[str]) -> Optional[str]:
    """Command string given to `env -S`, with the words after it appended."""
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--" or not a.startswith("-") or a == "-":
            return None
        if a in ("-S", "--split-string") and i + 1 < len(args):
            return " ".join(args[i + 1 :])
        if a.startswith("--split-string="):
            return " ".join([a[len("--split-string=") :]] + args[i + 1 :])
        if a.startswith("-S") and not a.startswith("--"):
            return " ".join([a[2:]] + args[i + 1 :])
        i += 2 if a in ("-u", "-C") else 1
    return None


def _find_execs(inv: Invocation) -> List[Invocation]:
    res: List[Invocation] = []
    argv, i = inv.argv, 1
    while i < len(argv):
        if argv[i] in ("-exec", "-execdir", "-ok", "-okdir"):
            j = i + 1
            while j < len(argv) and argv[j] not in (";", "+"):
                j += 1
            if j > i + 1:
                res.append(_clone(inv, argv[i + 1 : j], inv.dynamic[i + 1 : j]))
            i = j
        i += 1
    return res


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
    cmd = args[i + 1 :]  # skip HOST
    return cmd[1:] if cmd[:1] == ["--"] else cmd


_DOCKER_GLOBAL = {"--context", "-c", "-H", "--host", "--config", "-l", "--log-level", "--tlscacert", "--tlscert", "--tlskey",
                  "--connection", "--identity", "--url", "--remote", "-f", "--file", "-p", "--project-name", "--profile",
                  "--project-directory", "--env-file", "--ansi", "--parallel"}
_DOCKER_EXEC = {"-e", "--env", "-u", "--user", "-w", "--workdir", "--env-file", "--detach-keys", "--index"}
_DOCKER_RUN = _DOCKER_EXEC | {"--name", "-v", "--volume", "-p", "--publish", "--network", "--net", "--mount", "--entrypoint",
                              "-l", "--label", "--add-host", "--hostname", "-h", "--platform", "--pull", "--restart",
                              "--cpus", "-m", "--memory", "--cap-add", "--cap-drop", "--device", "--user-ns", "--tmpfs",
                              "--dns", "--link", "--log-driver", "--label-file", "--cidfile", "--pid", "--ipc", "--shm-size",
                              "--ulimit", "--security-opt", "--workdir", "-a", "--attach", "--expose", "--group-add"}


def _container_offset(name: str, args: List[str]) -> Optional[int]:
    """Offset into args of the command a docker/podman exec or run starts, or None."""
    i = _skip_opts(args, _DOCKER_GLOBAL)
    if i >= len(args):
        return None
    base = i
    sub = args[i]
    if sub == "container" and i + 1 < len(args):
        base, sub = i + 1, args[i + 1]
    if sub == "compose" and base + 1 < len(args):
        k = base + 1 + _skip_opts(args[base + 1 :], _DOCKER_GLOBAL)
        if k >= len(args) or args[k] not in ("exec", "run"):
            return None
        base, sub = k, args[k]
    if sub not in ("exec", "run"):
        return None
    rest = args[base + 1 :]
    j = _skip_opts(rest, _DOCKER_EXEC if sub == "exec" else _DOCKER_RUN)
    cmd = base + 1 + j + 1  # skip the container, service or image name
    return cmd if cmd < len(args) else None


def _step(inv: Invocation) -> List[Invocation]:
    argv = inv.argv
    if not argv:
        return []
    k = 0
    while k < len(argv) and _ASSIGN.match(argv[k]):
        k += 1
    if k:
        return _rest(inv, k)
    name, args = os.path.basename(argv[0]).lower(), argv[1:]

    if name == "env":
        split = _env_split_string(args)
        if split is not None:
            return parse_command(split)
    off = _wrapper_offset(name, args)
    if off is not None:
        inv.wrapper = True
        if len(argv) == 2 + off and re.search(r"\s", argv[1 + off]):
            return parse_command(argv[1 + off])  # watch 'a b': one word that is a command line
        return _rest(inv, 1 + off)
    if name in ("docker", "podman", "docker-compose", "podman-compose"):
        pre = ["compose"] if name.endswith("-compose") else []
        off = _container_offset(name, pre + args)
        if off is not None and off - len(pre) >= 0:
            inv.wrapper = True
            return _rest(inv, 1 + off - len(pre))
        return []
    if name in _SHELLS:
        script = _shell_script(args)
        if script is None:
            inv.opaque = True  # reads its script from stdin or a file
            return []
        inv.wrapper = True
        return parse_command(script)
    if name == "su":
        for k, a in enumerate(args):
            if a in ("-c", "--command") and k + 1 < len(args):
                inv.wrapper = True
                return parse_command(args[k + 1])
        return []
    if name == "eval":
        inv.opaque = True
        return []
    if name == "find":
        return _find_execs(inv)
    if name == "xargs":
        off = _xargs_offset(args)
        inv.wrapper = True
        if 1 + off >= len(argv):
            return [Invocation(["echo"], [False], list(inv.redirects), inv.raw, inv.opaque, True)]
        return [_clone(inv, argv[1 + off :], inv.dynamic[1 + off :], via_xargs=True)]
    if name == "ssh":
        cmd = _ssh_command(args)
        if cmd:
            inv.wrapper = True
        return parse_command(" ".join(cmd)) if cmd else []
    if name == "kubectl" and "exec" in args and "--" in args:
        idx = argv.index("--")
        if argv.index("exec") < idx:
            return _rest(inv, idx + 1)
    return []


def _expand(inv: Invocation, depth: int) -> List[Invocation]:
    if depth > MAX_DEPTH:
        return [Invocation([], [], [], inv.raw, opaque=True)]
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
