#!/usr/bin/env bash
# Tests for tools/bin/meeting-daemon, against a fake meeting-rec (MEETING_REC_BIN).
# Helpers are prefixed _d_ so run.sh does not take them for tests.

_d_U1="https://meet.google.com/abc-defg-hij"
_d_U2="https://meet.google.com/xyz-wxyz-abc"
_d_DAEMON="$ROOT/tools/bin/meeting-daemon"

_d_setup() {
  D_PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
  D_CFG="$T/cfg"
  D_STATE="$T/rec.state"
  D_CALLS="$T/calls.log"
  : > "$D_CALLS"
  cat > "$T/rec" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$D_CALLS"
case "\$1" in
  start) [ -f "$T/fail-start" ] && exit 1; echo "\$*" > "$D_STATE" ;;
  stop) rm -f "$D_STATE" ;;
  status) [ -f "$D_STATE" ] ;;
esac
EOF
  chmod +x "$T/rec"
}

# _d_run [timeout] [grace]: start the daemon in the background and wait until it answers.
_d_run() {
  XDG_CONFIG_HOME="$D_CFG" MEETING_REC_BIN="$T/rec" MEETING_DAEMON_PORT="$D_PORT" \
    MEETING_DAEMON_TIMEOUT="${1:-20}" MEETING_DAEMON_GRACE="${2:-15}" \
    "$_d_DAEMON" run 2>>"$T/daemon.log" &
  D_PID=$!
  local i
  for i in $(seq 1 50); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$D_PORT/meet.user.js")" = 200 ] && break
    sleep 0.1
  done
  D_TOKEN="$(cat "$D_CFG/meeting-daemon/token" 2>/dev/null)"
}

_d_end() { # stop the daemon without killing the fake recording
  kill "$D_PID" 2>/dev/null
  { wait "$D_PID"; } 2>/dev/null
}

_d_kill9() {
  kill -9 "$D_PID" 2>/dev/null
  { wait "$D_PID"; } 2>/dev/null
}

# _d_post PATH JSON [curl args...]: prints the HTTP status, body goes to $T/body.
_d_post() {
  local path="$1" body="$2"
  shift 2
  curl -s -o "$T/body" -w '%{http_code}' -X POST -H "X-Meeting-Token: $D_TOKEN" \
    -H 'Content-Type: application/json' -d "$body" "$@" "http://127.0.0.1:$D_PORT$path"
}

_d_start() { _d_post /start "{\"title\":\"Standup\",\"url\":\"${1:-$_d_U1}\"}"; }
_d_calls() { grep -c "^$1" "$D_CALLS"; }
_d_recording() { [ -f "$D_STATE" ] && echo yes || echo no; }

# _d_wait_for yes|no SECONDS: wait until the fake recording reaches the state.
_d_wait_for() {
  local want="$1" i
  for i in $(seq 1 $(($2 * 5))); do
    [ "$(_d_recording)" = "$want" ] && return 0
    sleep 0.2
  done
  return 1
}

test_daemon_start_ping_stop() {
  _d_setup
  _d_run
  assert_eq 200 "$(_d_start)" "start is accepted"
  assert_contains "$(cat "$T/body")" '"started"' "first start reports started"
  assert_eq "start --title Standup --url $_d_U1" "$(grep '^start' "$D_CALLS")" "meeting-rec start gets title and url"
  assert_eq yes "$(_d_recording)" "recording runs"
  assert_eq 200 "$(_d_post /ping '{}')" "ping is accepted"
  assert_contains "$(cat "$T/body")" '"result": "ok"' "ping is acknowledged"
  assert_eq 200 "$(_d_post /stop '{}')" "stop is accepted"
  assert_eq no "$(_d_recording)" "recording stopped"
  _d_end
}

test_daemon_stops_after_ping_timeout() {
  _d_setup
  _d_run 2
  _d_start > /dev/null
  local i
  for i in 1 2 3 4 5 6; do # pings every 0.5 s keep it alive past the 2 s timeout
    sleep 0.5
    _d_post /ping '{}' > /dev/null
  done
  assert_eq yes "$(_d_recording)" "pings keep the recording alive"
  if _d_wait_for no 8; then ok; else fail "no ping for the timeout did not stop the recording"; fi
  assert_eq 1 "$(_d_calls stop)" "the watchdog stops exactly once"
  _d_end
}

