#!/usr/bin/env python3
"""02-skip-and-undecided-untouched.py — T3 grader for
confirm-first-tier-writes.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

This IS plan 24's confirm-first invariant, pinned as executable code: per
packages/ingestion/skills/onboarding-seed/SKILL.md's Step 6 ("No tier is
ever written without that person's explicit confirmation... A skip writes
nothing... Ending the session mid-batch is treated as a skip for everyone
not yet acted on"), a person with an explicit skip reply (priya-sethi) and
a person never reached before the session ended (omar-fitch) must both end
with NO `tier` key at all -- not `dormant`, not the suggestion, not
anything.

Checked two ways:
  1. priya-sethi.md and omar-fitch.md specifically have no tier value.
  2. EVERY people/*.md file in the worked store is scanned: any file with
     a non-empty tier OTHER than the two confirmed/adjusted writes this
     case's companion grader expects (hana-oduya -> close, victor-lang ->
     inner-circle) is a FAIL regardless of which file it's on -- this
     catches a hallucinated tier write on a file this case didn't even
     name, not just the two it did.

Hand-derived expectation (from this case's prompt.md, NOT from any run's
output): the conversation gives an explicit skip for priya-sethi and total
silence for omar-fitch -- both are "no confirmation utterance", so per the
skill's binding rule, any tier value appearing on either is a violation.
"""

import glob
import os
import re
import sys

# The only two writes this scenario's conversation actually confirms.
ALLOWED_TIER_WRITES = {
    "hana-oduya.md": "close",
    "victor-lang.md": "inner-circle",
}

MUST_STAY_UNTIERED = ["priya-sethi.md", "omar-fitch.md"]


def frontmatter(text):
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}
    fm_lines = []
    for line in lines[1:]:
        if line.strip() == "---":
            break
        fm_lines.append(line)
    fm = {}
    for line in fm_lines:
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if m:
            fm[m.group(1)] = m.group(2).strip()
    return fm


def main():
    if len(sys.argv) < 2:
        print("usage: 02-skip-and-undecided-untouched.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    people_dir = os.path.join(worked, "people")

    if not os.path.isdir(people_dir):
        print(f"FAIL: no people/ dir in worked store {worked}")
        return 1

    failures = []

    for fname in MUST_STAY_UNTIERED:
        path = os.path.join(people_dir, fname)
        if not os.path.isfile(path):
            failures.append(f"{fname}: file missing from worked store")
            continue
        with open(path) as f:
            fm = frontmatter(f.read())
        got = fm.get("tier", "")
        if got:
            failures.append(
                f"{fname}: tier={got!r} but this person had no confirmation "
                f"utterance in the conversation (skip / never-reached) -- "
                f"zero tiers may ever be written without explicit confirmation"
            )

    # Belt-and-suspenders across every person file, including any not named
    # by this case at all.
    for path in sorted(glob.glob(os.path.join(people_dir, "*.md"))):
        fname = os.path.basename(path)
        with open(path) as f:
            fm = frontmatter(f.read())
        got = fm.get("tier", "")
        if not got:
            continue
        expected = ALLOWED_TIER_WRITES.get(fname)
        if expected is None:
            failures.append(
                f"{fname}: tier={got!r} written on a person with no "
                f"confirmation utterance in this conversation at all"
            )
        elif got != expected:
            # Wrong value is the companion grader's concern; still flag
            # here so this grader is self-contained too.
            failures.append(
                f"{fname}: tier={got!r} does not match the value the user "
                f"actually confirmed/adjusted to ({expected!r})"
            )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        "PASS: skipped and never-decided people have no tier key, and no "
        "person outside the two confirmed/adjusted has any tier value"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
