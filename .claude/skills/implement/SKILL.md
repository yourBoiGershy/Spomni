---
name: implement
description: Orchestrated implementation — split the work per the splitting rule, brief dev-workers, fan out in parallel, consolidate reports, commit per phase.
version: 1.0.0
triggers:
  keywords: [implement, build, "make the change"]
model: inherit
---

# /implement — orchestrated implementation (simple form)

The main conversation orchestrates; every production-code edit goes to a
dev-worker. No gates or attestation in the simple harness — verification is a
review of completion reports plus the project's own checks.
<!-- PARAMETERIZE: add the project's typecheck/lint/test commands as a
     post-phase verification step once the harness lives in a real project. -->

## Process

1. **Source of truth:** a plan from `docs/plans/` if one exists, else the
   user's task. If the task is large and unplanned, run plan-architect first
   (build it a context capsule: Task / Decisions / Affected files / Patterns /
   Constraints / Concerns).
2. **Split** into independent work units per the mandatory splitting rule
   (.claude/rules/orchestration.md). Implementation and its tests are two
   units. Re-check every brief: 4+ bulleted items = split again.
3. **Brief** each unit using .claude/context/agent-brief-template.md.
4. **Fan out:** spawn all dev-workers for a phase in ONE parallel message
   (rolling pool above 15). Workers for disjoint file sets only — overlapping
   files serialize into one worker.
5. **Consolidate:** read completion reports. BLOCKED "needs splitting" →
   split and respawn. PARTIAL/FAILED → one retry brief carrying the prior
   diff + failure output. Max 2 rounds, then escalate to the user.
6. **Commit per phase** on a work branch (never main) with a conventional
   message. Plain `git commit` via the Bash tool — no attestation trailer in
   the simple harness.
7. Repeat for the next phase; respect plan `Depends-On` — disjoint phases may
   overlap.

## Anti-patterns

- The orchestrator "quickly fixing" something itself (hook will block it).
- One mega-worker for a multi-unit phase.
- Re-briefing a retry without the prior attempt's failure output.
- Committing on main or pushing without an explicit user ask.
