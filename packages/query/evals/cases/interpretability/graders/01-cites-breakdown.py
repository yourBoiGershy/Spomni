#!/usr/bin/env python3
"""01-cites-breakdown.py — T2 grader for the interpretability eval case.

$1 = path to eval-run.sh's result JSON (fields: result, is_error, num_turns,
total_cost_usd, duration_ms, permission_denials, usage — per
packages/core/contracts/eval-case.md).

Hand-derived from the fixture store (never from a prior run's output, per
the golden-tests-before-prompts rule):

  packages/core/fixtures/store/wakeups/2026-09-05-james-okafor.md is the
  only `pending` wake-up due soonest, so it is suggest_reachouts' top
  suggestion (source: attention). Its concrete, tool-surfaced ranking facts:

    - due date:        2026-09-05
    - why field:        "gone quiet for nearly a year" / Redline Consulting
                         acquisition (frontmatter `why`)
    - origin:            signal (frontmatter `origin`)
    - status:            pending (frontmatter `status`)

  packages/core/fixtures/store/people/james-okafor.md +
  packages/core/fixtures/store/interactions/2025-09-15-james-okafor.md
  (surfaced via get_contact_stats):

    - tier:              dormant
    - open_threads:      1 ("Never followed up after the acquisition news")
    - median_gap_days:   null (only one recorded interaction, no cadence)

A grounded explanation should cite at least two of these concrete facts, not
just assert a ranking with no evidence. Exits 0 if >= 2 distinct fact-groups
are matched (case-insensitive) in the result text, 1 otherwise.
"""

import json
import re
import sys

FACT_GROUPS = [
    ("due date (2026-09-05)", re.compile(r"2026-09-05|september\s*5(st|th)?", re.IGNORECASE)),
    ("why-field content (Redline / acquisition / gone quiet / nearly a year)",
     re.compile(r"redline|acqui(re|sition)|gone quiet|nearly a year", re.IGNORECASE)),
    ("origin: signal", re.compile(r"\bsignal\b", re.IGNORECASE)),
    ("status: pending", re.compile(r"\bpending\b", re.IGNORECASE)),
    ("tier: dormant", re.compile(r"\bdormant\b", re.IGNORECASE)),
    ("open threads (1)", re.compile(r"open[-\s]thread", re.IGNORECASE)),
    ("no established cadence / median gap", re.compile(r"median[-\s]gap|no.*cadence|only one.*interaction", re.IGNORECASE)),
]


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: 01-cites-breakdown.py <result.json>")
        return 1

    result_path = sys.argv[1]

    try:
        with open(result_path) as f:
            data = json.load(f)
    except Exception as exc:
        print(f"FAIL: could not parse result JSON at {result_path}: {exc}")
        return 1

    if data.get("is_error"):
        print(f"FAIL: is_error is true in {result_path}")
        return 1

    result_text = data.get("result")
    if not isinstance(result_text, str):
        print(f"FAIL: result field missing or not a string in {result_path}")
        return 1

    matched = [label for label, pattern in FACT_GROUPS if pattern.search(result_text)]

    print(f"found {len(matched)} cited fact-group(s): {matched}")

    if len(matched) >= 2:
        print("PASS: explanation cites at least two concrete ranking facts")
        return 0

    print("FAIL: explanation does not ground its ranking in at least two "
          "concrete tool-surfaced facts (due date, why content, origin, "
          "status, tier, open threads, or median gap)")
    print(f"result text was: {result_text!r}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
