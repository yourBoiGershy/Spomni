#!/usr/bin/env python3
"""01-propagation.py — T3 grader for user-model-propagation.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from `packages/core/contracts/user-model.md`'s
"## Lifecycle" note — "scores are expected to change when this file
changes; that is the point" — and `packages/core/contracts/
relationship-scoring.md`'s "## Priors" section, NOT from any run's output —
per the eval-case contract's golden-tests-before-prompts rule): raising the
confirmed user model's `friends` axis weight from 0.30 (`before/
user-model.md`, revision 1) to 0.80 (`before/user-model.rev2.md`,
revision 2) — with the corpus, evidence, neighbors, and
`ranking-weights.json` priors held byte-identical between the two runs —
should raise `attention_warrant` for personal-relationship kinds
(`friend`, `family`) and leave every other kind roughly where it was. This
is a propagation check, not a re-classification check: it grades the
*shift* between the two files the run itself produces, not a fixed
per-slug target value (there is no fixed target to hand-derive here, since
which slug lands on which kind is itself model judgment — see
`kind-classification-corpus`'s README for why kind is set-graded, not
exact-value graded).

The rule this grader enforces, symmetrically for every slug present in
BOTH files:

  - if rev1's kind is `friend` or `family`: rev2's warrant must be >= rev1's
    (never allowed to drop), and at least ONE such slug across the whole
    batch must rise by >= 5 points (the propagation actually has to show up
    somewhere, not just "never decrease" by coincidence).
  - if rev1's kind is anything else: rev2's warrant must stay within a
    noise band of +/-5 points of rev1's warrant (judgment is
    non-deterministic; without an applicable prior, small drift is
    expected and tolerated, but a wholesale reshuffle is not). The
    fixture's `pip-larkin` is expired (`kind_expires: 2026-08-20`, already
    past "today" 2026-08-29) and the expired-kind rule forces
    `attention_warrant: 0` regardless of any prior — this grader requires
    it to be exactly 0 in BOTH files, which is also consistent with the
    noise-band check (0 - 0 = 0).

Also checked: both files exist, 12 records each, matching the fixture's 12
slugs, and every record's `user_model_revision` field is `1` in the rev1
file and `2` in the rev2 file.
"""

import json
import os
import sys

EXPECTED_SLUGS = {
    "bram-fiske", "dex-morrow", "hal-torrance", "ines-castellano",
    "june-abernathy", "mara-quill", "nell-ashby", "otto-brandvold",
    "pip-larkin", "ravi-sundar", "sol-abernathy", "wren-halloway",
}

PERSONAL_KINDS = {"friend", "family"}
NOISE_BAND = 5


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
                raise SystemExit(f"{path}:{lineno}: invalid JSON: {e}")
    return records


def by_slug(records):
    out = {}
    for rec in records:
        slug = rec.get("slug")
        if slug:
            out[slug] = rec
    return out


def check_file_shape(path, records, failures, expected_revision):
    if len(records) != 12:
        failures.append(f"{path}: expected 12 records, found {len(records)}")

    seen = {}
    for i, rec in enumerate(records):
        slug = rec.get("slug")
        if not slug:
            failures.append(f"{path}: record {i}: missing 'slug' field")
            continue
        if slug in seen:
            failures.append(f"{path}: duplicate record for slug '{slug}'")
        seen[slug] = rec

    missing = EXPECTED_SLUGS - set(seen)
    extra = set(seen) - EXPECTED_SLUGS
    if missing:
        failures.append(f"{path}: missing records for: {sorted(missing)}")
    if extra:
        failures.append(f"{path}: unexpected records for: {sorted(extra)}")

    for slug, rec in seen.items():
        rev = rec.get("user_model_revision")
        if rev != expected_revision:
            failures.append(
                f"{path}: {slug}: user_model_revision={rev!r}, "
                f"expected {expected_revision!r}"
            )


def main():
    if len(sys.argv) < 2:
        print("usage: 01-propagation.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    judgments_dir = os.path.join(worked, "data-ingestion", "review-judgments")
    rev1_path = os.path.join(judgments_dir, "2026-08-29-rev1.jsonl")
    rev2_path = os.path.join(judgments_dir, "2026-08-29-rev2.jsonl")

    failures = []

    for path in (rev1_path, rev2_path):
        if not os.path.isfile(path):
            failures.append(f"{path} does not exist")

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    try:
        rev1_records = load_records(rev1_path)
        rev2_records = load_records(rev2_path)
    except SystemExit as e:
        print(f"FAIL:\n  - {e}")
        return 1

    check_file_shape(rev1_path, rev1_records, failures, 1)
    check_file_shape(rev2_path, rev2_records, failures, 2)

    rev1_by_slug = by_slug(rev1_records)
    rev2_by_slug = by_slug(rev2_records)

    common_slugs = set(rev1_by_slug) & set(rev2_by_slug)

    any_personal_rise = False
    for slug in sorted(common_slugs):
        r1 = rev1_by_slug[slug]
        r2 = rev2_by_slug[slug]

        w1 = r1.get("attention_warrant")
        w2 = r2.get("attention_warrant")
        if not isinstance(w1, int) or isinstance(w1, bool):
            failures.append(f"{slug}: rev1 attention_warrant={w1!r} not an int")
            continue
        if not isinstance(w2, int) or isinstance(w2, bool):
            failures.append(f"{slug}: rev2 attention_warrant={w2!r} not an int")
            continue

        kind1 = r1.get("kind")

        if kind1 in PERSONAL_KINDS:
            if w2 < w1:
                failures.append(
                    f"{slug}: kind={kind1!r} in rev1, but rev2 warrant "
                    f"{w2} < rev1 warrant {w1} (friends axis rose "
                    f"0.30 -> 0.80; personal-kind warrant must not drop)"
                )
            if w2 - w1 >= NOISE_BAND:
                any_personal_rise = True
        else:
            if abs(w2 - w1) > NOISE_BAND:
                failures.append(
                    f"{slug}: kind={kind1!r} (not friend/family) in rev1, "
                    f"but warrant moved {w1} -> {w2} "
                    f"(|delta|={abs(w2 - w1)} > noise band {NOISE_BAND})"
                )

    # pip-larkin: kind_expires 2026-08-20 is already past "today" 2026-08-29
    # in the pre-seeded fixture (see relationship-scoring.md's expired-kind
    # rule) — attention_warrant must be exactly 0 in BOTH files, no prior
    # (including a raised friends axis) overrides an expired kind.
    for label, rec_map, path in (
        ("rev1", rev1_by_slug, rev1_path), ("rev2", rev2_by_slug, rev2_path)
    ):
        pip = rec_map.get("pip-larkin")
        if pip is not None and pip.get("attention_warrant") != 0:
            failures.append(
                f"pip-larkin: {label} attention_warrant="
                f"{pip.get('attention_warrant')!r}, expected 0 "
                f"(kind_expires 2026-08-20 already past today 2026-08-29 "
                f"— expired-kind rule)"
            )

    if not any_personal_rise:
        personal_slugs = sorted(
            s for s in common_slugs if rev1_by_slug[s].get("kind") in PERSONAL_KINDS
        )
        failures.append(
            f"no friend/family slug rose by >= {NOISE_BAND} points from "
            f"rev1 to rev2 (personal-kind slugs found: {personal_slugs}) — "
            f"the friends-axis propagation must actually show up somewhere"
        )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        "PASS: friend/family warrants rose (>=1 by >=5pts) from rev1 to "
        "rev2, non-personal kinds stayed within the noise band, and "
        "user_model_revision tags match each file"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
