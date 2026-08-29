---
name: explore
description: Orchestrated read-only exploration of the codebase. Classifies the question, fans out checker scouts in parallel, consolidates with confidence.
version: 1.0.0
triggers:
  keywords: [explore, "where is", "how does", find, locate]
model: inherit
---

# /explore — orchestrated codebase exploration

The main conversation runs this; it spawns only read-only checkers (40-cap
tier) and never edits anything.

## Process

1. **Classify the question:**
   - *locate* ("where is X?") → codebase-locator-checker
   - *pattern* ("how do we usually do X?") → codebase-locator-checker with an
     exemplar-hunting brief
   - *analyze* ("how does X work?", "what breaks if…?") → locate first if the
     target is unknown, then codebase-analyzer-checker on the confirmed target
2. **Shard broad queries** into at most 5 independent sub-questions and spawn
   all scouts in ONE parallel message. Give overlapping scopes to 2 scouts
   when the answer matters — agreement is the confidence signal.
3. **Consolidate:** dedupe findings; where ≥2 scouts agree independently, mark
   the finding high-confidence; where scouts conflict or a scope came back
   "not found", say so explicitly — gaps are part of the answer.
4. **Report** to the user: answer first, then evidence (`path:line`), then
   gaps/low-confidence areas.

## Anti-patterns

- Exploring serially when scouts are independent.
- The orchestrator grepping alongside its own scouts (duplicated work).
- Presenting single-scout findings as certain.
- Spawning an analyzer before the target is actually located.
