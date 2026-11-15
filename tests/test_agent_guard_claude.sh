#!/usr/bin/env bash
# Tests for the agent-guard Claude Code hook adapter (agent-guard claude).

ag_cl_setup() { # ag_cl_setup <mode>
  AG_D="$(mktemp -d)"
  jq --arg m "$1" '.mode = $m' "$ROOT/shared/agent-guard/policy.json" >"$AG_D/policy.json"
  AG_LOG="$AG_D/state/log.jsonl"
  mkdir -p "$AG_D/proj" "$AG_D/home"
}

ag_claude() { # ag_claude <stdin text>: run the hook, print stdout; exit code goes to $AG_D/rc
  local rc=0
  printf '%s' "$1" | AGENT_GUARD_POLICY="$AG_D/policy.json" AGENT_GUARD_LOG="$AG_LOG" \
    HOME="$AG_D/home" python3 "$ROOT/tools/bin/agent-guard" claude || rc=$?
  echo "$rc" >"$AG_D/rc"
}

ag_rc() { cat "$AG_D/rc"; }

ag_hook_json() { # ag_hook_json <tool_name> <tool_input json>
  jq -nc --arg t "$1" --argjson i "$2" --arg d "$AG_D/proj" \
    '{tool_name:$t,tool_input:$i,cwd:$d,session_id:"s1",agent_id:null,agent_type:null,permission_mode:"auto"}'
}

test_ag_claude_enforce_asks() {
  ag_cl_setup enforce
  local out; out="$(ag_claude "$(ag_hook_json Bash '{"command":"kubectl delete ns demo"}')")"
  assert_eq 0 "$(ag_rc)" "exit"
  assert_eq 1 "$(wc -l <<<"$out" | tr -d ' ')" "one line"
  assert_eq ask "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")" "decision"
  assert_eq PreToolUse "$(jq -r .hookSpecificOutput.hookEventName <<<"$out")" "event"
  local reason; reason="$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$out")"
  assert_contains "$reason" "agent-guard: " "prefix"
  assert_contains "$reason" "Command: kubectl delete ns demo" "command"
  rm -rf "$AG_D"
}

test_ag_claude_denies_secret_read() {
  ag_cl_setup enforce
  local out; out="$(ag_claude "$(ag_hook_json Bash '{"command":"cat ~/.ssh/id_ed25519"}')")"
  assert_eq 0 "$(ag_rc)" "exit"
  assert_eq deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")" "decision"
  rm -rf "$AG_D"
}

test_ag_claude_none_is_silent() {
  ag_cl_setup enforce
  assert_eq "" "$(ag_claude "$(ag_hook_json Bash '{"command":"ls"}')")" "ls silent"
  assert_eq 0 "$(ag_rc)" "exit"
  assert_eq "" "$(ag_claude "$(ag_hook_json Read '{"file_path":"/etc/hosts"}')")" "other tool silent"
  assert_eq 0 "$(ag_rc)" "exit other"
  assert_eq "" "$(ag_claude '{"tool_name":"Bash","tool_input":null}')" "null tool_input silent"
  assert_eq 0 "$(ag_rc)" "exit null input"
  rm -rf "$AG_D"
}

test_ag_claude_shadow_is_silent() {
  ag_cl_setup shadow
  assert_eq "" "$(ag_claude "$(ag_hook_json Bash '{"command":"kubectl delete ns demo"}')")" "silent"
  assert_eq 0 "$(ag_rc)" "exit"
  assert_eq ask "$(jq -r .decision "$AG_LOG")" "logged decision"
  assert_eq claude "$(jq -r .source "$AG_LOG")" "logged source"
  rm -rf "$AG_D"
}

test_ag_claude_edit_path() {
  ag_cl_setup enforce
  local out
  out="$(ag_claude "$(ag_hook_json Write '{"file_path":"~/.zshrc","content":"x"}')")"
  assert_eq ask "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")" "write"
  assert_contains "$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$out")" "Path: ~/.zshrc" "path"
  out="$(ag_claude "$(ag_hook_json Edit '{"file_path":"~/.zshrc"}')")"
  assert_eq ask "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")" "edit"
  out="$(ag_claude "$(ag_hook_json MultiEdit '{"file_path":"~/.zshrc"}')")"
  assert_eq ask "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")" "multiedit"
  out="$(ag_claude "$(ag_hook_json NotebookEdit '{"notebook_path":"~/.zshrc"}')")"
  assert_eq ask "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")" "notebook"
  rm -rf "$AG_D"
}

test_ag_claude_subagent_logged() {
  ag_cl_setup shadow
  ag_claude "$(ag_hook_json Bash '{"command":"ls"}' | jq -c '.agent_id="a1" | .agent_type="general-purpose"')" >/dev/null
  assert_eq a1 "$(jq -r .agent_id "$AG_LOG")" "agent_id"
  assert_eq general-purpose "$(jq -r .agent_type "$AG_LOG")" "agent_type"
  assert_eq auto "$(jq -r .permission_mode "$AG_LOG")" "permission_mode"
  rm -rf "$AG_D"
}

test_ag_claude_bad_input() {
  ag_cl_setup enforce
  local out inp
  local big; big="$(head -c 100000 /dev/zero | tr '\0' 'a')"
  for inp in "" "not json" "[1,2]" "$big"; do
    out="$(ag_claude "$inp")"
    assert_eq 0 "$(ag_rc)" "exit enforce"
    assert_eq ask "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")" "enforce asks"
  done
  out="$(printf '\377\376\200' | AGENT_GUARD_POLICY="$AG_D/policy.json" AGENT_GUARD_LOG="$AG_LOG" HOME="$AG_D/home" python3 "$ROOT/tools/bin/agent-guard" claude; echo "rc=$?")"
  assert_contains "$out" "rc=0" "exit non-utf8"
  assert_contains "$out" "\"permissionDecision\": \"ask\"" "non-utf8 asks"
  rm -rf "$AG_D"
  ag_cl_setup shadow
  for inp in "" "not json"; do
    assert_eq "" "$(ag_claude "$inp")" "shadow silent"
    assert_eq 0 "$(ag_rc)" "exit shadow"
  done
  rm -rf "$AG_D"
}
