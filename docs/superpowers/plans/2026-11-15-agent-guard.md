# Agent Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A guard for OpenCode V2 (the main working environment) and Claude Code that asks or denies destructive commands (databases, cluster and cloud mutations, git history rewrites, file deletes and overwrites) before they run, for the main agent and subagents.

**Architecture:** One Python script, `tools/bin/agent-guard`, with a small shell parser, a rules engine driven by a JSON policy, and a shared decision entry that logs every decision. Two thin adapters call it: an OpenCode V2 plugin (`permission.evaluate` hook) and a Claude Code `PreToolUse` hook. The guard only adds `ask` or `deny`; it never grants permission. It ships in `shadow` mode (log only) and is switched to `enforce` after a review period. OpenCode is built and verified first.

**Tech Stack:** Python 3 standard library only (macOS system Python is 3.9, so no 3.10+ syntax), dependency-free Node ESM for the OpenCode plugin (Node 26 is installed), bash tests in the existing `tests/` suite, `jq`.

**Spec:** `docs/superpowers/specs/2026-11-13-agent-guard-design.md`

## Global Constraints

- Python 3.9 compatible, standard library only; every module starts with `from __future__ import annotations`.
- The guard returns `ask` or `deny` or no opinion. It never returns `allow`.
- The Claude Code hook is registered with `"onFailure": "block"` and matcher `Bash|Write|Edit|MultiEdit|NotebookEdit`; the command is `"$HOME/bin/agent-guard" claude`.
- The OpenCode plugin targets OpenCode V2 only (`ctx.tool.hook`, `ctx.permission.hook("evaluate")`), lives in `opencode/plugins/agent-guard/` as a directory plugin (entrypoint `index.js`, no `package.json`, no `server.*` file), and is linked into `~/.config/opencode/plugins/`. A V1 `opencode` binary is not supported.
- The plugin shells out to `agent-guard decide`; no policy logic is duplicated in JavaScript.
- Policy file: `shared/agent-guard/policy.json`, installed to `~/.config/agent-guard/policy.json`, merged with the overlay's copy by the existing `install_json` (arrays are unioned). Env override for tests: `AGENT_GUARD_POLICY`.
- Decision log: `~/.local/state/agent-guard/decisions.jsonl` (env override `AGENT_GUARD_LOG`), one JSON line per decision with `ts`, `session_id`, `agent_id`, `agent_type`, `permission_mode`, `tool`, `decision`, `rule`, `mode`, `command`. Values after `password|token|secret|key=` are masked; heredoc bodies are replaced by `<<heredoc>>`; `command` is capped at 300 characters.
- `mode` is `shadow` or `enforce`. In `shadow` the adapter always exits 0 with no output, even on its own errors. In `enforce`, a broken policy or an internal error returns `ask`.
- The existing `permissions.deny` entries in `claude/settings.json` stay untouched.
- Public repo: no tokens, hostnames or work-specific rules. Work policy goes in the overlay.
- Commit messages are conventional commits with no `Co-Authored-By` trailer and no "Generated with" line.

## Review Focus

- Quoted text that only mentions a sensitive tool (`echo "run psql later"`, `git commit -m "fix psql bug"`, a heredoc body) must give no opinion. (Task 1, Task 2)
- `git push origin +main` and `git push origin :old-branch` must ask even though they contain no `--force`. (Task 2)
- `kubectl get pods | xargs kubectl delete` and `sh -c 'psql -c "select 1"'` must ask; wrapping must not hide the tool. (Task 1, Task 2)
- Empty, very long (100 KB), non-UTF-8 or malformed input, and an OpenCode plugin whose subprocess crashes or times out, must never crash the guard or let a command through unasked in `enforce`; `shadow` stays silent. (Task 4, Task 5, Task 6)
- `rm ../x`, `rm "$HOME/x"` and `rm /etc/hosts` must ask, while `rm build/out.o` inside the project and `rm "$TMPDIR/x"` give no opinion. (Task 3)

---

### Task 0: OpenCode V2 prerequisite and spike (manual)

No code is merged by this task. Its findings go into spec section 9 and can change the Task 5 interfaces, so run it first.

