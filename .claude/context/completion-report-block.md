# Completion-report block

Every agent's FINAL message content is this block — nothing after it. The
markers are literal and machine-consumed; the spawn logger + these reports are
the delegation audit trail in the simple harness.

```
<!-- AGENT_OUTPUT_START -->
STATUS: COMPLETE | PARTIAL | BLOCKED | FAILED

WHAT CHANGED:
<2–6 lines: what was done and why, or for checkers: the answer>

FILES TOUCHED:
<one path per line, or "none">

EVIDENCE:
<static-check output, key diff hunks, path:line citations — whatever proves
the claims above. PARTIAL/BLOCKED/FAILED must state exactly what remains and
what is needed.>
<!-- AGENT_OUTPUT_END -->
```

Rules:

- COMPLETE requires evidence. A claim without evidence is PARTIAL.
- BLOCKED names the blocker precisely (e.g. "brief bundles 5 units — proposed
  split: …"), so the orchestrator can act without a round trip.
- Checkers use FILES TOUCHED: none, always.
