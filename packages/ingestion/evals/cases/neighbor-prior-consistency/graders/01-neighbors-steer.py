#!/usr/bin/env python3
"""01-neighbors-steer.py — T3 grader for neighbor-prior-consistency.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from this case's prompt.md and fixture, NOT from
any run's output — per the eval-case contract's golden-tests-before-
prompts rule): `sol-abernathy` and `june-abernathy` are unkinded members of
`mara-quill`'s confirmed exemplar cluster (`friend`/`close`,
`kind_source: stated-by-user`), and `before/data-ingestion/neighbors.tsv`
gives both of them `mara-quill` as their sole confirmed neighbor
(similarity 0.93 / 0.90). Per `relationship-scoring.md`'s `## Priors`
("neighbor priors... e.g. 'most similar confirmed people: [[dana]]
(friend, close)'") the judgment should be steered by that neighbor toward
a `friend`- or `family`-shaped kind, and the derived-kind write (Step 3 of
`review-tiers/SKILL.md`) should land for both of them, since neither has
`kind_source: stated-by-user`. The prompt also requires the judgment
record's additive `neighbors` field to name `mara-quill` for exactly these
two people (input 3d of the judgment prompt contract), the one
observable, checkable trace that the neighbor prior was actually
consulted.

Fact-based only: frontmatter-field checks and JSONL-field text checks,
never prose-diffing.
"""

import json
import os
import sys

ALLOWED_KINDS = {"friend", "family"}
TARGETS = ["sol-abernathy", "june-abernathy"]


def read_frontmatter(text):
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return {}
    fm = {}
    for line in lines[1:]:
        if line.strip() == "---":
            break
        if ":" in line:
            k, _, v = line.partition(":")
            fm[k.strip()] = v.strip()
    return fm


def main():
    if len(sys.argv) < 2:
        print("usage: 01-neighbors-steer.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    failures = []

    # 1. Person-file kind writes: derived, kind in {friend, family}.
    for slug in TARGETS:
        path = os.path.join(worked, "people", f"{slug}.md")
        if not os.path.isfile(path):
            failures.append(f"people/{slug}.md: missing from worked store")
            continue
        with open(path) as f:
            fm = read_frontmatter(f.read())
        if fm.get("kind_source") != "derived":
            failures.append(
                f"people/{slug}.md: kind_source={fm.get('kind_source')!r}, "
                f"expected 'derived'"
            )
        if fm.get("kind") not in ALLOWED_KINDS:
            failures.append(
                f"people/{slug}.md: kind={fm.get('kind')!r}, expected one "
                f"of {sorted(ALLOWED_KINDS)} (steered by the mara-quill "
                f"neighbor prior)"
            )

    # 2. Judgment records: neighbors field mentions mara-quill for both.
    jsonl_path = os.path.join(
        worked, "data-ingestion", "review-judgments", "2026-08-29.jsonl"
    )
    records = {}
    if not os.path.isfile(jsonl_path):
        failures.append(f"{jsonl_path}: missing")
    else:
        with open(jsonl_path) as f:
            for lineno, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError as e:
                    failures.append(f"review-judgments line {lineno}: not valid JSON ({e})")
                    continue
                slug = rec.get("slug")
                if slug:
                    records[slug] = rec

        for slug in TARGETS:
            rec = records.get(slug)
            if rec is None:
                failures.append(f"review-judgments/2026-08-29.jsonl: no record for {slug!r}")
                continue
            neighbors = str(rec.get("neighbors", ""))
            if "mara-quill" not in neighbors:
                failures.append(
                    f"{slug}'s judgment record neighbors={neighbors!r} does "
                    f"not mention 'mara-quill' — the neighbor prior was not "
                    f"consulted"
                )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        "PASS: sol-abernathy and june-abernathy were judged derived "
        "friend/family, steered by their confirmed mara-quill neighbor"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
