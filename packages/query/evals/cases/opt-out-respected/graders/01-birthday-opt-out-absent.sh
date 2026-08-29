#!/bin/bash
# $1 = path to eval-run.sh's result JSON.
#
# Hand-derived expectation (packages/query/tests/fixtures/personalization-
# overlay/README.md, "Hand-derived expectations" #1): with the overlay's
# `## Signal opt-outs` bullet (`birthday — all`) respected, suggest_reachouts
# must NOT surface marcus-chen's overlay birthday wake-up
# (2026-09-10-marcus-chen--2, signal-type: birthday). Its wakeup id is the
# most specific string this fixture set exposes for that entry, so absence
# of that id from the result JSON is the assertion.
#
# Today suggest_reachouts does not read profile.md at all (verified: no
# reference to profile.md/ranking-weights.json anywhere under
# packages/query/server/src/) so this id is surfaced (it falls well within
# the default top-5 by due-date sort) and this grader FAILS — which is
# exactly why this case carries `xfail: ... plan-13 query-personalization
# integration`. The runner reports XFAIL, not FAIL, for that reason. When
# plan-13 wires opt-out suppression into suggest_reachouts, this grader will
# start passing and the case must flip from XFAIL to XPASS-then-must-pass
# (drop the xfail field) in that same change.

if grep -q "2026-09-10-marcus-chen--2" "$1"; then
  # Opted-out birthday wake-up was surfaced — opt-out not respected.
  exit 1
fi

exit 0
