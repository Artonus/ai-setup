"""Policy rules: turn a shell command into an ask, deny or none decision.

Tool names, verbs, paths and patterns come from the policy file. The one
exception is parser knowledge about how wrappers (sudo, env, docker exec, ssh,
sh -c) hand a command line to another tool: those tables live in unwrap.py.
The guard never returns "allow": "none" means no opinion, so the normal
permission flow runs.
"""
from __future__ import annotations

import fnmatch
import glob
import itertools
import json
import os
import re
from dataclasses import dataclass, field
from typing import List, Optional, Tuple

from agent_guard.parse import Invocation, parse_command
from agent_guard.unwrap import shell_script_index, unwrap

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


def _git_config(inv: Invocation, cfg: dict) -> Optional[Decision]:
    """Ask when a `git -c key=value` before the verb can run a command."""
    argv, i = inv.argv, 1
    while i < len(argv):
        a = argv[i]
        if a == "-c" and i + 1 < len(argv):
            key = argv[i + 1].partition("=")[0].lower()
            if any(fnmatch.fnmatchcase(key, p.lower()) for p in cfg.get("dangerousConfig", [])):
                return _ask("dynamic-sensitive", "%s (-c %s)" % (cfg.get("dangerousReason", "git -c can run a command"), key))
            i += 2
        elif a in cfg.get("valueOpts", []):
            i += 2
        elif a.startswith("-"):
            i += 1
        else:
            break
    return None


def _git(inv: Invocation, policy: dict) -> Decision:
    cfg = policy.get("git", {})
    dangerous = _git_config(inv, cfg)
    if dangerous:
        return dangerous
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
        hit = bool(pat.get("always"))
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


def _name(inv: Invocation) -> str:
    """Lower-cased basename of argv[0]: APFS is case-insensitive, so PSQL runs psql."""
    return os.path.basename(inv.argv[0]).lower() if inv.argv else ""


def _inline(inv: Invocation, policy: dict) -> bool:
    """True for python -c, node -e and similar: the script text hides other tools."""
    name = _name(inv)
    flags = policy.get("inlineInterpreters", {}).get(name) or policy.get("inlineInterpreters", {}).get(name.rstrip("0123456789."))
    if not flags:
        return False
    return any(a in flags or any(f.startswith("--") and a.startswith(f + "=") for f in flags) for a in inv.argv[1:])


def _dynamic_script(inv: Invocation, policy: dict) -> bool:
    """sh -c "$CMD": a script that is itself dynamic, like eval."""
    if _name(inv) not in policy.get("dynamicScriptShells", []):
        return False
    idx = shell_script_index(inv.argv[1:])
    if idx is None or not inv.dynamic[1 + idx]:
        return False
    return any(i.opaque or not i.argv or i.dynamic[0] for i in parse_command(inv.argv[1 + idx]))


def _tool_rules(
    inv: Invocation, policy: dict, names: List[str], command: str = "", verbs: Optional[List[str]] = None,
    opaque_names: Optional[List[str]] = None,
) -> Decision:
    verbs = _verb_words(policy) if verbs is None else verbs
    if (inv.opaque or _inline(inv, policy)) and _mentions(command or inv.raw, opaque_names or names):
        return _ask("dynamic-sensitive", "command cannot be analysed and mentions a sensitive tool")
    if not inv.argv:
        return Decision()
    git_cfg = policy.get("git", {})
    if inv.argv[0].startswith(tuple(e + "=" for e in git_cfg.get("dangerousEnv", ()))) or (
        _name(inv) == "env" and any(a.startswith(tuple(e + "=" for e in git_cfg.get("dangerousEnv", ()))) for a in inv.argv[1:])
    ):
        return _ask("dynamic-sensitive", git_cfg.get("dangerousReason", "environment can run a command"))
    if inv.dynamic[0] and (_mentions(command, names) or any(w in verbs for w in inv.argv[1:])):
        return _ask("dynamic-sensitive", "dynamic command name next to a sensitive tool or verb")
    name = _name(inv)
    if name in policy.get("failClosedTools", []):
        return _ask("dynamic-sensitive", "%s hides the command that runs" % name)
    if _dynamic_script(inv, policy):
        return _ask("dynamic-sensitive", "%s -c runs a dynamic script that hides the command" % name)
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
    elif word.startswith("~"):  # ~user, ~+, ~-: a user's home, only when it resolves
        user, slash, rest = word[1:].partition("/")
        home = os.path.expanduser("~" + user) if re.match(r"^[A-Za-z_][A-Za-z0-9_.-]*$", user) else "~"
        if home.startswith("~"):
            return None
        word = home + slash + rest

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