- [ ] **Step 1: Get OpenCode V2 running.** `opencode` on this machine is 1.18.34 (V1) and rejects the repo's V2 `opencode.json`; there is no `opencode2` binary yet. Install V2 following https://v2.opencode.ai/docs, then confirm `opencode2 --version` (or the V2 binary's name) works and `opencode2 debug config` accepts `~/.config/opencode/opencode.json`. Note the binary name; the README and Task 8 use it.
- [ ] **Step 2: Spike plugin.** In a scratch directory, write a throwaway plugin (`default export {id, setup(ctx)}`) that registers `ctx.tool.hook("execute.before")` and `ctx.permission.hook("evaluate")`, appends each event as JSON to a log file, sets `effect = "ask"` with a message for a command containing `spike-ask`, and `"deny"` for `spike-deny`. Load it through `<config dir>/plugins/<name>/index.js`.
- [ ] **Step 3: Verify and record**, with `opencode2 run` where possible:
  - the shell tool name and the fields: `e.tool`, `e.input.command`, `e.id`, and `ev.source.id` matching `e.id`;
  - `ev.action` values for shell, read, edit and write, and what `ev.resources` holds;
  - `ev.agent` and a subagent (task) call: does the hook fire, and what identifies the subagent;
  - `child_process.spawnSync` works inside a plugin and returns within 2 s;
  - `ask` shows a prompt, `deny` blocks with the message, and an `ask` from the hook on an `allow` default is honoured;
  - a plugin that throws, and a plugin directory reached through a symlink, behave as expected;
  - the `~/.config/opencode/plugins` directory name is accepted.
- [ ] **Step 4: Update spec section 9** with the verified facts and any change to the hook or event names. If a verified fact contradicts the Interfaces block of Task 5, change that block before starting Task 5.

### Task 1: Shell parser and unwrapper

**Files:**
- Create: `tools/lib/agent_guard/__init__.py` (empty), `tools/lib/agent_guard/parse.py`, `tools/lib/agent_guard/unwrap.py`, `tools/bin/agent-guard`
- Test: `tests/test_agent_guard_parse.sh`

**Interfaces:**
- Produces, in `parse.py`: `@dataclass class Invocation` with fields `argv: list[str]`, `dynamic: list[bool]` (parallel to `argv`, true when the word contains `$VAR`, `${}`, `$()` or backticks), `redirects: list[tuple[str, str]]` (operator, target), `raw: str`, `opaque: bool = False` (parse failed or word list unreliable), `via_xargs: bool = False`.
- Produces: `parse_command(command: str) -> list[Invocation]`. Splits on `; && || | & newline`, honours single and double quotes, recurses into `$(...)`, backticks and `( )`, treats heredoc bodies as data, never raises (an unterminated quote runs to the end; nesting is capped at depth 20).
- Produces, in `unwrap.py`: `unwrap(invs: list[Invocation]) -> list[Invocation]`. Returns the input plus the inner commands found by stripping `VAR=x` prefixes, `env`, `timeout N`, `nohup`, `time`, `command`, `builtin`, `exec`, `sudo`, and by following `sh|bash|zsh -c SCRIPT`, `xargs CMD` (inner marked `via_xargs=True`), `ssh HOST CMD` and `kubectl exec ... -- CMD`.
- Produces, in `tools/bin/agent-guard`: Python 3 script (`#!/usr/bin/env python3`) that resolves its own real path (`os.path.realpath`) to add `tools/lib` to `sys.path`; subcommand `parse '<command>'` prints one JSON object per invocation (`argv`, `via_xargs`, `opaque`) after unwrapping.

