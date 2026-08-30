#!/usr/bin/env python3
"""01-interaction-and-person-facts.py — T3 grader for 12-debrief-new-person.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Fact-based grading, replacing a full-tree byte-diff (which was too brittle —
whitespace/prose phrasing in `## Summary`/`## Personal details` legitimately
varies run to run). Per SKILL.md's "New-person creation" section and
packages/core/contracts/person.md / interaction.md, this case's expected
outcome (hand-derived from prompt.md, not from any run's output):

- people/priya-nair.md is created with EXACTLY the person-1.0.0 contract's
  key set (no invented fields like `company`, `context`, `context-details`,
  `status`) — schema_version, name, org, role, last-touch always present;
  `tier` is present too: SKILL.md explicitly makes `tier: active` the
  correct judgment call for this exact case (the debrief's own "want to
  keep in touch" enthusiasm), not a blanket default — see the worked
  example in SKILL.md's New-person creation section and this same case's
  golden fixture (tests/goldens/debrief/06-new-unknown-person/expected/
  people/priya-nair.md).
- interactions/2026-08-29-priya-nair.md is created (filename per SKILL.md
  section 5b's `<date>-<primary-person-slug>.md` rule — NEVER the capture
  event's own id, 20260829T101500Z-manual-3a7c).
- Its frontmatter is exact: schema_version 1.0.0, date 2026-08-29,
  people ["[[priya-nair]]"], calendar-event null,
  source-capture 20260829T101500Z-manual-3a7c.
- Both fixed body sections are present, `## Commitments` is exactly `_none_`
  (no explicit promise was stated — "want to keep in touch" is a sentiment,
  not a commitment).
- `## Summary` contains the load-bearing content words from the debrief.
"""

import os
import re
import sys

INTERACTION_REL = "interactions/2026-08-29-priya-nair.md"
WRONG_INTERACTION_REL = "interactions/20260829T101500Z-manual-3a7c.md"
PERSON_REL = "people/priya-nair.md"

EXPECTED_INTERACTION_FM = {
    "schema_version": "1.0.0",
    "date": "2026-08-29",
    "people": '["[[priya-nair]]"]',
    "calendar-event": "null",
    "source-capture": "20260829T101500Z-manual-3a7c",
}

# Full person-1.0.0 contract key set (packages/core/contracts/person.md).
PERSON_CONTRACT_KEYS = {
    "schema_version",
    "name",
    "org",
    "role",
    "location",
    "tags",
    "birthday",
    "how-met",
    "last-touch",
    "tier",
}
REQUIRED_PERSON_FM = {
    "schema_version": "1.0.0",
    "name": "Priya Nair",
    "org": "Lumen Analytics",
    "role": "Product Manager",
    "last-touch": "2026-08-29",
    "tier": "active",
}

REQUIRED_PERSON_SECTIONS = ["## Facts", "## Open threads", "## Personal details"]
REQUIRED_SUMMARY_WORDS = ["Priya", "Lumen Analytics", "Product Manager"]


def split_frontmatter(text):
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}, text
    fm_lines = []
    body_start = None
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            body_start = i + 1
            break
        fm_lines.append(line)
    fm = {}
    for line in fm_lines:
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if m:
            fm[m.group(1)] = m.group(2).strip()
    body = "\n".join(lines[body_start:]) if body_start is not None else ""
    return fm, body