def _project_guard(path: str, policy: dict, ctx: Ctx, root_counts: bool = True) -> str:
    """Reason when path is the project root, an ancestor of a protected entry, or inside one."""
    if not ctx.project_dir:
        return ""
    protected = policy.get("fileRules", {}).get("protectedInProject", [])
    for form in _forms(path):
        for root in {_lex(ctx.project_dir), _real(ctx.project_dir)}:
            if root_counts and form == root:
                return "the project root"
            wild = policy.get("fileRules", {}).get("rootWildcard")
            if root_counts and wild and re.match(wild, os.path.basename(form)) and os.path.dirname(form) == root:
                return "every file in the project root"
            for name in protected:
                prot = os.path.join(root, name)
                if _under(form, prot) or (root_counts and _under(prot, form)):
                    return os.path.join(root, name)
    return ""


def _destructive_target(
    word: str, cwd: Optional[str], policy: dict, ctx: Ctx, verb: str, root_counts: bool = True
) -> Decision:
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
    hit = _project_guard(path, policy, ctx, root_counts)
    if hit:
        return _ask(rule, "%s target %s would remove %s" % (verb, path, hit))
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


def _in_place(inv: Invocation, name: str, cfg: dict, policy: dict, ctx: Ctx, cwd: Optional[str]) -> List[Decision]:
    """sed -i / perl -i: the file operands are overwritten."""
    args = inv.argv[1:]
    inplace, skip = False, False
    for a in args:
        if skip:
            skip = False
        elif a in cfg.get("valueOpts", []):
            skip = True
        elif a in cfg.get("long", []) or any(f.startswith("--") and a.startswith(f + "=") for f in cfg.get("long", [])):
            inplace = True
        elif a.startswith("-") and not a.startswith("--") and "i" in a[1:]:
            inplace = True
    if not inplace:
        return []
    words = [w for w, _ in _positionals(inv, cfg.get("valueOpts", [])) if w != ""]
    if not any(a in cfg.get("scriptOpts", []) for a in args):
        words = words[1:]  # the first operand is the script
    return [_write_target(w, cwd, policy, ctx, name) for w in words]


def _rsync(inv: Invocation, cfg: dict, policy: dict, ctx: Ctx, cwd: Optional[str]) -> List[Decision]:
    """rsync --delete: the destination loses files that are not in the source."""
    if not any(a.startswith(tuple(cfg.get("deletePrefixes", ["--delete"]))) for a in inv.argv[1:]):
        return []
    pos = [w for w, _ in _positionals(inv, cfg.get("valueOpts", []))]
    if len(pos) < 2:
        return []
    dest = pos[-1]
    rule = policy.get("fileRules", {}).get("rule", "file-destructive")
    if re.match(r"^[^/]*:", dest):
        return [_ask(rule, "rsync --delete to remote %s" % dest)]
    return [_destructive_target(dest, cwd, policy, ctx, "rsync --delete", False)]


