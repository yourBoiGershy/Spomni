---
tier: agent
store: packages/core/fixtures/store
allowed-tools:
  - mcp__ra-query__suggest_reachouts
  - mcp__ra-query__get_contact_stats
max-turns: 8
model: haiku
budget-usd: 0.05
---
Call suggest_reachouts and look at the top suggestion. Why does your top
reach-out suggestion rank where it does? Explain the ranking using the data
the tools give you.
