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

- **Inputs:** what the worker starts from — carried **inline**, not as bare
  paths. The orchestrator (or a checker) has already read the contract, type
  shape, or signature; paste the relevant excerpt into the brief verbatim,
  with the path attached only so the worker knows where it lives. Litmus: a
  worker that must open more than ~2 files before its first edit got an
  underspecified brief — go gather the content and paste it.
- **Outputs:** what must exist when done (files created/changed, shapes of any
  new types), and what must NOT change.

## §3 Rules profile

Which doctrine applies to this unit — usually one line, e.g. "standard
dev-worker rules; static checks only; no test runs" plus any unit-specific
constraint ("do not touch the public API surface").

## §4 References & decisions

- Exemplars pasted verbatim (the ~10 relevant lines), with `path:line` for
  provenance — the worker follows the snippet, never a pointer hunt.
- Decisions already made, with the one-line why — the worker never re-litigates.
- For retries: the prior attempt's diff and failure output, verbatim.