def _file_rules(inv: Invocation, policy: dict, ctx: Ctx, cwd: Optional[str]) -> Decision:
    cfg = policy.get("fileRules", {})
    rule = cfg.get("rule", "file-destructive")
    out: List[Decision] = []
    name = _name(inv)
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
        unfiltered = not any(a in find.get("filters", []) for a in argv)
        for i, a in enumerate(argv[:-1]):
            if a in find.get("execFlags", []) and os.path.basename(argv[i + 1]).lower() in destructive:
                hit = True
        if hit:
            for w in _find_paths(argv):
                out.append(_destructive_target(w, cwd, policy, ctx, "find", unfiltered))
    elif name == "dd":
        for a in inv.argv[1:]:
            if a.startswith(cfg.get("ddOutput", "of=")):
                out.append(_destructive_target(a.split("=", 1)[1], cwd, policy, ctx, "dd"))
    elif name in overwrite:
        vopts = overwrite[name]
        pos = [w for w, _ in _positionals(inv, vopts)]
        if name in cfg.get("moveSources", []):
            for w in pos:
                p = resolve_target(w, cwd, ctx)
                hit = _project_guard(p, policy, ctx) if p else ""
                if hit:
                    out.append(_ask(rule, "%s of %s would remove %s" % (name, w, hit)))
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
    elif name in cfg.get("tee", {}).get("tools", []):
        for w, _ in _positionals(inv, cfg.get("tee", {}).get("valueOpts", [])):
            out.append(_write_target(w, cwd, policy, ctx, name))
    elif name in cfg.get("inPlace", {}):
        out.extend(_in_place(inv, name, cfg["inPlace"][name], policy, ctx, cwd))
    elif name == "rsync":
        out.extend(_rsync(inv, cfg.get("rsync", {}), policy, ctx, cwd))
    for op, target in inv.redirects:
        if op.lstrip("0123456789") in cfg.get("writeRedirects", []):
            if target.isdigit() or target == "-":
                continue
            out.append(_write_target(target, cwd, policy, ctx, "redirect"))
    return _worst(out)


_GLOB_CHARS = re.compile(r"[*?\[]")


def _safe_tool(inv: Invocation, policy: dict) -> bool:
    """Tools that name a path without reading its content (ls, chmod, git add ...)."""
    name = _name(inv)
    for entry in policy.get("secretSafeTools", []):
        parts = entry.split()
        if parts[0] != name:
            continue
        if len(parts) == 1:
            return True
        pos = [w for w, _ in _positionals(inv, policy.get("git", {}).get("valueOpts", []) if name == "git" else [])]
        if pos[: len(parts) - 1] == parts[1:]:
            return True
    return False


def _candidates(word: str) -> List[str]:
    """Path candidates inside a word: the word, and the parts after `=`, `@` and `:`."""
    if re.search(r"\s", word):
        return []
    out = [] if word.startswith("-") else [word]
    for sep in "=@:":
        k = word.find(sep)
        while k >= 0:
            out.append(word[k + 1 :])
            k = word.find(sep, k + 1)
    return [c for c in dict.fromkeys(out) if c and not c.startswith("//")]


def _secret_dirs(policy: dict, ctx: Ctx) -> List[str]:
    dirs = []
    for pat in policy.get("secretPaths", []):
        if pat.startswith("**/"):
            continue
        exp = _expand_home(pat, ctx)
        dirs.append(_lex(os.path.dirname(_GLOB_CHARS.split(exp)[0] + "x") if _GLOB_CHARS.search(exp) else os.path.dirname(exp)))
    return list(dict.fromkeys(dirs))


def _secret_path(path: str, recursive: bool, policy: dict, ctx: Ctx) -> bool:
    if _is_secret(path, policy, ctx):
        return True
    for d in _secret_dirs(policy, ctx):
        for form in _forms(path):
            if form == d or (recursive and _under(d, form)):
                return True
    return False


