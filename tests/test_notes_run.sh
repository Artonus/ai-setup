#!/usr/bin/env bash
# Tests for tools/bin/meeting-notes-run and meeting-notify, with fake agent and desktop tools.
# Helpers are prefixed _n_ so run.sh does not take them for tests.

_n_RUN="$ROOT/tools/bin/meeting-notes-run"
_n_NOTIFY="$ROOT/tools/bin/meeting-notify"
_n_TOKEN="s3cr3t-token-value"

_n_setup() {
  N_DIR="$T/notes"
  N_BIN="$T/bin"
  N_CALLS="$T/agent.calls"
  mkdir -p "$N_DIR" "$N_BIN"
  : > "$N_CALLS"
  printf 'Me: hello\nRemote 1: hi\n' > "$N_DIR/meeting-2026-01-01-1000.txt"
  N_TR="$N_DIR/meeting-2026-01-01-1000.txt"
  # fake agent: logs the call, prints a report; behaviour switched by files in $T
  cat > "$N_BIN/agent" <<EOS
#!/usr/bin/env bash
echo "called \$MEETING_NOTES_FILE" >> "$N_CALLS"
echo "token-seen \$TRILIUM_MCP_TOKEN" >> "$T/agent.env"
[ -f "$T/agent-sleep" ] && sleep "\$(cat "$T/agent-sleep")"
if [ -f "$T/agent-fail" ]; then echo "boom with \$TRILIUM_MCP_TOKEN" >&2; exit 7; fi
echo "# Report"
echo "Proposed Todoist tasks: none"
echo "NOTE_TITLE: Standup 2026-01-01"
[ -f "$T/agent-noid" ] || echo "NOTE_ID: abc123"
EOS
  chmod +x "$N_BIN/agent"
}

# _n_run [transcript]: run meeting-notes-run with the fake agent; sets N_OUT and N_RC.
_n_run() {
  N_OUT="$(PATH="$N_BIN:$PATH" MEETING_NOTES_DIR="$N_DIR" MEETING_NOTES_CMD="$N_BIN/agent" \
    MEETING_NOTES_TIMEOUT="${N_TIMEOUT:-20}" TMPDIR="$T" \
    TRILIUM_MCP_URL="${N_URL-http://localhost:1}" TRILIUM_MCP_TOKEN="${N_TOK-$_n_TOKEN}" \
    "$_n_RUN" "${1:-$N_TR}" 2>&1)"
  N_RC=$?
}

test_notes_run_success() {
  _n_setup
  _n_run
  assert_eq 0 "$N_RC" "success exit code"
  [ -f "$N_DIR/meeting-2026-01-01-1000.notes-done" ] && ok || fail "marker missing"
  assert_contains "$(cat "$N_DIR/meeting-2026-01-01-1000.report.md")" "NOTE_ID: abc123" "report content"
  assert_eq 1 "$(wc -l < "$N_CALLS" | tr -d ' ')" "agent called once"
  assert_contains "$(cat "$N_DIR/.notes.log")" "done" "log has done"
  case "$(cat "$N_DIR/.notes.log")$N_OUT" in *"$_n_TOKEN"*) fail "token leaked" ;; *) ok ;; esac
}

test_notes_run_prompt_forbids_todoist() {
  _n_setup
  cat > "$N_BIN/agent" <<EOS
#!/usr/bin/env bash
echo "\$MEETING_NOTES_PROMPT" > "$T/prompt"
echo "NOTE_TITLE: t"
EOS
  _n_run
  assert_contains "$(cat "$T/prompt")" "Do NOT create any Todoist" "prompt forbids todoist"
  assert_contains "$(cat "$T/prompt")" "$N_TR" "prompt names the file"
}

test_notes_run_rerun_is_noop() {
  _n_setup
  _n_run
  _n_run
  assert_eq 0 "$N_RC" "rerun exit code"
  assert_eq 1 "$(wc -l < "$N_CALLS" | tr -d ' ')" "agent not called a second time"
  assert_contains "$(cat "$N_DIR/.notes.log")" "already done" "log notes skip"
}

test_notes_run_agent_failure() {
  _n_setup
  : > "$T/agent-fail"
  _n_run
  assert_eq 1 "$N_RC" "failure exit code"
  [ -e "$N_DIR/meeting-2026-01-01-1000.notes-done" ] && fail "marker must not exist" || ok
  [ -e "$N_DIR/meeting-2026-01-01-1000.report.md" ] && fail "report must not exist" || ok
  assert_contains "$(cat "$N_DIR/.notes.log")" "exit code 7" "log has exit code"
  assert_contains "$(cat "$N_DIR/.notes.log")" "boom" "log has stderr tail"
  case "$(cat "$N_DIR/.notes.log")$N_OUT" in *"$_n_TOKEN"*) fail "token leaked" ;; *) ok ;; esac
  # a retry after the failure is possible
  rm "$T/agent-fail"
  _n_run
  assert_eq 0 "$N_RC" "retry succeeds"
}

test_notes_run_timeout() {
  _n_setup
  echo 30 > "$T/agent-sleep"
  N_TIMEOUT=1 _n_run
  assert_eq 1 "$N_RC" "timeout exit code"
  assert_contains "$(cat "$N_DIR/.notes.log")" "timed out" "log has timeout"
  [ -e "$N_DIR/meeting-2026-01-01-1000.notes-done" ] && fail "marker must not exist" || ok
}

