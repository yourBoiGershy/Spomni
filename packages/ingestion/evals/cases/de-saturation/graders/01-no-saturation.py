#!/usr/bin/env python3
"""01-no-saturation.py — T3 grader for de-saturation.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

The plan-30 regression guard: on 2026-08-29 a live review-tiers Step-3 run
saturated the population to inner-circle (20 of 23 people suggested
inner-circle). This fixture reuses the same 12-person corpus, priors, and
neighbor/cluster files as the sibling `kind-classification-corpus` case
(`./before` is shared — see that case's `expected/README.md`), and its
`neighbors.tsv` is the exact shape that produced the live bug: two
confirmed exemplars sit at the top tiers (`mara-quill` stated `close`,
`ravi-sundar` stated `inner-circle`), and three low-touchpoint members
(`sol-abernathy`, `june-abernathy`, `otto-brandvold`) have those exemplars
as their nearest confirmed neighbor. A judge that lets neighbor similarity
override the evidence-driven rules (rather than treat it as one input
among several, per relationship-scoring.md's "## Priors" — "a prior never
overrides ... any rule") drifts the whole batch toward those two tiers.

Every check below is hand-derived from the fixture and from
`packages/core/contracts/relationship-scoring.md`'s "## Rules" — never
copied from a run's own output (golden-tests-before-prompts, eval-case.md).
Checks over all 12 records in
`data-ingestion/review-judgments/2026-08-29.jsonl`:

  1. Record count: exactly 12 records, one per fixture slug.
  2. Population cap: at most 2 records have `suggested_tier: inner-circle`
     (this fixture confirms exactly 2 people at/above inner-circle-adjacent
     tiers — `mara-quill` close, `ravi-sundar` inner-circle — so a judge
     that reasons from evidence, not neighbor-drift, has no basis to push
     a third person to inner-circle).
  3. Kind caps: no record with `kind` in
     `{scheduling, transactional, unsolicited}` has `suggested_tier` in
     `{inner-circle, close}` (relationship-scoring.md's kind-cap rule: those
     kinds never suggest above `active`).
  4. No `kind: unknown` record has `suggested_tier: inner-circle`
     (relationship-scoring.md's kind-cap rule: `unknown` never suggests
     above `close`).
  5. `pip-larkin`: the fixture's pre-seeded evidence carries
     `kind_expires: 2026-08-20`, already in the past relative to today
     (2026-08-29) — the expired-kind rule forces `attention_warrant: 0` and
     `suggested_tier: null` regardless of the neighbor line or any kind the
     judge proposes.
  6. `wren-halloway`: `touchpoints=1 < 2` — the insufficient-data gate
     forces `suggested_tier: null` (same gate the sibling case's
     `02-record-shape.py` checks).
  7. Spread: at least 3 distinct `suggested_tier` values appear across the
     non-null records — a real de-saturation guard, not merely a
     "different single tier" regression (e.g. everything collapsed to
     `active` would still fail this).
"""

import json
import os
import sys

EXPECTED_SLUGS = {
    "bram-fiske", "dex-morrow", "hal-torrance", "ines-castellano",
    "june-abernathy", "mara-quill", "nell-ashby", "otto-brandvold",
    "pip-larkin", "ravi-sundar", "sol-abernathy", "wren-halloway",
}
LOW_CAP_KINDS = {"scheduling", "transactional", "unsolicited"}
TOP_TIERS = {"inner-circle", "close"}


def load_records(path):
    records = []
    with open(path) as f:
        for lineno, line in enumerate(f, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError as e:
                raise SystemExit(f"line {lineno}: invalid JSON: {e}")
    return records


def main():
    if len(sys.argv) < 2:
        print("usage: 01-no-saturation.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    jsonl_path = os.path.join(
        worked, "data-ingestion", "review-judgments", "2026-08-29.jsonl"
    )
    failures = []

    if not os.path.isfile(jsonl_path):
        print(f"FAIL:\n  - {jsonl_path} does not exist")
        return 1

    try:
        records = load_records(jsonl_path)
    except SystemExit as e:
        print(f"FAIL:\n  - {e}")
        return 1

    by_slug = {}
    for rec in records:
        slug = rec.get("slug")
        if slug:
            by_slug[slug] = rec

    got_slugs = set(by_slug.keys())
    if len(records) != 12 or got_slugs != EXPECTED_SLUGS:
        missing = EXPECTED_SLUGS - got_slugs
        extra = got_slugs - EXPECTED_SLUGS
        failures.append(
            f"expected exactly 12 records for {sorted(EXPECTED_SLUGS)}, "
            f"got {len(records)} records for {sorted(got_slugs)} "
            f"(missing={sorted(missing)}, extra={sorted(extra)})"
        )

    inner_circle_slugs = [
        slug for slug, rec in by_slug.items()
        if rec.get("suggested_tier") == "inner-circle"
    ]
    if len(inner_circle_slugs) > 2:
        failures.append(
            f"population saturation: {len(inner_circle_slugs)} records "
            f"suggested_tier=inner-circle (max 2 expected — "
            f"{sorted(inner_circle_slugs)})"
        )

    for slug, rec in by_slug.items():
        kind = rec.get("kind")
        tier = rec.get("suggested_tier")
        if kind in LOW_CAP_KINDS and tier in TOP_TIERS:
            failures.append(
                f"{slug}: kind={kind!r} suggested_tier={tier!r} exceeds the "
                f"'active' kind cap"
            )
        if kind == "unknown" and tier == "inner-circle":
            failures.append(
                f"{slug}: kind=unknown suggested_tier=inner-circle exceeds "
                f"the 'close' kind cap"
            )

    pip = by_slug.get("pip-larkin")
    if pip is not None:
        if pip.get("attention_warrant") != 0:
            failures.append(
                f"pip-larkin: kind_expires 2026-08-20 is in the past but "
                f"attention_warrant={pip.get('attention_warrant')!r} != 0"
            )
        if pip.get("suggested_tier") is not None:
            failures.append(
                f"pip-larkin: kind_expires 2026-08-20 is in the past but "
                f"suggested_tier={pip.get('suggested_tier')!r} != null"
            )

    wren = by_slug.get("wren-halloway")
    if wren is not None and wren.get("suggested_tier") is not None:
        failures.append(
            f"wren-halloway: touchpoints=1 < 2 insufficient-data gate "
            f"requires suggested_tier=null, got "
            f"{wren.get('suggested_tier')!r}"
        )

    non_null_tiers = {
        rec.get("suggested_tier") for rec in records
        if rec.get("suggested_tier") is not None
    }
    if len(non_null_tiers) < 3:
        failures.append(
            f"insufficient tier spread: only {sorted(non_null_tiers)} "
            f"distinct non-null suggested_tier values appear (need >= 3) — "
            f"population may have collapsed to a single tier"
        )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print("PASS: population does not saturate to inner-circle")
    return 0


if __name__ == "__main__":
    sys.exit(main())