- [ ] **Step 1: Write the failing tests** in `tests/test_agent_guard_parse.sh`, using a helper `ag_parse() { python3 "$ROOT/tools/bin/agent-guard" parse "$1" | jq -c '.argv'; }`. Tests (names and assertions):
  - `test_ag_parse_splits_operators`: `a 1 && b 2 | c; d` gives four argv lines `["a","1"] ["b","2"] ["c"] ["d"]`.
  - `test_ag_parse_quotes_hide_operators`: `echo "a; psql"` gives only `["echo","a; psql"]`.
  - `test_ag_parse_unwraps_wrappers`: `timeout 5 env X=1 kubectl delete ns demo` contains `["kubectl","delete","ns","demo"]`; `bash -c 'psql -c "select 1"'` contains `["psql","-c","select 1"]`; `kubectl exec pod -- psql` contains `["psql"]`.
  - `test_ag_parse_xargs_and_subst`: `kubectl get pods | xargs kubectl delete` marks the inner `["kubectl","delete"]` with `via_xargs` true; `echo $(rm -f x)` contains `["rm","-f","x"]`.
  - `test_ag_parse_heredoc_is_data`: a command with `cat <<EOF\npsql\nEOF` gives only `["cat"]`.
  - `test_ag_parse_never_crashes`: unterminated quote `echo "abc`, empty string, 100000-character string, and invalid UTF-8 bytes all exit 0.
- [ ] **Step 2: Run** `bash tests/run.sh 2>&1 | grep -A3 test_ag_parse`. Expected: failures, `agent-guard` missing.
- [ ] **Step 3: Implement** `parse.py`, `unwrap.py` and the `parse` subcommand per the Interfaces block. A hand-written character scanner is enough; do not use `shlex` alone (it cannot split on operators or recurse).
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: all tests pass, `0 failed`.
- [ ] **Step 5: Commit**

```bash
git add tools/bin/agent-guard tools/lib/agent_guard tests/test_agent_guard_parse.sh
git commit -m "feat(guard): add shell parser and unwrapper"
```

### Task 2: Policy and tool rules

**Files:**
- Create: `shared/agent-guard/policy.json`, `tools/lib/agent_guard/rules.py`, `tests/agent_guard_corpus.tsv`
- Modify: `tools/bin/agent-guard` (add `check` and `explain`)
- Test: `tests/test_agent_guard_rules.sh`

**Interfaces:**
- Consumes: `parse_command`, `unwrap`, `Invocation` from Task 1.
- Produces, in `rules.py`: `@dataclass class Decision` with `decision: str` (`"none"`, `"ask"` or `"deny"`), `rule: str` (rule id), `reason: str`; `@dataclass class Ctx` with `cwd: str`, `project_dir: str`, `home: str`, `tmp_roots: list[str]`; `load_policy(path: str) -> dict`; `decide_bash(command: str, policy: dict, ctx: Ctx) -> Decision` (strictest invocation wins, `deny` > `ask` > `none`).
- Produces: CLI `agent-guard check '<command>'` prints `none` or `<ask|deny><TAB><rule><TAB><reason>`; `agent-guard explain '<command>'` prints each invocation and the rule that matched. Both read the policy from `$AGENT_GUARD_POLICY`, else `~/.config/agent-guard/policy.json`, with `project_dir` from `$CLAUDE_PROJECT_DIR` or the cwd.
- Produces, in `policy.json`: keys `mode` (`"shadow"`), `dbClients` (list of tool names), `verbGated` (object: tool to `{"readVerbs": [...]}`), `git` (object of dangerous verb patterns), `protectedPaths`, `secretPaths` (used in Task 3).

**Policy values (from the spec):**
- `dbClients`: `psql mysql mariadb mongosh redis-cli sqlite3 pg_restore`, plus `kubectl cnpg` and any DB client inside `kubectl exec ... --`: always `ask`, rule id `db-client`.
- `aws rds-data execute-statement`, `aws rds delete-*|modify-*|reboot-*`, `aws dynamodb` non-read verbs, `aws ssm start-session`, `aws ecs execute-command`: `ask`, rule id `db-cloud` or `cloud-session`.
- `verbGated` read verbs, everything else `ask` (rule id `cluster-mutation` or `cloud-mutation`): `kubectl`: `get describe logs top events diff explain version api-resources config view`; `helm`: `list get status show search template lint version history repo list`; `flux`: `get logs events check version tree stats`; `talosctl`: `get read logs dmesg version health containers services`; `aws`: verbs starting `describe-|list-|get-|head-`, plus `s3 ls` and `sts get-caller-identity`; `terraform` and `tofu`: `plan validate fmt show output version`, `state list|show`.
- `git` (rule id `git-destructive`, `ask`): `push` with `--force`, `-f`, `--force-with-lease`, `--delete`, `-d`, `--mirror`, a refspec starting with `+` or `:`; `reset --hard`; `branch -D|-d|--delete`; `clean` with `-f`; `checkout .` and `checkout --`; `restore .`; `stash drop|clear`; `reflog expire`; `gc --prune`.
- Fail closed (rule id `dynamic-sensitive`, `ask`): a sensitive tool with a dynamic verb or target (`kubectl $VERB`); `eval`; `xargs` whose inner tool is sensitive; `sh -c` bodies are already unwrapped; the parser marking a command `opaque` while the raw text contains a sensitive tool name. Unknown binaries: `none`.

