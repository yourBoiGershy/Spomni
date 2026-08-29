#!/usr/bin/env python3
"""02-signal-event-logged.py — T3 grader for the scheduling-intent-proposal
eval case.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from
packages/attention/tests/fixtures/scheduling-intent/clear-intent/expected/
signal-event.md and interactions/2026-08-27-theo-bramwell.md, per
packages/attention/skills/scheduling-intent/SKILL.md's step 3 -- the signal
event is written unconditionally, first, before any gate): the detector
must write exactly one new `wakeups/signals/*.md` file conforming to
packages/core/contracts/signal-event.md, with `type: scheduling-intent`,
`person` naming [[theo-bramwell]], `confidence: high`, and `evidence`
quoting the actual source line from the 2026-08-27 interaction ("are you
free for lunch") rather than paraphrasing it away -- provenance-labeling
(CLAUDE.md) requires the evidence be traceable to the source text, not just
asserted.
"""

import glob
import os
import re
import sys

EXPECTED_QUOTE_FRAGMENT = "free for lunch"


def parse_top_level(text):
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}
    fm = {}
    for line in lines[1:]:
        if line.strip() == "---":
            break
        if line.startswith((" ", "\t")):
            continue
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if m:
            fm[m.group(1)] = m.group(2).strip()
    return fm


def main():
    if len(sys.argv) < 2:
        print("usage: 02-signal-event-logged.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    signals_dir = os.path.join(worked, "wakeups", "signals")

    if not os.path.isdir(signals_dir):
        print(f"FAIL: no wakeups/signals/ dir in worked store {worked}")
        return 1

    candidates = sorted(glob.glob(os.path.join(signals_dir, "*.md")))

    before_dir = os.environ.get("RA_EVAL_BEFORE_DIR", "")
    if before_dir:
        before_signals = os.path.join(before_dir, "wakeups", "signals")
        before_names = set()
        if os.path.isdir(before_signals):
            before_names = {
                os.path.basename(p)
                for p in glob.glob(os.path.join(before_signals, "*.md"))
            }
        candidates = [c for c in candidates if os.path.basename(c) not in before_names]

    if len(candidates) != 1:
        print(f"FAIL: expected exactly one new signal event, found {len(candidates)}: {candidates}")
        return 1

    signal_path = candidates[0]
    with open(signal_path) as f:
        text = f.read()

    fm = parse_top_level(text)

    if fm.get("type") != "scheduling-intent":
        print(f"FAIL: expected type: scheduling-intent, got {fm.get('type')!r} in {signal_path}")
        return 1

    if "theo-bramwell" not in fm.get("person", ""):
        print(f"FAIL: expected person to include [[theo-bramwell]], got {fm.get('person')!r} in {signal_path}")
        return 1

    if fm.get("confidence") != "high":
        print(f"FAIL: expected confidence: high, got {fm.get('confidence')!r} in {signal_path}")
        return 1

    # `evidence` is a YAML folded/multi-line scalar (`evidence: >` in the
    # fixture) -- rather than re-implement YAML folding, just check the
    # quoted-line fragment appears somewhere in the file text at all.
    if EXPECTED_QUOTE_FRAGMENT not in text:
        print(
            f"FAIL: evidence does not contain the source quote fragment "
            f"{EXPECTED_QUOTE_FRAGMENT!r} -- expected a quoted line traceable "
            f"to interactions/2026-08-27-theo-bramwell.md, not a paraphrase"
        )
        print(f"file was: {text}")
        return 1

    print(f"PASS: found conforming scheduling-intent signal event at {signal_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
