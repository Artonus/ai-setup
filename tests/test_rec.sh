#!/usr/bin/env bash
# Tests for tools/bin/meeting-rec start|stop|status, using fake ffmpeg and pactl.

# Builds fakes in $T and exports the environment meeting-rec reads.
rec_setup() {
  mkdir -p "$T/run" "$T/rec"
  cat > "$T/pactl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "get-default-sink") echo alsa_output.usb-test ;;
  "get-default-source") echo alsa_input.usb-test ;;
  "list sources short") printf '1\talsa_output.usb-test.monitor\n2\talsa_input.usb-test\n' ;;
esac
EOF
  # Fake ffmpeg: logs its arguments, writes the "WAV" only after SIGINT, like the real one.
  cat > "$T/ffmpeg" <<'EOF'
#!/usr/bin/env bash
out="${*: -1}"
printf '%s\n' "$@" > "$out.args"
trap 'echo RIFF > "$out"; exit 0' INT
while :; do sleep 0.05; done
EOF
  chmod +x "$T/pactl" "$T/ffmpeg"
  export XDG_RUNTIME_DIR="$T/run" MEETING_REC_DIR="$T/rec" \
    MEETING_REC_FFMPEG="$T/ffmpeg" MEETING_REC_PACTL="$T/pactl"
  REC="$ROOT/tools/bin/meeting-rec"
}

rec_wav() { ls "$T"/rec/meeting-*.wav 2>/dev/null | head -n1; }
rec_meta() { ls "$T"/rec/meeting-*.json 2>/dev/null | head -n1; }

# Kill a leftover fake ffmpeg if a test failed half way.
rec_cleanup() {
  local pid
  pid=$(sed -n 1p "$T/run/meeting-rec.pid" 2>/dev/null)
  [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null
  return 0
}

test_rec_status_is_1_when_idle() {
  rec_setup
  "$REC" status > "$T/out"
  assert_eq 1 "$?" "status exits 1 when not recording"
}

test_rec_start_status_stop_cycle() {
  rec_setup
  local out pid wav meta
  out=$("$REC" start --title "Daily sync" --url "https://meet.google.com/abc-defg-hij")
  assert_eq 0 "$?" "start exits 0"
  assert_contains "$out" "Recording started" "start says it started"

  assert_eq yes "$([ -f "$T/run/meeting-rec.pid" ] && echo yes || echo no)" "pid file written"
  pid=$(sed -n 1p "$T/run/meeting-rec.pid")
  wav=$(sed -n 2p "$T/run/meeting-rec.pid")
  assert_eq yes "$(kill -0 "$pid" 2>/dev/null && echo yes || echo no)" "ffmpeg is running"
  case $wav in "$T"/rec/meeting-????-??-??-????.wav) ok ;; *) fail "wav path shape: $wav" ;; esac

  meta="${wav%.wav}.json"
  assert_eq yes "$([ -f "$meta" ] && echo yes || echo no)" "metadata file next to the wav"
  assert_contains "$(cat "$meta")" '"title": "Daily sync"' "title in metadata"
  assert_contains "$(cat "$meta")" '"url": "https://meet.google.com/abc-defg-hij"' "url in metadata"
  assert_contains "$(cat "$meta")" '"ended_at": null' "ended_at null while recording"
  assert_contains "$(cat "$meta")" "\"wav\": \"$wav\"" "wav in metadata"
  case $(cat "$meta") in *'"started_at": "20'*) ok ;; *) fail "started_at missing" ;; esac

  out=$("$REC" status)
  assert_eq 0 "$?" "status exits 0 while recording"
  assert_contains "$out" "\"pid\": $pid" "status shows pid"
  assert_contains "$out" "$wav" "status shows wav"
  assert_contains "$out" '"title": "Daily sync"' "status shows title"

  "$REC" stop > /dev/null
  assert_eq 0 "$?" "stop exits 0"
  assert_eq no "$(kill -0 "$pid" 2>/dev/null && echo yes || echo no)" "ffmpeg is gone after stop"
  assert_eq "RIFF" "$(cat "$wav")" "wav finished by SIGINT handler"
  assert_eq no "$([ -f "$T/run/meeting-rec.pid" ] && echo yes || echo no)" "pid file removed"
  assert_contains "$(cat "$meta")" '"ended_at": "20' "ended_at filled in"
  "$REC" status > /dev/null
  assert_eq 1 "$?" "status exits 1 after stop"
  rec_cleanup
}

