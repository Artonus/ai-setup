#!/usr/bin/env bash
# Tests for the ASR evaluation tools: wer.py, parakeet-adapter.py, meeting-wer, meeting-wer-prep, meeting-transcribe config.

wer_py() { python3 -c "
import sys; sys.path.insert(0, '$ROOT/tools/lib')
import wer
$1"; }

test_wer_normalizes_punctuation_case_and_unicode_form() {
  local out
  out=$(wer_py "print(wer.normalize('„Cześć” – mówi Łukasz… «Tak»!'))")
  assert_eq "cześć mówi łukasz tak" "$out" "quotes, dashes, ellipsis dropped, Polish letters kept"
  out=$(wer_py "print(wer.normalize('zażółć') == wer.normalize('zażółć'))")
  assert_eq "True" "$out" "decomposed and composed forms are equal"
}

test_wer_unifies_numbers_written_as_digits_and_words() {
  local out
  out=$(wer_py "print('|'.join(wer.normalize(x) for x in ['dwadzieścia pięć osób', 'dwa tysiące dwadzieścia', 'trzysta', 'dwa dwa', 'jedenaście', 'sto tysięcy', '3,5%']))")
  assert_eq "25 osób|2020|300|2 2|11|100000|3.5 procent" "$out" "number words become digits"
  out=$(wer_py "print(wer.wer_cer('mam 25 lat', 'mam dwadzieścia pięć lat')[0])")
  assert_eq "0.0" "$out" "digits and words score as equal"
}

test_wer_computes_word_and_character_error_rate() {
  local out
  out=$(wer_py "w, c = wer.wer_cer('ala ma kota', 'ala ma psa i kota'); print(round(w, 4), round(c, 4))")
  assert_eq "0.6667 0.5455" "$out" "one substitution+one insertion over 3 words"
  out=$(wer_py "print(wer.wer_cer('a b c d', 'a b c d')[0], wer.edit_distance('kitten', 'sitting'))")
  assert_eq "0.0 3" "$out" "identical texts give 0, Levenshtein kitten/sitting is 3"
}

test_wer_cli_prints_json() {
  printf 'Ala ma kota.\n' > "$T/r.txt"
  printf 'ala ma psa\n' > "$T/h.txt"
  out=$(python3 "$ROOT/tools/lib/wer.py" "$T/r.txt" "$T/h.txt")
  assert_contains "$out" '"word_edits": 1' "cli reports edits"
  assert_contains "$out" '"ref_words": 3' "cli reports reference size"
}

test_parakeet_adapter_builds_whisper_style_words_for_merge_tracks() {
  local out
  cat > "$T/pk.json" <<'JSON'
[{"text": "Dzień dobry wszystkim", "offset": 10.0,
  "tokens": ["▁Dzień", "▁do", "bry", "▁wszyst", "kim"], "timestamps": [0.08, 0.5, 0.7, 1.0, 1.2]},
 {"text": "Do widzenia", "offset": 30.0,
  "tokens": ["▁Do", "▁wi", "dzenia"], "timestamps": [0.0, 0.4, 0.6]}]
JSON
  python3 "$ROOT/tools/lib/parakeet-adapter.py" "$T/pk.json" > "$T/pk.out.json"
  out=$(python3 -c "
import json
d = json.load(open('$T/pk.out.json'))
s = d['segments']
print(len(s), [w['word'] for w in s[0]['words']], s[0]['words'][0]['start'], s[0]['words'][0]['end'], s[1]['words'][0]['start'])")
  assert_eq "2 [' Dzień', ' dobry', ' wszystkim'] 10.08 10.5 30.0" "$out" "tokens join into words with offset and end = next start"
  echo '{"segments": []}' > "$T/me.json"
  out=$(python3 "$ROOT/tools/lib/merge-tracks.py" Remote "$T/pk.out.json" Me "$T/me.json")
  assert_eq "[00:10] Remote: Dzień dobry wszystkim Do widzenia" "$out" "merge-tracks reads the adapter output (same speaker: one turn)"
}

test_parakeet_adapter_txt_format() {
  echo '{"text": "x", "tokens": ["▁Ala", "▁ma"], "timestamps": [0, 0.3]}' > "$T/pk.json"
  assert_eq "Ala ma" "$(python3 "$ROOT/tools/lib/parakeet-adapter.py" --format txt "$T/pk.json")" "plain text output"
}

# --- meeting-wer with fake whisper / nvidia-smi / parakeet ---------------------------------------

make_wer_fakes() {
  mkdir -p "$T/fk"
  cat > "$T/fk/whisper" <<EOS
#!/usr/bin/env bash
in=\$1; shift
echo "\$*" >> "$T/fk/whisper.log"
dir=""; batch=""
while [ \$# -gt 0 ]; do case \$1 in --output_dir) dir=\$2;; --batch_size) batch=\$2;; esac; shift; done
if [ "\$batch" = 8 ]; then echo "CUDA failed with error out of memory" >&2; exit 1; fi
touch "$T/fk/busy"; sleep 0.6; rm -f "$T/fk/busy"
b=\$(basename "\${in%.wav}")
case \$b in
  remote) echo "Dzień dobry, dwadzieścia pięć osób." > "\$dir/\$b.txt" ;;
  me) echo "Tak, zaczynamy." > "\$dir/\$b.txt" ;;
esac
EOS
  cat > "$T/fk/nvidia-smi" <<EOS
#!/usr/bin/env bash
if [ -e "$T/fk/busy" ]; then echo 3500; else echo 1500; fi
EOS
  cat > "$T/fk/parakeet" <<'EOS'
#!/usr/bin/env bash
echo "Dzień dobry dwadzieścia pięć osób" > "$3.txt"
EOS
  chmod +x "$T/fk/"*
  mkdir -p "$T/set"
  : > "$T/set/audio.wav"; : > "$T/set/remote.wav"; : > "$T/set/me.wav"
  cat > "$T/set/reference.txt" <<'EOS'
# comment line
[00:00] Remote: Dzień dobry, 25 osób.
[00:05] Me: Tak,
zaczynamy.
EOS
  export MEETING_WER_WHISPER_CMD="$T/fk/whisper" MEETING_WER_NVIDIA_SMI="$T/fk/nvidia-smi" \
    MEETING_WER_PARAKEET_CMD="$T/fk/parakeet"
}

test_meeting_wer_table_batches_oom_and_gpu_peak() {
  local out
  make_wer_fakes
  out=$(python3 "$ROOT/tools/bin/meeting-wer" "$T/set" --models large-v3-turbo,parakeet --batch-sizes 8,2 --out "$T/res" 2>/dev/null)
  assert_contains "$out" "| large-v3-turbo | 2 | no | 0.0 | 0.0 |" "batch 2 run: perfect WER on matching text"
  assert_contains "$out" "FAIL: out of memory, try a smaller batch size" "batch 8 fails with an OOM hint"
  assert_contains "$out" "| 2000 |" "peak GPU memory = peak minus baseline (3500-1500)"
  assert_contains "$out" "| parakeet | - | no |" "parakeet row has no batch size"
  assert_contains "$(cat "$T/fk/whisper.log")" "--batch_size 2" "batch size is passed on"
  assert_contains "$(cat "$T/res/results.json")" '"wer"' "json written"
  [ -s "$T/res/results.md" ] && ok || fail "results.md missing"
  case $out in *"| parakeet | - | no | 0.0 |"*) fail "parakeet fake text is wrong for the 'me' channel, WER must be above 0" ;; *) ok ;; esac
}

