# Agent guard: a global permission layer for AI agents

- **Date:** 2026-11-13
- **Status:** Draft, for review
- **Issue:** [AAR-24](https://linear.app/aartuss/issue/AAR-24/create-a-global-permission-manager-for-ai-agents)
- **Targets:** OpenCode V2 (main working environment, built and verified first) and Claude Code,
  both in the same plan. Kilo later, if it is installed.

## 1. Problem

Agents (Claude Code, OpenCode, subagents) run with the user's full credentials. Today the only
guard is a short `permissions.deny` list in `claude/settings.json` (force-push, `reset --hard`,
`rm -rf`, `sudo`, a few secret paths) and a prose rule in `AGENTS.md`. Prefix patterns do not
survive wrapped commands:

- `bash -c "..."`, `sh script.sh`, `env X=1 cmd`, `timeout 5 cmd`
- `kubectl exec pod -- psql ...`, `xargs`, `$(...)`
- `git push origin +main` (not matched by `git push --force`)

Nothing covers databases, `kubectl`, `aws`, `terraform`, branch deletion or file overwrites.

## 2. Goal and non-goals

**Goal.** One central policy, installed from this repo, that applies to every project and every
agent. A destructive or hard-to-reverse command is blocked until a human approves that exact
command. Subagents are covered. An unclassifiable command on a sensitive tool fails closed.

**Non-goals.**

- Protection against an agent acting in bad faith (it can still write and run its own binary).
- A sandbox or network control. Both are a separate, later step.
- Classifying every shell command. Only sensitive tools are gated; the rest follows the normal
  permission flow, so local work is not slowed down.
- Dev-versus-prod target detection in v1 (see section 9).

## 3. Decision: where to enforce

| Option | Verdict |
|---|---|
| `settings.json` permission patterns only | Rejected as the main gate: bypassable by wrapping, and OpenCode needs its own list. Kept as a second layer. |
| Wrapper or proxy around the shell | Rejected: heavy, and agents can route around it. |
| **`PreToolUse` hook calling one policy script** | **Chosen.** Sees the full command, can return allow, ask or deny with a reason, and fires for subagents. |

Facts checked in the Claude Code docs (v2.1.319 installed):

- A hook `ask` still prompts in `auto` mode, and `permissionDecisionReason` is shown in the prompt.
- Exit code 2 or `deny` blocks before permission rules run, so an allow rule cannot override it.
- Deny and ask rules are still evaluated whatever the hook returns.
- `PreToolUse` fires for subagent tool calls, and the input carries `agent_id` and `agent_type`.
- A hook that crashes, times out or exits with a code other than 0 or 2 **does not block**. The
  hook must set `"onFailure": "block"` (needs Claude Code 2.1.295 or later).

## 4. Architecture

```
Claude Code tool call (main agent or subagent)
        |
        v
PreToolUse hook (matcher: Bash|Write|Edit|MultiEdit|NotebookEdit, onFailure: block)
        |   stdin: tool_name, tool_input, cwd, agent_id, agent_type
        v
agent-guard claude            <- tools/bin/agent-guard (Python 3, standard library only)
   1. parse: split the command into invocations
   2. unwrap: env, timeout, nohup, sudo, sh -c, bash -c, $(...), xargs, ssh host cmd
   3. match each invocation against the policy
   4. strictest decision wins; write one log line
        |
        v
stdout JSON: permissionDecision allow-with-no-opinion | ask | deny  (+ reason)
```

Returning no decision (exit 0, no output) leaves the call to the normal permission flow. The
guard never grants permission; it only adds `ask` or `deny`.

**Files.**

| Path | Role |
|---|---|
| `tools/bin/agent-guard` | Entry point, linked into `~/bin`. Subcommands: `claude` (hook adapter), `check '<cmd>'` (CLI for tests and debugging), `explain '<cmd>'` (shows which rule matched). |
| `tools/lib/agent_guard/` | `parse.py`, `unwrap.py`, `rules.py`, `log.py`, `hookio.py`. Standard library only. |
| `shared/agent-guard/policy.json` | The policy. Installed to `~/.config/agent-guard/policy.json`. Merged with the overlay's copy like the other JSON configs (arrays are unioned, so an overlay can add rules but never remove base ones). |
| `claude/settings.json` | Adds the `PreToolUse` hook entry. |
| `tests/test_agent_guard.sh` and `tests/agent_guard_corpus.tsv` | Corpus of command, expected decision. |

The installer change is small: one more `install_json`-style target for the policy file, and the
file added to `preflight_overlay`'s list. The hook command uses `$HOME/bin/agent-guard`.

## 5. Policy

Each rule has: tool match, verb match, decision (`ask` or `deny`), and a short reason. The first
column is the area from the issue.

| Area | Rule | Decision |
|---|---|---|
| Database | Any invocation of `psql`, `mysql`, `mariadb`, `mongosh`, `redis-cli`, `sqlite3` (write or unknown), `pg_restore`, `kubectl cnpg`, `kubectl exec ... -- <db client>` | ask |
| Database | `aws rds-data execute-statement`, `aws rds delete-*\|modify-*\|reboot-*`, `aws dynamodb` non-read verbs | ask |
| Database | Inline SQL words (`DROP`, `TRUNCATE`, `DELETE FROM`, `ALTER`, `UPDATE`, `INSERT`, `GRANT`) in args or heredocs of a DB client | ask (already covered by the rule above; kept as a reason string) |
| Cluster | `kubectl`, `helm`, `flux`, `talosctl`: read verbs allowed (`get`, `describe`, `logs`, `top`, `events`, `diff`, `explain`, `version`, `config view`); everything else | ask |
| Cluster | `kubectl exec`, `kubectl cp`, `kubectl delete`, `kubectl drain`, `helm uninstall` | ask (named in the reason) |
| Cloud | `aws`: read verbs allowed (`describe-*`, `list-*`, `get-*`, `head-*`, `s3 ls`, `sts get-caller-identity`); everything else | ask |
| Cloud | `aws ssm start-session`, `aws ecs execute-command` | ask |
| Cloud | `terraform` and `tofu`: `plan`, `validate`, `fmt`, `show`, `output`, `state list\|show` allowed; `apply`, `destroy`, `import`, `state rm\|mv\|push`, `taint`, `force-unlock` | ask |
| Git | `push --force\|-f\|--force-with-lease\|--delete\|-d\|--mirror`, refspec with `+` or leading `:`; `reset --hard`; `branch -D\|-d\|--delete`; `clean -f*`; `checkout .\|--`; `restore .`; `stash drop\|clear`; `rebase` on a pushed branch; `reflog expire`; `gc --prune` | ask |
| Files | `rm`, `rmdir`, `shred`, `find ... -delete\|-exec rm`, `mv` or `cp` onto an existing file, `>` redirect onto an existing file, `truncate`, `dd of=` | ask unless every target is inside the project directory or `$TMPDIR` and not a protected path |
| Files | `Write` or `Edit` on a path outside the project or on a protected path (`~/.ssh`, `~/.aws`, `~/.claude`, `~/.config`, shell rc files) | ask |
| Secrets | Reads of `~/.ssh/id_*`, `~/.aws/credentials`, `.env*` | deny (the existing `Read` deny rules stay; the guard adds the shell route, e.g. `cat ~/.ssh/id_x`) |
| AI setup | Writes under `~/.claude` or `~/.config/opencode` | ask, with the reason "change the AI setup in the ai-setup repo" |

`sudo` and `rm -rf` stay in `permissions.deny` as they are.

**Unclassifiable commands (fail closed, but only where it matters).**

| Situation | Decision |
|---|---|
| A sensitive tool appears and the verb, subcommand or target is dynamic (`kubectl $VERB`, `$K get`) | ask |
| `eval`, `xargs <sensitive tool>`, `sh -c` with a body that hides a sensitive tool, a script from `$TMPDIR` | ask |
| The parser fails on a command that mentions a sensitive tool name anywhere | ask |
| The parser fails and no sensitive tool name appears | no opinion (normal permission flow) |
| An unknown binary | no opinion (normal permission flow) |
| The guard itself errors or times out | block (`onFailure: block`), with a message to retry or ask the user |

Project scripts (`make deploy`, `./scripts/x.sh`, `npm run ...`) are not inspected. This is a
known gap, accepted for v1 and listed in section 10.

## 6. Approvals and audit

- **Shown:** the hook returns `ask` with a reason that names the tool, verb and, when it can be
  read from the command, the target. Example: `agent-guard: kubectl delete (cluster mutation) on
  context from current kubeconfig. Command: kubectl delete ns demo`. Claude Code puts this in the
  permission prompt.
- **One-time:** the guard asks on every matching call. It never writes an allow rule.
- **Saved approvals:** a saved "Yes, don't ask again" approval is stored as an allow rule. The
  spike (section 8) showed that a matching allow rule does not skip a hook `ask`. A true
  interactive "don't ask again" click was not tested, only the equivalent allow rule. Re-check
  it once in the first interactive session. If it does skip the hook, the fallback is to return
  `deny` with a message telling the agent to ask the user in chat.
- **Recorded:** one JSON line per decision in `~/.local/state/agent-guard/decisions.jsonl`:
  timestamp, session id, `agent_id`, `agent_type`, tool, decision, matched rule id, and the command
  (heredoc bodies replaced, `password|token|secret|key=` values masked, length capped). The log
  records what was asked, not what the user answered; Claude Code does not report the answer to the
  hook.

## 7. Modes and failure handling

`mode` in `policy.json` (and the overlay): `shadow` or `enforce`.

- **shadow:** the guard logs what it would decide and returns no opinion. Used for the first days.
- **enforce:** the guard returns `ask` or `deny`.
- The hook is registered with `onFailure: block`, so a missing or crashing script blocks tool calls
  instead of silently removing the gate. In `shadow` mode the adapter catches its own errors and
  exits 0, so a bug cannot block work while the policy is being tuned.
- A broken or unreadable policy file in `enforce` mode makes the guard ask for every matching tool
  call, never allow.

## 8. Rollout and tests

1. **Corpus first.** A TSV of commands and expected decisions, including the bypasses from section
   1 and the safe commands we use every day. The corpus runs through `agent-guard check` in
   `tests/run.sh`.
2. **Spike (done 2026-11-14, Claude Code 2.1.319, `claude -p --settings <file>`, mode `auto`):**
   - A hook `ask` with no allow rule: the call did not run, and the hook's reason text reached
     the result. In `-p` mode nobody can answer, so the call is refused. The prompt display itself
     was not seen.
   - A hook `ask` with a matching allow rule (`Bash(echo spike-ask:*)`): the call still did not
     run. An allow rule does not override the hook.
   - A subagent (`general-purpose`) call reached the hook with `agent_id` and `agent_type` set,
     and the hook's `deny` blocked it. Main-agent calls have both fields null.
   - A hook command that does not exist, with `onFailure: block`: the call was blocked with
     `failed; blocking because onFailure is "block"`.
   - The hook input includes `permission_mode` (`auto` here), which the guard can log.
   - Still to confirm interactively: the prompt text, and a real "don't ask again" click.
3. **Implement** parser, unwrapper, rules, log, and the hook adapter. Install through `install.sh`.
4. **Shadow** for a few days of real use. Review the log for false asks and misses, then tune.
5. **Enforce** in one commit, easy to revert.
6. **Docs.** Update `AGENTS.md` with one line: sensitive commands are gated by `agent-guard`; state
   the target in one line before running them. Update `README.md`'s layout table. The "HARD RULE on
   database operations" mentioned in the issue is not in this repo; find where it lives (work
   overlay or memory) and make the policy file its single source.

