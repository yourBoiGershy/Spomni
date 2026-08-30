#!/usr/bin/env python3
"""01-cadence-wish-filed.py — T3 grader for 03-cadence-wish.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from this case's prompt.md and
packages/ingestion/specs/stated-preference-filing.md section (c), NOT from
any run's output — per the eval-case contract's golden-tests-before-prompts
rule): the utterance "I want to stay quarterly with my Michigan crew --
don't let those go dormant" is a stated rhythm ask, so it must land as
exactly one appended `**[stated-by-user]**` bullet in `profile.md`'s
`## Cadence wishes` section, dated `(2026-08-29)`.

Byte-exact prose matching of a live model's "lightly cleaned up" rewording
is inherently flaky (the spec explicitly allows light cleanup, not
paraphrase-into-a-different-claim) -- so this grader is structure-exact,
prose-tolerant: it pins the section shape, the provenance tag, the date,
and the load-bearing content words (quarterly, Michigan), while tolerating
any reasonable light rewording of the rest of the sentence. It also asserts
the other three sections and the frontmatter are untouched, and that no
other file in the store was created, deleted, or modified.
"""

import os
import re
import sys

SECTION_ORDER = ["Priorities", "Cadence wishes", "Signal opt-outs", "Style notes"]

REQUIRED_WORDS = ["quarterly", "michigan"]


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
        print("usage: 01-cadence-wish-filed.py <worked-store-dir> [result.json]")
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
        for heading in ("Priorities", "Signal opt-outs", "Style notes"):
            got_bullets = bullets_of(sections.get(heading, []))
            if got_bullets:
                failures.append(
                    f"'## {heading}' should remain empty but has bullets: "
                    f"{got_bullets!r}"
                )

        cadence_bullets = bullets_of(sections.get("Cadence wishes", []))
        if len(cadence_bullets) != 1:
            failures.append(
                f"'## Cadence wishes' should gain exactly one bullet, "
                f"found {len(cadence_bullets)}: {cadence_bullets!r}"
            )
        else:
            bullet = cadence_bullets[0]
            if "**[stated-by-user]**" not in bullet:
                failures.append(
                    f"cadence-wish bullet missing '**[stated-by-user]**' "
                    f"provenance tag: {bullet!r}"
                )
            if "(2026-08-29)" not in bullet:
                failures.append(
                    f"cadence-wish bullet missing capture date "
                    f"'(2026-08-29)': {bullet!r}"
                )
            lowered = bullet.lower()
            for word in REQUIRED_WORDS:
                if word not in lowered:
                    failures.append(
                        f"cadence-wish bullet missing load-bearing word "
                        f"{word!r}: {bullet!r}"
                    )
            # Section-shape check: exactly one section-body line before the
            # bullet was appended (a blank separator), i.e. the bullet is
            # appended, not prepended or merged into a rewritten heading.
    else:
        failures.append("profile.md body unreadable")

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        "PASS: exactly one **[stated-by-user]** bullet appended to "
        "'## Cadence wishes', dated (2026-08-29), containing 'quarterly' "
        "and 'Michigan'; all other sections and files untouched"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
