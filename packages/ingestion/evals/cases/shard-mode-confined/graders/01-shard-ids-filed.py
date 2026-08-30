#!/usr/bin/env python3
"""01-shard-ids-filed.py — T3 grader for shard-mode-confined.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from this case's prompt.md and fixture, NOT from
any run's output — per the eval-case contract's golden-tests-before-
prompts rule): `./store/data-ingestion/shards/shard-1.ids` lists exactly
two ids, `shard-fixture-dana-standup` and `shard-fixture-dana-followup`.
Both must be filed normally:

  - `data-ingestion/debrief-filed.shard-1.log` contains exactly those two
    ids, nothing else (no dup, no extra line),
  - an `interactions/*.md` file exists per id, traceable via
    `source-capture`, each carrying the `[[dana-kowalski]]` person link.

Fact-based only: file-existence and ledger/frontmatter-field checks, never
prose-diffing.
"""

import glob
import os
import re
import sys

SHARD_IDS = ["shard-fixture-dana-standup", "shard-fixture-dana-followup"]


def read_lines(path):
    if not os.path.isfile(path):
        return []
    with open(path) as f:
        return [line.rstrip("\n") for line in f if line.strip()]


def source_capture(text):
    m = re.search(r"^source-capture:\s*(\S+)\s*$", text, re.MULTILINE)
    return m.group(1) if m else None


def main():
    if len(sys.argv) < 2:
        print("usage: 01-shard-ids-filed.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    failures = []

    shard_log = os.path.join(worked, "data-ingestion", "debrief-filed.shard-1.log")
    shard_ids = read_lines(shard_log)
    if sorted(shard_ids) != sorted(SHARD_IDS):
        failures.append(
            f"debrief-filed.shard-1.log contains {shard_ids!r}, expected "
            f"exactly {SHARD_IDS!r} (no more, no less)"
        )

    interactions_dir = os.path.join(worked, "interactions")
    found_for = {}
    for path in sorted(glob.glob(os.path.join(interactions_dir, "*.md"))):
        with open(path) as f:
            text = f.read()
        sc = source_capture(text)
        if sc in SHARD_IDS:
            found_for.setdefault(sc, []).append((path, text))

    for cid in SHARD_IDS:
        matches = found_for.get(cid, [])
        if not matches:
            failures.append(
                f"no interactions/*.md file found with source-capture={cid!r}"
            )
            continue
        if len(matches) > 1:
            failures.append(
                f"more than one interaction file traces to source-capture={cid!r}: "
                f"{[os.path.basename(p) for p, _ in matches]}"
            )
        path, text = matches[0]
        if "[[dana-kowalski]]" not in text:
            failures.append(
                f"{os.path.basename(path)}: missing '[[dana-kowalski]]' person link"
            )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        "PASS: both shard-1.ids ids filed — debrief-filed.shard-1.log has "
        "exactly the two ids, each with a traceable interaction file linking "
        "[[dana-kowalski]]"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