- [ ] **Step 1: Write the corpus** `tests/agent_guard_corpus.tsv` (columns: command, expected `none|ask|deny`, tab-separated, `#` comments allowed) and `tests/test_agent_guard_rules.sh::test_ag_corpus_matches`, which runs `agent-guard check` for each row with `AGENT_GUARD_POLICY="$ROOT/shared/agent-guard/policy.json"` and asserts the first field. Required rows (at least): every Review Focus case for this task; `psql -c "drop table x"` ask; `kubectl get pods -n x` none; `kubectl delete ns demo` ask; `kubectl exec p -- psql` ask; `kubectl $VERB pods` ask; `helm uninstall x` ask; `helm list` none; `aws s3 ls` none; `aws s3 rm s3://b/k` ask; `aws rds delete-db-instance --db-instance-identifier x` ask; `terraform plan` none; `terraform apply` ask; `git push --force` ask; `git push origin +main` ask; `git push origin :old` ask; `git push origin main` none; `git reset --hard HEAD~1` ask; `git branch -D x` ask; `git status` none; `git commit -m "fix psql bug"` none; `echo "run psql later"` none; `ls -la` none; `make deploy` none; `./unknown-binary --x` none.
- [ ] **Step 2: Run** `bash tests/run.sh 2>&1 | grep -A5 test_ag_corpus`. Expected: FAIL, no `check` subcommand.
- [ ] **Step 3: Implement** `policy.json`, `rules.py` (`decide_bash`, `load_policy`) and the `check` and `explain` subcommands. Data-driven: all tool and verb lists come from the policy, none hard-coded in `rules.py`.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: `0 failed`.
- [ ] **Step 5: Commit**

```bash
git add shared/agent-guard tools tests
git commit -m "feat(guard): add policy and tool rules"
```

### Task 3: Path rules (files, secrets, AI-setup)

**Files:**
- Modify: `tools/lib/agent_guard/rules.py`, `shared/agent-guard/policy.json`, `tools/bin/agent-guard` (a `check-path` subcommand)
- Test: `tests/test_agent_guard_paths.sh`, rows appended to `tests/agent_guard_corpus.tsv`

**Interfaces:**
- Consumes: `Decision`, `Ctx`, `decide_bash` from Task 2.
- Produces: `decide_path(tool: str, path: str, policy: dict, ctx: Ctx) -> Decision` for the `Write`, `Edit`, `MultiEdit` and `NotebookEdit` tools; `decide_bash` also applies the file rules to Bash invocations.
- Produces: CLI `agent-guard check-path <tool> <path>` printing the same format as `check`.

