#!/usr/bin/env python3
"""Convert Parakeet (token timestamps) output to Whisper-style JSON for merge-tracks.py.

Usage: parakeet-adapter.py [--format json|txt] [IN.json]     (stdin when IN.json is omitted)

Input: one object, or a list of objects (one per audio chunk), each like
  {"text": "...", "tokens": ["▁Dzień", "▁do", "bry"], "timestamps": [0.08, 0.4, 0.56], "offset": 12.0}
`tokens` are SentencePiece pieces ("▁" starts a word), `timestamps` the start time in seconds of
each token relative to the chunk, `offset` (optional, default 0) the chunk's start in the file.
Output: {"segments": [{"start", "end", "text", "words": [{"start", "end", "word": " Dzień"}]}]}
A chunk becomes one segment; it is split further where the silence between two words exceeds 1.5 s.
A word ends where the next word starts, or 0.3 s after its start for the last word of a chunk.
With --format txt the plain text is printed instead.
"""
import json
import sys

GAP = 1.5
LAST_WORD = 0.3
MARK = "▁"


def words_of(chunk):
    tokens, stamps = chunk.get("tokens") or [], chunk.get("timestamps") or []
    if len(tokens) != len(stamps):
        raise ValueError(f"{len(tokens)} tokens but {len(stamps)} timestamps")
    offset = float(chunk.get("offset", 0.0))
    words = []  # [start, text]
    for tok, ts in zip(tokens, stamps):
        starts_word = tok.startswith(MARK) or not words
        piece = tok.lstrip(MARK) if tok.startswith(MARK) else tok
        if not piece.strip():
            continue
        if starts_word:
            words.append([offset + float(ts), piece])
        else:
            words[-1][1] += piece
    return words


def convert(chunks):
    if isinstance(chunks, dict):
        chunks = [chunks]
    segments = []
    for chunk in chunks:
        words = words_of(chunk)
        if not words:
            continue
        timed = []
        for i, (start, text) in enumerate(words):
            end = words[i + 1][0] if i + 1 < len(words) else start + LAST_WORD
            timed.append({"start": round(start, 3), "end": round(max(end, start), 3), "word": " " + text})
        groups, cur = [], [timed[0]]
        for prev, w in zip(timed, timed[1:]):
            if w["start"] - (prev["start"] + LAST_WORD) > GAP:
                groups.append(cur)
                cur = []
            cur.append(w)
        groups.append(cur)
        for g in groups:
            # a word ends at the next word only within a group
            g[-1]["end"] = min(g[-1]["end"], g[-1]["start"] + LAST_WORD)
            segments.append({
                "start": g[0]["start"], "end": g[-1]["end"],
                "text": "".join(w["word"] for w in g), "words": g,
            })
    return {"segments": segments}


def main(argv):
    fmt = "json"
    if argv[:1] == ["--format"]:
        fmt, argv = argv[1], argv[2:]
    if fmt not in ("json", "txt") or len(argv) > 1:
        sys.exit(__doc__.strip().splitlines()[2])
    raw = open(argv[0], encoding="utf-8").read() if argv else sys.stdin.read()
    result = convert(json.loads(raw))
    if fmt == "txt":
        print(" ".join(s["text"].strip() for s in result["segments"]))
    else:
        json.dump(result, sys.stdout, ensure_ascii=False)
        print()


if __name__ == "__main__":
    main(sys.argv[1:])
