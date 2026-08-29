#!/usr/bin/env python3
"""01-proposal-created.py — T3 grader for the tier-drift-upward eval case.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused by this grader; the
     assertion is entirely about the resulting store contents).

Hand-derived expectation (from
packages/attention/tests/fixtures/tier-drift-upward/expected-proposal.md and
people/owen-marsh.md, per packages/attention/specs/tier-drift.md's UPWARD
table): owen-marsh is tagged `tier: dormant` with 5 interactions in the
trailing 90 days (>= the dormant threshold of 3), so the detector must write
exactly one new wakeup proposing a `dormant` -> `active` bump for
`[[owen-marsh]]`, with `origin: signal` and `status: pending`. The fixture's
`wakeups/` starts empty, so "new" here means "any file at all".

We deliberately do NOT require byte-identity against expected-proposal.md:
the real detector generates its own `id`/`due`/`source-signal` values from
the run date, which are not fixed by the fixture. What IS fixed, and what we
assert:
  - exactly one file lands under wakeups/ (top-level, *.md)
  - frontmatter: origin: signal, status: pending
  - people includes [[owen-marsh]]
  - the why-line + body together mention both "dormant" and "active"
    (expected-proposal.md's why references "dormant-tier cadence" and its
    ## Context proposes "dormant` -> `active`" -- both terms must appear
    somewhere in the file for the proposal to be legible as a tier bump,
    per the spec's promotion-wording requirement).
"""

import glob
import os
import re
import sys


def frontmatter_and_body(text):
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}, text
    fm_lines = []
    body_start = None
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            body_start = i + 1
            break
        fm_lines.append(line)
    if body_start is None:
        return {}, text
    fm = {}
    for line in fm_lines:
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if m:
            fm[m.group(1)] = m.group(2).strip()
    body = "\n".join(lines[body_start:])
    return fm, body


def main():
    if len(sys.argv) < 2:
        print("usage: 01-proposal-created.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    wakeups_dir = os.path.join(worked, "wakeups")

    if not os.path.isdir(wakeups_dir):
        print(f"FAIL: no wakeups/ dir in worked store {worked}")
        return 1

    # Fixture starts with an empty wakeups/, so any top-level *.md file here
    # is new (see RA_EVAL_BEFORE_DIR, the pristine fixture copy, for a
    # belt-and-suspenders check if it's set).
    candidates = sorted(glob.glob(os.path.join(wakeups_dir, "*.md")))

    before_dir = os.environ.get("RA_EVAL_BEFORE_DIR", "")
    if before_dir:
        before_wakeups = os.path.join(before_dir, "wakeups")
        before_names = set()
        if os.path.isdir(before_wakeups):
            before_names = {
                os.path.basename(p)
                for p in glob.glob(os.path.join(before_wakeups, "*.md"))
            }
        candidates = [c for c in candidates if os.path.basename(c) not in before_names]

    if len(candidates) != 1:
        print(f"FAIL: expected exactly one new wakeup file, found {len(candidates)}: {candidates}")
        return 1

    proposal_path = candidates[0]
    with open(proposal_path) as f:
        text = f.read()

    fm, body = frontmatter_and_body(text)

    if fm.get("origin") != "signal":
        print(f"FAIL: expected origin: signal, got {fm.get('origin')!r} in {proposal_path}")
        return 1

    if fm.get("status") != "pending":
        print(f"FAIL: expected status: pending, got {fm.get('status')!r} in {proposal_path}")
        return 1

    people = fm.get("people", "")
    if "owen-marsh" not in people:
        print(f"FAIL: expected people to include [[owen-marsh]], got {people!r} in {proposal_path}")
        return 1

    lower_text = text.lower()
    if "dormant" not in lower_text or "active" not in lower_text:
        print(
            "FAIL: proposal does not mention both 'dormant' and 'active' -- "
            "expected a tier-bump why-line/context per "
            "expected-proposal.md"
        )
        print(f"file was: {text}")
        return 1

    print(f"PASS: found conforming proposal wake-up at {proposal_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
