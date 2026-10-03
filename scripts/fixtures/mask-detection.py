#!/usr/bin/env python3
"""Mask a Herdr `agent.read --source detection` capture into a committable fixture.

Usage:
  mask-detection.py RAW OUT            write the masked copy of RAW to OUT
  mask-detection.py --check RAW OUT    verify OUT is a structure-preserving mask of RAW

This tool contains no captured data; raw captures stay outside the repository.

Masking rules (docs/specs fixtures plan, Task 5):
- every maximal run of ASCII letters becomes a same-length pseudo-word drawn deterministically
  (sha256 of the run's position) from a fixed lorem-ipsum vocabulary; the case of each letter is kept;
- the Claude Code marker word "recap" is kept (DetectionTextParser looks for "※ recap:");
- non-ASCII letters become "x";
- digits are kept only in option prefixes matching ^\\s*(❯\\s*)?\\d+\\.\\s ; every other digit becomes "7";
- every other character (spaces, punctuation, box drawing, markers such as ❯ ⏺ ※ ⎿ ▎ ✻ ← → ☐ ✔ ·)
  is copied verbatim, so line count, line lengths and trailing whitespace are unchanged.
"""
import hashlib
import re
import sys

VOCABULARY = (
    "a e i o u ad do ea et ex id in ut non qui sed sit est "
    "amet anim aute duis elit enim esse nisi quis sint sunt "
    "culpa dolor irure ipsum lorem magna minim nulla velit "
    "aliqua cillum dolore fugiat labore mollit tempor veniam "
    "aliquip commodo eiusmod laboris laborum nostrud officia ullamco "
    "deserunt occaecat pariatur proident "
    "consequat cupidatat excepteur voluptate "
    "adipiscing incididunt "
    "consectetur "
    "exercitation "
    "reprehenderit"
).split()
KEEP = {"recap"}
ALLOWED = set(VOCABULARY) | KEEP
BY_LENGTH = {}
for _word in VOCABULARY:
    BY_LENGTH.setdefault(len(_word), []).append(_word)

OPTION_PREFIX = re.compile(r"^(\s*(?:❯\s*)?)(\d+)(\.\s)")
LETTERS = re.compile(r"[A-Za-z]+")


def _digest(*parts):
    return int(hashlib.sha256(":".join(str(p) for p in parts).encode("utf-8")).hexdigest(), 16)


def pseudo_word(length, line_number, column):
    seed = _digest("word", line_number, column, length)
    candidates = BY_LENGTH.get(length)
    if candidates:
        return candidates[seed % len(candidates)]
    pieces = ""
    step = 0
    while len(pieces) < length:
        pieces += VOCABULARY[_digest("piece", seed, step) % len(VOCABULARY)]
        step += 1
    return pieces[:length]


def apply_case(original, replacement):
    return "".join(r.upper() if o.isupper() else r.lower() for o, r in zip(original, replacement))


def mask_line(line, line_number):
    protected = set()
    prefix = OPTION_PREFIX.match(line)
    if prefix:
        protected = set(range(prefix.start(2), prefix.end(2)))
    chars = list(line)
    for match in LETTERS.finditer(line):
        word = match.group(0)
        if word.lower() in KEEP:
            continue
        chars[match.start():match.end()] = list(apply_case(word, pseudo_word(len(word), line_number, match.start())))
    for index, ch in enumerate(chars):
        if ch.isdigit() and index not in protected:
            chars[index] = "7"
        elif ch.isalpha() and not ch.isascii():
            chars[index] = "x"
    return "".join(chars)


def mask_text(text):
    return "\n".join(mask_line(line, number) for number, line in enumerate(text.split("\n")))


def is_ascii_letter(ch):
    return ch.isascii() and ch.isalpha()


def check(raw_text, masked_text):
    problems = []
    raw_lines = raw_text.split("\n")
    masked_lines = masked_text.split("\n")
    if len(raw_lines) != len(masked_lines):
        problems.append("line count %d != %d" % (len(raw_lines), len(masked_lines)))
    for number, (raw, masked) in enumerate(zip(raw_lines, masked_lines), start=1):
        if len(raw) != len(masked):
            problems.append("line %d: length %d != %d" % (number, len(raw), len(masked)))
            continue
        for column, (r, m) in enumerate(zip(raw, masked), start=1):
            if is_ascii_letter(r):
                ok = is_ascii_letter(m)
            elif r.isalpha():
                ok = m == "x"
            elif r.isdigit():
                ok = m.isascii() and m.isdigit()
            else:
                ok = m == r
            if not ok:
                problems.append("line %d col %d: structure character changed" % (number, column))
                break
    raw_words = {w.lower() for w in LETTERS.findall(raw_text) if len(w) >= 4}
    masked_words = {w.lower() for w in LETTERS.findall(masked_text) if len(w) >= 4}
    leaked = (raw_words & masked_words) - ALLOWED
    if leaked:
        # Never print the words themselves: they are raw session text.
        problems.append("%d raw word(s) of 4+ letters survived masking" % len(leaked))
    return problems


def read(path):
    with open(path, "r", encoding="utf-8", newline="") as handle:
        return handle.read()


def main(argv):
    if len(argv) == 4 and argv[1] == "--check":
        problems = check(read(argv[2]), read(argv[3]))
        if problems:
            for problem in problems[:20]:
                print("mask-detection: FAIL: " + problem, file=sys.stderr)
            return 1
        print("mask-detection: OK (%d lines)" % read(argv[3]).count("\n"))
        return 0
    if len(argv) == 3 and not argv[1].startswith("-"):
        masked = mask_text(read(argv[1]))
        with open(argv[2], "w", encoding="utf-8", newline="") as handle:
            handle.write(masked)
        problems = check(read(argv[1]), masked)
        if problems:
            for problem in problems[:20]:
                print("mask-detection: FAIL: " + problem, file=sys.stderr)
            return 1
        print("mask-detection: wrote %s" % argv[2])
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
