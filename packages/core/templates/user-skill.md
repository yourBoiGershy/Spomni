---
name: <name>
description: <one line — what this answers/does, and any read-only-vs-drafts caveat, written for the invoking model>
---

<!--
Scaffold for a user-authored skill, per packages/core/contracts/user-skill.md
1.0.0. Save this file as <data-dir>/skills/<name>/SKILL.md — the directory
name must equal the `name` above. Run
packages/core/scripts/link-user-skills.sh <data-dir> afterward to expose it
as a personal-scope Claude Code skill (~/.claude/skills/<name>).
-->

# <name>

<!--
What it answers/does — one paragraph. Say plainly what question this
answers or what it does, then close with the mission-test line: which
running cost does this cut for you (coordinating, following up,
remembering-to, restarting a stale thread)? If you can't name one, this
isn't a skill worth building — it's substituting for the relationship
itself, which is out of scope even for a personal skill.
-->

## Read path

<!--
Primary: the spomni-query MCP tools, if registered in your session —
search_people, get_person, list_interactions, get_contact_stats,
suggest_reachouts, upcoming_meetings, who_next_pool.

Fallback, when the MCP server is absent (e.g. a cold cloud/phone session):
  bash packages/query/scripts/who-next-direct.sh <store-dir>
or read index.json / stats.json / people/*.md directly.
-->

## Rules

<!--
Render per packages/core/contracts/answer-style.md 1.0.0: action-first,
lead with the situation then the list, ≤2 lines per item, cap 5 items,
no scores/breakdowns/JSON unless asked, no-guilt (no "pending"/"missed"/
"overdue"/streaks), draft on demand — never render a message inline.

Read-only by default. Any write goes only through a sanctioned core
script (wakeup-add.sh, person-set-tier.sh, person-set-kind.sh,
store-sync.sh) followed by reindex.sh — never a raw edit to people/ or
interactions/.

Draft, never send: this skill may compose a draft on request, headed
"Draft (unsent):" — the human always sends it themselves.
-->

## Schedule (optional)

<!--
If this skill should run on a recurring cadence rather than only
on-demand, add it as a row in <data-dir>/connectors/sync-scheduler/lanes.tsv
per packages/core/contracts/sync-lanes.md, or invoke it repeatedly
in-session with /loop. A skill file alone is not scheduled by default.
-->
