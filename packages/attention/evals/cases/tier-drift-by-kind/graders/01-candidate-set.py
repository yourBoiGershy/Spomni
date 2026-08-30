#!/usr/bin/env python3
"""01-candidate-set.py — T3 grader for the tier-drift-by-kind eval case.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused; assertion is entirely
     about the resulting store contents).

Hand-derived expectation (packages/attention/specs/tier-drift.md's
"## Prefilter", applied to the fixture's four people as of 2026-08-30, see
this case's expected/README.md table):

  - greer-holloway: kind=scheduling, kind_expires=2026-08-15 (past) ->
    expired kind, never enters the prefilter regardless of kind. NOT a
    candidate.
  - isla-marchetti: kind=friend, days_since_last=18 < horizon 30 -> inside
    horizon. NOT a candidate.
  - dana-whitfield: kind=friend, days_since_last=66 > horizon 30 ->
    candidate, goes to judgment.
  - milo-vantage: unkinded -> professional horizon (120), days_since_last
    =151 > 120 -> candidate, goes to judgment.

Only dana-whitfield and/or milo-vantage may appear in any NEW wakeup
proposal (top-level wakeups/*.md) or signal event (wakeups/signals/*.md,
excluding the run's own scan-log.md, which legitimately names the two
ruled-out people as `no-drift` log lines per the prompt -- that's a log,
not a signal event or proposal). Any new proposal or signal event naming
greer-holloway or isla-marchetti is a prefilter violation and an immediate
FAIL. At least one new proposal or signal event for dana-whitfield and/or
milo-vantage must exist -- the prefilter only narrows the candidate set,
it does not itself guarantee a fired proposal, but both candidates being
judged to `no-drift` with zero artifacts would leave nothing to check.
"""

import glob
import os
import sys

FORBIDDEN = {"greer-holloway", "isla-marchetti"}
ALLOWED = {"dana-whitfield", "milo-vantage"}


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
        print("usage: 01-candidate-set.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    before_dir = os.environ.get("RA_EVAL_BEFORE_DIR", "")

    proposal_files = new_files(worked, before_dir, "wakeups")
    signal_files = new_files(worked, before_dir, "wakeups/signals")
    # scan-log.md is a run log, not a signal event -- it legitimately names
    # the ruled-out people as no-drift reasons per the prompt.
    signal_files = [
        f for f in signal_files if os.path.basename(f) != "scan-log.md"
    ]

    checked = proposal_files + signal_files
    if not checked:
        print("FAIL: no new wakeup proposals or signal events found at all")
        return 1

    any_allowed = False
    for path in checked:
        with open(path) as f:
            text = f.read()
        hit_forbidden = [name for name in FORBIDDEN if name in text]
        if hit_forbidden:
            print(
                f"FAIL: {path} names ruled-out person(s) {hit_forbidden} -- "
                f"the kind-horizon prefilter must exclude expired/inside-"
                f"horizon people from every signal event and proposal"
            )
            return 1
        if any(name in text for name in ALLOWED):
            any_allowed = True

    if not any_allowed:
        print(
            f"FAIL: found {len(checked)} new file(s) but none name "
            f"dana-whitfield or milo-vantage: {checked}"
        )
        return 1

    print(
        f"PASS: {len(checked)} new file(s) checked, none name a ruled-out "
        f"person, at least one names an admitted candidate"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
