#!/usr/bin/env python3
"""01-warning-surfaced.py — T3 grader for rescale-skew-detection.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from this case's prompt.md and
`before/data-ingestion/rescale-report.tsv`'s overall row, NOT from any run's
output — per the eval-case contract's golden-tests-before-prompts rule):
that row reads `skew: yes` (share_ge_80 = 1.00 > 0.5), so SKILL.md's Step 4
requires the skill to print the exact skew warning before presenting
anything. This grader does not pin the warning's full exact byte string
(the model's rendering of `<m>`/`<share>` could reasonably vary in
formatting) — it checks the two operative substrings the warning must
carry: the word "skewed" and a `--rescale` mention, per SKILL.md's quoted
template `Warrant distribution is skewed (<reason>): mean <m>, <share>% >=
80. Re-center with \`--rescale\`? Suggestions below are shown un-rescaled.`
"""

import os
import sys


def main():
    if len(sys.argv) < 2:
        print("usage: 01-warning-surfaced.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    warning_path = os.path.join(worked, "data-ingestion", "skew-warning.txt")

    if not os.path.isfile(warning_path):
        print(f"FAIL: {warning_path} does not exist — the skew warning was never written")
        return 1

    with open(warning_path) as f:
        text = f.read()

    failures = []
    if "skewed" not in text.lower():
        failures.append("skew-warning.txt does not contain 'skewed'")
    if "--rescale" not in text:
        failures.append("skew-warning.txt does not mention '--rescale'")

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print("PASS: skew-warning.txt exists and carries the skew warning's operative wording")
    return 0


if __name__ == "__main__":
    sys.exit(main())
