#!/usr/bin/env python3
"""Scores a transcript revision's word start times against a fixture's ground truth (phrase-initial words).

    scripts/speech/timing-report.py <revision.json> <package>/speech-words.json

Words are paired by sequence alignment on normalised text; errors are reported on matched words only, and the
unmatched count is reported separately so recognition errors can't hide behind timing numbers.
"""

import json
import re
import sys


def norm(word):
    return re.sub(r"[^a-z0-9']", "", word.lower())


revision = json.load(open(sys.argv[1]))
truth = [(norm(w["word"]), w["start"]) for w in json.load(open(sys.argv[2])) if norm(w["word"])]
hyp = []
for segment in revision["segments"]:
    raw = segment["rawText"].encode()
    for unit in segment["units"]:
        if unit["kind"] == "punctuation" or not unit.get("timing"):
            continue
        text = raw[unit["utf8Start"]:unit["utf8End"]].decode()
        r = unit["timing"]["sourceRange"]["start"]
        start = int(r["value"]) / r["timescale"]
        for i, part in enumerate(text.split()):  # multi-token units ("Part 28") keep the first start
            if norm(part):
                hyp.append((norm(part), start if i == 0 else None))

# Truth covers phrase-initial words only: pair each with the hypothesis word of the same text nearest in time
# (within 1 s); anything else counts as unmatched.
errors = []
matched = 0
for word, t in truth:
    candidates = [h for w, h in hyp if w == word and h is not None and abs(h - t) <= 1.0]
    if candidates:
        matched += 1
        errors.append(min(abs(h - t) for h in candidates))
errors.sort()
if not errors:
    sys.exit("no matched words")
p = lambda q: errors[min(len(errors) - 1, int(q * len(errors)))]
print(f"truth words {len(truth)}  matched {matched}  unmatched {len(truth) - matched}")
print(f"start error: median {p(0.5) * 1000:.0f} ms  p95 {p(0.95) * 1000:.0f} ms  max {errors[-1] * 1000:.0f} ms")
