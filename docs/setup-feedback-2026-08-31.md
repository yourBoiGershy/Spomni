# First-run setup feedback — 2026-08-31 (second-machine install, Eric's Mac)

Running notes from walking a real second-machine setup (clone → store →
lanes → connectors) with the assistant driving from docs/SETUP.md. Each item
is a gap in the onboarding flow, not in the machinery itself.

## 1. Reminders/wake-up delivery should be surfaced first, and explained

The reminder side (wake-ups → notify lane → where nudges actually land) was
the first thing that needed attention in this run, but the current flow
buries it: nudge delivery (SETUP §5b) only comes up deep in the scheduler
section, and this install finished with the notify lane enabled but no
delivery channel configured — reminders silently render to `outbox/` only.

What the flow should do instead:
- Treat reminder delivery as an early, explicit setup step — prompt the user
  through it rather than leaving it as an optional subsection.
- While setting it up, *tell the user what is being set up and how* (what a
  wake-up is, where nudges will be delivered, what the lane does) — not just
  execute silently.

## 2. Connector choice should be a direct, structured prompt — not buried in chat

The user should be asked up front, as a direct question (a structured
prompt/dialog, not a line of conversational text), something like:

> "The default connectors are Beeper, Gmail, and Calendar through Claude.
> How would you like to set this up so we can get started?"

Right now connector setup is discovered piecemeal (setup.sh's trailing
"left for you" list + SETUP §3). It should be one consolidated, explicit
choice at the start of onboarding.

Prior art: this direct-prompt connector picker was built once before in
Node — but never on the site. Worth digging that version up as a reference
for the flow.

## 3. Bug: profile.md template trips the store validator, blocking all auto-commits

`profile-set-notify.sh` creates `profile.md` from
`packages/core/templates/profile.md`, whose line 17 example comment contains
a literal `[[slug]]`. `validate-store.sh` doesn't skip HTML comments, flags
it as a broken people-link, and `store-sync.sh` then refuses every commit —
so the store-commit lane silently stops pushing the moment notify is
configured on a fresh profile. Found live on this install (2026-08-31).

Fix belongs in machinery (worker-scoped, packages/core): either make the
validator ignore `<!-- -->` comments or remove the bracketed example from
the template. Worked around here by rewording the comment in the store copy.

## 4. No forced write path: agents hand-write store files and get the schema wrong

A cloud session filing hacker-weekend followups hand-wrote `people/*.md` and
`wakeups/*.md` with invalid enum values (`tier_source: user`,
`origin: user` — contracts require `stated-by-user` / `user-ask`). Nothing
stopped it at write time; `validate-store.sh` only catches it later, at
which point store-sync refuses to commit and the work strands. Every entry
surface (chat session, cron tick, cloud/mobile session) currently
free-hands markdown against the contracts.

Blessed writers already partially exist (`wakeup-add.sh`,
`person-set-kind.sh`, `person-set-tier.sh`, `person-merge.sh`) — the cloud
session just bypassed them and hand-wrote the files. So the gap is
(a) coverage: no `person-add` / `interaction-add` creator equivalents, and
(b) enforcement: nothing makes the writers the ONLY write path.

Direction: complete the writer CLI surface, then enforce it — "forced
interpretation" via tooling, per the agent-harness philosophy
(yourBoiGershy/agent-harness: confinement hooks, schema-validated agent
output via subagent-stop-validate, gates). A pre-commit hook in the data
repo (or a store-sync check) that rejects hand-written store files failing
contract validation closes the loop at the choke point every surface
(chat, cron tick, cloud/mobile session) already passes through.
Connector-agnostic: the same writer regardless of where the data came from.

## 5. No standardized end-of-session ship flow — work strands on unmerged branches

The same followups sat on `claude/hacker-weekend-followups-21veoe`, never
merged into the data repo's `main` — invisible to who-next, wake-ups, and
every other reader until manually discovered and merged (2026-08-31).
Nothing detects a session that ends without landing its branch.

Direction: (a) a `ship`/`land` script every session runs at the end —
validate → merge to main → push (data repo) or open PR (machinery repo);
(b) the staleness lane also flags unmerged `claude/*` branches on the data
repo older than ~1 day, so stranded work raises a wake-up instead of being
silently lost.

---

*Add items below as the walkthrough continues.*
