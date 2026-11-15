"""Policy rules: turn a shell command into an ask, deny or none decision.

All tool names, verbs and patterns come from the policy file. The guard never
returns "allow": "none" means no opinion, so the normal permission flow runs.
"""
from __future__ import annotations

import fnmatch
import json
import os
import re
from dataclasses import dataclass, field
from typing import List, Optional, Tuple

from agent_guard.parse import Invocation, parse_command
from agent_guard.unwrap import unwrap

_ORDER = {"none": 0, "ask": 1, "deny": 2}


@dataclass
class Decision:
    decision: str = "none"
    rule: str = ""
    reason: str = ""


@dataclass
class Ctx:
    cwd: str = ""
    project_dir: str = ""
    home: str = ""
    tmp_roots: List[str] = field(default_factory=list)


def load_policy(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


Pos = List[Tuple[str, bool]]


def _positionals(inv: Invocation, value_opts: List[str]) -> Pos:
    """Non-option words after argv[0], skipping the values of known options."""
    out: Pos = []
    i, argv = 1, inv.argv
    while i < len(argv):
        a = argv[i]
        if a == "--":
            out.extend(zip(argv[i + 1 :], inv.dynamic[i + 1 :]))
            break
        if a.startswith("-") and a != "-":
            i += 2 if (a in value_opts) else 1
            continue
        out.append((a, inv.dynamic[i]))
        i += 1
    return out


def _matches(pattern: str, pos: Pos) -> Optional[bool]:
    """None: no match. Otherwise True when a matched word was dynamic."""
    toks = pattern.split()
    if len(pos) < len(toks):
        return None
    dyn = False
    for tok, (word, is_dyn) in zip(toks, pos):
        if not fnmatch.fnmatchcase(word, tok):
            return None
        dyn = dyn or (is_dyn and tok != "*")
    return dyn


def _sensitive_names(policy: dict) -> List[str]:
    names = {c.split()[0] for c in policy.get("dbClients", [])}
    names.update(policy.get("verbGated", {}))
    return sorted(names)


def _mentions(raw: str, names: List[str]) -> bool:
    return any(re.search(r"(?<![\w.-])" + re.escape(n) + r"(?![\w-])", raw) for n in names)


def _ask(rule: str, reason: str) -> Decision:
    return Decision("ask", rule, reason)


def _git(inv: Invocation, policy: dict) -> Decision:
    cfg = policy.get("git", {})
    pos = _positionals(inv, cfg.get("valueOpts", []))
    if not pos:
        return Decision()
    verb = pos[0][0]
    rest = inv.argv[1:]
    # words after the verb, including options
    try:
        rest = inv.argv[inv.argv.index(verb, 1) + 1 :]
    except ValueError:
        pass
    for pat in cfg.get("patterns", []):
        if pat.get("verb") != verb:
            continue
        hit = False
        if "sub" in pat and len(pos) > 1 and pos[1][0] in pat["sub"]:
            hit = True
        for a in rest:
            if a in pat.get("args", []) or any(a.startswith(p) for p in pat.get("argPrefixes", [])):
                hit = True
            elif a.startswith("-") and not a.startswith("--") and any(c in a[1:] for c in pat.get("shortChars", [])):
                hit = True
        if hit:
            return _ask(cfg.get("rule", "git-destructive"), pat.get("reason", "git %s" % verb))
    return Decision()


def _cloud(inv: Invocation, name: str, policy: dict) -> Decision:
    gated = policy.get("verbGated", {}).get(name, {})
    pos = _positionals(inv, gated.get("valueOpts", []))
    for r in policy.get("cloudRules", []):
        if r.get("tool") == name and _matches(r["match"], pos) is not None:
            if any(_matches(e, pos) is not None for e in r.get("except", [])):
                continue
            return _ask(r["rule"], r["reason"])
    return Decision()


def _gated(inv: Invocation, name: str, policy: dict) -> Decision:
    cfg = policy["verbGated"][name]
    rule = cfg.get("rule", "cluster-mutation")
    pos = _positionals(inv, cfg.get("valueOpts", []))
    if not pos:
        return Decision()
    cloud = _cloud(inv, name, policy)
    if cloud.decision != "none":
        return cloud
    if pos[0][1]:
        return _ask("dynamic-sensitive", "%s with a dynamic verb or target" % name)
    for rv in cfg.get("readVerbs", []):
        if _matches(rv, pos) is False:
            return Decision()
    verb = " ".join(w for w, _ in pos[:2]) if name in ("aws",) else pos[0][0]
    return _ask(rule, "%s %s is not a read verb" % (name, verb))


def _invocation(inv: Invocation, policy: dict, names: List[str]) -> Decision:
    if inv.opaque and _mentions(inv.raw, names):
        return _ask("dynamic-sensitive", "command cannot be analysed and mentions a sensitive tool")
    if not inv.argv:
        return Decision()
    name = os.path.basename(inv.argv[0])
    if name in policy.get("failClosedTools", []):
        return _ask("dynamic-sensitive", "%s hides the command that runs" % name)
    if inv.via_xargs and name in names:
        return _ask("dynamic-sensitive", "xargs %s runs with unknown targets" % name)
    for client in policy.get("dbClients", []):
        parts = client.split()
        if name != parts[0]:
            continue
        if len(parts) == 1:
            return _ask("db-client", "%s is a database client" % name)
        pos = _positionals(inv, policy.get("verbGated", {}).get(name, {}).get("valueOpts", []))
        if [w for w, _ in pos[: len(parts) - 1]] == parts[1:]:
            return _ask("db-client", "%s is a database client" % client)
    if name in policy.get("verbGated", {}):
        return _gated(inv, name, policy)
    if name == "git":
        return _git(inv, policy)
    return Decision()


def explain_bash(command: str, policy: dict, ctx: Ctx) -> List[Tuple[Invocation, Decision]]:
    names = _sensitive_names(policy)
    return [(inv, _invocation(inv, policy, names)) for inv in unwrap(parse_command(command))]


def decide_bash(command: str, policy: dict, ctx: Ctx) -> Decision:
    best = Decision()
    for _, d in explain_bash(command, policy, ctx):
        if _ORDER[d.decision] > _ORDER[best.decision]:
            best = d
    return best
