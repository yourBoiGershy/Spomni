#!/usr/bin/env python3
"""02-rejection-recorded.py — T3 grader for stated-kind-sticks.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation: the pre-seeded judgment record for
`ravi-sundar` wrongly says `kind: collaborator` while his person file has
`kind_source: stated-by-user` / `kind: friend`. Per SKILL.md's Step 3
description of `check-judgment.sh`'s `stated-kind-changed` check, this
must be caught and recorded somehow. This case's prompt.md asks the skill
to apply that check by hand, so either of the following counts as the
rejection having actually happened (accept either, per the case brief —
FAIL only if neither is true):

  (a) `data-ingestion/run.log` contains a line
      `ravi-sundar\treject:stated-kind-changed`, or
  (b) the judgments jsonl file's `ravi-sundar` record now has
      `"kind":"friend"` (the record itself was corrected to the stated
      kind in place).
"""

import json
import os
import sys

SLUG = "ravi-sundar"
REJECT_LINE_PREFIX = f"{SLUG}\treject:stated-kind-changed"
JUDGMENTS_REL = os.path.join(
    "data-ingestion", "review-judgments", "2026-08-29.jsonl"
)
RUN_LOG_REL = os.path.join("data-ingestion", "run.log")


def run_log_has_rejection(worked):
    path = os.path.join(worked, RUN_LOG_REL)
    if not os.path.isfile(path):
        return False
    with open(path) as f:
        for line in f:
            if line.rstrip("\n") == REJECT_LINE_PREFIX:
                return True
    return False


def judgments_record_corrected(worked):
    path = os.path.join(worked, JUDGMENTS_REL)
    if not os.path.isfile(path):
        return False
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("slug") == SLUG and rec.get("kind") == "friend":
                return True
    return False


def main():
    if len(sys.argv) < 2:
        print("usage: 02-rejection-recorded.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]

    via_log = run_log_has_rejection(worked)
    via_record = judgments_record_corrected(worked)

    if not (via_log or via_record):
        print(
            "FAIL:\n  - "
            f"neither {RUN_LOG_REL} contains "
            f"'{REJECT_LINE_PREFIX}' nor does the judgments jsonl's "
            f"'{SLUG}' record now read kind=friend — the "
            "stated-kind-changed rejection was never recorded"
        )
        return 1

    print(
        "PASS: stated-kind-changed rejection recorded for "
        f"'{SLUG}' (via {'run.log' if via_log else 'corrected judgment record'})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
