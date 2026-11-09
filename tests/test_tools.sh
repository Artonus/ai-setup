#!/usr/bin/env bash
# Tests for the helper scripts under tools/.

test_merge_tracks_interleaves_speakers_by_word_time() {
  local a="$T/remote.json" b="$T/me.json" out
  cat > "$a" <<'EOF'
{"segments": [{"start": 0.0, "end": 4.0, "text": " Hello there. How are you?", "words": [
  {"start": 0.0, "end": 0.5, "word": " Hello"}, {"start": 0.5, "end": 1.0, "word": " there."},
  {"start": 3.0, "end": 3.5, "word": " How"}, {"start": 3.5, "end": 3.8, "word": " are"},
  {"start": 3.8, "end": 4.0, "word": " you?"}]}]}
EOF
  cat > "$b" <<'EOF'
{"segments": [{"start": 1.5, "end": 2.5, "text": " Hi, good.", "words": [
  {"start": 1.5, "end": 2.0, "word": " Hi,"}, {"start": 2.0, "end": 2.5, "word": " good."}]},
  {"start": 3605.0, "end": 3606.0, "text": " Bye.", "words": []}]}
EOF
  out="$(python3 "$ROOT/tools/lib/merge-tracks.py" Remote "$a" Me "$b")"
  assert_eq "[00:00] Remote: Hello there.
[00:01] Me: Hi, good.
[00:03] Remote: How are you?
[1:00:05] Me: Bye." "$out" "turns alternate in time order, segments without words still appear"
}

test_merge_tracks_handles_an_empty_track() {
  local a="$T/remote.json" b="$T/me.json" out
  printf '{"segments": [{"start": 2, "end": 3, "text": " Only them.", "words": [{"start": 2, "end": 3, "word": " Only them."}]}]}' > "$a"
  printf '{"segments": []}' > "$b"
  out="$(python3 "$ROOT/tools/lib/merge-tracks.py" Remote "$a" Me "$b")"
  assert_eq "[00:02] Remote: Only them." "$out" "a silent track adds nothing"
}

# mt_track FILE start:word ... – writes a whisper-like JSON with one-second words.
mt_track() {
  local f="$1" sep="" w; shift
  printf '{"segments":[{"start":0,"end":99,"text":"x","words":[' > "$f"
  for w in "$@"; do
    printf '%s{"start":%s,"end":%s,"word":" %s"}' "$sep" "${w%%:*}" "$(( ${w%%:*} + 1 ))" "${w#*:}" >> "$f"
    sep=","
  done
  printf ']}]}' >> "$f"
}
# mt_diar FILE speaker:start:end ... – writes diarize.py-style JSON.
mt_diar() {
  local f="$1" sep="" s; shift
  printf '{"segments":[' > "$f"
  for s in "$@"; do
    IFS=: read -r sp a b <<< "$s"
    printf '%s{"start":%s,"end":%s,"speaker":"%s"}' "$sep" "$a" "$b" "$sp" >> "$f"
    sep=","
  done
  printf '],"num_speakers":0}' >> "$f"
}
mt() { python3 "$ROOT/tools/lib/merge-tracks.py" "$@"; }

test_merge_tracks_two_remote_speakers() {
  mt_track "$T/r.json" 0:Hi 1:there 4:Hello 5:back
  mt_track "$T/m.json" 2:Me1
  mt_diar "$T/d.json" S_A:0:2 S_B:3:6
  assert_eq "[00:00] Remote 1: Hi there
[00:02] Me: Me1
[00:04] Remote 2: Hello back" "$(mt --diarization "Remote=$T/d.json" Remote "$T/r.json" Me "$T/m.json")" "speakers become Remote 1 / Remote 2, Me untouched"
}

test_merge_tracks_three_speakers_and_label_order() {
  mt_track "$T/r.json" 0:a 10:b 20:c 30:d
  # raw names are not in appearance order: S9 speaks first
  mt_diar "$T/d.json" S1:20:25 S9:0:5 S5:10:15 S1:30:35
  assert_eq "[00:00] Remote 1: a
[00:10] Remote 2: b
[00:20] Remote 3: c d" "$(mt --diarization "Remote=$T/d.json" Remote "$T/r.json")" "labels numbered by first assigned word"
}

