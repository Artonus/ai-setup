# Tests for tools/bin/meeting-cleanup. Sourced by tests/run.sh ($T, ROOT, assert_* available).

CLEANUP="$ROOT/tools/bin/meeting-cleanup"

# mk_rec <name> <age_days> <transcript: ok|empty|none> [notes-done]
cl_mk() {
  local name=$1 age=$2 tr=$3 done=${4:-}
  printf 'RIFFdata' >"$T/rec/$name.wav"
  python3 -c 'import os,sys,time; t=time.time()-float(sys.argv[2])*86400; os.utime(sys.argv[1],(t,t))' "$T/rec/$name.wav" "$age"
  printf '{"title":"x"}' >"$T/rec/$name.json"
  case $tr in
    ok) printf 'Me: hello\n' >"$T/notes/$name.txt" ;;
    empty) : >"$T/notes/$name.txt" ;;
  esac
  if [ -n "$done" ]; then : >"$T/notes/$name.notes-done"; fi
}

cl_run() {
  MEETING_REC_DIR="$T/rec" MEETING_NOTES_DIR="$T/notes" "$CLEANUP" "$@" </dev/null 2>&1
}

cl_setup() { mkdir -p "$T/rec" "$T/notes"; }

test_cleanup_too_young() {
  cl_setup; cl_mk meeting-a 3 ok
  out=$(cl_run --archive)
  assert_eq yes "$([ -f "$T/rec/meeting-a.wav" ] && echo yes)" "young wav stays"
  assert_contains "$out" "0 candidate" "reports no candidates"
}

test_cleanup_no_transcript() {
  cl_setup; cl_mk meeting-a 30 none
  cl_run --archive >/dev/null
  assert_eq yes "$([ -f "$T/rec/meeting-a.wav" ] && echo yes)" "wav without transcript stays"
}

test_cleanup_empty_transcript() {
  cl_setup; cl_mk meeting-a 30 empty
  cl_run --archive >/dev/null
  assert_eq yes "$([ -f "$T/rec/meeting-a.wav" ] && echo yes)" "wav with empty transcript stays"
}

test_cleanup_require_notes() {
  cl_setup; cl_mk meeting-a 30 ok; cl_mk meeting-b 30 ok done
  cl_run --archive --require-notes >/dev/null
  assert_eq yes "$([ -f "$T/rec/meeting-a.wav" ] && echo yes)" "no marker: stays"
  assert_eq yes "$([ -f "$T/rec/archive/meeting-b.wav" ] && echo yes)" "marker: archived"
}

test_cleanup_dry_run() {
  cl_setup; cl_mk meeting-a 30 ok
  out=$(cl_run)
  assert_contains "$out" "meeting-a.wav" "lists candidate"
  assert_eq yes "$([ -f "$T/rec/meeting-a.wav" ] && echo yes)" "dry-run keeps wav"
  assert_eq "" "$([ -e "$T/rec/archive" ] && echo yes)" "dry-run creates no archive dir"
}

test_cleanup_archive() {
  cl_setup; cl_mk meeting-a 30 ok
  cl_run --archive >/dev/null
  assert_eq yes "$([ -f "$T/rec/archive/meeting-a.wav" ] && echo yes)" "wav moved to archive"
  assert_eq "" "$([ -e "$T/rec/meeting-a.wav" ] && echo yes)" "wav gone from recordings"
  assert_eq yes "$([ -f "$T/rec/meeting-a.json" ] && echo yes)" "json stays"
  assert_eq yes "$([ -f "$T/notes/meeting-a.txt" ] && echo yes)" "transcript stays"
}

test_cleanup_delete_needs_confirmation() {
  cl_setup; cl_mk meeting-a 30 ok
  cl_run --delete >/dev/null; rc=$?
  assert_eq yes "$([ -f "$T/rec/meeting-a.wav" ] && echo yes)" "no tty, no --yes: nothing deleted"
  [ "$rc" != 0 ] && ok || fail "refusal should exit non-zero"
}

test_cleanup_delete_yes() {
  cl_setup; cl_mk meeting-a 30 ok; cl_mk meeting-b 30 none
  cl_run --delete --yes >/dev/null
  assert_eq "" "$([ -e "$T/rec/meeting-a.wav" ] && echo yes)" "candidate deleted"
  assert_eq yes "$([ -f "$T/rec/meeting-b.wav" ] && echo yes)" "non-candidate kept"
}

test_cleanup_still_writing() {
  cl_setup; cl_mk meeting-a 30 ok
  touch "$T/rec/meeting-a.wav"   # mtime = now, recording still being written
  cl_run --delete --yes >/dev/null
  assert_eq yes "$([ -f "$T/rec/meeting-a.wav" ] && echo yes)" "fresh mtime: untouched"
}

test_cleanup_busy_but_old_name() {
  # mtime within the busy window must win even with retention 0
  cl_setup; cl_mk meeting-a 0 ok
  MEETING_RETENTION_DAYS=0 cl_run --archive >/dev/null
  assert_eq yes "$([ -f "$T/rec/meeting-a.wav" ] && echo yes)" "retention 0 still spares busy file"
}

test_cleanup_retention_env() {
  cl_setup; cl_mk meeting-a 5 ok
  MEETING_RETENTION_DAYS=2 cl_run --archive >/dev/null
  assert_eq yes "$([ -f "$T/rec/archive/meeting-a.wav" ] && echo yes)" "custom retention honoured"
}
