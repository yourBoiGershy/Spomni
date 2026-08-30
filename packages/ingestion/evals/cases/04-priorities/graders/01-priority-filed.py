#!/usr/bin/env python3
"""01-priority-filed.py — T3 grader for 04-priorities.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from this case's prompt.md and
packages/ingestion/specs/stated-preference-filing.md section (c), NOT from
any run's output — per the eval-case contract's golden-tests-before-prompts
rule): the utterance "This year I'm prioritizing fintech contacts -- that's
where my energy should go" is a freeform stated priority, so it must land
as exactly one appended `**[stated-by-user]**` bullet in `profile.md`'s
`## Priorities` section, dated `(2026-08-29)`.

Byte-exact prose matching of a live model's "lightly cleaned up" rewording
is inherently flaky (the spec explicitly allows light cleanup, not
paraphrase-into-a-different-claim) -- so this grader is structure-exact,
prose-tolerant: it pins the section shape, the provenance tag, the date,
and the load-bearing content words (fintech, a "prioritiz*" stem), while
tolerating any reasonable light rewording of the rest of the sentence. It
also asserts the other three sections and the frontmatter are untouched,
and that no other file in the store was created, deleted, or modified.
"""

import os
import re
import sys

SECTION_ORDER = ["Priorities", "Cadence wishes", "Signal opt-outs", "Style notes"]


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
        print("usage: 01-priority-filed.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    failures = []

    # --- nothing but profile.md should exist in the store -----------------
    entries = sorted(os.listdir(worked)) if os.path.isdir(worked) else []
    if entries != ["profile.md"]:
        failures.append(
            f"store contains {entries!r}, expected exactly ['profile.md'] -- "
            f"the spec says do not touch any other file"
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
        for heading in ("Cadence wishes", "Signal opt-outs", "Style notes"):
            got_bullets = bullets_of(sections.get(heading, []))
            if got_bullets:
                failures.append(
                    f"'## {heading}' should remain empty but has bullets: "
                    f"{got_bullets!r}"
                )

        priority_bullets = bullets_of(sections.get("Priorities", []))
        if len(priority_bullets) != 1:
            failures.append(
                f"'## Priorities' should gain exactly one bullet, "
                f"found {len(priority_bullets)}: {priority_bullets!r}"
            )
        else:
            bullet = priority_bullets[0]
            if "**[stated-by-user]**" not in bullet:
                failures.append(
                    f"priority bullet missing '**[stated-by-user]**' "
                    f"provenance tag: {bullet!r}"
                )
            if "(2026-08-29)" not in bullet:
                failures.append(
                    f"priority bullet missing capture date "
                    f"'(2026-08-29)': {bullet!r}"
                )
            lowered = bullet.lower()
            if "fintech" not in lowered:
                failures.append(
                    f"priority bullet missing load-bearing word 'fintech': "
                    f"{bullet!r}"
                )
            if not re.search(r"priorit", lowered):
                failures.append(
                    f"priority bullet missing a 'priorit*' stem "
                    f"(prioritizing/priority/prioritize): {bullet!r}"
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
        "'## Priorities', dated (2026-08-29), containing 'fintech' and a "
        "'priorit*' stem; all other sections and files untouched"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
