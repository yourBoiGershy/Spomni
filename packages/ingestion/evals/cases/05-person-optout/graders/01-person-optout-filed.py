#!/usr/bin/env python3
"""01-person-optout-filed.py -- T3 grader for 05-person-optout.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from this case's prompt.md and
packages/ingestion/specs/stated-preference-filing.md section (b) rule 3,
NOT from any run's output -- per the eval-case contract's
golden-tests-before-prompts rule): "No birthday reminders for Ben" names a
person, so it is a person-scoped signal opt-out, which lands as exactly one
appended `**[stated-by-user]**` bullet in `profile.md`'s `## Signal
opt-outs` section, grammar `<signal-type> -- [[<slug>]]`, signal-type
`birthday`, resolved slug `ben-whitmore`, dated `(2026-08-29)`. Per rule 5,
the opt-out is never encoded as a `person.md` edit, so
`people/ben-whitmore.md` must be byte-identical to `before/`.

Like 02-global-optout's grammar, (b)'s opt-out grammar is deterministic --
no "lightly cleaned up" latitude -- so this grader pins the bullet close to
exact while tolerating the one axis a live model run can vary on
harmlessly: an em dash vs. a plain hyphen as the "--" separator. It also
asserts the other three profile.md sections and person file are untouched,
and that no other file in the store was created, deleted, or modified.
"""

import filecmp
import os
import re
import sys

SECTION_ORDER = ["Priorities", "Cadence wishes", "Signal opt-outs", "Style notes"]

# Accept either an em dash or a plain hyphen/double-hyphen as the separator.
# Explicitly reject a code-span-wrapped bullet (backtick-wrapped content) --
# the spec's grammar is prose with an inline [[wiki-link]], not a code block.
BULLET_RE = re.compile(
    r"^-\s+\*\*\[stated-by-user\]\*\*\s+birthday\s+(?:—|--|-)\s+"
    r"\[\[ben-whitmore\]\]\s+\(2026-08-29\)\s*$"
)


def split_sections(body):
    """Split profile.md's body (after frontmatter) into {heading: [lines]}."""
    sections = {}
    current = None
    for line in body.splitlines():
        m = re.match(r"^##\s+(.+?)\s*$", line)
        if m:
            current = m.group(1).strip()
            sections[current] = []
            continue
        if current is not None:
            sections[current].append(line)
    return sections


def bullets_of(lines):
    return [l for l in lines if l.strip().startswith("- ")]


def read_profile(worked):
    path = os.path.join(worked, "profile.md")
    if not os.path.isfile(path):
        return None, None
    with open(path) as f:
        text = f.read()
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None, None
    fm_end = None
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            fm_end = i
            break
    if fm_end is None:
        return None, None
    frontmatter = "\n".join(lines[: fm_end + 1])
    body = "\n".join(lines[fm_end + 1 :])
    return frontmatter, body


def main():
    if len(sys.argv) < 2:
        print("usage: 01-person-optout-filed.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    failures = []

    # --- exactly profile.md and people/ben-whitmore.md should exist -------
    expected_entries = ["people", "profile.md"]
    entries = sorted(os.listdir(worked)) if os.path.isdir(worked) else []
    if entries != expected_entries:
        failures.append(
            f"store contains {entries!r}, expected exactly {expected_entries!r} "
            f"-- the spec says do not create, delete, or rewrite any other file"
        )

    people_dir = os.path.join(worked, "people")
    person_path = os.path.join(people_dir, "ben-whitmore.md")
    people_entries = sorted(os.listdir(people_dir)) if os.path.isdir(people_dir) else []
    if people_entries != ["ben-whitmore.md"]:
        failures.append(
            f"'people/' contains {people_entries!r}, expected exactly "
            f"['ben-whitmore.md'] -- an opt-out is never encoded as a "
            f"person.md edit (rule 5), so no person file may be created, "
            f"deleted, or renamed"
        )
    elif os.path.isfile(person_path):
        # Compare against this case's own before/ fixture -- the person
        # file must be byte-identical (untouched) after the run.
        case_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        before_person = os.path.join(
            case_dir, "..", "..", "..", "tests", "goldens", "preferences",
            "05-person-optout", "before", "people", "ben-whitmore.md",
        )
        before_person = os.path.normpath(before_person)
        if os.path.isfile(before_person):
            if not filecmp.cmp(person_path, before_person, shallow=False):
                failures.append(
                    "people/ben-whitmore.md was modified -- an opt-out must "
                    "never be encoded as a person.md edit (rule 5)"
                )
        else:
            failures.append(
                f"reference fixture missing at {before_person!r} -- cannot "
                f"verify people/ben-whitmore.md was left untouched"
            )

    frontmatter, body = read_profile(worked)
    if frontmatter is None:
        failures.append("profile.md missing or malformed frontmatter")
    elif "schema_version: 1.0.0" not in frontmatter:
        failures.append(f"frontmatter changed: {frontmatter!r}")

    if body is not None:
        sections = split_sections(body)

        for heading in SECTION_ORDER:
            if heading not in sections:
                failures.append(f"missing '## {heading}' section")

        # Sections that must remain untouched (empty, as in before/).
        for heading in ("Priorities", "Cadence wishes", "Style notes"):
            got_bullets = bullets_of(sections.get(heading, []))
            if got_bullets:
                failures.append(
                    f"'## {heading}' should remain empty but has bullets: "
                    f"{got_bullets!r}"
                )

        optout_bullets = bullets_of(sections.get("Signal opt-outs", []))
        if len(optout_bullets) != 1:
            failures.append(
                f"'## Signal opt-outs' should gain exactly one bullet, "
                f"found {len(optout_bullets)}: {optout_bullets!r}"
            )
        else:
            bullet = optout_bullets[0]
            if not BULLET_RE.match(bullet.strip()):
                failures.append(
                    f"signal opt-out bullet does not match the deterministic "
                    f"grammar '- **[stated-by-user]** birthday -- "
                    f"[[ben-whitmore]] (2026-08-29)' (plain prose, no code "
                    f"span): {bullet!r}"
                )
    else:
        failures.append("profile.md body unreadable")

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        "PASS: exactly one **[stated-by-user]** bullet appended to "
        "'## Signal opt-outs', 'birthday -- [[ben-whitmore]] (2026-08-29)'; "
        "people/ben-whitmore.md untouched; all other sections and files "
        "untouched"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
