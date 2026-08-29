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
Who should I prioritize reaching out to in the next couple of weeks, and why?
