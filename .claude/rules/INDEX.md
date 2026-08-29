# Rules index

Always-on doctrine. Keep this directory SMALL — it is a prompt-cache target.

| File | Contents |
|---|---|
| `orchestration.md` | Dispatch mechanics: concurrency tiers, the mandatory splitting rule, turn economy, monitoring, fix policy (condensed) |

Reference material that is loaded on demand (not always-on) lives in
`.claude/context/`:

| File | Contents |
|---|---|
| `../context/agent-brief-template.md` | The 4-section brief every worker receives |
| `../context/completion-report-block.md` | The report block every agent ends with |

Deliberately absent in this simplified harness (see README): gate system,
attestation, fix-policy machinery, agent-lint, task triage, worktree lifecycle.
