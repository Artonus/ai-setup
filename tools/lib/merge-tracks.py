#!/usr/bin/env python3
"""Merge per-speaker whisper JSON transcripts into one labelled transcript.

Usage: merge-tracks.py [--diarization LABEL=FILE.json] LABEL FILE.json [LABEL FILE.json ...]

Words from all tracks are ordered by start time; a new line starts whenever the
speaker changes. Segments without word timestamps count as a single word.

With --diarization (diarize.py output for the track LABEL), words of that track
are labelled "LABEL 1", "LABEL 2", ... in order of each speaker's first
assigned word. A word goes to the diarization segment it overlaps most; in a
gap it goes to the nearest segment within TOLERANCE seconds, otherwise it keeps
the bare LABEL.
"""
import json
import sys

TOLERANCE = 1.0  # seconds


def units(label, path):
    with open(path, encoding="utf-8") as f:
        segments = json.load(f).get("segments", [])
    for seg in segments:
        words = seg.get("words") or [{"start": seg["start"], "word": seg["text"]}]
        for w in words:
            text = w["word"].strip()
            if text:
                yield w["start"], label, text, w.get("end", w["start"])


def load_segments(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return sorted(
            (float(s["start"]), float(s["end"]), str(s["speaker"]))
            for s in data.get("segments", [])
        )
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
        sys.exit("merge-tracks: cannot read diarization file %s: %s" % (path, e))


def speaker_for(segments, start, end):
    """Speaker of the segment overlapping [start, end] most, else the nearest within TOLERANCE."""
    best, best_overlap = None, 0.0
    for s_start, s_end, speaker in segments:
        if end > start:
            overlap = min(end, s_end) - max(start, s_start)
        else:
            overlap = 1e-9 if s_start <= start < s_end else 0.0
        if overlap > best_overlap:
            best, best_overlap = speaker, overlap
    if best is not None:
        return best
    nearest, dist = None, TOLERANCE
    for s_start, s_end, speaker in segments:
        d = max(s_start - start, start - s_end, 0.0)
        if d <= dist:
            nearest, dist = speaker, d
    return nearest


def stamp(seconds):
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def main(args):
    diar = {}
    while args and args[0] == "--diarization":
        if len(args) < 2 or "=" not in args[1]:
            sys.exit("merge-tracks: --diarization needs LABEL=FILE.json")
        label, path = args[1].split("=", 1)
        diar[label] = load_segments(path)
        args = args[2:]
    if not args or len(args) % 2:
        sys.exit(__doc__.strip().splitlines()[2])
    labels = args[::2]
    for label in diar:
        if label not in labels:
            sys.exit("merge-tracks: --diarization label '%s' matches no track" % label)

    all_units = []
    for label, path in zip(labels, args[1::2]):
        all_units.extend(units(label, path))
    all_units.sort(key=lambda u: u[0])

    names = {}  # (label, raw speaker) -> "LABEL N", numbered by first assigned word
    turns = []  # [start, label, [words]]
    for start, label, text, end in all_units:
        if label in diar:
            speaker = speaker_for(diar[label], start, end)
            if speaker is not None:
                key = (label, speaker)
                if key not in names:
                    n = 1 + sum(1 for k in names if k[0] == label)
                    names[key] = "%s %d" % (label, n)
                label = names[key]
        if turns and turns[-1][1] == label:
            turns[-1][2].append(text)
        else:
            turns.append([start, label, [text]])
    for start, label, words in turns:
        print(f"[{stamp(start)}] {label}: {' '.join(words)}")


if __name__ == "__main__":
    main(sys.argv[1:])
