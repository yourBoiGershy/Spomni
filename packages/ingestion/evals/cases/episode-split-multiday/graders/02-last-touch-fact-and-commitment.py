#!/usr/bin/env python3
"""02-last-touch-fact-and-commitment.py — T3 grader for
episode-split-multiday.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Fact-based, content-word tolerant (prose phrasing may vary across live
runs; the underlying claim must not). Pins §5b-episodes point 4 ("person-
file effects run once, anchored to the latest episode") plus point 3
("facts/commitments attach to their own day"):

  1. people/erin-fixture.md's last-touch is 2026-07-05 -- the LATEST
     episode's date, not the first (2026-07-01) or middle (2026-07-03) one,
     and not run three separate times.
  2. people/erin-fixture.md has a ## Facts bullet about the new puppy
     Waffles (the fact stated on the first, 2026-07-01, episode).
  3. interactions/2026-07-05-erin-fixture.md's ## Commitments has a bullet
     attributed to [[erin-fixture]] about the pasta recipe (the commitment
     stated on the third, 2026-07-05, episode -- not lumped onto an earlier
     episode or dropped).
  4. people/erin-fixture.md's tier frontmatter is still empty -- this event
     never puts tier in play, and a hallucinated tier write would be a bug
     unrelated to this rule.
"""

import os
import re
import sys


def read(path):
    if not os.path.isfile(path):
        return ""
    with open(path) as f:
        return f.read()


def frontmatter(text):
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}, ""
    fm_lines = []
    body_start = 1
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
    body = "\n".join(lines[body_start:])
    return fm, body


def section(body, name, stop_names):
    if name not in body:
        return ""
    tail = body.split(name, 1)[-1]
    for stop in stop_names:
        tail = tail.split(stop, 1)[0]
    return tail


def main():
    if len(sys.argv) < 2:
        print("usage: 02-last-touch-fact-and-commitment.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    failures = []

    person_path = os.path.join(worked, "people", "erin-fixture.md")
    person_text = read(person_path)
    if not person_text:
        failures.append("people/erin-fixture.md: file missing from worked store")
    else:
        fm, body = frontmatter(person_text)

        last_touch = fm.get("last-touch", "")
        if last_touch != "2026-07-05":
            failures.append(
                f"people/erin-fixture.md: last-touch={last_touch!r}, expected "
                f"'2026-07-05' (the latest episode's date, per §5b-episodes point 4 -- "
                f"last-touch runs once for the whole event, anchored to the latest day, "
                f"not per-episode)"
            )

        facts_section = section(body, "## Facts", ["## Open threads"]).lower()
        if "waffles" not in facts_section:
            failures.append(
                "people/erin-fixture.md: no ## Facts bullet mentions the new puppy "
                "Waffles (the fact stated on the 2026-07-01 episode)"
            )

        tier = fm.get("tier", "")
        if tier:
            failures.append(
                f"people/erin-fixture.md: tier={tier!r}, expected empty -- this event "
                f"never puts tier in play"
            )

    interaction_path = os.path.join(worked, "interactions", "2026-07-05-erin-fixture.md")
    interaction_text = read(interaction_path)
    if not interaction_text:
        failures.append(
            "interactions/2026-07-05-erin-fixture.md: file missing from worked store"
        )
    else:
        _, body = frontmatter(interaction_text)
        commitments = section(body, "## Commitments", []).lower()
        has_owner = "[[erin-fixture]]" in commitments
        has_content = "pasta" in commitments or "recipe" in commitments
        if not (has_owner and has_content):
            failures.append(
                "interactions/2026-07-05-erin-fixture.md: ## Commitments does not have "
                "a [[erin-fixture]] bullet about the pasta recipe (the commitment "
                "stated on the 2026-07-05 episode)"
            )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        "PASS: last-touch anchored to the latest episode (2026-07-05), the "
        "day-1 Waffles fact and the day-3 (2026-07-05) pasta-recipe "
        "commitment both landed, tier untouched"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