**Rules (from the spec):**
- File rule id `file-destructive`, `ask`: `rm rmdir shred truncate`, `find` with `-delete` or `-exec rm`, `dd of=`, `mv` or `cp` onto an existing file, and a `>` or `>>`-style overwrite redirect onto an existing file, unless **every** target is inside `ctx.project_dir` or a path in `ctx.tmp_roots` and not under `protectedPaths`. A target that is dynamic or cannot be resolved asks. Relative targets resolve against the invocation's tracked `cwd` (`cd x && rm y` uses `x`).
- `protectedPaths` (rule id `protected-path`, `ask`): `~/.ssh`, `~/.aws`, `~/.claude`, `~/.config`, `~/.zshrc`, `~/.bashrc`, `~/.zprofile`. Writes by `Write` or `Edit` outside the project, or into a protected path, ask.
- `~/.claude` and `~/.config/opencode` writes use rule id `ai-setup` with reason "change the AI setup in the ai-setup repo".
- `secretPaths` (rule id `secret-read`, `deny`): `~/.ssh/id_*` (not `.pub`), `~/.aws/credentials`, `**/.env`, `**/.env.*` read through Bash tools (`cat head tail less more grep cp mv source .`).
- `/tmp` and `/private/tmp` normalise to the same root; paths resolve `..` and `~` and `$HOME` literals.

- [ ] **Step 1: Write failing tests** `test_ag_paths_*` in `tests/test_agent_guard_paths.sh` using `AGENT_GUARD_POLICY` and `CLAUDE_PROJECT_DIR="$T/proj"`: `rm "$T/proj/build/out.o"` is `none`; `rm ../x` ask; `rm "$HOME/x"` ask; `rm /etc/hosts` ask; `rm "$TMPDIR/x"` none; `cd "$T/proj/sub" && rm y` none; `cat ~/.ssh/id_ed25519` deny; `cat ~/.ssh/id_ed25519.pub` none; `check-path Write ~/.zshrc` ask with rule `protected-path`; `check-path Write ~/.claude/settings.json` ask with rule `ai-setup`; `check-path Edit "$T/proj/src/a.py"` none; `echo hi > "$T/proj/new.txt"` none; `echo hi > ~/.zshrc` ask.
- [ ] **Step 2: Run** `bash tests/run.sh 2>&1 | grep -A5 test_ag_paths`. Expected: FAIL.
- [ ] **Step 3: Implement** `decide_path` and the file and secret rules in `rules.py` with a helper `resolve_target(word: str, cwd: str, ctx: Ctx) -> Optional[str]` (returns `None` for dynamic words).
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: `0 failed`.
- [ ] **Step 5: Commit**

```bash
git add shared/agent-guard tools tests
git commit -m "feat(guard): add file, secret and ai-setup path rules"
```


### Task 4: Shared decision entry, log and modes

**Files:**
- Create: `tools/lib/agent_guard/decision.py`, `tools/lib/agent_guard/log.py`
- Modify: `tools/bin/agent-guard` (add `decide`)
- Test: `tests/test_agent_guard_decide.sh`

**Interfaces:**
- Consumes: `decide_bash`, `decide_path`, `load_policy`, `Ctx`, `Decision` from Tasks 2 and 3.
- Produces, in `log.py`: `mask(text: str) -> str` (heredoc bodies become `<<heredoc>>`, values after `password|token|secret|key=` become `***`, capped at 300 characters); `append(path: str, entry: dict) -> None` (creates parent directories, never raises).
- Produces, in `decision.py`: `run_decision(request: dict, policy_path: str, log_path: str) -> dict`. `request` keys: `source` (`"claude"` or `"opencode"`), `tool` (`"bash"`, `"write"`, `"edit"` or `"read"`), `command` (bash only), `path` (path tools only), `cwd`, `project_dir`, `session_id`, `agent_id`, `agent_type`, `permission_mode`. Returns `{"decision": "none|ask|deny", "rule": str, "reason": str, "mode": "shadow|enforce", "enforced": bool}`. `enforced` is true only when `mode == "enforce"`; the adapters apply the decision only when it is true. Writes exactly one log line per call. Never raises: any internal error, or an unreadable policy, returns `decision: "ask"`, `rule: "guard-error"`, and `mode` taken from the policy if readable, else from the last log line, else `"shadow"`.
- Produces: CLI `agent-guard decide` reading the request JSON on stdin and printing the result JSON; honours `AGENT_GUARD_POLICY` and `AGENT_GUARD_LOG`.

