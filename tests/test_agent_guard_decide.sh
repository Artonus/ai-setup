#!/usr/bin/env bash
# Tests for the agent-guard shared decision entry (agent-guard decide), log and modes.

ag_dec_setup() { # ag_dec_setup <mode>: temp policy with the given mode, empty log
  AG_D="$(mktemp -d)"
  jq --arg m "$1" '.mode = $m' "$ROOT/shared/agent-guard/policy.json" >"$AG_D/policy.json"
  AG_LOG="$AG_D/state/log.jsonl"
  mkdir -p "$AG_D/proj" "$AG_D/home"
}

ag_decide() { # ag_decide <json>: pipe a request into agent-guard decide
  printf '%s' "$1" | AGENT_GUARD_POLICY="${AG_POLICY:-$AG_D/policy.json}" AGENT_GUARD_LOG="$AG_LOG" \
    HOME="$AG_D/home" python3 "$ROOT/tools/bin/agent-guard" decide
}

ag_req() { # ag_req <command> [extra jq object]: a bash request
  jq -nc --arg c "$1" --arg d "$AG_D/proj" \
    '{source:"claude",tool:"bash",command:$c,cwd:$d,project_dir:$d,session_id:"s1",agent_id:"",agent_type:"",permission_mode:"default"}'
}

test_ag_decide_enforce_asks() {
  ag_dec_setup enforce
  local out; out="$(ag_decide "$(ag_req 'kubectl delete ns demo')")"
  assert_eq ask "$(jq -r .decision <<<"$out")" "decision"
  assert_eq true "$(jq -r .enforced <<<"$out")" "enforced"
  assert_contains "$(jq -r .reason <<<"$out")" "kubectl delete ns demo" "reason"
  rm -rf "$AG_D"
}

test_ag_decide_enforce_denies_secret_read() {
  ag_dec_setup enforce
  local out; out="$(ag_decide "$(ag_req 'cat ~/.ssh/id_ed25519')")"
  assert_eq deny "$(jq -r .decision <<<"$out")" "secret read"
  rm -rf "$AG_D"
}

test_ag_decide_path_tool() {
  ag_dec_setup enforce
  local out
  out="$(ag_decide "$(jq -nc --arg d "$AG_D/proj" '{source:"claude",tool:"Read",path:"~/.ssh/id_ed25519",cwd:$d,project_dir:$d}')")"
  assert_eq deny "$(jq -r .decision <<<"$out")" "read of secret path"
  assert_contains "$(tail -n1 "$AG_LOG")" '"command": "~/.ssh/id_ed25519"' "path logged as command"
  rm -rf "$AG_D"
}

test_ag_decide_none() {
  ag_dec_setup enforce
  assert_eq none "$(ag_decide "$(ag_req 'ls')" | jq -r .decision)" "ls"
  rm -rf "$AG_D"
}

test_ag_decide_shadow_not_enforced() {
  ag_dec_setup shadow
  local out; out="$(ag_decide "$(ag_req 'kubectl delete ns demo')")"
  assert_eq ask "$(jq -r .decision <<<"$out")" "decision"
  assert_eq false "$(jq -r .enforced <<<"$out")" "not enforced"
  assert_eq shadow "$(jq -r .mode "$AG_LOG")" "log mode"
  assert_eq 1 "$(wc -l <"$AG_LOG" | tr -d ' ')" "one log line"
  rm -rf "$AG_D"
}

test_ag_decide_logs_agent() {
  ag_dec_setup shadow
  ag_decide "$(ag_req 'ls' | jq -c '.agent_id="a1" | .agent_type="general-purpose"')" >/dev/null
  local line; line="$(tail -n1 "$AG_LOG")"
  assert_eq a1 "$(jq -r .agent_id <<<"$line")" "agent_id"
  assert_eq general-purpose "$(jq -r .agent_type <<<"$line")" "agent_type"
  assert_eq claude "$(jq -r .source <<<"$line")" "source"
  assert_eq s1 "$(jq -r .session_id <<<"$line")" "session_id"
  assert_eq default "$(jq -r .permission_mode <<<"$line")" "permission_mode"
  assert_eq bash "$(jq -r .tool <<<"$line")" "tool"
  rm -rf "$AG_D"
}

