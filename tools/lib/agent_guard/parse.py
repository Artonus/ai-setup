"""Shell command parser: splits a command line into simple invocations.

A hand-written scanner, not a shell. It splits on `; && || | & newline`,
honours quotes, recurses into `$(...)`, backticks and `( )`, and treats
heredoc bodies as data. It never raises.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import List, Tuple

MAX_DEPTH = 20
KEYWORDS = {"if", "then", "else", "elif", "fi", "do", "done", "while", "until", "esac", "!", "{", "}"}
_BLANKS = " \t\r"
_WORD_BREAK = " \t\r\n;&|()<>"
_REDIR_OP = re.compile(r"(\d*)(&>>|&>|>>|>&|>\||<<<|<<-|<<|<&|<>|>|<)")
_FD_REDIR = re.compile(r"\d+[<>]")
_VAR_START = re.compile(r"[A-Za-z_0-9@*?!#$-]")
_VAR_NAME = re.compile(r"[A-Za-z_][A-Za-z_0-9]*|[0-9@*?!#$-]")


@dataclass
class Invocation:
    argv: List[str]
    dynamic: List[bool]
    redirects: List[Tuple[str, str]] = field(default_factory=list)
    raw: str = ""
    opaque: bool = False
    via_xargs: bool = False
    wrapper: bool = False  # set by unwrap when the command is only a wrapper around an inner one


def parse_command(command: str) -> List[Invocation]:
    try:
        return _parse(command, 0)
    except Exception:  # never raise: an unparsable command is opaque
        return [Invocation([], [], [], str(command).strip(), opaque=True)]


def _parse(text: str, depth: int) -> List[Invocation]:
    if depth > MAX_DEPTH:
        return [Invocation([], [], [], text.strip(), opaque=True)]
    return _Scanner(text, depth).run()


class _Scanner:
    def __init__(self, text: str, depth: int) -> None:
        self.t = text
        self.n = len(text)
        self.depth = depth
        self.out: List[Invocation] = []
        self.words: List[str] = []
        self.dyn: List[bool] = []
        self.redirs: List[Tuple[str, str]] = []
        self.seg_start = 0
        self.seg_opaque = False
        self.pending: List[Tuple[str, bool, bool]] = []  # heredocs: delim, strip tabs, quoted

    # ---- helpers -------------------------------------------------------
    def _sub(self, inner: str) -> None:
        self.out.extend(_parse(inner, self.depth + 1))

    def _match(self, i: int) -> int:
        """Index of the `)` matching the `(` at i, or -1. Quote aware."""
        t, n, d = self.t, self.n, 0
        while i < n:
            c = t[i]
            if c == "\\":
                i += 2
                continue
            if c == "'":
                k = t.find("'", i + 1)
                if k < 0:
                    return -1
                i = k + 1
                continue
            if c == '"':
                i += 1
                while i < n and t[i] != '"':
                    i += 2 if t[i] == "\\" else 1
                i += 1
                continue
            if c == "(":
                d += 1
            elif c == ")":
                d -= 1
                if d == 0:
                    return i
            i += 1
        return -1

    def _backtick_end(self, i: int) -> int:
        j = i + 1
        while j < self.n and self.t[j] != "`":
            j += 2 if self.t[j] == "\\" else 1
        return j if j < self.n else -1

    def _substs_in(self, text: str) -> None:
        """Parse command substitutions inside text that is otherwise data."""
        sc = _Scanner(text, self.depth)
        i = 0
        while i < sc.n:
            c = text[i]
            if c == "\\":
                i += 2
            elif text.startswith("$(", i) and not text.startswith("$((", i):
                j = sc._match(i + 1)
                self._sub(text[i + 2 : j if j >= 0 else sc.n])
                i = sc.n if j < 0 else j + 1
            elif c == "`":
                j = sc._backtick_end(i)
                self._sub(text[i + 1 : j if j >= 0 else sc.n])
                i = sc.n if j < 0 else j + 1
            else:
                i += 1

    def _dollar(self, i: int) -> Tuple[str, int]:
        """Expand-like handling of `$` at i. Returns (raw text, new index)."""
        t, n = self.t, self.n
        if t.startswith("$((", i):
            j = self._match(i + 1)
            if j < 0:
                self.seg_opaque = True
                return t[i:], n
            return t[i : j + 1], j + 1
        if t.startswith("$(", i):
            j = self._match(i + 1)
            if j < 0:
                self.seg_opaque = True
                self._sub(t[i + 2 :])
                return t[i:], n
            self._sub(t[i + 2 : j])
            return t[i : j + 1], j + 1
        if t.startswith("${", i):
            j, d = i + 1, 0
            while j < n:
                if t[j] == "{":
                    d += 1
                elif t[j] == "}":
                    d -= 1
                    if d == 0:
                        break
                j += 1
            if j >= n:
                self.seg_opaque = True
                return t[i:], n
            self._substs_in(t[i + 2 : j])
            return t[i : j + 1], j + 1
        m = _VAR_NAME.match(t, i + 1) if _VAR_START.match(t, i + 1) else None
        if m:
            return t[i : m.end()], m.end()
        return "$", i + 1

    def _read_word(self, i: int) -> Tuple[str, bool, bool, int]:
        t, n = self.t, self.n
        buf: List[str] = []
        dyn = quoted = False
        while i < n:
            c = t[i]
            if c in _WORD_BREAK:
                if c in "<>" and t[i + 1 : i + 2] == "(":
                    j = self._match(i + 1)
                    if j < 0:
                        self.seg_opaque = True
                        self._sub(t[i + 2 :])
                        buf.append(t[i:])
                        i = n
                    else:
                        self._sub(t[i + 2 : j])
                        buf.append(t[i : j + 1])
                        i = j + 1
                    dyn = True
                    continue
                break
            if c == "'":
                quoted = True
                k = t.find("'", i + 1)
                if k < 0:
                    self.seg_opaque = True
                    buf.append(t[i + 1 :])
                    i = n
                else:
                    buf.append(t[i + 1 : k])
                    i = k + 1
            elif c == '"':
                quoted = True
                i += 1
                closed = False
                while i < n:
                    ch = t[i]
                    if ch == '"':
                        closed = True
                        i += 1
                        break
                    if ch == "\\" and i + 1 < n:
                        nx = t[i + 1]
                        if nx == "\n":
                            pass
                        elif nx in '$`"\\':
                            buf.append(nx)
                        else:
                            buf.append(ch + nx)
                        i += 2
                    elif ch == "$":
                        raw, i2 = self._dollar(i)
                        buf.append(raw)
                        dyn = dyn or raw != "$"
                        i = i2
                    elif ch == "`":
                        j = self._backtick_end(i)
                        end = j if j >= 0 else n
                        self._sub(t[i + 1 : end])
                        if j < 0:
                            self.seg_opaque = True
                        buf.append(t[i : end + 1])
                        dyn = True
                        i = end + 1
                    else:
                        buf.append(ch)
                        i += 1
                if not closed:
                    self.seg_opaque = True
            elif c == "\\":
                if i + 1 < n:
                    if t[i + 1] != "\n":
                        buf.append(t[i + 1])
                        quoted = True
                    i += 2
                else:
                    i += 1
            elif c == "$":
                if t.startswith("$'", i):
                    quoted = True
                    j = i + 2
                    while j < n and t[j] != "'":
                        j += 2 if t[j] == "\\" else 1
                    if j >= n:
                        self.seg_opaque = True
                    buf.append(t[i + 2 : j])
                    i = j + 1
                else:
                    raw, i = self._dollar(i)
                    buf.append(raw)
                    dyn = dyn or raw != "$"
            elif c == "`":
                j = self._backtick_end(i)
                end = j if j >= 0 else n
                self._sub(t[i + 1 : end])
                if j < 0:
                    self.seg_opaque = True
                buf.append(t[i : end + 1])
                dyn = True
                i = end + 1
            else:
                buf.append(c)
                i += 1
        return "".join(buf), dyn, quoted, i

    def _flush(self, end: int) -> None:
        words, dyn = self.words, self.dyn
        k = 0
        while k < len(words) and words[k] in KEYWORDS:
            k += 1
        words, dyn = words[k:], dyn[k:]
        if words or self.redirs:
            self.out.append(
                Invocation(words, dyn, self.redirs, self.t[self.seg_start : end].strip(), self.seg_opaque)
            )
        self.words, self.dyn, self.redirs, self.seg_opaque = [], [], [], False
        self.seg_start = end

    def _newline(self, i: int) -> int:
        """Consume the newline at i and any heredoc bodies it introduces."""
        t, n = self.t, self.n
        i += 1
        for delim, strip, quoted in self.pending:
            body: List[str] = []
            while i < n:
                le = t.find("\n", i)
                line, nxt = (t[i:], n) if le < 0 else (t[i:le], le + 1)
                i = nxt
                if (line.lstrip("\t") if strip else line).rstrip("\r") == delim:
                    break
                body.append(line)
            if not quoted:
                self._substs_in("\n".join(body))
        self.pending = []
        return i

    # ---- main loop -----------------------------------------------------
    def run(self) -> List[Invocation]:
        t, n = self.t, self.n
        i = 0
        while i < n:
            c = t[i]
            if c in _BLANKS:
                i += 1
            elif c == "\n":
                self._flush(i)
                i = self._newline(i)
                self.seg_start = i
            elif c == "#":
                k = t.find("\n", i)
                i = n if k < 0 else k
            elif (c in "<>" and t[i + 1 : i + 2] != "(") or (c == "&" and t[i + 1 : i + 2] == ">") or _FD_REDIR.match(t, i):
                i = self._redirect(i)
            elif c in ";&|":
                self._flush(i)
                i += 2 if t.startswith(("&&", "||"), i) else 1
                self.seg_start = i
            elif c == ")":
                self._flush(i)
                i += 1
                self.seg_start = i
            elif c == "(":
                self._flush(i)
                j = self._match(i)
                if j < 0:
                    self._sub(t[i + 1 :])
                    self.out.append(Invocation([], [], [], t[i:].strip(), opaque=True))
                    i = n
                else:
                    self._sub(t[i + 1 : j])
                    i = j + 1
                self.seg_start = i
            else:
                word, dyn, _q, i = self._read_word(i)
                self.words.append(word)
                self.dyn.append(dyn)
        self._flush(n)
        return self.out

    def _redirect(self, i: int) -> int:
        t, n = self.t, self.n
        m = _REDIR_OP.match(t, i)
        assert m is not None  # callers only enter on a redirect operator
        op = m.group(1) + m.group(2)
        i = m.end()
        while i < n and t[i] in _BLANKS:
            i += 1
        target, quoted = "", False
        if i < n and t[i] not in ";&|()\n<>":
            target, _d, quoted, i = self._read_word(i)
        if m.group(2) in ("<<", "<<-"):
            self.pending.append((target, m.group(2) == "<<-", quoted))
        self.redirs.append((op, target))
        return i
