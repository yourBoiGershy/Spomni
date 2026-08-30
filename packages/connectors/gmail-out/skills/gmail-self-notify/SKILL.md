---
name: gmail-self-notify
description: Session-driven fallback nudge delivery — emails any pending rendered wake-up batch to the user's own gmail_address (stated in profile.md ## Notify) via the first-party claude.ai Gmail connector, self-recipient only.
---

# Gmail self-notify

Delivers pending nudge cards by email, to the user's own inbox only. This
is the fallback channel `deliver-tick.sh` falls back to when the resolved
channel is `gmail-self`: the headless tick cannot send email itself (no
first-party Gmail connector outside a live session), so it writes the
rendered text to `<store-dir>/outbox/pending-gmail/<batch>.txt` and logs
`deliver: gmail-self pending (session)`; this skill (a session) finishes
the delivery.

**Hard rule — draft, never send: for anyone other than the user's own
`gmail_address`.** The only permitted recipient of any email this skill
sends is the address the user themselves stated in `## Notify`. This is
the self-notify exception (`notify-self-is-a-send`, `docs/DECISIONS.md`) —
a message to the user's own inbox is not a send to another person, it is
the assistant reaching the user. This skill never emails anyone else, never
infers an address from anywhere but `## Notify`, and never CCs or BCCs.

## Step 1 — resolve the recipient

Read `<store-dir>/profile.md`, `## Notify` section, the `gmail_address`
bullet:

```
- **[stated-by-user]** gmail_address: x@y (date)
```

Extract the address (strip the provenance tag and the trailing date). If
the `## Notify` section is absent, or present but has no `gmail_address`
bullet, **stop** — do not proceed to Step 2, do not guess or infer an
address from any other source (profile, people-store, past emails). Print:

```
skip: no gmail_address in ## Notify
```

## Step 2 — send each pending batch

For each file in `<store-dir>/outbox/pending-gmail/*.txt` (skip if the
directory is empty or absent — that is the normal "nothing pending"
state, not an error):

1. Read the file's text (the rendered card text `deliver-tick.sh` wrote,
   verbatim — this skill does not re-render or edit it).
2. Call `mcp__claude_ai_Gmail__send_message` with:
   - `to`: the address resolved in Step 1, and **only** that address —
     never any other recipient, never a CC/BCC.
   - `subject`: `Spomni: <today>` (today's date, `YYYY-MM-DD`).
   - `body`: the file's text, unmodified.
3. On success, append one line to `<store-dir>/outbox/delivered.log`:
   ```
   <batch-name>	gmail-self	<ISO 8601 Z timestamp>	<message-id>
   ```
   where `<batch-name>` is the pending file's basename (without `.txt`)
   and `<message-id>` is the id the send tool returned. Then delete the
   pending file.
4. On failure, leave the pending file in place (do not delete it, do not
   append to `delivered.log`) so the next run retries it; continue to the
   next pending file rather than aborting the whole run.

## Step 3 — summary

Print one of:

```
gmail-self: sent n=<k>
```

if at least one file was sent this run, or:

```
gmail-self: nothing pending
```

if `outbox/pending-gmail/` was empty or absent (and Step 1 resolved an
address — a Step 1 stop prints its own `skip:` line instead and this
summary is not printed).
