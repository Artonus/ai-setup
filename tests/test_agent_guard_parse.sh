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

ag_full() { python3 "$ROOT/tools/bin/agent-guard" parse "$1" | jq -c '[.argv, .opaque]'; }

test_ag_parse_deep_wrapper_stack_is_opaque() {
  local out
  out="$(python3 "$ROOT/tools/bin/agent-guard" parse "$(printf 'sudo %.0s' $(seq 25))psql" | jq -c 'select(.opaque) | .opaque')"
  assert_contains "$out" 'true' "a wrapper stack past the depth cap is marked opaque"
}

test_ag_parse_shell_options_before_c() {
  assert_contains "$(ag_parse 'bash --norc -c "psql"')" '["psql"]' "long option before -c"
  assert_contains "$(ag_parse 'bash --noprofile --login -c psql')" '["psql"]' "several long options"
  assert_contains "$(ag_parse 'bash -o pipefail -c psql')" '["psql"]' "-o NAME before -c"
  assert_contains "$(ag_parse 'bash -O extglob -c psql')" '["psql"]' "-O NAME before -c"
  assert_contains "$(ag_parse 'zsh -lc psql')" '["psql"]' "combined -lc"
  assert_contains "$(ag_parse "bash -c \"bash -c 'psql'\"")" '["psql"]' "nested bash -c"
}

test_ag_parse_env_split_string() {
  assert_contains "$(ag_parse 'env -S "psql -c 1"')" '["psql","-c","1"]' "env -S command is reparsed"
}

test_ag_parse_opaque_constructs() {
  assert_contains "$(ag_full 'eval "psql -c 1"')" '[["eval","psql -c 1"],true]' "eval is opaque"
  assert_contains "$(ag_full 'echo psql | bash')" '[["bash"],true]' "bash reading stdin is opaque"
  assert_contains "$(ag_full 'bash <<< "psql"')" '[["bash"],true]' "bash with here-string is opaque"
  assert_contains "$(ag_full 'bash -c psql')" '[["bash","-c","psql"],false]' "bash -c is not opaque"
  assert_contains "$(ag_full 'echo hi')" '[["echo","hi"],false]' "plain command is not opaque"
}

test_ag_parse_find_exec() {
  assert_contains "$(ag_parse 'find . -exec psql \;')" '["psql"]' "find -exec stops at ;"
  assert_contains "$(ag_parse 'find . -name x -exec kubectl delete {} +')" '["kubectl","delete","{}"]' "find -exec stops at +"
  assert_contains "$(ag_parse 'find . -execdir rm {} \; -ok mv {} y \;')" '["mv","{}","y"]' "second exec clause"
}

test_ag_parse_ssh_double_dash() {
  local out
  out="$(ag_parse 'ssh host -- psql')"
  assert_contains "$out" '["psql"]' "inner command starts after --"
  case $out in *'["--"'*) fail "inner argv must not start with --" ;; *) ok ;; esac
}

test_ag_parse_quoting_details() {
  assert_contains "$(ag_parse 'echo "$(psql)"')" '["psql"]' "substitution inside double quotes"
  assert_contains "$(ag_parse 'echo `psql`')" '["psql"]' "backticks"
  assert_eq '["echo","a;b"]' "$(ag_parse 'echo a\;b')" "escaped semicolon"
  assert_eq '["echo","a b"]' "$(ag_parse 'echo a\ b')" "escaped space"
  assert_eq '["echo","x"]' "$(ag_parse $'ec\\\nho x')" "line continuation"
  assert_eq '["ls"]' "$(ag_parse 'ls &> out')" "&> is a redirect, not a separator"
}

test_ag_parse_output_is_json_lines() {
  local c
  for c in 'echo "abc' '' $'echo \xff\xfe' 'a && (b | c) $(d `e`)'; do
    python3 "$ROOT/tools/bin/agent-guard" parse "$c" | jq -s -e 'type=="array"' >/dev/null 2>&1
    assert_eq 0 "$?" "valid JSON lines for: $c"
  done
}

test_ag_parse_generic_wrappers() {
  assert_contains "$(ag_parse 'watch -n 5 kubectl get pods')" '["kubectl","get","pods"]' "watch"
  assert_contains "$(ag_parse 'nice -n 5 psql -c x')" '["psql","-c","x"]' "nice -n"
  assert_contains "$(ag_parse 'nice -5 psql')" '["psql"]' "nice -N"
  assert_contains "$(ag_parse 'ionice -c 3 -n 7 psql')" '["psql"]' "ionice"
  assert_contains "$(ag_parse 'stdbuf -oL -e0 psql')" '["psql"]' "stdbuf"
  assert_contains "$(ag_parse 'stdbuf -o L psql')" '["psql"]' "stdbuf separate mode"
  assert_contains "$(ag_parse 'setsid psql')" '["psql"]' "setsid"
  assert_contains "$(ag_parse 'doas -u root psql')" '["psql"]' "doas"
  assert_contains "$(ag_parse "su -c 'kubectl delete ns x' root")" '["kubectl","delete","ns","x"]' "su -c"
}
