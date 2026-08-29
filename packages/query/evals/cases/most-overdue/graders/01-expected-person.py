#!/usr/bin/env python3
"""01-expected-person.py — T2 grader for the most-overdue eval case.

$1 = path to eval-run.sh's result JSON (fields: result, is_error, num_turns,
total_cost_usd, duration_ms, permission_denials, usage — per
packages/core/contracts/eval-case.md).

Hand-derived expected answer: packages/core/fixtures/store/wakeups/
2026-09-05-james-okafor.md is the only `pending` wake-up in the fixture
store, due 2026-09-05 — the earliest due date, so it is the single most
overdue reach-out `suggest_reachouts` should surface first. The agent's
answer must name James Okafor.

Exits 0 (pass) if is_error is false and the result text contains "james
okafor" in either slug form (james-okafor) or display form (James Okafor),
case-insensitive. Exits 1 (fail) otherwise, printing what it found.
"""

import json
import re
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: 01-expected-person.py <result.json>")
        return 1

    result_path = sys.argv[1]

    try:
        with open(result_path) as f:
            data = json.load(f)
    except Exception as exc:
        print(f"FAIL: could not parse result JSON at {result_path}: {exc}")
        return 1

    is_error = data.get("is_error")
    result_text = data.get("result")

    if is_error:
        print(f"FAIL: is_error is true in {result_path}")
        return 1

    if not isinstance(result_text, str):
        print(f"FAIL: result field missing or not a string in {result_path}")
        return 1

    # Accept slug form (james-okafor) or display form (James Okafor),
    # case-insensitive, tolerant of either hyphen or space between names.
    pattern = re.compile(r"james[-\s]okafor", re.IGNORECASE)
    match = pattern.search(result_text)

    if match:
        print(f"PASS: found expected person reference '{match.group(0)}' in result text")
        return 0

    print("FAIL: result text does not mention James Okafor (expected the "
          "single most-overdue reach-out per the earliest-due pending "
          "wake-up in the fixture store)")
    print(f"result text was: {result_text!r}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