def main():
    if len(sys.argv) < 2:
        print("usage: 01-interaction-and-person-facts.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    failures = []

    wrong_path = os.path.join(worked, WRONG_INTERACTION_REL)
    if os.path.isfile(wrong_path):
        failures.append(
            f"{WRONG_INTERACTION_REL}: interaction filed under the capture "
            f"event's own id instead of the <date>-<slug>.md convention"
        )

    interaction_path = os.path.join(worked, INTERACTION_REL)
    if not os.path.isfile(interaction_path):
        failures.append(f"{INTERACTION_REL}: file missing from worked store")
    else:
        with open(interaction_path) as f:
            fm, body = split_frontmatter(f.read())
        for key, expected in EXPECTED_INTERACTION_FM.items():
            got = fm.get(key)
            if got != expected:
                failures.append(
                    f"{INTERACTION_REL}: frontmatter {key}={got!r}, expected {expected!r}"
                )
        extra_keys = set(fm.keys()) - set(EXPECTED_INTERACTION_FM.keys())
        if extra_keys:
            failures.append(
                f"{INTERACTION_REL}: unexpected frontmatter keys {sorted(extra_keys)} "
                f"— interaction-1.0.0 has no other fields"
            )
        if "## Summary" not in body:
            failures.append(f"{INTERACTION_REL}: missing '## Summary' section")
        else:
            summary = body.split("## Summary", 1)[1]
            summary = summary.split("## Commitments", 1)[0] if "## Commitments" in summary else summary
            missing_words = [w for w in REQUIRED_SUMMARY_WORDS if w not in summary]
            if missing_words:
                failures.append(
                    f"{INTERACTION_REL}: '## Summary' is missing load-bearing "
                    f"content {missing_words}"
                )
        if "## Commitments" not in body:
            failures.append(f"{INTERACTION_REL}: missing '## Commitments' section")
        else:
            commitments = body.split("## Commitments", 1)[1].strip()
            if commitments != "_none_":
                failures.append(
                    f"{INTERACTION_REL}: Commitments={commitments!r}, expected '_none_' "
                    f"— nothing was explicitly promised in this debrief"
                )

    person_path = os.path.join(worked, PERSON_REL)
    if not os.path.isfile(person_path):
        failures.append(f"{PERSON_REL}: file missing from worked store")
    else:
        with open(person_path) as f:
            fm, body = split_frontmatter(f.read())

        invented_keys = set(fm.keys()) - PERSON_CONTRACT_KEYS
        if invented_keys:
            failures.append(
                f"{PERSON_REL}: invented frontmatter keys {sorted(invented_keys)} "
                f"not in the person-1.0.0 contract's key set"
            )

        for key, expected in REQUIRED_PERSON_FM.items():
            got = fm.get(key)
            if got != expected:
                failures.append(
                    f"{PERSON_REL}: frontmatter {key}={got!r}, expected {expected!r}"
                )

        for section in REQUIRED_PERSON_SECTIONS:
            if section not in body:
                failures.append(f"{PERSON_REL}: missing '{section}' section")

        facts_section = ""
        if "## Facts" in body:
            after = body.split("## Facts", 1)[1]
            facts_section = after.split("## Open threads", 1)[0] if "## Open threads" in after else after
        if "**[told-by-user]**" not in facts_section:
            failures.append(
                f"{PERSON_REL}: '## Facts' has no **[told-by-user]** tagged bullet"
            )
        if "lumen analytics" not in facts_section.lower():
            failures.append(
                f"{PERSON_REL}: '## Facts' is missing the org/role fact "
                f"(Product Manager at Lumen Analytics)"
            )
        if "**[inferred-public-web]**" in body:
            failures.append(
                f"{PERSON_REL}: has an **[inferred-public-web]** tag — the "
                f"off-by-default research-seed pass was not requested"
            )

    people_files = sorted(
        f for f in os.listdir(os.path.join(worked, "people")) if f.endswith(".md")
    ) if os.path.isdir(os.path.join(worked, "people")) else []
    if people_files != ["priya-nair.md"]:
        failures.append(
            f"people/: unexpected file set {people_files}, expected only "
            f"['priya-nair.md']"
        )

    interactions_files = sorted(
        f for f in os.listdir(os.path.join(worked, "interactions")) if f.endswith(".md")
    ) if os.path.isdir(os.path.join(worked, "interactions")) else []
    if interactions_files != ["2026-08-29-priya-nair.md"]:
        failures.append(
            f"interactions/: unexpected file set {interactions_files}, expected "
            f"only ['2026-08-29-priya-nair.md']"
        )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        "PASS: people/priya-nair.md created with exact person-1.0.0 "
        "frontmatter key set and interactions/2026-08-29-priya-nair.md "
        "filed with exact interaction-1.0.0 frontmatter/sections"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