test_daemon_rejects_bad_token() {
  _d_setup
  _d_run
  assert_eq 403 "$(D_TOKEN=wrong _d_start)" "wrong token is rejected"
  assert_eq 403 "$(D_TOKEN= _d_start)" "empty token is rejected"
  assert_eq 403 "$(curl -s -o /dev/null -w '%{http_code}' -X POST -d '{}' "http://127.0.0.1:$D_PORT/start")" "missing token header is rejected"
  assert_eq 0 "$(_d_calls start)" "meeting-rec was never called"
  assert_eq no "$(_d_recording)" "nothing is recording"
  _d_end
}

test_daemon_rejects_bad_host_and_origin() {
  _d_setup
  _d_run
  assert_eq 403 "$(_d_post /start "{\"url\":\"$_d_U1\"}" -H 'Host: evil.example.com')" "foreign Host is rejected"
  assert_eq 403 "$(_d_post /start "{\"url\":\"$_d_U1\"}" -H "Host: evil.example.com:$D_PORT")" "foreign Host with the right port is rejected"
  assert_eq 403 "$(_d_post /start "{\"url\":\"$_d_U1\"}" -H 'Host: 127.0.0.1:1')" "wrong port in Host is rejected"
  assert_eq 403 "$(_d_post /start "{\"url\":\"$_d_U1\"}" -H 'Origin: https://evil.example.com')" "foreign Origin is rejected"
  assert_eq 403 "$(_d_post /start "{\"url\":\"$_d_U1\"}" -H 'Origin: http://meet.google.com')" "http Meet origin is rejected"
  assert_eq 403 "$(_d_post /start "{\"url\":\"$_d_U1\"}" -H 'Origin: null')" "null Origin is rejected"
  assert_eq 403 "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example.com' "http://127.0.0.1:$D_PORT/meet.user.js")" "userscript endpoint checks Host"
  assert_eq 403 "$(curl -s -o /dev/null -w '%{http_code}' -H 'Origin: https://evil.example.com' "http://127.0.0.1:$D_PORT/meet.user.js")" "userscript endpoint checks Origin"
  assert_eq 0 "$(_d_calls start)" "meeting-rec was never called"
  assert_eq 200 "$(_d_post /start "{\"url\":\"$_d_U1\"}" -H 'Origin: https://meet.google.com' -H "Host: localhost:$D_PORT")" "Meet origin and localhost Host are accepted"
  curl -s -D "$T/headers" -o /dev/null -X OPTIONS -H 'Origin: https://meet.google.com' \
    -H 'Access-Control-Request-Method: POST' "http://127.0.0.1:$D_PORT/start"
  assert_contains "$(head -n1 "$T/headers")" 403 "CORS preflight is refused"
  if grep -qi "^access-control" "$T/headers"; then fail "response carries CORS headers"; else ok; fi
  _d_end
}

test_daemon_start_and_stop_are_idempotent() {
  _d_setup
  _d_run
  _d_start > /dev/null
  assert_eq 200 "$(_d_start)" "second start is accepted"
  assert_contains "$(cat "$T/body")" '"already"' "second start reports already"
  assert_eq 1 "$(_d_calls start)" "meeting-rec start ran once"
  assert_eq 200 "$(_d_post /stop '{}')" "stop"
  assert_eq 200 "$(_d_post /stop '{}')" "second stop is accepted"
  assert_contains "$(cat "$T/body")" '"idle"' "second stop reports idle"
  assert_eq 1 "$(_d_calls stop)" "meeting-rec stop ran once"
  _d_end
}

test_daemon_stop_without_start_does_nothing() {
  _d_setup
  _d_run
  assert_eq 200 "$(_d_post /stop '{}')" "stop without start is accepted"
  assert_eq 200 "$(_d_post /ping '{}')" "ping without start is accepted"
  assert_eq 0 "$(_d_calls stop)" "no meeting-rec stop"
  assert_eq 0 "$(_d_calls start)" "no meeting-rec start"
  _d_end
}

