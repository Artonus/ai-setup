# Choosing the ASR model (Polish meetings)

Pick the model from your own recordings, not from benchmarks. `meeting-wer-prep` builds a test set,
`meeting-wer` measures word error rate (WER), character error rate (CER), time and GPU memory.
No model is the default winner yet: the default stays `large-v3-turbo` until you have measured.

## 1. Collect recordings

Use 2-4 recordings of real meetings from `~/recordings` (stereo from `meeting-rec`: left = remote,
right = you). Cover different conditions: a quiet one-to-one, a many-voice call, one with names and
technical terms, one with a poor connection. Cut a 5-10 minute part from each (not the first
minutes, which are small talk):

```bash
meeting-wer-prep ~/recordings/meeting-2025-01-10-1000.wav --start 00:10:00 --duration 600
```

This creates `~/asr-eval/<name>/` with `audio.wav`, `remote.wav`, `me.wav`, a draft `reference.txt`
(made by the current `meeting-transcribe`) and a `README.md`. Correct `reference.txt` by listening
(rules are in that README). This is the slow part: about 3-4x the excerpt length. Do not skip it:
an uncorrected draft makes the current model look perfect.

## 2. Run the measurement (Ubuntu, GPU 4 GB)

Stop the daemon first so it does not compete for GPU memory, and close other GPU programs:

```bash
meeting-wer ~/asr-eval/<name1> ~/asr-eval/<name2> --models large-v3-turbo,large-v3-int8,parakeet --batch-sizes 8,4,2
```

Add `--initial-prompt-file ~/asr-eval/prompt.txt` to also run every Whisper config with that prompt.
`--dry-run` prints the commands without running anything. Results go to
`~/asr-eval/results/<timestamp>/` (`results.md`, `results.json`, transcripts under `hyp/`).

### Parakeet install (onnx-asr)

`onnx-asr` was chosen because it is a plain pip package with ONNX Runtime, no NeMo/PyTorch stack,
and has ready-made Parakeet TDT 0.6B v3 (multilingual, includes Polish) with token timestamps.
Install it into its own environment and tell the tools to use it:

```bash
pipx install "onnx-asr[gpu,hub]"      # use [cpu,hub] to test without GPU
```

`meeting-wer` and `meeting-transcribe` call `python3 tools/lib/wer_asr.py`; that python must be able
to `import onnx_asr`. With pipx the package is not visible to the system python, so instead use
`python3 -m venv ~/.venvs/asr && ~/.venvs/asr/bin/pip install "onnx-asr[gpu,hub]"` and start the
tools with `PATH=~/.venvs/asr/bin:$PATH`. The model downloads from Hugging Face on first use.
Silero VAD cuts long audio into pieces (the model takes about 25 s per pass).
Optional: `MEETING_ASR_PARAKEET_QUANT=int8` loads the int8 variant, which needs less memory.

## 3. Read the table

| Column | Meaning |
|---|---|
| Model / batch / prompt | The config. batch `off` = not batched, `-` = not applicable. |
| WER % | Word errors over all reference words of all sets and both speakers. Lower is better. The number to decide on. |
| CER % | The same on characters. Less sensitive to Polish inflection: a wrong ending costs a whole word in WER but one or two characters in CER. |
| time s, RTF | Wall time including model loading, summed over runs; RTF = time / audio length. |
| peak GPU MiB | Highest `nvidia-smi` memory.used during the run minus the value before it. The card has 4096 MiB in total, desktop use included, so stay clearly below about 3500. |
| prompt leaks | Prompt phrases (4+ words) found in the output but not in the reference. Should be 0. |
| status | `FAIL` with a note: most likely out of memory, then use a smaller batch size. |

A difference of about one percentage point between two models is within noise for 10-20 minutes of
audio: prefer the faster or smaller one. `results.json` has WER per set and speaker, so you can check
that a win is not from one recording only. Words are compared per speaker (the order between
speakers does not matter). Normalization: lower case, Unicode NFC, punctuation including „ ” – —
removed, Polish letters kept, Polish number words up to 999 999 become digits (details in the
docstring of `tools/lib/wer.py`). WER is computed by that file (no dependencies); `results.json`
also holds a `jiwer_wer` cross-check when `jiwer` happens to be installed.

## 4. Set the chosen model

`meeting-transcribe` reads three environment variables; unset means the old behaviour
(`large-v3-turbo`, batch size 8, no prompt):

```bash
export MEETING_ASR_MODEL=large-v3              # or large-v3-turbo, parakeet, any whisper-ctranslate2 model
export MEETING_ASR_BATCH_SIZE=4                # the largest value that did not run out of memory
export MEETING_ASR_INITIAL_PROMPT_FILE=~/asr-eval/prompt.txt   # optional
```

Put them where the daemon's environment is set (for example the systemd user unit's
`Environment=` lines) and restart it. `parakeet` ignores the batch size and the prompt. Note that
`meeting-transcribe` always passes `--compute_type int8_float16`; if `large-v3` needs plain `int8`
to fit (see the memory below), that is a follow-up change to the script.

## GPU memory (4 GB)

From faster-whisper's README for large-v2 on an 8 GB card, 13 minutes of audio: int8 about
2.9 GB, int8 with batch size 8 about 4.5 GB. Expect `large-v3` int8 to fit 4 GB only with a small
batch size (2-4) and the turbo model to be lighter; these are not measured for large-v3, which is
the point of step 2. Parakeet's need on 4 GB is unknown: if it fails, retry with
`MEETING_ASR_PARAKEET_QUANT=int8`.

## Initial prompt: read before using it

The prompt helps with names and jargon but has known failure modes:

- Whisper keeps only the last 223 tokens, so a longer prompt is cut from the start. Write names and
  terms only, for example `Kowalski, Nowak, VOCS, Kubernetes`, not sentences.
- In batched mode (`--batched True`, the current setup) the prompt goes to every chunk and there is
  no conditioning on previous text.
- `hallucination_silence_threshold` does not work in batched mode, so nothing stops the model from
  repeating the prompt in silence or noise. Keep VAD on (it is) and check the "prompt leaks" column;
  also search a real transcript for your prompt words where nobody was speaking.
- Use a prompt only if its WER gain on the table is clear and leaks stay at 0.