- [ ] **Step 1: Write failing tests** in `tests/test_agent_guard_decide.sh`, with a helper that pipes `jq -n` requests into `agent-guard decide` using a temp policy whose `mode` is set by `jq`:
  - `test_ag_decide_enforce_asks`: `kubectl delete ns demo` in `enforce` returns `decision == "ask"`, `enforced == true`, reason containing `kubectl delete ns demo`.
  - `test_ag_decide_enforce_denies_secret_read`: `cat ~/.ssh/id_ed25519` returns `"deny"`.
  - `test_ag_decide_none`: `ls` returns `"none"`.
  - `test_ag_decide_shadow_not_enforced`: in `shadow`, `kubectl delete ns demo` returns `decision == "ask"` and `enforced == false`; the log line has `mode == "shadow"`.
  - `test_ag_decide_logs_agent`: `agent_id: "a1"` and `agent_type: "general-purpose"` appear in the log line, together with `source`.
  - `test_ag_decide_masks_secrets`: a command containing `password=hunter2` is logged as `password=***`; a heredoc body is not logged.
  - `test_ag_decide_bad_input`: empty stdin, `not json`, a 100000-character command and invalid UTF-8 bytes never crash; each returns `ask` with `rule == "guard-error"` or `none`, and exit code 0.
  - `test_ag_decide_broken_policy`: a missing or invalid policy file returns `ask` with `rule == "guard-error"`.
- [ ] **Step 2: Run** `bash tests/run.sh 2>&1 | grep -A5 test_ag_decide`. Expected: FAIL.
- [ ] **Step 3: Implement** `log.py`, `decision.py` and the `decide` subcommand.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: `0 failed`.
- [ ] **Step 5: Commit**

```bash
git add tools tests
git commit -m "feat(guard): add shared decision entry, log and modes"
```

### Task 5: OpenCode V2 plugin

**Files:**
- Create: `opencode/plugins/agent-guard/index.js` (dependency-free ESM, no `package.json`, no `server.*` file), `tests/test_agent_guard_opencode.sh`, `tests/agent_guard_opencode.test.mjs`
- Modify: `opencode/opencode.json` only if Task 0 shows the plugin must be listed

**Interfaces:**
- Consumes: `agent-guard decide` from Task 4 (JSON on stdin and stdout).
- Produces: a default export `{ id: "agent-guard", setup(ctx) }` that does nothing unless `ctx.tool.hook` and `ctx.permission.hook` are functions (the V1 loader calls `setup` with a different context). Setup registers two hooks:
  - `ctx.tool.hook("execute.before", e => ...)`: when `e.tool === "shell"` and `e.id != null`, store `{command: e.input.command, workdir: e.input.workdir, sessionID: e.sessionID}` in a map keyed by `e.id` (entries expire after 120 s, at most 500 entries).
  - `ctx.permission.hook("evaluate", async ev => ...)`: handles `ev.action` values `shell`, `read`, `edit` and `write`; anything else returns untouched. For `shell` it takes the stored command via `ev.source?.id`, falling back to `ev.resources` joined as separate requests. It calls `agent-guard decide` with `child_process.spawnSync` (`input` = request JSON, `timeout` = 2000 ms, `maxBuffer` 1 MB) and applies the result only when `enforced` is true. `ask` sets `ev.effect = "ask"` when the incoming effect is `allow`; `deny` sets `ev.effect = "deny"`; `ev.message` is set to the reason for both. The plugin never lowers `ask` or `deny` to `allow`. The request's `agent_type` is `ev.agent`; `agent_id` is `ev.sessionID`.
  - On spawn error, non-zero exit, timeout or unparsable output: set `ev.effect = "ask"` with `ev.message = "agent-guard: guard unavailable"` when the policy file's `mode` is `enforce` (read directly from `AGENT_GUARD_POLICY` or `~/.config/agent-guard/policy.json`), otherwise leave the event untouched. A missing policy file counts as `enforce`.
- Environment overrides for tests: `AGENT_GUARD_BIN` (path to the script, default `agent-guard` on `PATH`), plus the two variables from Task 4.