test_merge_tracks_word_outside_segments_gets_bare_label() {
  mt_track "$T/r.json" 0:in 50:far 60:near
  mt_diar "$T/d.json" A:0:1 A:60.5:70
  # 'near' (60-61) overlaps; 'far' (50-51) is >1s from any segment
  assert_eq "[00:00] Remote 1: in
[00:50] Remote: far
[01:00] Remote 1: near" "$(mt --diarization "Remote=$T/d.json" Remote "$T/r.json")" "no segment within tolerance keeps bare label"
}

test_merge_tracks_gap_uses_nearest_segment_within_tolerance() {
  mt_track "$T/r.json" 0:x 10:y
  mt_diar "$T/d.json" A:0:0 B:10.4:20
  assert_eq "[00:00] Remote 1: x
[00:10] Remote 2: y" "$(mt --diarization "Remote=$T/d.json" Remote "$T/r.json")" "short gap resolved to nearest segment"
}

test_merge_tracks_speaker_without_words_takes_no_number() {
  mt_track "$T/r.json" 0:a 10:b
  mt_diar "$T/d.json" Silent:2:4 B:0:1 C:10:11
  assert_eq "[00:00] Remote 1: a
[00:10] Remote 2: b" "$(mt --diarization "Remote=$T/d.json" Remote "$T/r.json")" "silent speaker does not shift numbering"
}

test_merge_tracks_empty_segments_file_equals_plain() {
  mt_track "$T/r.json" 0:a 1:b
  printf '{"segments":[],"num_speakers":0}' > "$T/d.json"
  assert_eq "$(mt Remote "$T/r.json")" "$(mt --diarization "Remote=$T/d.json" Remote "$T/r.json")" "empty diarization changes nothing"
}

test_merge_tracks_overlapping_segments_pick_largest_overlap() {
  mt_track "$T/r.json" 0:a
  mt_diar "$T/d.json" A:0:0.3 B:0.2:3
  assert_eq "[00:00] Remote 1: a" "$(mt --diarization "Remote=$T/d.json" Remote "$T/r.json")" "overlap does not crash"
  mt_track "$T/r2.json" 0:a 5:b
  mt_diar "$T/d2.json" A:0:0.3 B:0.2:3 A:5:6
  assert_eq "[00:00] Remote 1: a
[00:05] Remote 2: b" "$(mt --diarization "Remote=$T/d2.json" Remote "$T/r2.json")" "B overlaps word a most (0.8s vs 0.3s) so A is first seen at b"
}

test_merge_tracks_without_flag_output_is_unchanged() {
  mt_track "$T/r.json" 0:a 5:b
  assert_eq "[00:00] Remote: a b" "$(mt Remote "$T/r.json")" "plain run keeps the bare label"
}

test_merge_tracks_diarization_errors_are_readable() {
  local out rc
  mt_track "$T/r.json" 0:a
  out="$(mt --diarization "Remote=$T/missing.json" Remote "$T/r.json" 2>&1)"; rc=$?
  assert_eq 1 "$rc" "missing diarization file fails"
  assert_contains "$out" "cannot read diarization file" "message names the problem"
  case $out in *Traceback*) fail "no traceback expected" ;; *) ok ;; esac
  mt_diar "$T/d.json" A:0:1
  out="$(mt --diarization "Other=$T/d.json" Remote "$T/r.json" 2>&1)"; rc=$?
  assert_eq 1 "$rc" "unknown label fails"
  assert_contains "$out" "matches no track" "message names the label"
  out="$(mt --diarization nonsense Remote "$T/r.json" 2>&1)"; rc=$?
  assert_eq 1 "$rc" "malformed flag fails"
  assert_contains "$out" "LABEL=FILE.json" "usage hint"
}
