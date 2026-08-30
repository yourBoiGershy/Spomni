# Spec: import triage

Status: spec (plan 26 unit 2). Package: `packages/ingestion` (the ledger
write, per the single-writer rule), consumed by
`packages/ingestion/scripts/triage-inbox.sh` (built in a later unit) and by
the debrief skill's batch mode
(`packages/ingestion/skills/debrief/SKILL.md` §1). This spec defines *what*
gets held and the ledger it is held in — it does not implement the checker
script itself.

## Problem

Backfill and steady-state sweeps land junk in `inbox/` alongside real person
events — marketing email, self-only calendar holds, OTP/security mail,
LinkedIn "wants to connect" pings, cold sales pitches. Every one of these
currently costs a full model judgment call during debrief. This spec adds a
cheap, deterministic, pre-judgment triage pass: six conservative rule
classes that can hold an event out of the debrief batch *without* a model in
the loop, for the classes of junk narrow enough to detect with certainty
from the event file alone.

## D4 — precision-first doctrine

A false hold loses a person event; a missed junk event only costs one model
judgment — so every rule is tuned for **zero false-holds**, and doubt always
falls through to judgment. Rules apply per event, deterministically, no
model in the loop. Calibration against the private live corpus happens later
(plan-26 unit 12) and may tighten these patterns further; they are authored
conservatively here, before that calibration data exists. Committed
goldens/fixtures are synthetic events *modeled on* the junk classes below —
the live corpus lives in the private data dir and **no real PII ever enters
`packages/`**.

## D3 — held-by-rule ledger

A new append-only ledger, `data/ingestion/triage-held.log`, one line per
held event:

```
<capture-id>\t<rule-name>\t<held-at ISO 8601 Z>
```

Tab-separated, exactly three fields. Example:

```
20260829T090100Z-gmail-in-4f2c	noreply-marketing	2026-08-29T09:15:00Z
```

- **Sole writer:** `packages/ingestion/scripts/triage-inbox.sh` (a later
  unit).
- **Readers:** the debrief skill — batch mode
  (`packages/ingestion/skills/debrief/SKILL.md` §1) additionally excludes
  ids present in `triage-held.log`, on top of its existing
  `debrief-filed.log` exclusion — and humans (a plain tab-separated log,
  greppable/reviewable directly).
- **Reversal:** an explicit **single-event** debrief invocation on a held id
  overrides the hold — the event files normally, and its resulting
  `debrief-filed.log` entry then outranks the hold everywhere (batch mode's
  exclusion check is "not filed AND not held"; once filed, the held-log line
  becomes moot, dead history left in place — append-only, never edited). No
  ledger surgery is ever performed to un-hold an event; the inbox file
  itself is never touched by triage, in either direction.

**Alternatives considered and rejected:**
- An inbox frontmatter marker — rejected because it would require editing
  `inbox/` files, which `capture-event.md` states are "never edited after
  creation" (an append-only archive).
- Moving the file (quarantine-style) — rejected because
  `docs/data-layout.md`'s quarantine convention is for **malformed** events
  (events a connector or filer could not even parse); held events here are
  perfectly valid, parseable capture events that are simply low-value —
  quarantine's semantics don't fit, and moving them would break `inbox/`'s
  flat, byte-for-byte-preserved layout for no reason.

## Deterministic checkability

Every rule below must be verifiable by a checker reading the event file
alone (frontmatter + body), plus `index.json`/`people/` for `cold-pitch`
only — no judgment calls, no free-text interpretation beyond fixed pattern
matching. Rules apply **in the order listed below; first match wins** (an
event matching more than one rule's pattern is held under whichever rule
appears first in this list, and only one ledger line is written). An event
matching none of the six rules is **not** held — it falls through to
normal debrief judgment, per the precision-first doctrine.

Fields referenced below are from capture-event 1.2.0
(`packages/core/contracts/capture-event.md` lines 28–39): `type` (enum),
`participant-hints` (raw unresolved identifiers), `source`
(`<connector>/<lane>`), and the body (raw captured text — for
`calendar-event`, the raw event JSON).

## Pattern source of truth

