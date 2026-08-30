#!/usr/bin/env python3
"""01-pairwise-order.py — T3 grader for warrant-ordering.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from this case's shared fixture — `before/` of
the sibling `kind-classification-corpus` case — and `prompt.md`, NOT from
any run's own output, per the eval-case contract's golden-tests-before-
prompts rule). This grader checks pairwise `attention_warrant` ORDERINGS,
not exact values, because the exact integer a judge lands on is model
judgment; what is fixture-mandated is the relative ranking that follows
from kind, evidence, and the user model's axis weights. Per-pair
reasoning (from `before/people/<slug>.md`, `before/data-ingestion/
evidence.jsonl`, `before/user-model.md`, `before/data-ingestion/
ranking-weights.json`):

  - mara-quill > pip-larkin: mara-quill is a stated (sticky) `friend`,
    touchpoints=7, meetings=7, a standing monthly dinner, protected under
    the confirmed user-model's `friends: 0.70` axis (explicitly called out
    as "protected time" in `before/user-model.md`) and `kinds.friend`
    carries a 1.3 emphasis prior — a clearly warm, active relationship.
    pip-larkin already carries `kind_expires: 2026-08-20`, which is in the
    past relative to "today" (2026-08-29) — `relationship-scoring.md`'s
    expired-kind rule forces `attention_warrant: 0` for pip-larkin
    regardless of which kind the judge assigns this pass. mara-quill's
    warrant, non-zero on any reasonable read of this evidence, must exceed
    pip-larkin's rule-forced 0.

  - pip-larkin == 0: pip-larkin's already-stored `kind_expires`
    (2026-08-20) is in the past relative to "today" (2026-08-29) —
    `relationship-scoring.md`'s expired-kind rule is unconditional
    ("a `kind_expires` in the past forces `attention_warrant: 0`... this
    applies whether the expired `kind_expires` is the person's
    already-stored value... or one this judgment pass itself would
    otherwise propose") — so this is an exact-value check, not an
    ordering, the one field in this fixture that is fully rule-bound
    rather than model judgment.

  - dex-morrow <= 25: dex-morrow is a cold, one-sided contact — touchpoints=3,
    three unanswered pitch emails, `user_initiated_share=0`. Not gated
    (touchpoints >= 2) and not expired, so it isn't rule-forced to any
    specific value, but `unsolicited` is kind-capped at `active` and
    carries a 0.5 de-emphasis prior in `ranking-weights.json`'s `kinds`
    block — an unanswered pitch with zero reciprocity has no plausible
    reading that lands it anywhere near "warrants real attention now".
    25 is a generous ceiling for a purely one-sided, capped-kind contact.

  - ravi-sundar > pip-larkin: ravi-sundar is the other stated (sticky)
    `friend`, touchpoints=11 (the highest in the corpus), meetings=2,
    chat_days=6, near-weekly book-recommendation trades, tier already
    `inner-circle` — clearly non-zero warrant. pip-larkin is rule-forced
    to 0 (see above). ravi-sundar's warrant must exceed it.

  - ines-castellano > bram-fiske: ines-castellano, touchpoints=8,
    meetings=3, co_attended=1, an upcoming 2026-09-03 sync, `kind:
    collaborator` (already derived, `kinds.collaborator` carries a 1.2
    emphasis prior) — an active, engaged, ongoing collaboration.
    bram-fiske, touchpoints=2 (at, not below, the insufficient-data gate),
    median_gap_days=93, days_since_last=23, `kind: transactional`
    (billing/filings only, no emphasis or de-emphasis prior on
    `transactional` in `ranking-weights.json`, so it floats at the 1.0
    default) — sparse, low-engagement, arm's-length contact. ines
    outranks bram on every evidence axis this fixture provides.

  - mara-quill > hal-torrance: mara-quill, see above — warm, active,
    protected-axis stated friend. hal-torrance, touchpoints=2 (at the
    gate boundary), days_since_last=41, `kind: professional`, "occasional
    check-ins" — low-frequency, thin, work-only contact with no emphasis
    prior. mara-quill's warrant must exceed hal-torrance's.

See `expected/README.md`'s "Why pip-larkin is graded as 0" note for the
full reasoning behind replacing the originally-proposed
`pip-larkin > dex-morrow` ordering leg with these two rule-consistent
checks (an exact-value check for pip-larkin, a ceiling check for
dex-morrow) — the ordering leg was a mistake in the case's original brief
(expired scheduling always warrants 0 by rule, regardless of what the
judge ranks a cold pitch at).
"""