def _secret_reads(inv: Invocation, policy: dict, ctx: Ctx, cwd: Optional[str]) -> Decision:
    """Deny any word that names a secret path, unless the tool only names it."""
    words: List[str] = []
    recursive = False
    if inv.argv and not inv.wrapper and not _safe_tool(inv, policy):
        words.extend(inv.argv[1:])
        if _name(inv) in policy.get("fileRules", {}).get("overwrite", {}) and not any(
            x in ("-t", "--target-directory") for x in inv.argv[1:]
        ):
            pos = [w for w, _ in _positionals(inv, policy["fileRules"]["overwrite"][_name(inv)])]
            if len(pos) > 1:  # the destination is written, not read: the write rules judge it
                words.reverse()
                words.remove(pos[-1])
                words.reverse()
        recursive = any(a == "--recursive" or (a.startswith("-") and not a.startswith("--") and re.search("[rR]", a[1:])) for a in inv.argv[1:])
    words.extend(t for op, t in inv.redirects if op.lstrip("0123456789") == "<")
    for w in words:
        for cand in _candidates(w):
            paths = []
            path = resolve_target(cand, cwd, ctx)
            if path is None and cwd is None and not os.path.isabs(cand) and not re.search(r"[$`~]", cand):
                path = _lex("/unknown-cwd/" + cand)  # unknown directory: `**/` patterns still match
            if re.match(r"^~[^/]", cand):  # ~user/rest: test rest under our home too
                rest = "/" + cand.partition("/")[2] if "/" in cand else ""
                paths.append(resolve_target("~" + rest, cwd, ctx))
            if path is not None and _GLOB_CHARS.search(path):
                paths.extend(itertools.islice(glob.iglob(path), 200))
            else:
                paths.append(path)
            for p in paths:
                if p is not None and _secret_path(p, recursive, policy, ctx):
                    return Decision("deny", "secret-read", "%s holds secrets; do not read it" % (p if cand == w else w))
    return Decision()


def _tmp_script(inv: Invocation, policy: dict, ctx: Ctx, cwd: Optional[str]) -> Decision:
    """A script under the temp dir is unreviewed code: ask before running it."""
    if not inv.argv:
        return Decision()
    name, words = _name(inv), []
    if "/" in inv.argv[0]:
        words.append(inv.argv[0])
    if name in policy.get("scriptRunners", []):
        args = inv.argv[1:]
        if name in ("source", ".") or shell_script_index(args) is None:
            words.extend(a for a in args if not a.startswith("-"))
            words = words[:1] if "/" not in inv.argv[0] else words
    for w in words:
        path = resolve_target(w, cwd, ctx)
        if path and not _outside_tmp(path, ctx) and _outside_project(path, ctx):
            return _ask("tmp-script", "%s runs a script from the temp dir" % (name or w))
    return Decision()


def _outside_tmp(path: str, ctx: Ctx) -> bool:
    return not any(_under(_real(path), _real(r)) for r in ctx.tmp_roots if r)


def _outside_project(path: str, ctx: Ctx) -> bool:
    return not (ctx.project_dir and _under(_real(path), _real(ctx.project_dir)))


def _invocation(
    inv: Invocation, policy: dict, names: List[str], command: str, ctx: Ctx, cwd: Optional[str],
    verbs: Optional[List[str]] = None, opaque_names: Optional[List[str]] = None,
) -> Decision:
    return _worst(
        [
            _tool_rules(inv, policy, names, command, verbs, opaque_names),
            _file_rules(inv, policy, ctx, cwd),
            _secret_reads(inv, policy, ctx, cwd),
            _tmp_script(inv, policy, ctx, cwd),
        ]
    )


def _next_cwd(inv: Invocation, cwd: Optional[str], ctx: Ctx) -> Optional[str]:
    """Working directory after the invocation, following `cd` best effort."""
    name = _name(inv)
    if name in ("pushd", "popd"):
        return None  # a directory stack: not tracked, relative targets then ask
    if name != "cd":
        return cwd
    args = [a for a in inv.argv[1:] if a != "--" and not (a.startswith("-") and a != "-")]
    if not args:
        return _lex(ctx.home) if ctx.home else None
    if args[0] == "-":
        return None  # the previous directory is unknown
    return resolve_target(args[0], cwd, ctx)


def explain_bash(command: str, policy: dict, ctx: Ctx) -> List[Tuple[Invocation, Decision]]:
    names = _sensitive_names(policy)
    verbs = _verb_words(policy)
    opaque_names = sorted(set(names) | set(policy.get("fileRules", {}).get("destructive", {})))
    cwd: Optional[str] = ctx.cwd or ctx.project_dir or None
    out: List[Tuple[Invocation, Decision]] = []
    for inv in unwrap(parse_command(command)):
        out.append((inv, _invocation(inv, policy, names, command, ctx, cwd, verbs, opaque_names)))
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