This spec is authoritative for the five rule regexes below (rules 1-5). The
checker script (`packages/ingestion/scripts/triage-inbox.sh`) duplicates them
verbatim (BSD/POSIX-shell-safe form) rather than sourcing this file — there
is no sync mechanism between the two copies. Any change to a pattern's
content MUST land in this spec section and the script's rules section in the
same commit; a change to only one side is a spec/script drift bug. Rule 6
(`noise-sender`) is table-driven instead — see its own section below, where
`packages/ingestion/config/noise-senders.tsv` is the single, non-duplicated
source of truth.

## The six rule classes

### 1. `noreply-marketing`

Applies only to `type: email`. Must **not** fire on `voice-note` or
`linkedin-notification` types even if their `participant-hints` happen to
contain a matching string — the type gate is checked first.

Sender pattern — any `participant-hints` entry (or, if the connector wrote
a `From:` header into the body, that header) matching, case-insensitive:

```regex
(?i)\b(no-?reply|do-?not-?reply|donotreply|newsletter|marketing|notifications?)@
```

Concretely, as a jq test over an event whose frontmatter has been parsed to
JSON (`participant-hints` as an array of strings):

```jq
(.type == "email") and
(.["participant-hints"] // [] | any(test("(?i)(no-?reply|do-?not-?reply|donotreply|newsletter|marketing|notifications?)@")))
```

### 2. `self-only-calendar`