import json
import os
import sys

PAIRS = [
    ("mara-quill", "pip-larkin"),
    ("ravi-sundar", "pip-larkin"),
    ("ines-castellano", "bram-fiske"),
    ("mara-quill", "hal-torrance"),
]

EXACT_CHECKS = [
    ("pip-larkin", 0),
]

CEILING_CHECKS = [
    ("dex-morrow", 25),
]


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
        print("usage: 01-pairwise-order.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    jsonl_path = os.path.join(
        worked, "data-ingestion", "review-judgments", "2026-08-29.jsonl"
    )

    if not os.path.isfile(jsonl_path):
        print(f"FAIL:\n  - {jsonl_path} does not exist")
        return 1

    try:
        records = load_records(jsonl_path)
    except SystemExit as e:
        print(f"FAIL:\n  - {e}")
        return 1

    failures = []

    if len(records) != 12:
        failures.append(f"expected 12 records, found {len(records)}")

    by_slug = {}
    for i, rec in enumerate(records):
        slug = rec.get("slug")
        if not slug:
            failures.append(f"record {i}: missing 'slug' field")
            continue
        if slug in by_slug:
            failures.append(f"duplicate record for slug '{slug}'")
        by_slug[slug] = rec

    overall_ok = True
    for higher, lower in PAIRS:
        rec_higher = by_slug.get(higher)
        rec_lower = by_slug.get(lower)
        if rec_higher is None or rec_lower is None:
            missing = [s for s, r in ((higher, rec_higher), (lower, rec_lower)) if r is None]
            print(f"FAIL: {higher} > {lower} — missing record(s) for {missing}")
            failures.append(f"{higher} > {lower}: missing record(s) for {missing}")
            overall_ok = False
            continue

        w_higher = rec_higher.get("attention_warrant")
        w_lower = rec_lower.get("attention_warrant")

        if not isinstance(w_higher, int) or not isinstance(w_lower, int):
            print(
                f"FAIL: {higher} > {lower} — non-integer attention_warrant "
                f"({higher}={w_higher!r}, {lower}={w_lower!r})"
            )
            failures.append(
                f"{higher} > {lower}: non-integer attention_warrant "
                f"({higher}={w_higher!r}, {lower}={w_lower!r})"
            )
            overall_ok = False
            continue

        if w_higher > w_lower:
            print(f"PASS: {higher} ({w_higher}) > {lower} ({w_lower})")
        else:
            print(f"FAIL: {higher} ({w_higher}) > {lower} ({w_lower}) — ordering violated")
            failures.append(
                f"{higher} > {lower}: attention_warrant {w_higher} <= {w_lower}"
            )
            overall_ok = False

    for slug, expected in EXACT_CHECKS:
        rec = by_slug.get(slug)
        if rec is None:
            print(f"FAIL: {slug} == {expected} — missing record")
            failures.append(f"{slug} == {expected}: missing record")
            overall_ok = False
            continue
        w = rec.get("attention_warrant")
        if w == expected:
            print(f"PASS: {slug} attention_warrant == {expected}")
        else:
            print(f"FAIL: {slug} attention_warrant = {w!r}, expected exactly {expected}")
            failures.append(
                f"{slug}: attention_warrant {w!r} != {expected} "
                f"(expired-kind rule requires exactly {expected})"
            )
            overall_ok = False

    for slug, ceiling in CEILING_CHECKS:
        rec = by_slug.get(slug)
        if rec is None:
            print(f"FAIL: {slug} <= {ceiling} — missing record")
            failures.append(f"{slug} <= {ceiling}: missing record")
            overall_ok = False
            continue
        w = rec.get("attention_warrant")
        if not isinstance(w, int):
            print(f"FAIL: {slug} attention_warrant = {w!r} — not an integer")
            failures.append(f"{slug}: attention_warrant {w!r} is not an integer")
            overall_ok = False
            continue
        if w <= ceiling:
            print(f"PASS: {slug} attention_warrant ({w}) <= {ceiling}")
        else:
            print(f"FAIL: {slug} attention_warrant ({w}) > {ceiling}")
            failures.append(f"{slug}: attention_warrant {w} > ceiling {ceiling}")
            overall_ok = False

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    if not overall_ok:
        return 1

    print("PASS: all pairwise warrant orderings and rule-bound checks hold")
    return 0


if __name__ == "__main__":
    sys.exit(main())