test_rec_start_is_idempotent() {
  rec_setup
  local pid1 pid2 out
  "$REC" start --title one > /dev/null
  pid1=$(sed -n 1p "$T/run/meeting-rec.pid")
  out=$("$REC" start --title two)
  assert_eq 0 "$?" "second start exits 0"
  assert_contains "$out" "Already recording" "second start says so"
  pid2=$(sed -n 1p "$T/run/meeting-rec.pid")
  assert_eq "$pid1" "$pid2" "second start keeps the first recording"
  assert_contains "$(cat "$(rec_meta)")" '"title": "one"' "metadata not overwritten"
  "$REC" stop > /dev/null
  rec_cleanup
}

test_rec_stop_when_idle_is_ok() {
  rec_setup
  "$REC" stop > /dev/null
  assert_eq 0 "$?" "stop with nothing recording exits 0"
}

test_rec_stale_pid_counts_as_not_recording() {
  rec_setup
  local out
  printf '999999\n%s\n' "$T/rec/meeting-old.wav" > "$T/run/meeting-rec.pid"
  "$REC" status > /dev/null
  assert_eq 1 "$?" "status exits 1 for a dead pid"
  assert_eq no "$([ -f "$T/run/meeting-rec.pid" ] && echo yes || echo no)" "stale pid file removed by status"

  printf '999999\n%s\n' "$T/rec/meeting-old.wav" > "$T/run/meeting-rec.pid"
  "$REC" stop > /dev/null
  assert_eq 0 "$?" "stop exits 0 for a dead pid"
  assert_eq no "$([ -f "$T/run/meeting-rec.pid" ] && echo yes || echo no)" "stale pid file removed by stop"

  printf '999999\n%s\n' "$T/rec/meeting-old.wav" > "$T/run/meeting-rec.pid"
  out=$("$REC" start --title fresh)
  assert_contains "$out" "Recording started" "start works over a stale pid file"
  "$REC" stop > /dev/null
  rec_cleanup
}

test_rec_uses_stereo_filter_and_default_devices() {
  rec_setup
  local args
  "$REC" start > /dev/null
  args=$(cat "$T"/rec/meeting-*.wav.args)
  assert_contains "$args" "alsa_output.usb-test.monitor" "left channel from the sink monitor"
  assert_contains "$args" "alsa_input.usb-test" "right channel from the mic"
  assert_contains "$args" "join=inputs=2:channel_layout=stereo" "stereo join filter"
  assert_contains "$args" "volume=2.5" "USB mic gain"
  assert_contains "$args" "volume=0.7" "remote gain"
  assert_contains "$(cat "$(rec_meta)")" '"title": ""' "title defaults to empty"
  "$REC" stop > /dev/null
  rec_cleanup
}

test_rec_metadata_escapes_json() {
  rec_setup
  "$REC" start --title 'He said "hi" \ ok' > /dev/null
  assert_contains "$(cat "$(rec_meta)")" '"title": "He said \"hi\" \\ ok"' "quotes and backslashes escaped"
  "$REC" stop > /dev/null
  rec_cleanup
}

test_rec_rejects_unknown_argument() {
  rec_setup
  "$REC" bogus > /dev/null 2>&1
  assert_eq 2 "$?" "unknown command exits 2"
  "$REC" start --nope > /dev/null 2>&1
  assert_eq 2 "$?" "unknown start option exits 2"
}
