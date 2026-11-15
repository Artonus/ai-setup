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


def _verb_words(policy: dict) -> List[str]:
    words = set()
    for cfg in policy.get("verbGated", {}).values():
        for rv in cfg.get("readVerbs", []):
            toks = [t for t in rv.split() if "*" not in t]
            words.update(toks[:1])
    return sorted(words)


def _tool_rules(inv: Invocation, policy: dict, names: List[str], command: str = "") -> Decision:
    if inv.opaque and _mentions(command or inv.raw, names):
        return _ask("dynamic-sensitive", "command cannot be analysed and mentions a sensitive tool")
    if not inv.argv:
        return Decision()
    if inv.dynamic[0] and (_mentions(command, names) or any(w in _verb_words(policy) for w in inv.argv[1:])):
        return _ask("dynamic-sensitive", "dynamic command name next to a sensitive tool or verb")
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


# ---- path rules ------------------------------------------------------------

_HOME_TMP_VAR = re.compile(r"\$\{(HOME|TMPDIR)\}|\$(HOME|TMPDIR)(?![A-Za-z0-9_])")


def _tmp_alias(p: str) -> str:
    """/private/tmp and /tmp are the same root."""
    return "/tmp" + p[len("/private/tmp") :] if p == "/private/tmp" or p.startswith("/private/tmp/") else p


def _lex(path: str) -> str:
    """Absolute path with `..` resolved but symlinks kept."""
    return _tmp_alias(os.path.normpath(path))


def _real(path: str) -> str:
    return _tmp_alias(os.path.realpath(path))


def _forms(path: str) -> List[str]:
    """The path as written and with symlinks resolved: a rule matches either."""
    return [path, _real(path)]


def resolve_target(word: str, cwd: Optional[str], ctx: Ctx) -> Optional[str]:
    """Absolute path for a word, or None when it is dynamic or cannot be resolved."""
    if not word:
        return None
    if word == "~" or word.startswith("~/"):
        if not ctx.home:
            return None
        word = ctx.home + word[1:]

    def sub(m: "re.Match[str]") -> str:
        if (m.group(1) or m.group(2)) == "HOME":
            return ctx.home or "$"
        return os.environ.get("TMPDIR") or (ctx.tmp_roots[0] if ctx.tmp_roots else "$")

    word = _HOME_TMP_VAR.sub(sub, word)
    if "$" in word or "`" in word or word.startswith(("<(", ">(")):
        return None
    if not os.path.isabs(word):
        if not cwd:
            return None
        word = os.path.join(cwd, word)
    return _lex(word)


def _under(path: str, root: str) -> bool:
    return bool(root) and (path == root or path.startswith(root.rstrip("/") + "/"))


def _expand_home(pattern: str, ctx: Ctx) -> str:
    return ctx.home + pattern[1:] if pattern == "~" or pattern.startswith("~/") else pattern


def _in_any(path: str, patterns: List[str], ctx: Ctx) -> bool:
    roots = [r for p in patterns for r in _forms(_lex(_expand_home(p, ctx)))]
    return any(_under(f, r) for f in _forms(path) for r in roots)


def _is_secret(path: str, policy: dict, ctx: Ctx) -> bool:
    for form in _forms(path):
        if any(fnmatch.fnmatchcase(os.path.basename(form), e) for e in policy.get("secretExcept", [])):
            continue
        for pat in policy.get("secretPaths", []):
            glob = "*/" + pat[3:] if pat.startswith("**/") else _expand_home(pat, ctx)
            if fnmatch.fnmatchcase(form, glob):
                return True
    return False


def _outside(path: str, ctx: Ctx) -> bool:
    roots = [r for r in [ctx.project_dir] + list(ctx.tmp_roots) if r]
    return not any(_under(_real(path), _real(r)) for r in roots)


