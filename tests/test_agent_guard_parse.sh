#!/usr/bin/env bash
# Tests for the agent-guard shell parser and unwrapper.

ag_parse() { python3 "$ROOT/tools/bin/agent-guard" parse "$1" | jq -c '.argv'; }

test_ag_parse_splits_operators() {
  assert_eq '["a","1"]
["b","2"]
["c"]
["d"]' "$(ag_parse 'a 1 && b 2 | c; d')" "operators split into four invocations"
}

test_ag_parse_quotes_hide_operators() {
  assert_eq '["echo","a; psql"]' "$(ag_parse 'echo "a; psql"')" "quoted operators stay in one word"
}

test_ag_parse_unwraps_wrappers() {
  assert_contains "$(ag_parse 'timeout 5 env X=1 kubectl delete ns demo')" '["kubectl","delete","ns","demo"]' "timeout and env are stripped"
  assert_contains "$(ag_parse "bash -c 'psql -c \"select 1\"'")" '["psql","-c","select 1"]' "bash -c script is parsed"
  assert_contains "$(ag_parse 'kubectl exec pod -- psql')" '["psql"]' "kubectl exec inner command is found"
}

test_ag_parse_xargs_and_subst() {
  local out
  out="$(python3 "$ROOT/tools/bin/agent-guard" parse 'kubectl get pods | xargs kubectl delete' | jq -c 'select(.argv == ["kubectl","delete"]) | .via_xargs')"
  assert_eq 'true' "$out" "xargs inner command is marked via_xargs"
  assert_contains "$(ag_parse 'echo $(rm -f x)')" '["rm","-f","x"]' "command substitution is parsed"
}

test_ag_parse_heredoc_is_data() {
  assert_eq '["cat"]' "$(ag_parse $'cat <<EOF\npsql\nEOF')" "heredoc body is not a command"
}

test_ag_parse_never_crashes() {
  local big
  big="$(head -c 100000 /dev/zero | tr '\0' 'a')"
  python3 "$ROOT/tools/bin/agent-guard" parse 'echo "abc' >/dev/null 2>&1; assert_eq 0 "$?" "unterminated quote exits 0"
  python3 "$ROOT/tools/bin/agent-guard" parse '' >/dev/null 2>&1; assert_eq 0 "$?" "empty string exits 0"
  python3 "$ROOT/tools/bin/agent-guard" parse "$big" >/dev/null 2>&1; assert_eq 0 "$?" "100000 characters exits 0"
  python3 "$ROOT/tools/bin/agent-guard" parse $'echo \xff\xfe' >/dev/null 2>&1; assert_eq 0 "$?" "invalid UTF-8 exits 0"
}
