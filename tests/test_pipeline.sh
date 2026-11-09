#!/usr/bin/env bash
# End-to-end tests of meeting-transcribe --once with fake whisper-ctranslate2, notify-send,
# diarize (MEETING_DIARIZE_FAKE) and notes agent. Needs only python3, ffmpeg and ffprobe.

# pl_setup: fake tools in $T/bin, dirs $T/rec and $T/notes, env for the script
pl_setup() {
  mkdir -p "$T/bin" "$T/rec" "$T/notes"
  cat > "$T/bin/whisper-ctranslate2" <<'FAKE'
#!/usr/bin/env bash
# fake: whisper-ctranslate2 IN --output_format F --output_dir D ...; json for remote.wav/me.wav, text otherwise
in="$1"; shift
while [ $# -gt 0 ]; do
  case $1 in --output_format) fmt=$2; shift ;; --output_dir) dir=$2; shift ;; esac
  shift
done
echo "whisper $in" >> "$PL_CALLS"
b=$(basename "${in%.wav}")
if [ "$fmt" = txt ]; then echo "[00:00] mono text" > "$dir/$b.txt"; exit 0; fi
case $b in
  remote) printf '{"segments":[{"start":0,"end":1,"text":" hello there","words":[{"start":0,"end":0.5,"word":" hello"},{"start":0.5,"end":1,"word":" there"}]},{"start":5,"end":6,"text":" again","words":[{"start":5,"end":6,"word":" again"}]}]}' > "$dir/$b.json" ;;
  me) printf '{"segments":[{"start":2,"end":3,"text":" mine","words":[{"start":2,"end":3,"word":" mine"}]}]}' > "$dir/$b.json" ;;
esac
FAKE
  cat > "$T/bin/notify-send" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$PL_NOTIFY"
FAKE
  cat > "$T/bin/notes-agent" <<'FAKE'
#!/usr/bin/env bash
echo "$1" >> "$PL_AGENT"
[ "${PL_AGENT_FAIL:-0}" = 1 ] && exit 1
exit 0
FAKE
  chmod +x "$T/bin/"*
  export PL_CALLS="$T/calls" PL_NOTIFY="$T/notify" PL_AGENT="$T/agent"
  export PATH="$T/bin:$PATH"
  export MEETING_REC_DIR="$T/rec" MEETING_NOTES_DIR="$T/notes" MEETING_NOTES_RUN="$T/bin/notes-agent"
  unset MEETING_DIARIZE MEETING_NOTES_AUTO MEETING_DIARIZE_FAKE MEETING_ASR_MODEL PL_AGENT_FAIL
}

# pl_wav FILE CHANNELS: one second of silence
pl_wav() {
  python3 - "$1" "$2" <<'PY'
import sys, wave
w = wave.open(sys.argv[1], "wb")
w.setnchannels(int(sys.argv[2])); w.setsampwidth(2); w.setframerate(16000)
w.writeframes(b"\0\0" * 16000 * int(sys.argv[2]))
w.close()
PY
}

pl_diar() {
  printf '{"segments":[{"start":0,"end":2,"speaker":"S_B"},{"start":4,"end":7,"speaker":"S_A"}],"num_speakers":2}' > "$T/diar-fake.json"
}

pl_run() { "$ROOT/tools/bin/meeting-transcribe" --once "$@" >"$T/out" 2>&1; }

pl_wait_agent() { local i=0; while [ ! -s "$PL_AGENT" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; }

test_pipeline_once_with_file_makes_txt_and_copies_json() {
  pl_setup
  pl_wav "$T/rec/meeting-2026-01-01-1000.wav" 2
  echo '{"title":"Standup"}' > "$T/rec/meeting-2026-01-01-1000.json"
  pl_run "$T/rec/meeting-2026-01-01-1000.wav"
  assert_eq 0 "$?" "--once FILE succeeds"
  assert_eq "[00:00] Remote: hello there
[00:02] Me: mine
[00:05] Remote: again" "$(cat "$T/notes/meeting-2026-01-01-1000.txt")" "plain merge without diarization"
  assert_eq '{"title":"Standup"}' "$(cat "$T/notes/meeting-2026-01-01-1000.json")" "sidecar copied"
  [ ! -e "$PL_AGENT" ] && ok || fail "agent not started by default"
}

test_pipeline_missing_sidecar_is_fine() {
  pl_setup
  pl_wav "$T/rec/meeting-2026-01-01-1000.wav" 2
  pl_run "$T/rec/meeting-2026-01-01-1000.wav"
  assert_eq 0 "$?" "succeeds without sidecar"
  [ ! -e "$T/notes/meeting-2026-01-01-1000.json" ] && ok || fail "no json invented"
}

test_pipeline_diarization_labels_remote_speakers() {
  pl_setup
  pl_diar
  pl_wav "$T/rec/meeting-2026-01-01-1000.wav" 2
  MEETING_DIARIZE=1 MEETING_DIARIZE_FAKE="$T/diar-fake.json" pl_run "$T/rec/meeting-2026-01-01-1000.wav"
  assert_eq "[00:00] Remote 1: hello there
[00:02] Me: mine
[00:05] Remote 2: again" "$(cat "$T/notes/meeting-2026-01-01-1000.txt")" "Remote N labels"
}

test_pipeline_diarization_runs_after_whisper() {
  pl_setup
  pl_diar
  pl_wav "$T/rec/meeting-2026-01-01-1000.wav" 2
  # diarize wrapper records how many whisper runs had finished when it started
  mkdir -p "$T/inst/bin" "$T/inst/lib"
  cp "$ROOT/tools/lib/"* "$T/inst/lib/"
  cp "$ROOT/tools/bin/meeting-transcribe" "$T/inst/bin/"
  printf 'import os,shutil,sys\nopen(os.environ["PL_ORDER"],"w").write(str(sum(1 for _ in open(os.environ["PL_CALLS"]))))\nshutil.copy(os.environ["MEETING_DIARIZE_FAKE"],sys.argv[2])\n' > "$T/inst/lib/diarize.py"
  PL_ORDER="$T/order" MEETING_DIARIZE=1 MEETING_DIARIZE_FAKE="$T/diar-fake.json" \
    "$T/inst/bin/meeting-transcribe" --once "$T/rec/meeting-2026-01-01-1000.wav" >"$T/out" 2>&1
  assert_eq 2 "$(cat "$T/order")" "both whisper runs finished before diarize started"
}

test_pipeline_diarization_failure_falls_back_to_plain_remote() {
  pl_setup
  pl_wav "$T/rec/meeting-2026-01-01-1000.wav" 2
  # no fake file and no pyannote: diarize.py fails
  MEETING_DIARIZE=1 HF_TOKEN=hf_SECRETSECRET123 pl_run "$T/rec/meeting-2026-01-01-1000.wav"
  assert_eq 0 "$?" "transcript still produced"
  assert_contains "$(cat "$T/notes/meeting-2026-01-01-1000.txt")" "Remote: hello there" "bare Remote label"
  assert_contains "$(cat "$T/notes/.transcribe.log")" "diarization failed" "failure logged"
  case "$(cat "$T/notes/.transcribe.log")$(cat "$T/out")" in *hf_SECRETSECRET123*) fail "token leaked" ;; *) ok ;; esac
}

