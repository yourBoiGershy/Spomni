#!/usr/bin/env python3
"""01-global-optout-filed.py -- T3 grader for 02-global-optout.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from this case's prompt.md and
packages/ingestion/specs/stated-preference-filing.md section (b), NOT from
any run's output -- per the eval-case contract's golden-tests-before-prompts
rule): "stop nudging me about company news" is a global signal opt-out, so
it must land as exactly one appended `**[stated-by-user]**` bullet in
`profile.md`'s `## Signal opt-outs` section, grammar
`<signal-type> -- all`, signal-type `company-news`, dated `(2026-08-29)`.

Unlike the freeform-prose bullets in (c) (priorities/cadence wishes), (b)'s
opt-out grammar is deterministic -- there is no "lightly cleaned up"
latitude, so this grader pins the bullet close to exact while still
tolerating the one axis a live model run can vary on harmlessly: an em dash
vs. a plain hyphen as the "--" separator. It also asserts the other three
sections and the frontmatter are untouched, and that no other file in the
store was created, deleted, or modified.
"""

import os
import re
import sys

SECTION_ORDER = ["Priorities", "Cadence wishes", "Signal opt-outs", "Style notes"]

# Accept either an em dash or a plain hyphen/double-hyphen as the separator.
BULLET_RE = re.compile(
    r"^-\s+\*\*\[stated-by-user\]\*\*\s+company-news\s+(?:—|--|-)\s+all\s+\(2026-08-29\)\s*$"
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
        print("usage: 01-global-optout-filed.py <worked-store-dir> [result.json]")
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
                    f"grammar '- **[stated-by-user]** company-news -- all "
                    f"(2026-08-29)': {bullet!r}"
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
        "'## Signal opt-outs', 'company-news -- all (2026-08-29)'; all "
        "other sections and files untouched"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
