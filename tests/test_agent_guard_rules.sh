#!/usr/bin/env bash
# Tests for the agent-guard policy rules.

ag_check() { AGENT_GUARD_POLICY="$ROOT/shared/agent-guard/policy.json" python3 "$ROOT/tools/bin/agent-guard" check "$1"; }

test_ag_corpus_matches() {
  local cmd want got
  while IFS=$'\t' read -r cmd want; do
    case "$cmd" in '' | '#'*) continue ;; esac
    got="$(ag_check "$cmd" | cut -f1)"
    assert_eq "$want" "$got" "corpus: $cmd"
  done <"$ROOT/tests/agent_guard_corpus.tsv"
}

test_ag_heredoc_body_is_data() {
  assert_eq none "$(ag_check $'cat <<EOF\npsql\nkubectl delete ns x\nEOF' | cut -f1)" "heredoc body gives no opinion"
}

test_ag_check_output_format() {
  local out
  out="$(ag_check 'kubectl delete ns demo')"
  assert_eq ask "$(printf '%s' "$out" | cut -f1)" "decision field"
  assert_eq cluster-mutation "$(printf '%s' "$out" | cut -f2)" "rule field"
  assert_contains "$(printf '%s' "$out" | cut -f3)" "delete" "reason names the verb"
  assert_contains "$(ag_check 'kubectl exec p -- ls')" "kubectl exec" "kubectl exec is named in the reason"
  assert_eq none "$(ag_check 'ls')" "no opinion prints none"
}

test_ag_explain_lists_invocations() {
  local out
  out="$(AGENT_GUARD_POLICY="$ROOT/shared/agent-guard/policy.json" python3 "$ROOT/tools/bin/agent-guard" explain 'ls; psql -c x')"
  assert_contains "$out" "psql" "explain shows the invocation"
  assert_contains "$out" "db-client" "explain shows the rule"
}

test_ag_never_crashes_on_odd_input() {
  local big
  big="$(head -c 100000 /dev/zero | tr '\0' 'a')"
  ag_check '' >/dev/null 2>&1; assert_eq 0 "$?" "empty command"
  ag_check "$big" >/dev/null 2>&1; assert_eq 0 "$?" "100 KB command"
  ag_check 'psql "abc' >/dev/null 2>&1; assert_eq 0 "$?" "unterminated quote"
}
