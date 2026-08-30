#!/usr/bin/env python3
"""01-stated-untouched.py — T3 grader for stated-kind-sticks.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from this case's prompt.md and fixture, NOT from
any run's output — per the eval-case contract's golden-tests-before-
prompts rule): `ravi-sundar`'s person file has `kind_source: stated-by-user`
(`kind: friend`), and the pre-seeded judgment record for him wrongly says
`kind: collaborator`. Per relationship-scoring.md's "Stated kinds are
sticky" rule, a stated kind is never overwritten by a judgment record —
`people/ravi-sundar.md` must be byte-identical to its state before this
run, no matter what the (wrong) judgment record said.
"""

import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CASE_DIR = os.path.dirname(SCRIPT_DIR)
BEFORE_DIR = os.path.join(CASE_DIR, "before")

PERSON_REL = os.path.join("people", "ravi-sundar.md")


def main():
    if len(sys.argv) < 2:
        print("usage: 01-stated-untouched.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    worked_person = os.path.join(worked, PERSON_REL)
    before_person = os.path.join(BEFORE_DIR, PERSON_REL)

    if not os.path.isfile(worked_person):
        print(f"FAIL:\n  - {PERSON_REL}: missing from worked store")
        return 1

    with open(worked_person) as f:
        got = f.read()
    with open(before_person) as f:
        want = f.read()

    if got != want:
        print(
            "FAIL:\n  - "
            f"{PERSON_REL}: byte content changed — a stated-by-user kind "
            "must never be overwritten by a contradicting judgment record"
        )
        return 1

    print(
        f"PASS: {PERSON_REL} is byte-identical to before/ — the "
        "stated-by-user kind was not overwritten by the wrong "
        "'collaborator' judgment record"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
