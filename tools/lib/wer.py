#!/usr/bin/env python3
"""Word and character error rate for Polish ASR evaluation. Pure Python, no dependencies.

Usage: wer.py REFERENCE.txt HYPOTHESIS.txt     (prints JSON)

Normalization (applied identically to reference and hypothesis):
  1. Unicode NFC, lower case (str.casefold is NOT used: it would turn 'ß' etc. into other letters).
  2. A decimal separator between digits ("3,5" / "3.5") is kept as ".", so it stays one token.
  3. "%" becomes the word "procent" ("50%" -> "50 procent").
  4. Every other punctuation or symbol character (Unicode categories P* and S*, which includes
     ASCII punctuation and „ ” “ " « » – — … ) becomes a space. Polish letters (ąćęłńóśźż)
     are kept as they are.
  5. Polish cardinal numbers written as words are converted to digits: "dwadzieścia pięć" -> "25",
     "trzysta" -> "300", "dwa tysiące dwadzieścia" -> "2020". Handled: 0-999 999 in the nominative,
     plus the common forms "jedna/jedno", "dwie", "tysiąc/tysiące/tysięcy". Not handled: ordinals
     ("trzeci"), declined forms ("dwóch", "pięciu"), "milion", fractions. A run of number words that
     is not a valid number ("dwa dwa") is converted word by word.
  6. Digits split by a space ("1 000") are NOT joined; write numbers in the reference without
     thousands separators.
Whitespace is collapsed. WER is the word-level Levenshtein distance divided by the reference
word count; CER is the same on characters of the normalized text (spaces included).
"""
import json
import re
import sys
import unicodedata

UNITS = {
    "zero": 0, "jeden": 1, "jedna": 1, "jedno": 1, "dwa": 2, "dwie": 2, "trzy": 3, "cztery": 4,
    "pięć": 5, "sześć": 6, "siedem": 7, "osiem": 8, "dziewięć": 9,
}
TEENS = {
    "dziesięć": 10, "jedenaście": 11, "dwanaście": 12, "trzynaście": 13, "czternaście": 14,
    "piętnaście": 15, "szesnaście": 16, "siedemnaście": 17, "osiemnaście": 18, "dziewiętnaście": 19,
}
TENS = {
    "dwadzieścia": 20, "trzydzieści": 30, "czterdzieści": 40, "pięćdziesiąt": 50,
    "sześćdziesiąt": 60, "siedemdziesiąt": 70, "osiemdziesiąt": 80, "dziewięćdziesiąt": 90,
}
HUNDREDS = {
    "sto": 100, "dwieście": 200, "trzysta": 300, "czterysta": 400, "pięćset": 500,
    "sześćset": 600, "siedemset": 700, "osiemset": 800, "dziewięćset": 900,
}
THOUSANDS = {"tysiąc", "tysiące", "tysięcy"}

_DEC = ""  # private-use placeholder protecting decimal separators


def _classify(t):
    """(rank, value) for a number word: rank 3 hundreds, 2 tens/teens, 1 units; None otherwise."""
    if t in HUNDREDS:
        return 3, HUNDREDS[t]
    if t in TENS:
        return 2, TENS[t]
    if t in TEENS:
        return 0, TEENS[t]  # rank 0: nothing may follow a teen
    if t in UNITS and t != "zero":
        return 1, UNITS[t]
    return None


def _words_to_digits(tokens):
    out = []
    i, n = 0, len(tokens)
    while i < n:
        t = tokens[i]
        if t == "zero":
            out.append("0")
            i += 1
            continue
        if _classify(t) is None and t not in THOUSANDS:
            out.append(t)
            i += 1
            continue
        total, current, last_rank, thousand_used = 0, 0, 4, False
        j = i
        while j < n:
            t = tokens[j]
            if t in THOUSANDS:
                if thousand_used or (current == 0 and j != i):
                    break
                total, current, last_rank, thousand_used = max(current, 1) * 1000, 0, 4, True
                j += 1
                continue
            c = _classify(t)
            if c is None:
                break
            rank, val = c
            # ranks must strictly descend (hundreds, tens, units); a teen ends the group
            if last_rank != 4 and (last_rank == 0 or (rank != 0 and rank >= last_rank)):
                break
            current += val
            last_rank = rank
            j += 1
        out.append(str(total + current))
        i = j
    return out


def normalize(text):
    text = unicodedata.normalize("NFC", text).lower()
    text = re.sub(r"(?<=\d)[.,](?=\d)", _DEC, text)
    text = text.replace("%", " procent ")
    text = "".join(
        " " if unicodedata.category(c)[0] in "PS" else c for c in text
    )
    text = text.replace(_DEC, ".")
    tokens = _words_to_digits(text.split())
    return unicodedata.normalize("NFC", " ".join(tokens))


def edit_distance(a, b):
    """Levenshtein distance between two sequences (insert, delete, substitute all cost 1)."""
    if len(a) < len(b):
        a, b = b, a
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]


def score(reference, hypothesis):
    """Return edit counts for already raw (not normalized) strings."""
    ref, hyp = normalize(reference), normalize(hypothesis)
    rw, hw = ref.split(), hyp.split()
    return {
        "word_edits": edit_distance(rw, hw), "ref_words": len(rw),
        "char_edits": edit_distance(ref, hyp), "ref_chars": len(ref),
    }


def rate(edits, total):
    return edits / total if total else (0.0 if edits == 0 else 1.0)


def wer_cer(reference, hypothesis):
    s = score(reference, hypothesis)
    return rate(s["word_edits"], s["ref_words"]), rate(s["char_edits"], s["ref_chars"])


def jiwer_wer(reference, hypothesis):
    """WER from jiwer on the normalized texts, or None when jiwer is not installed."""
    try:
        import jiwer
    except ImportError:
        return None
    ref, hyp = normalize(reference), normalize(hypothesis)
    return jiwer.wer(ref, hyp) if ref else None


def main(argv):
    if len(argv) != 2:
        sys.exit(__doc__.strip().splitlines()[2])
    with open(argv[0], encoding="utf-8") as f:
        ref = f.read()
    with open(argv[1], encoding="utf-8") as f:
        hyp = f.read()
    w, c = wer_cer(ref, hyp)
    print(json.dumps({"wer": w, "cer": c, **score(ref, hyp), "jiwer_wer": jiwer_wer(ref, hyp)},
                     ensure_ascii=False))


if __name__ == "__main__":
    main(sys.argv[1:])
