---
tier: agent
store: packages/core/fixtures/store
allowed-tools:
  - mcp__ra-query__suggest_reachouts
  - mcp__ra-query__get_person
max-turns: 8
model: haiku
budget-usd: 0.05
---
Using ONLY the ra-query MCP tools, figure out who the single most overdue
reach-out is right now. Name the person, cite the evidence for why they're
overdue, and keep your answer under 120 words.

End your answer with a line `slug: <the person's exact slug from the tool
output>`.