def _protected(path: Optional[str], policy: dict, ctx: Ctx) -> Decision:
    """ai-setup or protected-path ask for a resolved path; none otherwise."""
    if path is None:
        return Decision()
    ai = policy.get("aiSetup", {})
    if _in_any(path, ai.get("paths", []), ctx):
        return _ask(ai.get("rule", "ai-setup"), ai.get("reason", "change the AI setup in the ai-setup repo"))
    if _in_any(path, policy.get("protectedPaths", []), ctx):
        return _ask("protected-path", "%s is a protected path" % path)
    return Decision()


def _safe_target(path: str, policy: dict) -> bool:
    return any(fnmatch.fnmatchcase(path, g) for g in policy.get("fileRules", {}).get("safeTargets", []))


def _destructive_target(word: str, cwd: Optional[str], policy: dict, ctx: Ctx, verb: str) -> Decision:
    rule = policy.get("fileRules", {}).get("rule", "file-destructive")
    path = resolve_target(word, cwd, ctx)
    if path is None:
        return _ask(rule, "%s target %s is dynamic or cannot be resolved" % (verb, word))
    if _safe_target(path, policy):
        return Decision()
    prot = _protected(path, policy, ctx)
    if prot.decision != "none":
        return prot
    if _outside(path, ctx):
        return _ask(rule, "%s target %s is outside the project" % (verb, path))
    return Decision()


def _write_target(word: str, cwd: Optional[str], policy: dict, ctx: Ctx, verb: str) -> Decision:
    """Overwrite of a path: protected always asks, other paths only when they exist."""
    cfg = policy.get("fileRules", {})
    path = resolve_target(word, cwd, ctx)
    if path is None:
        return _ask(cfg.get("rule", "file-destructive"), "%s target %s is dynamic or cannot be resolved" % (verb, word))
    if _safe_target(path, policy):
        return Decision()
    prot = _protected(path, policy, ctx)
    if prot.decision != "none":
        return prot
    if os.path.lexists(path) and _outside(path, ctx):
        return _ask(cfg.get("rule", "file-destructive"), "%s overwrites %s outside the project" % (verb, path))
    return Decision()


def _worst(decisions: List[Decision]) -> Decision:
    best = Decision()
    for d in decisions:
        if _ORDER[d.decision] > _ORDER[best.decision]:
            best = d
    return best


def _find_paths(argv: List[str]) -> List[str]:
    paths: List[str] = []
    for a in argv[1:]:
        if re.match(r"^-([HLP]|O\d)$", a) and not paths:
            continue
        if a.startswith("-") or a in ("(", "!"):
            break
        paths.append(a)
    return paths or ["."]


def _file_rules(inv: Invocation, policy: dict, ctx: Ctx, cwd: Optional[str]) -> Decision:
    cfg = policy.get("fileRules", {})
    rule = cfg.get("rule", "file-destructive")
    out: List[Decision] = []
    name = os.path.basename(inv.argv[0]) if inv.argv else ""
    destructive = cfg.get("destructive", {})
    overwrite = cfg.get("overwrite", {})
    if inv.via_xargs and (name in destructive or name in overwrite):
        out.append(_ask(rule, "xargs %s runs with unknown targets" % name))
    elif name in destructive:
        for w, _ in _positionals(inv, destructive[name]):
            out.append(_destructive_target(w, cwd, policy, ctx, name))
    elif name == "find":
        find = cfg.get("find", {})
        argv = inv.argv
        hit = any(a in find.get("actions", []) for a in argv)
        for i, a in enumerate(argv[:-1]):
            if a in find.get("execFlags", []) and os.path.basename(argv[i + 1]) in destructive:
                hit = True
        if hit:
            for w in _find_paths(argv):
                out.append(_destructive_target(w, cwd, policy, ctx, "find"))
    elif name == "dd":
        for a in inv.argv[1:]:
            if a.startswith(cfg.get("ddOutput", "of=")):
                out.append(_destructive_target(a.split("=", 1)[1], cwd, policy, ctx, "dd"))
    elif name in overwrite:
        vopts = overwrite[name]
        pos = [w for w, _ in _positionals(inv, vopts)]
        tdir = None
        for i, a in enumerate(inv.argv[:-1]):
            if a in ("-t", "--target-directory"):
                tdir = inv.argv[i + 1]
        dest, srcs = (tdir, pos) if tdir is not None else ((pos[-1], pos[:-1]) if len(pos) > 1 else (None, []))
        if dest is not None:
            dpath = resolve_target(dest, cwd, ctx)
            if dpath is not None and os.path.isdir(dpath):
                for s in srcs:
                    base = os.path.basename(s.rstrip("/"))
                    if "$" in base or "`" in base:
                        out.append(_ask(rule, "%s source %s is dynamic" % (name, s)))
                    else:
                        out.append(_write_target(os.path.join(dpath, base), cwd, policy, ctx, name))
            else:
                out.append(_write_target(dest, cwd, policy, ctx, name))
    for op, target in inv.redirects:
        if op.lstrip("0123456789") in cfg.get("writeRedirects", []):
            if target.isdigit() or target == "-":
                continue
            out.append(_write_target(target, cwd, policy, ctx, "redirect"))
    return _worst(out)