test_ag_decide_masks_secrets() {
  ag_dec_setup shadow
  ag_decide "$(ag_req 'curl -d password=hunter2 https://x.test')" >/dev/null
  local line; line="$(tail -n1 "$AG_LOG")"
  assert_contains "$line" 'password=***' "masked"
  case $line in *hunter2*) fail "secret leaked into log" ;; *) ok ;; esac
  ag_decide "$(ag_req $'cat <<EOF\nsupersecretbody\nEOF')" >/dev/null
  line="$(tail -n1 "$AG_LOG")"
  case $line in *supersecretbody*) fail "heredoc body leaked into log" ;; *) ok ;; esac
  assert_contains "$line" '<<heredoc>>' "heredoc marker"
  rm -rf "$AG_D"
}

test_ag_decide_bad_input() {
  ag_dec_setup shadow
  local out rc big
  out="$(printf '' | AGENT_GUARD_POLICY="$AG_D/policy.json" AGENT_GUARD_LOG="$AG_LOG" python3 "$ROOT/tools/bin/agent-guard" decide)"; rc=$?
  assert_eq 0 "$rc" "empty stdin exit"
  assert_eq guard-error "$(jq -r .rule <<<"$out")" "empty stdin rule"
  out="$(ag_decide 'not json')"; rc=$?
  assert_eq 0 "$rc" "not json exit"
  assert_eq ask "$(jq -r .decision <<<"$out")" "not json decision"
  big="$(head -c 100000 /dev/zero | tr '\0' 'a')"
  out="$(ag_decide "$(ag_req "echo $big")")"; rc=$?
  assert_eq 0 "$rc" "big command exit"
  assert_eq none "$(jq -r .decision <<<"$out")" "big command decision"
  assert_eq 1 "$(( $(tail -n1 "$AG_LOG" | jq -r '.command | length') <= 300 ))" "command capped"
  out="$(printf '{"source":"claude","tool":"bash","command":"echo \xff\xfe"}' | AGENT_GUARD_POLICY="$AG_D/policy.json" AGENT_GUARD_LOG="$AG_LOG" python3 "$ROOT/tools/bin/agent-guard" decide)"; rc=$?
  assert_eq 0 "$rc" "invalid utf-8 exit"
  assert_contains "$(jq -r .decision <<<"$out")" "" "invalid utf-8 output is json"
  case "$(jq -r .decision <<<"$out")" in ask|none) ok ;; *) fail "invalid utf-8 decision: $out" ;; esac
  rm -rf "$AG_D"
}

test_ag_decide_broken_policy() {
  ag_dec_setup enforce
  local out
  out="$(AG_POLICY="$AG_D/missing.json" ag_decide "$(ag_req 'ls')")"
  assert_eq ask "$(jq -r .decision <<<"$out")" "missing policy"
  assert_eq guard-error "$(jq -r .rule <<<"$out")" "missing policy rule"
  assert_eq shadow "$(jq -r .mode <<<"$out")" "mode falls back to shadow"
  printf '{broken' >"$AG_D/bad.json"
  out="$(AG_POLICY="$AG_D/bad.json" ag_decide "$(ag_req 'ls')")"
  assert_eq guard-error "$(jq -r .rule <<<"$out")" "invalid policy rule"
  # mode now comes from the last log line, which was written under shadow; seed an enforce line
  printf '%s\n' '{"mode": "enforce"}' >>"$AG_LOG"
  out="$(AG_POLICY="$AG_D/bad.json" ag_decide "$(ag_req 'ls')")"
  assert_eq enforce "$(jq -r .mode <<<"$out")" "mode from last log line"
  assert_eq true "$(jq -r .enforced <<<"$out")" "enforced from log mode"
  rm -rf "$AG_D"
}