- [ ] **Step 1: Write failing tests** in `tests/agent_guard_opencode.test.mjs` (run by `node --test`) with a fake `ctx` that records registered hooks, and a stub `AGENT_GUARD_BIN` shell script that echoes a canned decision. `tests/test_agent_guard_opencode.sh::test_ag_opencode_plugin` runs `node --test tests/agent_guard_opencode.test.mjs` and asserts exit 0 (skipped with an `ok` when `node` is missing). Test names and assertions:
  - `setup is a no-op without ctx.tool and ctx.permission`.
  - `shell ask when enforced`: stored command plus an `evaluate` event with `effect: "allow"` ends with `effect === "ask"` and the reason in `message`.
  - `deny wins and an incoming deny is never lowered`.
  - `not enforced leaves the event untouched`.
  - `uncorrelated shell falls back to resources`.
  - `edit and write pass the path to decide` with `tool: "edit"` or `"write"` and `path` equal to `ev.resources[0]`.
  - `subprocess failure asks in enforce and is silent in shadow`: stub exits 1, then hangs past the timeout; both cases checked against a temp policy in each mode.
  - `unrelated actions are ignored` (`ev.action === "webfetch"`).
- [ ] **Step 2: Run** `node --test tests/agent_guard_opencode.test.mjs`. Expected: FAIL, plugin missing.
- [ ] **Step 3: Implement** `index.js` per the Interfaces block. Keep it in one file under 200 lines; all policy logic stays in Python.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: `0 failed`.
- [ ] **Step 5: Commit**

```bash
git add opencode/plugins tests
git commit -m "feat(guard): add OpenCode V2 plugin"
```

### Task 6: Claude Code hook adapter

**Files:**
- Create: `tools/lib/agent_guard/claude_hook.py`
- Modify: `tools/bin/agent-guard` (add `claude`)
- Test: `tests/test_agent_guard_claude.sh`

**Interfaces:**
- Consumes: `run_decision` from Task 4.
- Produces: `run_claude_hook(stdin_text: str, policy_path: str, log_path: str) -> tuple[int, str]` returning `(exit_code, stdout)`. Maps the hook JSON (`tool_name` of `Bash`, `Write`, `Edit`, `MultiEdit`, `NotebookEdit`; `tool_input.command`, `tool_input.file_path` or `notebook_path`; `cwd`, `session_id`, `agent_id`, `agent_type`, `permission_mode`) to a request with `source: "claude"`. When `enforced` and the decision is `ask` or `deny`, returns exit 0 and `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask|deny","permissionDecisionReason":"agent-guard: <reason>. Command: <command>"}}`; otherwise prints nothing. Unparsable input counts as a guard error (`ask` when enforced, silent otherwise).
- Produces: CLI `agent-guard claude` reading stdin.

- [ ] **Step 1: Write failing tests**: `test_ag_claude_enforce_asks` (`kubectl delete ns demo` gives `permissionDecision == "ask"`, reason contains the command); `test_ag_claude_denies_secret_read`; `test_ag_claude_none_is_silent`; `test_ag_claude_shadow_is_silent` (prints nothing, exit 0, log line has `decision == "ask"`); `test_ag_claude_edit_path` (`Write` to `~/.zshrc` asks); `test_ag_claude_subagent_logged` (`agent_id` appears in the log); `test_ag_claude_bad_input` (empty stdin, `not json`: enforce asks, shadow silent, exit 0).
- [ ] **Step 2: Run** `bash tests/run.sh 2>&1 | grep -A5 test_ag_claude`. Expected: FAIL.
- [ ] **Step 3: Implement** `claude_hook.py` and the `claude` subcommand as a thin translation layer; no rules logic here.
- [ ] **Step 4: Run** `bash tests/run.sh`. Expected: `0 failed`.
- [ ] **Step 5: Commit**

```bash
git add tools tests
git commit -m "feat(guard): add Claude Code hook adapter"
```

### Task 7: Installation, settings and docs

**Files:**
- Modify: `install.sh`, `claude/settings.json`, `shared/AGENTS.md`, `README.md`
- Test: `tests/test_agent_guard_install.sh`

**Interfaces:**
- Consumes: the policy file (Task 2), the `agent-guard` binary (Task 1, linked into `~/bin` by the existing `link_children tools bin`), the OpenCode plugin directory (Task 5), the hook adapter (Task 6).