test_meeting_wer_prompt_variants_and_leak_count() {
  local out
  make_wer_fakes
  printf 'Dzień dobry wszystkim zebranym tutaj\n' > "$T/prompt.txt"
  : > "$T/fk/whisper.log"
  out=$(python3 "$ROOT/tools/bin/meeting-wer" "$T/set" --models large-v3-turbo --batch-sizes 2 \
    --initial-prompt-file "$T/prompt.txt" --out "$T/res" 2>/dev/null)
  assert_contains "$out" "| large-v3-turbo | 2 | no |" "row without prompt"
  assert_contains "$out" "| large-v3-turbo | 2 | yes |" "row with prompt"
  assert_contains "$(cat "$T/fk/whisper.log")" "--initial_prompt Dzień dobry wszystkim zebranym tutaj" "prompt text passed to whisper"
}

test_meeting_wer_dry_run_prints_commands_only() {
  local out
  make_wer_fakes
  : > "$T/fk/whisper.log"
  out=$(python3 "$ROOT/tools/bin/meeting-wer" "$T/set" --models large-v3-int8 --batch-sizes 4,0 --dry-run --out "$T/res")
  assert_contains "$out" "--model large-v3 " "large-v3 model"
  assert_contains "$out" "--compute_type int8 " "int8 compute type"
  assert_contains "$out" "--batched True --batch_size 4" "batched variant"
  assert_eq "" "$(cat "$T/fk/whisper.log")" "dry run runs nothing"
}

test_meeting_wer_rejects_set_without_reference() {
  mkdir -p "$T/empty"
  out=$(python3 "$ROOT/tools/bin/meeting-wer" "$T/empty" 2>&1)
  assert_contains "$out" "no reference.txt" "clear error"
}

# --- meeting-transcribe model configuration ------------------------------------------------------

