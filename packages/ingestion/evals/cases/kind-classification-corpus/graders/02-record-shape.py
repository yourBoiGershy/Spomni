#!/usr/bin/env python3
"""02-record-shape.py — T3 grader for kind-classification-corpus.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from `packages/core/contracts/relationship-
scoring.md`'s "## Kind vocabulary", "## Judgment record", and "## Rules"
sections, NOT from any run's output — per the eval-case contract's golden-
tests-before-prompts rule). Fact-based shape/rule checks over all 12
records in `data-ingestion/review-judgments/2026-08-29.jsonl`:

  1. `kind` is a member of the fixed 9-value vocabulary.
  2. `kind_note` is non-empty.
  3. `attention_warrant` is an int in [0, 100].
  4. `confidence` is one of low/medium/high.
  5. `rationale` is at most 2 sentences (split on '. ', '! ', '? '), names
     the record's own `kind` value, and cites at least one evidence field
     by name (the fixed vocabulary from relationship-scoring.md's
     "## Evidence inputs").
  6. `kind: scheduling` records carry a non-null `kind_expires`.
  7. Kind caps: scheduling/transactional/unsolicited never suggest above
     `active` (i.e. never `close`/`inner-circle`); `unknown` never
     suggests above `close` (i.e. never `inner-circle`).
  8. Expired-kind rule: any record whose `kind_expires` is a past date
     (before today, 2026-08-29) forces `attention_warrant: 0` and
     `suggested_tier: null` — this fixture's `pip-larkin` already carries
     a past `kind_expires` (2026-08-20) in the pre-seeded evidence/person
     file, so a record that keeps `kind: scheduling` with that same past
     date (or proposes any other past `kind_expires`) must zero the
     warrant and null the tier.
  9. Stated-kind stickiness: `mara-quill` and `ravi-sundar` (both
     `kind_source: stated-by-user` in the fixture, kind already `friend`)
     must have `kind: friend`, byte-identical, in their record.
  10. `wren-halloway` (touchpoints=1, below the insufficient-data gate) has
      no stated kind in the fixture, so its record's `kind` must be
      `unknown` (the gate's mandated consequence when no kind was already
      stated).
"""

import datetime
import json
import os
import re
import sys

KIND_VOCAB = {
    "friend", "family", "collaborator", "professional", "community",
    "scheduling", "transactional", "unsolicited", "unknown",
}
TIER_VOCAB = {"inner-circle", "close", "active", "dormant", None}
CONFIDENCE_VOCAB = {"low", "medium", "high"}
EVIDENCE_FIELDS = [
    "touchpoints", "median_gap_days", "days_since_last", "meetings",
    "chat_days", "emails", "user_initiated_share", "participation",
    "co_attended", "upcoming", "talking_points",
]
LOW_CAP_KINDS = {"scheduling", "transactional", "unsolicited"}  # cap: active
UNKNOWN_CAP = "unknown"  # cap: close
TIER_RANK = {None: -1, "dormant": 0, "active": 1, "close": 2, "inner-circle": 3}
TODAY = datetime.date(2026, 8, 29)
STATED_STICKY = {"mara-quill": "friend", "ravi-sundar": "friend"}


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


def sentence_count(text):
    parts = re.split(r"[.!?]\s+", text.strip())
    parts = [p for p in parts if p.strip()]
    return len(parts)


def parse_date(value):
    if not value or not isinstance(value, str):
        return None
    try:
        return datetime.datetime.strptime(value, "%Y-%m-%d").date()
    except ValueError:
        return None


def main():
    if len(sys.argv) < 2:
        print("usage: 02-record-shape.py <worked-store-dir> [result.json]")
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

    for rec in records:
        slug = rec.get("slug", "<no-slug>")

        kind = rec.get("kind")
        if kind not in KIND_VOCAB:
            failures.append(f"{slug}: kind={kind!r} not in vocabulary {sorted(KIND_VOCAB)}")

        kind_note = rec.get("kind_note")
        if not isinstance(kind_note, str) or not kind_note.strip():
            failures.append(f"{slug}: kind_note is empty or missing")

        warrant = rec.get("attention_warrant")
        if not isinstance(warrant, int) or isinstance(warrant, bool) or not (0 <= warrant <= 100):
            failures.append(f"{slug}: attention_warrant={warrant!r} not an int in [0, 100]")

        confidence = rec.get("confidence")
        if confidence not in CONFIDENCE_VOCAB:
            failures.append(f"{slug}: confidence={confidence!r} not in {sorted(CONFIDENCE_VOCAB)}")

        tier = rec.get("suggested_tier")
        if tier not in TIER_VOCAB:
            failures.append(f"{slug}: suggested_tier={tier!r} not a valid tier or null")

        rationale = rec.get("rationale")
        if not isinstance(rationale, str) or not rationale.strip():
            failures.append(f"{slug}: rationale is empty or missing")
        else:
            if sentence_count(rationale) > 2:
                failures.append(f"{slug}: rationale has more than 2 sentences: {rationale!r}")
            if isinstance(kind, str) and kind not in rationale:
                failures.append(f"{slug}: rationale does not name kind={kind!r}: {rationale!r}")
            if not any(field in rationale for field in EVIDENCE_FIELDS):
                failures.append(
                    f"{slug}: rationale cites no evidence field by name "
                    f"({EVIDENCE_FIELDS}): {rationale!r}"
                )

        kind_expires = rec.get("kind_expires")
        if kind == "scheduling" and not kind_expires:
            failures.append(f"{slug}: kind=scheduling but kind_expires is null/missing")

        if kind in LOW_CAP_KINDS and tier is not None:
            if TIER_RANK.get(tier, 99) > TIER_RANK["active"]:
                failures.append(
                    f"{slug}: kind={kind!r} suggested_tier={tier!r} exceeds the "
                    f"'active' cap"
                )
        if kind == UNKNOWN_CAP and tier is not None:
            if TIER_RANK.get(tier, 99) > TIER_RANK["close"]:
                failures.append(
                    f"{slug}: kind=unknown suggested_tier={tier!r} exceeds the "
                    f"'close' cap"
                )

        expiry_date = parse_date(kind_expires)
        if expiry_date is not None and expiry_date < TODAY:
            if warrant != 0:
                failures.append(
                    f"{slug}: kind_expires={kind_expires} is in the past but "
                    f"attention_warrant={warrant!r} != 0"
                )
            if tier is not None:
                failures.append(
                    f"{slug}: kind_expires={kind_expires} is in the past but "
                    f"suggested_tier={tier!r} != null"
                )

    for slug, expected_kind in STATED_STICKY.items():
        rec = by_slug.get(slug)
        if rec is not None and rec.get("kind") != expected_kind:
            failures.append(
                f"{slug}: stated kind_source=stated-by-user requires "
                f"kind={expected_kind!r}, got {rec.get('kind')!r}"
            )

    wren = by_slug.get("wren-halloway")
    if wren is not None and wren.get("kind") != "unknown":
        failures.append(
            f"wren-halloway: insufficient-data gate (touchpoints=1, no stated "
            f"kind) requires kind='unknown', got {wren.get('kind')!r}"
        )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print("PASS: all records satisfy vocabulary/shape/cap/expiry/sticky-kind rules")
    return 0


if __name__ == "__main__":
    sys.exit(main())
