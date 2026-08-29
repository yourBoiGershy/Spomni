# Agent brief template

Every worker receives a brief in this shape. The orchestrator authors it; the
splitting rule (.claude/rules/orchestration.md) has already been applied — a
brief describes ONE unit sized for a ≤3-minute run.

---

## §1 Mission

One paragraph: the single work unit, stated as the outcome ("add X to Y so
that Z"), not a task list. If you cannot state it without bullets, it is more
than one unit — split before spawning.

## §2 Contract

- **Inputs:** files/types/artifacts the worker starts from (paths).
- **Outputs:** what must exist when done (files created/changed, shapes of any
  new types), and what must NOT change.

## §3 Rules profile

Which doctrine applies to this unit — usually one line, e.g. "standard
dev-worker rules; static checks only; no test runs" plus any unit-specific
constraint ("do not touch the public API surface").

## §4 References & decisions

- Patterns to follow (`path:line` of an exemplar).
- Decisions already made, with the one-line why — the worker never re-litigates.
- For retries: the prior attempt's diff and failure output, verbatim.
