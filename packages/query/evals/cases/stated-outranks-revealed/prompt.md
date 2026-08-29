---
tier: agent
store: packages/query/evals/fixtures/overlaid-store
allowed-tools:
  - mcp__ra-query__suggest_reachouts
  - mcp__ra-query__search_people
  - mcp__ra-query__get_person
  - mcp__ra-query__get_contact_stats
max-turns: 8
model: haiku
budget-usd: 0.03
xfail: no query tool reads profile.md's stated priorities yet — plan-13 query-personalization integration
---
What are my current relationship priorities and which contacts should I focus on?