def _secret_reads(inv: Invocation, policy: dict, ctx: Ctx, cwd: Optional[str]) -> Decision:
    words: List[str] = []
    if inv.argv and os.path.basename(inv.argv[0]) in policy.get("secretReadTools", []):
        words.extend(a for a in inv.argv[1:] if not a.startswith("-") or a == "-")
    words.extend(t for op, t in inv.redirects if op.lstrip("0123456789") == "<")
    for w in words:
        path = resolve_target(w, cwd, ctx)
        if path is not None and _is_secret(path, policy, ctx):
            return Decision("deny", "secret-read", "%s holds secrets; do not read it" % path)
    return Decision()


def _invocation(inv: Invocation, policy: dict, names: List[str], command: str, ctx: Ctx, cwd: Optional[str]) -> Decision:
    return _worst(
        [_tool_rules(inv, policy, names, command), _file_rules(inv, policy, ctx, cwd), _secret_reads(inv, policy, ctx, cwd)]
    )


def _next_cwd(inv: Invocation, cwd: Optional[str], ctx: Ctx) -> Optional[str]:
    """Working directory after the invocation, following `cd` best effort."""
    if not inv.argv or os.path.basename(inv.argv[0]) != "cd":
        return cwd
    args = [a for a in inv.argv[1:] if a != "--" and not (a.startswith("-") and a != "-")]
    if not args:
        return _lex(ctx.home) if ctx.home else None
    return resolve_target(args[0], cwd, ctx)


def explain_bash(command: str, policy: dict, ctx: Ctx) -> List[Tuple[Invocation, Decision]]:
    names = _sensitive_names(policy)
    cwd: Optional[str] = ctx.cwd or ctx.project_dir or None
    out: List[Tuple[Invocation, Decision]] = []
    for inv in unwrap(parse_command(command)):
        out.append((inv, _invocation(inv, policy, names, command, ctx, cwd)))
        cwd = _next_cwd(inv, cwd, ctx)
    return out


def decide_bash(command: str, policy: dict, ctx: Ctx) -> Decision:
    return _worst([d for _, d in explain_bash(command, policy, ctx)])


def decide_path(tool: str, path: str, policy: dict, ctx: Ctx) -> Decision:
    """Decision for a file tool (Write, Edit, MultiEdit, NotebookEdit, Read)."""
    kind = policy.get("pathTools", {}).get(str(tool).lower())
    if kind is None:
        return Decision()
    cwd = ctx.cwd or ctx.project_dir or None
    resolved = resolve_target(path, cwd, ctx)
    if resolved is None:
        if kind == "read":
            return Decision()
        return _ask("protected-path", "%s path %s is dynamic or cannot be resolved" % (tool, path))
    if kind == "read":
        if _is_secret(resolved, policy, ctx):
            return Decision("deny", "secret-read", "%s holds secrets; do not read it" % resolved)
        return Decision()
    prot = _protected(resolved, policy, ctx)
    if prot.decision != "none":
        return prot
    if _outside(resolved, ctx):
        return _ask("protected-path", "%s writes %s outside the project" % (tool, resolved))
    return Decision()
