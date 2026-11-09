#!/usr/bin/env python3
"""Speaker diarization with pyannote Community-1.

Usage: diarize.py MONO.wav OUT.json

Writes {"segments": [{"start", "end", "speaker"}], "num_speakers": N} built from
the model's exclusive_speaker_diarization. On any failure exits non-zero and
leaves no output file, so the caller can fall back to "no diarization".

Environment:
  HF_TOKEN                 Hugging Face token (else the `huggingface-cli login` cache).
                           Never written or logged by this script.
  HF_HUB_OFFLINE=1         use the already downloaded model only.
  MEETING_DIARIZE_DEVICE   cuda (default, falls back to cpu on CUDA/OOM errors) or cpu.
  MEETING_DIARIZE_FAKE     path to a ready result JSON, copied instead of running
                           pyannote (tests).
"""
import inspect
import json
import os
import shutil
import sys

MODEL = "pyannote/speaker-diarization-community-1"


def log(msg):
    print("diarize: " + msg, file=sys.stderr)


def load_pipeline(device):
    from pyannote.audio import Pipeline  # lazy: absent on macOS dev machines

    kwargs = {}
    token = os.environ.get("HF_TOKEN")
    if token:
        params = inspect.signature(Pipeline.from_pretrained).parameters
        name = "token" if "token" in params else "use_auth_token"
        kwargs[name] = token
    try:
        pipeline = Pipeline.from_pretrained(MODEL, **kwargs)
    except TypeError:
        if not token or "token" not in kwargs:
            raise
        pipeline = Pipeline.from_pretrained(MODEL, use_auth_token=token)
    if pipeline is None:
        raise RuntimeError("model %s could not be loaded (token or licence not accepted?)" % MODEL)
    import torch

    pipeline.to(torch.device(device))
    return pipeline


def is_cuda_error(exc):
    text = (type(exc).__name__ + " " + str(exc)).lower()
    return "cuda" in text or "out of memory" in text


def run_pipeline(wav, device):
    pipeline = load_pipeline(device)
    output = pipeline(wav)
    return getattr(output, "exclusive_speaker_diarization", None) or output.speaker_diarization


def to_result(annotation):
    segments = [
        {"start": round(turn.start, 3), "end": round(turn.end, 3), "speaker": speaker}
        for turn, _, speaker in annotation.itertracks(yield_label=True)
    ]
    segments.sort(key=lambda s: (s["start"], s["end"]))
    return {"segments": segments, "num_speakers": len({s["speaker"] for s in segments})}


def diarize(wav, device):
    try:
        return to_result(run_pipeline(wav, device))
    except Exception as exc:  # noqa: BLE001 - retry once on CPU for CUDA/OOM problems
        if device == "cpu" or not is_cuda_error(exc):
            raise
        log("CUDA failed (%s); retrying on CPU" % type(exc).__name__)
        try:
            import torch

            torch.cuda.empty_cache()
        except Exception:  # noqa: BLE001
            pass
        return to_result(run_pipeline(wav, "cpu"))


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def main(argv):
    if len(argv) != 2 or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if argv and argv[0] in ("-h", "--help") else 2
    wav, out = argv
    if os.path.exists(out):
        os.remove(out)  # a failed run must not leave a stale result behind
    fake = os.environ.get("MEETING_DIARIZE_FAKE")
    if fake:
        try:
            shutil.copyfile(fake, out)
        except OSError as exc:
            log("cannot copy fake result: %s" % exc)
            return 1
        return 0
    if not os.path.isfile(wav):
        log("no such file: %s" % wav)
        return 1
    device = os.environ.get("MEETING_DIARIZE_DEVICE", "cuda")
    if device not in ("cuda", "cpu"):
        log("MEETING_DIARIZE_DEVICE must be cuda or cpu, got '%s'" % device)
        return 2
    try:
        write_json(out, diarize(wav, device))
    except Exception as exc:  # noqa: BLE001
        # Only the exception type and message; the token is never part of either.
        log("failed: %s: %s" % (type(exc).__name__, str(exc).replace(os.environ.get("HF_TOKEN") or "\0", "***")))
        for p in (out, out + ".tmp"):
            if os.path.exists(p):
                os.remove(p)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
