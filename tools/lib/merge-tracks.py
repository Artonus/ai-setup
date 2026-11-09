#!/usr/bin/env python3
"""Merge per-speaker whisper JSON transcripts into one labelled transcript.

Usage: merge-tracks.py LABEL FILE.json [LABEL FILE.json ...]

Words from all tracks are ordered by start time; a new line starts whenever the
speaker changes. Segments without word timestamps count as a single word.
"""
import json
import sys


def units(label, path):
    with open(path, encoding="utf-8") as f:
        segments = json.load(f).get("segments", [])
    for seg in segments:
        words = seg.get("words") or [{"start": seg["start"], "word": seg["text"]}]
        for w in words:
            text = w["word"].strip()
            if text:
                yield w["start"], label, text


def stamp(seconds):
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def main(args):
    if not args or len(args) % 2:
        sys.exit(__doc__.strip().splitlines()[2])
    all_units = []
    for label, path in zip(args[::2], args[1::2]):
        all_units.extend(units(label, path))
    all_units.sort(key=lambda u: u[0])

    turns = []  # [start, label, [words]]
    for start, label, text in all_units:
        if turns and turns[-1][1] == label:
            turns[-1][2].append(text)
        else:
            turns.append([start, label, [text]])
    for start, label, words in turns:
        print(f"[{stamp(start)}] {label}: {' '.join(words)}")


if __name__ == "__main__":
    main(sys.argv[1:])
