#!/usr/bin/env python3
"""02-facts-and-commitment.py — T3 grader for 09-debrief-multi-person-chat.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Fact-based, content-word tolerant (prose phrasing may vary across live
runs; the underlying claim must not). Checks the three content facts this
debrief actually carries, per SKILL.md §5a/§5b:

  1. Nadia's promotion is recorded — either the `role` frontmatter field
     was updated to reflect it, or a `## Facts` bullet contains it (the
     skill's frontmatter-update rule is conditional on judgment; either
     placement satisfies the underlying "promotion is on file" fact this
     case pins).
  2. Sam's house-closing is recorded as a `## Facts` bullet on his file.
  3. A commitment about Nadia picking/sending a dinner spot exists,
     somewhere in the interaction's `## Commitments` section or a person
     file's `## Open threads` (SKILL.md files a commitment on the
     interaction; an open-thread cross-reference is also acceptable
     content, same underlying claim).

This grader does not check exact wording -- it checks that the required
content words are present, case-insensitively, so paraphrased-but-correct
output is not penalized.
"""

import os
import re
import sys


def read(path):
    if not os.path.isfile(path):
        return ""
    with open(path) as f:
        return f.read()


def has_words(text, words):
    lowered = text.lower()
    return all(w.lower() in lowered for w in words)


def main():
    if len(sys.argv) < 2:
        print("usage: 02-facts-and-commitment.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    failures = []

    nadia_path = os.path.join(worked, "people", "nadia-okafor.md")
    nadia_text = read(nadia_path)
    if not nadia_text:
        failures.append("people/nadia-okafor.md: file missing from worked store")
    else:
        # Role frontmatter updated, OR a Facts bullet states the promotion.
        # The debrief itself says "Director of Ops"; a filing pass may keep
        # that literal phrasing or expand it to "Director of Operations" --
        # both are correct, so match on the shared "director of op" stem.
        m = re.search(r"^role:\s*(.*)$", nadia_text, re.MULTILINE)
        role_updated = bool(m) and "director of op" in m.group(1).strip().lower()
        facts_section = nadia_text.split("## Facts", 1)[-1].split("## Open threads", 1)[0]
        fact_states_promotion = "director of op" in facts_section.lower()
        if not (role_updated or fact_states_promotion):
            failures.append(
                "people/nadia-okafor.md: promotion to Director of Ops(erations) "
                "not recorded (neither `role` frontmatter nor a ## Facts bullet "
                "mentions it)"
            )

    sam_path = os.path.join(worked, "people", "sam-vartan.md")
    sam_text = read(sam_path)
    if not sam_text:
        failures.append("people/sam-vartan.md: file missing from worked store")
    else:
        facts_section = sam_text.split("## Facts", 1)[-1].split("## Open threads", 1)[0]
        if not (has_words(facts_section, ["hous"]) and has_words(facts_section, ["clos"])):
            failures.append(
                "people/sam-vartan.md: no ## Facts bullet about the house-closing "
                "(expected content mentioning a house and closing on it)"
            )

    interaction_text = read(
        os.path.join(worked, "interactions", "2026-08-29-nadia-okafor.md")
    )
    nadia_open_threads = ""
    if nadia_text:
        nadia_open_threads = nadia_text.split("## Open threads", 1)[-1].split(
            "## Personal details", 1
        )[0]

    commitment_found = (
        has_words(interaction_text, ["dinner"])
        or has_words(nadia_open_threads, ["dinner"])
    )
    if not commitment_found:
        failures.append(
            "no record found of Nadia's dinner-spot commitment (expected a "
            "## Commitments bullet on the interaction, or an ## Open threads "
            "cross-reference on nadia-okafor.md, mentioning dinner)"
        )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        "PASS: Nadia's promotion, Sam's house-closing fact, and the dinner-spot "
        "commitment are all recorded"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
