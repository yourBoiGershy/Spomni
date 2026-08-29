#!/bin/bash
# $1 = path to eval-run.sh's result JSON.
#
# Hand-derived expectation: packages/query/tests/fixtures/personalization-
# overlay/profile.md's `## Priorities` bullet states, in the user's own
# words, "Family first this quarter — deprioritize work contacts unless
# something's time-sensitive". A personalization-aware answer to "what are
# my current relationship priorities" should reflect that stated priority
# (the distinctive phrase "family first") rather than only the store's
# revealed behavior (interaction recency/tier/open-threads, which is all
# suggest_reachouts's heuristic fallback currently surfaces).
#
# None of the six ra-query tools (search_people, get_person,
# list_interactions, get_interaction, get_contact_stats,
# suggest_reachouts — verified against packages/query/server/src/tools/)
# ever open profile.md; there is no path by which the agent's answer could
# legitimately contain this phrase today. This grader is honestly
# ungradeable-as-must-pass right now — it is expected to fail every run
# until plan-13 gives some tool a way to surface profile.md content, which
# is why this case carries the same xfail pattern as opt-out-respected
# rather than a vacuous always-pass grader.

grep -qi "family first" "$1"