test_pipeline_diarization_off_by_default() {
  pl_setup
  pl_diar
  pl_wav "$T/rec/meeting-2026-01-01-1000.wav" 2
  MEETING_DIARIZE_FAKE="$T/diar-fake.json" pl_run "$T/rec/meeting-2026-01-01-1000.wav"
  assert_contains "$(cat "$T/notes/meeting-2026-01-01-1000.txt")" "Remote: hello there" "no numbering when MEETING_DIARIZE unset"
}

test_pipeline_backlog_processed_once_and_notified() {
  pl_setup
  pl_wav "$T/rec/meeting-2026-01-01-1000.wav" 2
  pl_wav "$T/rec/meeting-2026-01-02-1000.wav" 2
  : > "$T/rec/notes-ignored.wav"
  pl_run
  assert_eq 0 "$?" "--once without files succeeds"
  [ -s "$T/notes/meeting-2026-01-01-1000.txt" ] && [ -s "$T/notes/meeting-2026-01-02-1000.txt" ] && ok || fail "both transcribed"
  assert_eq 2 "$(wc -l < "$T/notify" | tr -d ' ')" "one notification per transcript"
  assert_contains "$(cat "$T/notify")" "Transcript ready" "notification text"
  : > "$PL_CALLS"
  pl_run
  [ ! -s "$PL_CALLS" ] && ok || fail "second run does not transcribe again"
  assert_eq 2 "$(wc -l < "$T/notify" | tr -d ' ')" "no new notifications"
}

test_pipeline_notes_agent_only_when_auto() {
  pl_setup
  pl_wav "$T/rec/meeting-2026-01-01-1000.wav" 2
  MEETING_NOTES_AUTO=1 pl_run "$T/rec/meeting-2026-01-01-1000.wav"
  pl_wait_agent
  assert_eq "$T/notes/meeting-2026-01-01-1000.txt" "$(cat "$PL_AGENT")" "agent called with the transcript"
}

test_pipeline_agent_failure_does_not_affect_transcript_or_notification() {
  pl_setup
  pl_wav "$T/rec/meeting-2026-01-01-1000.wav" 2
  PL_AGENT_FAIL=1 MEETING_NOTES_AUTO=1 pl_run
  assert_eq 0 "$?" "exit status unaffected"
  pl_wait_agent
  [ -s "$T/notes/meeting-2026-01-01-1000.txt" ] && ok || fail "transcript present"
  assert_contains "$(cat "$T/notify")" "meeting-2026-01-01-1000.txt" "notification sent"
}

test_pipeline_mono_uses_old_path() {
  pl_setup
  pl_wav "$T/rec/meeting-2026-01-01-1000.wav" 1
  MEETING_DIARIZE=1 pl_run "$T/rec/meeting-2026-01-01-1000.wav"
  assert_eq "[00:00] mono text" "$(cat "$T/notes/meeting-2026-01-01-1000.txt")" "whisper txt output used directly"
  assert_eq 1 "$(wc -l < "$PL_CALLS" | tr -d ' ')" "single whisper run"
}

test_pipeline_source_loads_functions_without_running() {
  pl_setup
  local out
  out="$(bash -c 'source "$1"; declare -F transcribe process_pending | wc -l' _ "$ROOT/tools/bin/meeting-transcribe" </dev/null)"
  assert_eq 2 "$(echo "$out" | tr -d ' ')" "sourcing defines functions and returns (no daemon loop)"
}
