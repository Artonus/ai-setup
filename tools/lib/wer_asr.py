#!/usr/bin/env python3
"""Run Parakeet TDT 0.6B v3 (via onnx-asr) on one audio file and write Whisper-style output.

Usage: wer_asr.py parakeet AUDIO.wav OUT_BASE

Writes OUT_BASE.json (segments[].words[], read by merge-tracks.py), OUT_BASE.txt (plain text) and
OUT_BASE.raw.json (what onnx-asr returned, for debugging). Needs `pip install "onnx-asr[gpu,hub]"`
(or [cpu,hub]); onnxruntime picks CUDA by itself when onnxruntime-gpu is installed.
Env: MEETING_ASR_PARAKEET_MODEL (default nemo-parakeet-tdt-0.6b-v3), MEETING_ASR_PARAKEET_QUANT
(for example int8; default: the full-precision model).

Long audio is cut by Silero VAD (the model takes ~20-30 s per pass). The result fields used
(.start, .text, .tokens, .timestamps) are assumed from the onnx-asr docs and are not verified
here: if they differ, the raw dump shows what came back.
"""
import importlib.util
import json
import os
import sys


def load_adapter():
    path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "parakeet-adapter.py")
    spec = importlib.util.spec_from_file_location("parakeet_adapter", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def chunk_of(res):
    text = getattr(res, "text", "") or ""
    start = float(getattr(res, "start", 0.0) or 0.0)
    tokens = list(getattr(res, "tokens", None) or [])
    stamps = list(getattr(res, "timestamps", None) or [])
    if not tokens or len(tokens) != len(stamps):  # no token timing: spread words at the chunk start
        tokens = ["▁" + w for w in text.split()]
        stamps = [0.0] * len(tokens)
    return {"text": text, "tokens": tokens, "timestamps": stamps, "offset": start}


def run_parakeet(audio, out_base):
    import onnx_asr

    name = os.environ.get("MEETING_ASR_PARAKEET_MODEL", "nemo-parakeet-tdt-0.6b-v3")
    quant = os.environ.get("MEETING_ASR_PARAKEET_QUANT")
    model = onnx_asr.load_model(name, quantization=quant) if quant else onnx_asr.load_model(name)
    model = model.with_timestamps().with_vad(onnx_asr.load_vad("silero"))
    chunks = [chunk_of(r) for r in model.recognize(audio)]
    with open(out_base + ".raw.json", "w", encoding="utf-8") as f:
        json.dump(chunks, f, ensure_ascii=False)
    result = load_adapter().convert(chunks)
    with open(out_base + ".json", "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False)
    with open(out_base + ".txt", "w", encoding="utf-8") as f:
        f.write(" ".join(s["text"].strip() for s in result["segments"]) + "\n")


def main(argv):
    if len(argv) != 3 or argv[0] != "parakeet":
        sys.exit(__doc__.strip().splitlines()[2])
    run_parakeet(argv[1], argv[2])


if __name__ == "__main__":
    main(sys.argv[1:])