make_transcribe_fake() {
  mkdir -p "$T/bin"
  cat > "$T/bin/whisper-ctranslate2" <<EOS
#!/usr/bin/env bash
echo "\$*" >> "$T/args.log"
in=\$1; dir=""; fmt=""
while [ \$# -gt 0 ]; do case \$1 in --output_dir) dir=\$2;; --output_format) fmt=\$2;; esac; shift; done
b=\$(basename "\${in%.wav}")
if [ "\$fmt" = json ]; then
  echo '{"segments": [{"start": 1, "end": 2, "text": " Cześć.", "words": [{"start": 1, "end": 2, "word": " Cześć."}]}]}' > "\$dir/\$b.json"
else
  echo "Cześć." > "\$dir/\$b.txt"
fi
EOS
  chmod +x "$T/bin/whisper-ctranslate2"
  command -v ffmpeg >/dev/null && ffmpeg -loglevel error -f lavfi -i "sine=frequency=440:duration=2" \
    -f lavfi -i "sine=frequency=880:duration=2" -filter_complex "[0][1]amerge=inputs=2" "$T/st.wav"
}

test_meeting_transcribe_keeps_old_invocation_by_default() {
  command -v ffmpeg >/dev/null || return 0
  make_transcribe_fake
  mkdir -p "$T/notes"
  PATH="$T/bin:$PATH" MEETING_NOTES_DIR="$T/notes" MEETING_REC_DIR="$T/rec" \
    bash "$ROOT/tools/bin/meeting-transcribe" --once "$T/st.wav"
  assert_contains "$(head -1 "$T/args.log")" "--model large-v3-turbo --language pl --device cuda --compute_type int8_float16 --batched True --batch_size 8 --vad_filter True --output_format json --output_dir" "unchanged arguments"
  case $(cat "$T/args.log") in *initial_prompt*) fail "no prompt by default" ;; *) ok ;; esac
  assert_contains "$(cat "$T/notes/st.txt")" "Remote: Cześć." "merged transcript is written"
}

test_meeting_transcribe_reads_model_batch_and_prompt_from_env() {
  command -v ffmpeg >/dev/null || return 0
  make_transcribe_fake
  mkdir -p "$T/notes"
  printf 'Kowalski, Nowak\nVOCS\n' > "$T/prompt.txt"
  PATH="$T/bin:$PATH" MEETING_NOTES_DIR="$T/notes" MEETING_REC_DIR="$T/rec" \
    MEETING_ASR_MODEL=large-v3 MEETING_ASR_BATCH_SIZE=3 MEETING_ASR_INITIAL_PROMPT_FILE="$T/prompt.txt" \
    bash "$ROOT/tools/bin/meeting-transcribe" --once "$T/st.wav"
  assert_contains "$(head -1 "$T/args.log")" "--model large-v3 " "model from env"
  assert_contains "$(head -1 "$T/args.log")" "--batch_size 3 " "batch size from env"
  assert_contains "$(head -1 "$T/args.log")" "--initial_prompt Kowalski, Nowak VOCS " "prompt file contents on one line"
}

# --- meeting-wer-prep ---------------------------------------------------------------------------

test_meeting_wer_prep_creates_set_with_split_channels() {
  command -v ffmpeg >/dev/null || return 0
  make_transcribe_fake
  cat > "$T/fake-transcribe" <<'EOS'
#!/usr/bin/env bash
# fake meeting-transcribe: --once FILE -> $MEETING_NOTES_DIR/<base>.txt
f=$2; b=$(basename "${f%.wav}")
echo "[00:00] Remote: szkic" > "$MEETING_NOTES_DIR/$b.txt"
EOS
  chmod +x "$T/fake-transcribe"
  local out d
  out=$(MEETING_ASR_EVAL_DIR="$T/eval" MEETING_TRANSCRIBE="$T/fake-transcribe" \
    bash "$ROOT/tools/bin/meeting-wer-prep" "$T/st.wav" --start 00:00:01 --duration 1 --name demo 2>&1)
  d="$T/eval/demo"
  assert_eq "2" "$(ffprobe -v error -show_entries stream=channels -of csv=p=0 "$d/audio.wav")" "audio.wav is stereo"
  assert_eq "1" "$(ffprobe -v error -show_entries stream=channels -of csv=p=0 "$d/remote.wav")" "remote.wav is mono"
  assert_eq "1" "$(ffprobe -v error -show_entries stream=channels -of csv=p=0 "$d/me.wav")" "me.wav is mono"
  assert_eq "1.0" "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$d/audio.wav" | awk '{printf "%.1f", $1}')" "excerpt length"
  assert_eq "[00:00] Remote: szkic" "$(cat "$d/reference.txt")" "draft from the transcriber"
  assert_contains "$(cat "$d/README.md")" "Correct the reference" "README with instructions"
  out=$(MEETING_ASR_EVAL_DIR="$T/eval" MEETING_TRANSCRIBE="$T/fake-transcribe" \
    bash "$ROOT/tools/bin/meeting-wer-prep" "$T/st.wav" --name demo 2>&1) && fail "should refuse to overwrite" || ok
  assert_contains "$out" "already exists" "existing set kept"
}

test_meeting_wer_prep_rejects_mono_input() {
  command -v ffmpeg >/dev/null || return 0
  ffmpeg -loglevel error -f lavfi -i "sine=frequency=440:duration=1" "$T/mono.wav"
  out=$(MEETING_ASR_EVAL_DIR="$T/eval" bash "$ROOT/tools/bin/meeting-wer-prep" "$T/mono.wav" --no-draft 2>&1) && fail "mono should fail" || ok
  assert_contains "$out" "need stereo" "explains why"
}
