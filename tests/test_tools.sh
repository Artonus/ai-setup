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
