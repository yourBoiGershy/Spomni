#!/usr/bin/env python3
"""02-breakdown-regex.py — T3 grader for the tier-drift-by-kind eval case.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Every new proposal (wakeups/*.md) and signal event (wakeups/signals/*.md,
excluding scan-log.md) must carry a breakdown string matching
packages/core/contracts/relationship-scoring.md's "## Breakdown string"
exact format:

  warrant: <0-100> | kind: <kind> (<kind_source>[, expires <date>]) —
  <kind_note> | evidence: touchpoints=<n> median_gap_days=<n>
  days_since_last=<n> meetings=<n> chat_days=<n> participation=<v> |
  priors: ... | rationale: <text> | suggested: <tier>

This fixture's store has no user-model.md (see this case's prompt.md),
so the `priors:` segment is expected to disclose `user-model: none`
rather than fabricate a `user-model.<axis>=<w>` prior -- the regex below
is deliberately tolerant of the priors segment's exact contents (it only
requires the segment to exist between `priors:` and `| rationale:`), since
that disclosure is the point being tested, not a fixed weight format.

Additionally, any new file naming milo-vantage (the unkinded candidate)
must carry the unkinded-fallback disclosure string verbatim, per
specs/tier-drift.md's prefilter rule 1: "no kind on file — professional
horizon assumed".
"""

import glob
import os
import re
import sys

BREAKDOWN_RE = re.compile(
    r"warrant:\s*\d{1,3}\s*\|\s*"
    r"kind:\s*\S+\s*\([^)]*\)\s*[—-]\s*.+?\s*\|\s*"
    r"evidence:.+?\|\s*"
    r"priors:.+?\|\s*"
    r"rationale:.+?\|\s*"
    r"suggested:\s*\S+",
    re.DOTALL,
)

DISCLOSURE = "no kind on file — professional horizon assumed"


def existing_names(before_dir, subpath):
    d = os.path.join(before_dir, subpath)
    if not os.path.isdir(d):
        return set()
    return {os.path.basename(p) for p in glob.glob(os.path.join(d, "*.md"))}


def new_files(worked, before_dir, subpath):
    d = os.path.join(worked, subpath)
    if not os.path.isdir(d):
        return []
    candidates = sorted(glob.glob(os.path.join(d, "*.md")))
    if before_dir:
        before_names = existing_names(before_dir, subpath)
        candidates = [c for c in candidates if os.path.basename(c) not in before_names]
    return candidates


def main():
    if len(sys.argv) < 2:
        print("usage: 02-breakdown-regex.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    before_dir = os.environ.get("RA_EVAL_BEFORE_DIR", "")

    proposal_files = new_files(worked, before_dir, "wakeups")
    signal_files = new_files(worked, before_dir, "wakeups/signals")
    signal_files = [f for f in signal_files if os.path.basename(f) != "scan-log.md"]
    checked = proposal_files + signal_files

    if not checked:
        print("FAIL: no new wakeup proposals or signal events found at all")
        return 1

    milo_files_seen = 0
    for path in checked:
        with open(path) as f:
            text = f.read()

        if not BREAKDOWN_RE.search(text):
            print(
                f"FAIL: {path} has no breakdown string matching the "
                f"relationship-scoring.md '## Breakdown string' format"
            )
            return 1

        if "milo-vantage" in text:
            milo_files_seen += 1
            if DISCLOSURE not in text:
                print(
                    f"FAIL: {path} names milo-vantage (unkinded candidate) "
                    f"but is missing the verbatim disclosure string "
                    f"{DISCLOSURE!r}"
                )
                return 1

    print(
        f"PASS: {len(checked)} new file(s) all carry a conforming "
        f"breakdown string ({milo_files_seen} milo-vantage file(s) also "
        f"carry the unkinded-fallback disclosure)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