Applies only to `type: calendar-event`. The body is the raw event JSON
(per `capture-event.md`'s calendar example). Holds when the parsed
`attendees[]` array has zero entries beyond the user's own — i.e. every
attendee entry is either absent or is the user themself (`self: true`), or
the array is empty/absent and the event is otherwise organizer-is-self with
no guests.

```jq
(.type == "calendar-event") and
(.body_json.attendees // [] | map(select((.self // false) | not)) | length == 0)
```

Concretely: an `attendees` array of length 0, or one containing only the
entry with `self: true`, both hold; any entry lacking `self: true` (a real
other-party guest) blocks the hold — falls through to judgment.

### 3. `otp-security`

Applies only to `type: email`. Subject (the first `Subject: ...` line of
the body, per the capture-event example format) matches:

```regex
(?i)\b(verification code|one-?time (code|passcode)|otp|security alert|new sign-?in|sign-?in attempt|confirm your (email|account)|2fa|two-?factor)\b
```

```jq
(.type == "email") and
(.subject // "" | test("(?i)(verification code|one-?time (code|passcode)|otp|security alert|new sign-?in|sign-?in attempt|confirm your (email|account)|2fa|two-?factor)"))
```

### 4. `linkedin-invitation`

Applies to `type: linkedin-notification`, or `type: email` whose sender
(`participant-hints` / `From:`) matches `@.*linkedin\.com`. Subject matches
an invitation pattern:

```regex
(?i)\b(wants to connect|invitation to connect|accepted your invitation|connection request)\b
```

```jq
((.type == "linkedin-notification") or
 (.type == "email" and (.["participant-hints"] // [] | any(test("(?i)@[a-z0-9.-]*linkedin\\.com")))))
and (.subject // "" | test("(?i)(wants to connect|invitation to connect|accepted your invitation|connection request)"))
```

Other LinkedIn notifications (post likes, job alerts, "X commented", etc.)
do **not** match this pattern and fall through to judgment — this rule is
narrowly scoped to the invitation subtype only, since other LinkedIn
notification subtypes are not conservatively distinguishable from
low-value-but-real signal without wider calibration data (plan-26 unit 12).

### 5. `cold-pitch`

The weakest rule — when in doubt it must not fire. Applies only to
`type: email`, and only when **all** of the following hold:

- **Single-message thread.** No `In-Reply-To:`/`References:` header or
  equivalent thread marker in the body (a first-contact message only — a
  reply in an existing thread never matches, regardless of content).
- **Unknown sender.** The sender identifier (from `participant-hints`)
  matches no contact detail in `index.json` or any `people/*.md` file — a
  deterministic store lookup, not a judgment call.
- **Strong pitch phrasing.** Subject or body matches:

```regex
(?i)\b(quick (question|intro)|are you the right person|i (came across|noticed) your (company|profile)|book a (demo|call)|unsubscribe (from this list|here)|following up on my (last|previous) (email|message)|reaching out because)\b
```

```jq
(.type == "email") and
(thread_has_no_reply_markers) and
(sender_unknown_to_store) and
((.subject // "") + " " + (.body // "") | test("(?i)(quick (question|intro)|are you the right person|i (came across|noticed) your (company|profile)|book a (demo|call)|unsubscribe (from this list|here)|following up on my (last|previous) (email|message)|reaching out because)"))
```

`thread_has_no_reply_markers` and `sender_unknown_to_store` are named
predicates standing in for, respectively, a header/body scan for
reply/reference markers and the `index.json`/`people/` lookup — both
deterministic, both to be spelled out concretely by the checker script that
implements this spec. Both the unknown-sender **and** the strong-phrasing
condition are required together; either alone is not sufficient to hold —
a known sender using pitch-like phrasing (e.g. a colleague joking "quick
question") is common and must not be held, and an unknown sender with a
plain, non-pitch subject must not be held either.

### 6. `noise-sender`

Added by plan 36 unit C1, after live-corpus calibration surfaced a large
remainder-time class the first five rules miss entirely: CI notices,
security notices, newsletters, and GitHub/Vercel/Slack/Google-Workspace
system notifications — none of them `noreply@`-shaped, so rule 1 never
catches them. Applies only to `type: email`, checked last (after rule 5).

Unlike rules 1–5, this rule is **table-driven**, not an embedded regex:
its pattern source of truth is `packages/ingestion/config/noise-senders.tsv`,
a tab-separated `name<TAB>regex<TAB>scope` table (`#`-prefixed and blank
lines ignored; `regex` is `grep -E -i`; `scope` is `from` — matched against
`participant-hints` plus a connector-written `From:` body header, same
extraction as rule 1 — or `subject` — matched against the `Subject:`
line only). Rows are checked in file order; the first matching row wins.

An optional **local override table** lives at
`<data-dir>/noise-senders.local.tsv` (same columns), read after the
shipped table. A local row whose `name` matches a shipped row's `name`
**replaces** that shipped row entirely (the shipped pattern is dropped,
not additionally applied) — this is the escape hatch for a user's private
corpus turning up a false-positive or a new noise class the shipped table
doesn't cover, without editing `packages/` at all.

Held reason is written to the D3 ledger as `noise-sender:<name>`
(e.g. `noise-sender:ci-sender`), not a bare rule name — the ledger's
`per-rule=` summary counter aggregates all names under one
`noise-sender:<n>` total.

Precision-first (D4) applies here as strictly as the other five rules:
every shipped pattern is scoped to a specific system/notification
local-part or domain, never a bare personal domain, and a pattern that
would otherwise collide with an already-covered class (e.g. a bare
`notifications@`/`noreply@` local part, already owned by rule 1's
domain-agnostic match) is deliberately narrowed or dropped rather than
duplicated as dead code. Two shipped subject-scope rows
(`verification-code-subject`, `security-alert-subject`) are present in
the table for documentation/future-proofing even though, for `type: email`,
rule 3 (`otp-security`) always matches the identical subject phrasing
first — first-match-wins means they are currently unreachable in practice
for `type: email`, which is expected and not a bug.

## Group-noise deferral (future work)

Non-participating group-chat noise (e.g. a group thread where the user
never spoke and the other participants are all strangers) is **not**
covered by any rule above, and is explicitly deferred — it is a
cross-event, cross-conversation property (participation across a thread
over time), not a per-event deterministic test computable from one event
file in isolation, so it cannot meet the "deterministic checkability" bar
this spec holds every rule to. It remains judgment's territory for now,
recorded as future work for chunk 30.

## Out of scope

- The `triage-inbox.sh` checker script's implementation (argument parsing,
  jq/regex engine specifics, exit codes) — a later plan-26 unit.
- The debrief skill's batch-mode exclusion-check wiring — a later plan-26
  unit amends `packages/ingestion/skills/debrief/SKILL.md` §1 to add the
  `triage-held.log` exclusion alongside the existing `debrief-filed.log`
  one.
- Live-corpus calibration and any pattern tightening it motivates — plan-26
  unit 12.
- Group-noise detection — chunk 30, per "Group-noise deferral" above.
