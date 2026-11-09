#!/usr/bin/env bash
# Tests for tools/lib/diarize.py (pyannote itself is only exercised on Ubuntu).

test_diarize_fake_mode_copies_result() {
  printf '{"segments":[{"start":0.0,"end":1.0,"speaker":"SPEAKER_00"}],"num_speakers":1}' > "$T/fake.json"
  MEETING_DIARIZE_FAKE="$T/fake.json" python3 "$ROOT/tools/lib/diarize.py" "$T/none.wav" "$T/out.json"
  assert_eq 0 "$?" "fake mode succeeds without pyannote or wav"
  assert_eq "$(cat "$T/fake.json")" "$(cat "$T/out.json")" "result copied verbatim"
}

test_diarize_help_needs_no_pyannote() {
  local out
  out="$(python3 "$ROOT/tools/lib/diarize.py" --help)"
  assert_eq 0 "$?" "--help exits 0"
  assert_contains "$out" "MEETING_DIARIZE_DEVICE" "documents the device variable"
}

test_diarize_failure_exits_nonzero_and_leaves_no_file() {
  local rc out
  : > "$T/in.wav"
  printf 'stale' > "$T/out.json"
  out="$(env -u MEETING_DIARIZE_FAKE HF_TOKEN=hf_SECRETSECRET123 python3 "$ROOT/tools/lib/diarize.py" "$T/in.wav" "$T/out.json" 2>&1)"; rc=$?
  assert_eq 1 "$rc" "missing pyannote or model is a failure"
  [ ! -e "$T/out.json" ] && ok || fail "no output file (stale one removed) after failure"
  case $out in *hf_SECRETSECRET123*) fail "token leaked into log" ;; *) ok ;; esac
}

test_diarize_missing_input_and_bad_device() {
  local rc
  python3 "$ROOT/tools/lib/diarize.py" "$T/nope.wav" "$T/out.json" 2>/dev/null; rc=$?
  assert_eq 1 "$rc" "missing wav fails"
  : > "$T/in.wav"
  MEETING_DIARIZE_DEVICE=tpu python3 "$ROOT/tools/lib/diarize.py" "$T/in.wav" "$T/out.json" 2>/dev/null; rc=$?
  assert_eq 2 "$rc" "unknown device is a usage error"
  python3 "$ROOT/tools/lib/diarize.py" 2>/dev/null; rc=$?
  assert_eq 2 "$rc" "wrong argument count is a usage error"
}

test_diarize_fake_with_token_does_not_leak_it() {
  local out
  printf '{"segments":[],"num_speakers":0}' > "$T/fake.json"
  out="$(HF_TOKEN=hf_SECRETSECRET123 MEETING_DIARIZE_FAKE="$T/fake.json" python3 "$ROOT/tools/lib/diarize.py" "$T/x.wav" "$T/out.json" 2>&1)"
  case "$out$(cat "$T/out.json")" in *hf_SECRETSECRET123*) fail "token appeared in output" ;; *) ok ;; esac
}
