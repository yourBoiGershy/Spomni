#!/bin/bash
# $1 = path to eval-run.sh's result JSON.
#
# Hand-derived expectation (packages/query/tests/fixtures/personalization-
# overlay/README.md, "Hand-derived expectations" #1): with the overlay's
# `## Signal opt-outs` bullet (`birthday — all`) respected, suggest_reachouts
# must NOT surface marcus-chen's overlay birthday wake-up
# (2026-09-10-marcus-chen--2, signal-type: birthday). Its wakeup id is the
# most specific string this fixture set exposes for that entry, so absence
# of that id from the result JSON is the assertion. A line pairing
# `marcus-chen` with `birthday` (agent using the slug + signal-type instead
# of the full wakeup id) is treated as the same presence signal.
#
# Anti-XPASS guard: the prompt now forces full enumeration (limit 10, one
# line per suggestion, none omitted) precisely so this absence check can
# never pass vacuously. Before this guard, an agent that answered too
# briefly to enumerate anything (or errored, or was refused permission)
# would trivially satisfy "does not contain the opted-out id" and XPASS the
# case without suggest_reachouts having done anything right. So this grader
# ALSO requires the answer look like a real enumerated list — non-empty and
# at least 3 entries — before it will accept an absence result as a pass.
# Too few entries means the agent did not actually enumerate
# suggest_reachouts's output, so the absence check tells us nothing and the
# grader fails.
#
# Today suggest_reachouts does not read profile.md at all (verified: no
# reference to profile.md/ranking-weights.json anywhere under
# packages/query/server/src/) so the opted-out wake-up id is surfaced (it
# falls well within the default top-5-of-10 by due-date sort) and this
# grader FAILS — which is exactly why this case carries
# `xfail: ... plan-13 query-personalization integration`. The runner
# reports XFAIL, not FAIL, for that reason. When plan-13 wires opt-out
# suppression into suggest_reachouts, this grader will start passing and
# the case must flip from XFAIL to XPASS-then-must-pass (drop the xfail
# field) in that same change.

result_json="$1"

if [ ! -f "$result_json" ]; then
  echo "FAIL: no result JSON at $result_json"
  exit 1
fi

# Extract the "result" field's text. python3 is available per the case's
# other grader; keep this one dependency-light by shelling out to it only
# for JSON parsing, same as 01-expected-person.py does for most-overdue.
result_text=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception as exc:
    print("")
    sys.exit(0)
text = data.get("result")
print(text if isinstance(text, str) else "")
' "$result_json")

if [ -z "$result_text" ]; then
  echo "FAIL: result field missing, empty, or not a string in $result_json"
  exit 1
fi

# Anti-XPASS guard: require at least 3 enumerated-looking lines (the prompt
# asks for "<slug-or-wakeup-id> — <one-line reason>" per suggestion). Count
# lines containing the em-dash/hyphen separator as a proxy for "this looks
# like a real enumerated suggestion list," not just prose.
entry_count=$(printf '%s\n' "$result_text" | grep -c -- '—\|--\| - ')

if [ "$entry_count" -lt 3 ]; then
  echo "FAIL: only $entry_count enumerated-looking line(s) found in result text — the prompt requires listing every suggest_reachouts suggestion (expected at least 3), so an absence-only pass here would be vacuous"
  exit 1
fi

if printf '%s\n' "$result_text" | grep -qi "2026-09-10-marcus-chen--2"; then
  echo "FAIL: opted-out birthday wake-up id 2026-09-10-marcus-chen--2 was surfaced"
  exit 1
fi

if printf '%s\n' "$result_text" | grep -i "marcus-chen" | grep -qi "birthday"; then
  echo "FAIL: a line pairing marcus-chen with birthday was surfaced (opt-out not respected)"
  exit 1
fi

echo "PASS: $entry_count enumerated suggestion(s) found, none surfacing the opted-out marcus-chen birthday wake-up"
exit 0