## 9. OpenCode V2 adapter (main environment; same plan as the Claude Code hook)

Target: OpenCode V2 (the `opencode2` binary; `opencode` 1.18.34 on this machine is V1 and rejects
the repo's V2 `opencode.json`, so the install on each machine must be checked first).

- A directory plugin in `opencode/plugins/agent-guard/`, linked into `~/.config/opencode/plugins`.
  It registers `ctx.permission.hook("evaluate")` for `shell`, `edit` and `write` actions, runs
  `agent-guard check --json` as a subprocess with a time budget, and sets `effect` and `message`.
- Config `deny` is final and never reaches the hook (OpenCode behaviour), so the plugin only adds
  `ask` and `deny`.
- Known limits from the reference implementation: `message` is not shown in the approval dialog (it
  goes to the model), so agents are told to state the target in one line before running a gated
  command.
- Needs verification on V2: that the hook fires for subagent sessions, that a subprocess call is
  allowed from a plugin, and fail-closed behaviour when the plugin errors.
- Kilo: not installed on this machine. Revisit when it is; it uses V1 permission keys.

## 10. Risks and deferred items

- **Wrapped or opaque execution** (project scripts, binaries the agent writes and runs) is not
  inspected. A sandbox is the real fix and is out of scope.
- **Parser coverage.** A hand-written parser will miss shell corners. The rule is to over-match
  (extra asks) rather than miss, and the corpus grows with every miss found in shadow mode.
- **Target classes.** v1 asks for every cluster or cloud mutation. If that is too noisy, add
  `dev`/`prod`/`home` context lists in `policy.json` later, as in jabbas/opencode-config's
  `permission-model` (a reference for the model, not a dependency).
- **Existing bug, unrelated:** `claude/settings.json` has a `SessionStart` hook pointing at
  `/home/bbratus@atsi.zab/.claude/hooks/herdr-agent-state.sh`, a path that does not exist on this
  Mac. Worth its own issue.

## 11. Done when

- A destructive command from an agent (main or subagent) is blocked until the user approves it,
  shown in the prompt with the exact command.
- The guard is installed through `install.sh` and covered by `tests/run.sh`.
- Both the OpenCode V2 plugin and the Claude Code hook run in enforce mode, after a shadow period.
