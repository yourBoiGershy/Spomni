#!/usr/bin/env python3
"""01-kind-sets.py — T3 grader for kind-classification-corpus.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from this case's fixture and prompt.md, NOT from
any run's output — per the eval-case contract's golden-tests-before-
prompts rule). Grading is by ACCEPTABLE SET, not exact value, because kind
classification is model judgment, not a deterministic function — a
reasonable judge can land on more than one defensible kind for several of
these people; what would be a bug is landing outside the whole set of
defensible reads, or breaking a sticky/insufficient-data rule. Per-slug
reasoning (from `before/people/<slug>.md`, `before/data-ingestion/
evidence.jsonl`, `before/data-ingestion/neighbors.tsv`):

  - pip-larkin: touchpoints=10, `kind: scheduling` already derived,
    `kind_expires: 2026-08-20` already stored — the Aug 18 venue handoff
    that already happened before "today" (2026-08-29). A judge may keep
    `scheduling` (an expired scheduling contact) or reclassify to
    `transactional` now the logistics are done and closed. Never a
    relationship kind (friend/collaborator/etc) — nothing in the fixture
    supports one.
  - dex-morrow: touchpoints=3, cold pitch emails, zero replies
    ("Keeps sending pitch emails without a reply from me") — textbook
    `unsolicited`; `unknown` is defensible too (thin, one-sided contact)
    but never a warm relationship kind.
  - mara-quill: `kind_source: stated-by-user`, kind already `friend` —
    sticky rule requires the record's kind to equal `friend`, verbatim,
    no exceptions.
  - ravi-sundar: same sticky rule, kind already `friend`.
  - ines-castellano: touchpoints=8, meetings=3, co_attended=1, upcoming
    sync, `kind: collaborator` already derived, weekly launch-plan syncs —
    `collaborator` (keep) or `professional` (still work-only, no personal
    content) are both defensible; never a personal-relationship kind.
  - bram-fiske: touchpoints=2 (at the gate boundary, not below it),
    accountant, `kind: transactional` already derived ("billing and
    filings only") — `transactional` (keep) or `professional` (a
    professional-services relationship) are both defensible.
  - hal-torrance: touchpoints=2, `kind: professional` already derived,
    low-frequency former-client check-ins — `professional` (keep),
    `collaborator` (a stretch, given "occasional check-ins" is thin
    engagement), or `unknown` (evidence this thin could reasonably decline
    to commit) are all defensible.
  - wren-halloway: touchpoints=1, below the insufficient-data gate
    (`touchpoints < 2`) — `suggested_tier` must be `null` per the gate
    rule; no stated kind exists so `kind` must be `unknown`. Checked here
    on `suggested_tier` since that's the rule-mandated field; `02-record-
    shape.py` separately checks the gate's `kind: unknown` consequence.
"""

import json
import os
import sys

EXPECTED_SLUGS = {
    "bram-fiske", "dex-morrow", "hal-torrance", "ines-castellano",
    "june-abernathy", "mara-quill", "nell-ashby", "otto-brandvold",
    "pip-larkin", "ravi-sundar", "sol-abernathy", "wren-halloway",
}

KIND_SET_CHECKS = {
    "pip-larkin": {"scheduling", "transactional"},
    "dex-morrow": {"unsolicited", "unknown"},
    "mara-quill": {"friend"},
    "ravi-sundar": {"friend"},
    "ines-castellano": {"collaborator", "professional"},
    "bram-fiske": {"transactional", "professional"},
    "hal-torrance": {"professional", "collaborator", "unknown"},
}


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
        print("usage: 01-kind-sets.py <worked-store-dir> [result.json]")
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

    missing = EXPECTED_SLUGS - set(by_slug)
    extra = set(by_slug) - EXPECTED_SLUGS
    if missing:
        failures.append(f"missing records for: {sorted(missing)}")
    if extra:
        failures.append(f"unexpected records for: {sorted(extra)}")

    for slug, acceptable in KIND_SET_CHECKS.items():
        rec = by_slug.get(slug)
        if rec is None:
            continue
        kind = rec.get("kind")
        if kind not in acceptable:
            failures.append(
                f"{slug}: kind={kind!r} not in acceptable set {sorted(acceptable)}"
            )

    wren = by_slug.get("wren-halloway")
    if wren is not None:
        tier = wren.get("suggested_tier")
        if tier is not None:
            failures.append(
                f"wren-halloway: suggested_tier={tier!r} — must be null "
                f"(touchpoints=1 < 2, insufficient-data gate)"
            )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print("PASS: all 12 kind-classification records land within their acceptable sets")
    return 0


if __name__ == "__main__":
    sys.exit(main())