- [ ] **Step 1: Write failing tests**: after `run_install`, `$HOME/.config/agent-guard/policy.json` is a symlink to `$REPO/shared/agent-guard/policy.json`; `$HOME/bin/agent-guard` links to `$REPO/tools/bin/agent-guard`; `$HOME/.config/opencode/plugins/agent-guard` links to `$REPO/opencode/plugins/agent-guard`; `jq` on `$REPO/claude/settings.json` shows a `PreToolUse` hook with matcher `Bash|Write|Edit|MultiEdit|NotebookEdit`, command `"$HOME/bin/agent-guard" claude` and `onFailure` equal to `block`; with an overlay holding `shared/agent-guard/policy.json` that adds a `dbClients` entry, the installed policy is a merged regular file with both entries; a second `run_install` makes 0 changes; `--uninstall` removes the policy and plugin links.
- [ ] **Step 2: Run** `bash tests/run.sh 2>&1 | grep -A5 test_ag_install`. Expected: FAIL.
- [ ] **Step 3: Implement** in `install.sh`: in `install_all`, `install_json shared agent-guard/policy.json "${XDG_CONFIG_HOME:-$HOME/.config}/agent-guard/policy.json"`; add `plugins` to the `for kind in skills agents commands` loop that links OpenCode-only entries; add `shared/agent-guard/policy.json` to the `preflight_overlay` file list. In `claude/settings.json` add the `PreToolUse` entry beside the existing `SessionStart` hook.
- [ ] **Step 4: Docs.** `README.md`: layout-table rows for `shared/agent-guard/`, `opencode/plugins/` and `tools/bin/agent-guard`, and an "Agent guard" section: what it gates, `shadow` versus `enforce`, the log path, `agent-guard check '<cmd>'`, and the review one-liner `jq -r 'select(.decision!="none") | [.decision,.rule,.command] | @tsv' ~/.local/state/agent-guard/decisions.jsonl | sort | uniq -c | sort -rn`. `shared/AGENTS.md`: under the global rules, "Destructive commands (database clients, cluster and cloud mutations, force-push, deletes) are gated by `agent-guard`; state the target in one line in chat before running one." (OpenCode does not show the hook's message in the approval dialog.)
- [ ] **Step 5: Run** `bash tests/run.sh` and `./install.sh --dry-run`. Expected: `0 failed`; the dry run lists the new links and nothing unexpected.
- [ ] **Step 6: Commit**

```bash
git add install.sh claude/settings.json shared/AGENTS.md README.md tests
git commit -m "feat(guard): install the guard for OpenCode and Claude Code in shadow mode"
```

### Task 8: Live verification and rollout (manual)

No code. Run after Task 7 is merged and `./install.sh` has been run.

- [ ] **Step 1: OpenCode V2 live check.** In OpenCode V2, with a local policy copy set to `enforce`, ask the agent to run `sh -c 'psql --version'`. Expected: an approval prompt for that command; a subagent (task) doing the same is also prompted; with the plugin file made unreadable, the prompt still appears (fail-closed). Record anything that differs from Task 0 in spec section 9.
- [ ] **Step 2: Claude Code live check.** Same command in Claude Code with `enforce`. Expected: a prompt showing `agent-guard: ...` and the exact command. Choose "Yes, and don't ask again" if offered and repeat. Expected: it prompts again; if it does not, switch that rule to `deny` (spec section 6 fallback) and record it.
- [ ] **Step 3: Run in shadow** for several days of normal work in both tools. Review the log with the README one-liner; add each miss and false ask to `tests/agent_guard_corpus.tsv` and fix the rules.
- [ ] **Step 4: Switch to enforce** by setting `mode` to `enforce` in `shared/agent-guard/policy.json`, run `bash tests/run.sh`, and commit as `feat(guard): enforce the policy`.
- [ ] **Step 5: File follow-up issues in Linear** (with the user's confirmation): Kilo support (if it is installed later); the broken `SessionStart` hook path in `claude/settings.json`; find the "HARD RULE on database operations" text and make the policy its single source.