test_notes_run_parallel_lock() {
  _n_setup
  echo 2 > "$T/agent-sleep"
  _n_run >/dev/null &
  local bg=$!
  local i=0
  while [ ! -s "$N_CALLS" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  _n_run
  assert_eq 3 "$N_RC" "second run is locked out"
  wait "$bg"
  assert_eq 1 "$(wc -l < "$N_CALLS" | tr -d ' ')" "agent called once"
  [ -f "$N_DIR/meeting-2026-01-01-1000.notes-done" ] && ok || fail "first run finished"
}

test_notes_run_missing_env() {
  _n_setup
  N_TOK="" _n_run
  assert_eq 2 "$N_RC" "missing token exit code"
  assert_contains "$N_OUT" "TRILIUM_MCP_TOKEN" "names missing variable"
  assert_contains "$N_OUT" "INVALID_CONFIG" "explains the symptom"
  assert_eq 0 "$(wc -l < "$N_CALLS" | tr -d ' ')" "agent not called"
  N_URL="" N_TOK="" _n_run
  assert_contains "$N_OUT" "TRILIUM_MCP_URL, TRILIUM_MCP_TOKEN" "names both"
  case "$N_OUT$(cat "$N_DIR/.notes.log")" in *"$_n_TOKEN"*) fail "token leaked" ;; *) ok ;; esac
}

test_notes_run_usage() {
  _n_setup
  _n_run "$N_DIR/nope.txt"
  assert_eq 2 "$N_RC" "missing transcript"
}

test_notes_run_report_without_note_id() {
  _n_setup
  : > "$T/agent-noid"
  _n_run
  assert_eq 0 "$N_RC" "still success"
  assert_contains "$(cat "$N_DIR/.notes.log")" "no NOTE_ID" "warns in log"
  # notify then sends a notification without link
  : > "$T/ns.calls"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s"\n' "$T/ns.calls" > "$N_BIN/notify-send"
  chmod +x "$N_BIN/notify-send"
  PATH="$N_BIN:$PATH" TRILIUM_URL="http://trilium.example" "$_n_NOTIFY" "$N_DIR/meeting-2026-01-01-1000.report.md"
  assert_contains "$(cat "$T/ns.calls")" "Notatka gotowa" "notification sent"
  assert_contains "$(cat "$T/ns.calls")" "Standup 2026-01-01" "title in body"
  case "$(cat "$T/ns.calls")" in *"http://"*) fail "no link expected" ;; *) ok ;; esac
}

_n_notify_fakes() {
  mkdir -p "$N_BIN"
  : > "$T/ns.calls"; : > "$T/xo.calls"
  # $1 = "action" makes the fake notify-send advertise --action and answer "open"
  cat > "$N_BIN/notify-send" <<EOS
#!/usr/bin/env bash
case "\$1" in --help) echo "  -A, --action=[NAME=]Text"; exit 0 ;; esac
echo "\$*" >> "$T/ns.calls"
$( [ "${1:-}" = action ] && echo 'echo open' )
EOS
  printf '#!/usr/bin/env bash\necho "$*" >> "%s"\n' "$T/xo.calls" > "$N_BIN/xdg-open"
  chmod +x "$N_BIN/notify-send" "$N_BIN/xdg-open"
  printf 'x\nNOTE_TITLE: Planning\nNOTE_ID: id42\n' > "$T/r.report.md"
}

test_notify_link_and_action() {
  _n_setup
  _n_notify_fakes action
  PATH="$N_BIN:$PATH" TRILIUM_URL="http://trilium.example/" MEETING_NOTIFY_SYNC=1 "$_n_NOTIFY" "$T/r.report.md"
  assert_contains "$(cat "$T/ns.calls")" "http://trilium.example/#root/id42" "link in body"
  assert_contains "$(cat "$T/ns.calls")" "--action" "action passed"
  assert_contains "$(cat "$T/xo.calls")" "http://trilium.example/#root/id42" "xdg-open called"
}

test_notify_without_action_support() {
  _n_setup
  _n_notify_fakes
  PATH="$N_BIN:$PATH" TRILIUM_URL="http://t" MEETING_NOTIFY_SYNC=1 "$_n_NOTIFY" "$T/r.report.md"
  assert_contains "$(cat "$T/ns.calls")" "http://t/#root/id42" "link in body"
  assert_eq "" "$(cat "$T/xo.calls")" "xdg-open not called"
}

test_notify_without_trilium_url_or_notify_send() {
  _n_setup
  _n_notify_fakes
  PATH="$N_BIN:$PATH" TRILIUM_URL="" "$_n_NOTIFY" "$T/r.report.md"
  case "$(cat "$T/ns.calls")" in *"#root"*) fail "no link expected" ;; *) ok ;; esac
  assert_contains "$(cat "$T/ns.calls")" "Planning" "title only"
  # no notify-send at all: silent, exit 0 (restricted PATH keeps the real one out)
  rm "$N_BIN/notify-send"
  local out rc
  out="$(PATH="$N_BIN:/usr/bin:/bin" "$_n_NOTIFY" "$T/r.report.md" 2>&1)"; rc=$?
  assert_eq 0 "$rc" "silent skip exit code"
  assert_eq "" "$out" "no output"
}