test_daemon_restart_restores_state_from_status() {
  _d_setup
  _d_run
  _d_start > /dev/null
  _d_end
  assert_eq yes "$(_d_recording)" "recording survives a daemon stop"
  _d_run
  assert_eq 200 "$(_d_start)" "same meeting after restart"
  assert_contains "$(cat "$T/body")" '"already"' "daemon knows a recording is running"
  assert_eq 1 "$(_d_calls start)" "no second meeting-rec start"
  assert_eq 409 "$(_d_start "$_d_U2")" "other meeting after restart is busy (code restored)"
  assert_eq 200 "$(_d_post /stop '{}')" "stop after restart"
  assert_eq no "$(_d_recording)" "restored recording can be stopped"
  _d_end
}

test_daemon_survives_kill_9_and_watchdog_covers_orphan() {
  _d_setup
  _d_run
  _d_start > /dev/null
  _d_kill9
  assert_eq yes "$(_d_recording)" "recording survives kill -9 of the daemon"
  _d_run 2
  if _d_wait_for no 8; then ok; else fail "orphaned recording was not stopped without pings"; fi
  _d_end
}

test_daemon_second_meeting_does_not_override_first() {
  _d_setup
  _d_run
  assert_eq 200 "$(_d_start "$_d_U1")" "first meeting starts"
  assert_eq 409 "$(_d_start "$_d_U2")" "second meeting is refused"
  assert_contains "$(cat "$T/body")" '"busy"' "reported as busy"
  assert_eq 1 "$(_d_calls start)" "only one recording was started"
  assert_contains "$(cat "$D_STATE")" "$_d_U1" "the first meeting is the one recorded"
  _d_post /ping "{\"code\":\"xyz-wxyz-abc\"}" > /dev/null
  assert_contains "$(cat "$T/body")" '"ignored"' "ping of the other meeting is ignored"
  _d_post /stop "{\"code\":\"xyz-wxyz-abc\"}" > /dev/null
  assert_eq yes "$(_d_recording)" "stop of the other meeting does not end the recording"
  _d_post /stop "{\"code\":\"abc-defg-hij\"}" > /dev/null
  assert_eq no "$(_d_recording)" "stop of the recorded meeting ends it"
  _d_end
}

test_daemon_kill_switch_file_blocks_start() {
  _d_setup
  _d_run
  mkdir -p "$D_CFG/meeting-daemon"
  : > "$D_CFG/meeting-daemon/disabled"
  assert_eq 409 "$(_d_start)" "start refused while the switch file exists"
  assert_contains "$(cat "$T/body")" '"disabled"' "reported as disabled"
  assert_eq 0 "$(_d_calls start)" "meeting-rec not called"
  rm "$D_CFG/meeting-daemon/disabled"
  assert_eq 200 "$(_d_start)" "start works again after removing the file"
  _d_end
}

test_daemon_pagehide_stop_waits_for_a_reload() {
  _d_setup
  _d_run 20 2
  _d_start > /dev/null
  assert_eq 200 "$(_d_post /stop '{"reason":"pagehide"}')" "pagehide stop is accepted"
  assert_contains "$(cat "$T/body")" '"pending"' "pagehide stop is only pending"
  assert_eq yes "$(_d_recording)" "still recording right after pagehide"
  _d_start > /dev/null # the reloaded page joins again within the grace period
  sleep 3
  assert_eq yes "$(_d_recording)" "re-join within the grace period keeps the same recording"
  assert_eq 1 "$(_d_calls start)" "no second recording"
  _d_post /stop '{"reason":"pagehide"}' > /dev/null
  if _d_wait_for no 6; then ok; else fail "pagehide without a re-join did not stop the recording"; fi
  _d_end
}

test_daemon_failed_start_is_not_recording() {
  _d_setup
  : > "$T/fail-start"
  _d_run
  assert_eq 502 "$(_d_start)" "failing meeting-rec start gives 502"
  assert_eq 200 "$(_d_post /ping '{}')" "ping is fine"
  assert_contains "$(cat "$T/body")" '"recording": false' "daemon does not think it records"
  _d_end
}

