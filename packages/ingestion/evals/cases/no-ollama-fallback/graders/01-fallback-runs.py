#!/usr/bin/env python3
"""01-fallback-runs.py — T3 grader for no-ollama-fallback.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from this case's prompt.md and fixture, NOT from
any run's output — per the eval-case contract's golden-tests-before-
prompts rule): `before/data-ingestion/run.log` records `embeddings:
unavailable` and there is deliberately no `neighbors.tsv`/`clusters.tsv` in
this fixture. Per `review-tiers/SKILL.md`'s "Both Ollama modes" section,
the flow must still run to completion: all 5 people (bram-fiske,
hal-torrance, june-abernathy, mara-quill, sol-abernathy) get a judgment
record, every record's neighbor input is the literal `neighbors: none
(embeddings unavailable)` line (never an invented neighbor, never another
slug), and the derived-kind write still happens for the two unkinded
people (sol-abernathy, june-abernathy — the same as the
neighbor-prior-consistency sibling case, just without a neighbor prior
available to steer it). sol-abernathy and june-abernathy's kind values are
looser here (no neighbor prior to narrow them) — checked against the
plausible-kind sets a reasonable judge could reach purely from each
person's own evidence/facts, not narrowed to {friend, family} the way the
sibling case's neighbor-steered grader is.

Fact-based only: file-existence, JSONL-field, and frontmatter-field
checks, never prose-diffing.
"""

import json
import os
import sys

ALL_SLUGS = {"bram-fiske", "hal-torrance", "june-abernathy", "mara-quill", "sol-abernathy"}
FALLBACK_NEIGHBORS = "none (embeddings unavailable)"
SOL_ALLOWED_KINDS = {"friend", "unknown", "community", "professional"}
JUNE_ALLOWED_KINDS = {"family", "friend", "unknown"}
UNKINDED_TARGETS = ["sol-abernathy", "june-abernathy"]
OTHER_SLUGS = ALL_SLUGS - {"mara-quill"}  # slugs that must never appear as a "neighbor"


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
        print("usage: 01-fallback-runs.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    failures = []

    jsonl_path = os.path.join(
        worked, "data-ingestion", "review-judgments", "2026-08-29.jsonl"
    )
    records = {}
    if not os.path.isfile(jsonl_path):
        print(f"FAIL:\n  - {jsonl_path}: missing")
        return 1

    with open(jsonl_path) as f:
        raw_lines = [line.strip() for line in f if line.strip()]

    if len(raw_lines) != 5:
        failures.append(
            f"review-judgments/2026-08-29.jsonl has {len(raw_lines)} records, "
            f"expected exactly 5 (one per person, the flow never stalls when "
            f"embeddings are unavailable)"
        )

    for lineno, line in enumerate(raw_lines, 1):
        try:
            rec = json.loads(line)
        except json.JSONDecodeError as e:
            failures.append(f"review-judgments line {lineno}: not valid JSON ({e})")
            continue
        slug = rec.get("slug")
        if slug:
            records[slug] = rec

        neighbors = str(rec.get("neighbors", ""))
        if neighbors != FALLBACK_NEIGHBORS:
            failures.append(
                f"{slug or f'line {lineno}'}: neighbors={neighbors!r}, "
                f"expected exactly {FALLBACK_NEIGHBORS!r}"
            )
        # No record's text may mention another slug as a neighbor.
        for other in OTHER_SLUGS:
            if other == slug:
                continue
            if other in neighbors:
                failures.append(
                    f"{slug or f'line {lineno}'}: neighbors field mentions "
                    f"{other!r} — no neighbor should be named when "
                    f"embeddings are unavailable"
                )

    for slug in ALL_SLUGS:
        if slug not in records:
            failures.append(f"review-judgments/2026-08-29.jsonl: no record for {slug!r}")

    mara_rec = records.get("mara-quill")
    if mara_rec is not None and mara_rec.get("kind") != "friend":
        failures.append(
            f"mara-quill's judgment record kind={mara_rec.get('kind')!r}, "
            f"expected 'friend' (stated kinds are sticky)"
        )

    sol_rec = records.get("sol-abernathy")
    if sol_rec is not None and sol_rec.get("kind") not in SOL_ALLOWED_KINDS:
        failures.append(
            f"sol-abernathy's judgment record kind={sol_rec.get('kind')!r}, "
            f"expected one of {sorted(SOL_ALLOWED_KINDS)}"
        )

    june_rec = records.get("june-abernathy")
    if june_rec is not None and june_rec.get("kind") not in JUNE_ALLOWED_KINDS:
        failures.append(
            f"june-abernathy's judgment record kind={june_rec.get('kind')!r}, "
            f"expected one of {sorted(JUNE_ALLOWED_KINDS)}"
        )

    # Derived kind writes still happened for the two unkinded people.
    for slug in UNKINDED_TARGETS:
        path = os.path.join(worked, "people", f"{slug}.md")
        if not os.path.isfile(path):
            failures.append(f"people/{slug}.md: missing from worked store")
            continue
        with open(path) as f:
            fm = read_frontmatter(f.read())
        if fm.get("kind_source") != "derived":
            failures.append(
                f"people/{slug}.md: kind_source={fm.get('kind_source')!r}, "
                f"expected 'derived' — the flow must still write kinds "
                f"without embeddings"
            )
        if not fm.get("kind"):
            failures.append(f"people/{slug}.md: no kind field written")

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        "PASS: the flow ran identically with embeddings unavailable — 5 "
        "judgment records, every neighbors field the literal fallback "
        "string, derived kind writes still landed"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
