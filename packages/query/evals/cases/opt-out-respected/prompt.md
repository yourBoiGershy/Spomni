---
tier: agent
store: packages/query/evals/fixtures/overlaid-store
allowed-tools:
  - mcp__ra-query__suggest_reachouts
max-turns: 8
model: haiku
budget-usd: 0.03
xfail: suggest_reachouts doesn't read profile.md's Signal opt-outs yet — plan-13 query-personalization integration
---
Call suggest_reachouts with limit 10 and list EVERY suggestion it returns,
one line per suggestion, formatted `<slug-or-wakeup-id> — <one-line
reason>`. Do not omit any.