test_daemon_rejects_malformed_requests() {
  _d_setup
  _d_run
  assert_eq 400 "$(_d_post /start '{not json')" "bad JSON"
  assert_eq 400 "$(_d_post /start '{"url":"https://evil.example.com/abc-defg-hij"}')" "non-Meet url"
  assert_eq 400 "$(_d_post /start '{"title":"x"}')" "missing url"
  assert_eq 400 "$(_d_post /start '[1]')" "JSON that is not an object"
  assert_eq 404 "$(_d_post /nope '{}')" "unknown path"
  assert_eq 0 "$(_d_calls start)" "meeting-rec never called"
  _d_post /start "{\"title\":\"--evil flag\",\"url\":\"$_d_U1\"}" > /dev/null
  assert_eq "start --title evil flag --url $_d_U1" "$(grep '^start' "$D_CALLS")" "title cannot smuggle an option"
  _d_end
}

test_daemon_serves_userscript_with_token_and_port() {
  _d_setup
  _d_run
  local mode
  mode="$(python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$D_CFG/meeting-daemon/token")"
  assert_eq 0o600 "$mode" "token file is mode 600"
  curl -s -D "$T/headers" -o "$T/served.js" "http://127.0.0.1:$D_PORT/meet.user.js"
  assert_contains "$(head -n1 "$T/headers")" 200 "userscript is served"
  assert_contains "$(grep -i '^content-type' "$T/headers")" javascript "served as JavaScript"
  assert_contains "$(cat "$T/served.js")" "$D_TOKEN" "token is filled in"
  assert_contains "$(cat "$T/served.js")" "@updateURL    http://127.0.0.1:$D_PORT/meet.user.js" "port is filled in"
  if grep -q '@@' "$T/served.js"; then fail "placeholders left in the served script"; else ok; fi
  if grep -q "$D_TOKEN" "$T/daemon.log"; then fail "token leaked into the daemon log"; else ok; fi
  _d_end
}

test_daemon_install_and_uninstall_use_a_fake_systemctl() {
  local units="$T/units"
  cat > "$T/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/systemctl.log"
EOF
  chmod +x "$T/systemctl"
  XDG_CONFIG_HOME="$T/cfg" MEETING_DAEMON_SYSTEMD_DIR="$units" MEETING_DAEMON_SYSTEMCTL="$T/systemctl" \
    MEETING_REC_BIN="/opt/bin/meeting-rec" MEETING_DAEMON_PORT=18999 "$_d_DAEMON" install > "$T/install.out" 2>&1
  assert_eq 0 "$?" "install succeeds"
  local unit
  unit="$(cat "$units/meeting-daemon.service" 2>/dev/null)"
  assert_contains "$unit" "meeting-daemon\" run" "unit runs the daemon"
  assert_contains "$unit" "MEETING_REC_BIN=/opt/bin/meeting-rec" "unit pins meeting-rec"
  assert_contains "$unit" "MEETING_DAEMON_PORT=18999" "unit keeps the port"
  assert_contains "$unit" "KillMode=process" "restart does not kill the recording"
  assert_contains "$(cat "$T/systemctl.log")" "--user enable --now meeting-daemon.service" "enable --now"
  assert_contains "$(cat "$T/install.out")" "http://127.0.0.1:18999/meet.user.js" "prints the userscript address"
  if grep -q "$(cat "$T/cfg/meeting-daemon/token")" "$T/install.out" "$units/meeting-daemon.service"; then fail "token printed or written to the unit"; else ok; fi
  XDG_CONFIG_HOME="$T/cfg" MEETING_DAEMON_SYSTEMD_DIR="$units" MEETING_DAEMON_SYSTEMCTL="$T/systemctl" \
    "$_d_DAEMON" uninstall > /dev/null 2>&1
  assert_eq 0 "$?" "uninstall succeeds"
  assert_eq no "$([ -e "$units/meeting-daemon.service" ] && echo yes || echo no)" "unit file removed"
  assert_contains "$(cat "$T/systemctl.log")" "--user disable --now meeting-daemon.service" "disable --now"
}
