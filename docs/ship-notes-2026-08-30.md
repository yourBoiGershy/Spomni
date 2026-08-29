# Ship notes — 2026-08-30 (chunk 20: backfill blitz & ship-day shakedown)

Run date: 2026-08-29. Plan: `docs/plans/2026-08-29-20-backfill-shakedown.md`.
PII rule: events referenced by capture-event id + lane only; person-level detail
lives in the private data dir companion note (`data/ship-notes-private.md`,
never in this repo).

## Manifest & outcome (counts)

- Phase 0 baseline: **45** fileable inbox events + empty `quarantine/`
  (roadmap said 46 incl. 1 quarantined — stale; observed manifest is the
  loss baseline).
- Outcome: **15 filed** (ledger), **27 held** in inbox (reasons below),
  **3 quarantined** with written reasons — **45/45 accounted, zero loss**
  (all originals present in `inbox/` or `inbox/quarantine/`; inbox was
  append-only throughout; pre-blitz snapshot tarball in private
  `data/backups/`).
- Store after run: 21 people, 15 interactions, index + stats rebuilt,
  `validate-store.sh` exit 0 (36 files), `check-sync.sh` exit 0
  (52 events incl. 10 fresh new-lane captures; 17 accepted legacy WARNs).
- 10 fresh events arrived mid-run from the new direct lanes
  (6 calendar-in, 1 beeper-in, 3 gmail-in) — all conformant to
  capture-event 1.2.0, all held on filing review (holidays/future
  events/solo entries/automated senders). This closes the plan-14 caveat's
  live-verification for the new lanes' field shapes.

## Filing pass (6 batches of ≤8, sequential workers + checker pairs)

- Batches 1–2 (16 gmail/calendar events): all held — automated/marketing/
  bot senders or the user's own solo calendar entries. Correct per the
  debrief skill's not-a-person / zero-match rules.
- Batches 3–6 (beeper + remainder): 15 filed across 21 people; checker
  pairs after every batch (integrity + fidelity spot-audits) — all
  integrity checks green throughout.

## Triage table (held/quarantined, by id + lane + reason class)

Disposition `hold-for-context` = stays in inbox, eligible for a future pass.

| event id | lane | reason class | disposition |
|---|---|---|---|
| 20260824T000000Z-googlecalendar-5e1a | calendar (legacy) | solo calendar entry, no counterpart | hold-for-context |
| 20260824T013000Z-googlecalendar-df1e | calendar (legacy) | solo calendar entry, no counterpart | hold-for-context |
| 20260828T230558Z-gmail-0676 | gmail (legacy) | automated (CI notification) | hold-for-context |
| 20260828T230836Z-gmail-9745 | gmail (legacy) | automated (CI notification) | hold-for-context |
| 20260828T231935Z-gmail-c398 | gmail (legacy) | automated (CI notification) | hold-for-context |
| 20260828T233433Z-gmail-9bcc | gmail (legacy) | marketing | hold-for-context |
| 20260829T035410Z-gmail-cff5 | gmail (legacy) | newsletter | hold-for-context |
| 20260829T041113Z-gmail-e863 | gmail (legacy) | automated reminder | hold-for-context |
| 20260829T041146Z-gmail-04f2 | gmail (legacy) | platform auto-invitation (named human behind it — user question pending) | hold-for-context |
| 20260829T054752Z-gmail-adfa | gmail (legacy) | automated (CI notification) | hold-for-context |
| 20260829T061146Z-gmail-e416 | gmail (legacy) | platform auto-invitation (named human behind it — user question pending) | hold-for-context |
| 20260829T100509Z-gmail-1703 | gmail (legacy) | marketing | hold-for-context |
| 20260829T123824Z-gmail-3bed | gmail (legacy) | marketing (mass blast) | hold-for-context |
| 20260829T131542Z-gmail-4e46 | gmail (legacy) | automated (terms notice) | hold-for-context |
| 20260829T145038Z-gmail-f440 | gmail (legacy) | automated (account notice) | hold-for-context |
| 20260829T145151Z-gmail-6d2e | gmail (legacy) | automated (security alert) | hold-for-context |
| 20260829T145220Z-gmail-fdd6 | gmail (legacy) | automated (security alert) | hold-for-context |
| 20260829T150640Z-linkedin-aad2 | linkedin (legacy) | transport wrapper leak; self-referential payload | **quarantined** |
| 20260829T184410Z-beeper-0d67 | beeper | cold solicitation | hold-for-context |
| 20260829T184410Z-beeper-5586 | beeper | cold pitch; possible identity link to an existing person — user question pending | hold-for-context |
| 20260829T184410Z-beeper-589c | beeper | cold solicitation | hold-for-context |
| 20260829T184410Z-beeper-7dde | beeper | company broadcast channel | hold-for-context |
| 20260829T184410Z-beeper-8cdb | beeper | cold solicitation | hold-for-context |
| 20260829T184410Z-beeper-94bc | beeper | cold outreach | hold-for-context |
| 20260829T184410Z-beeper-a0a2 | beeper | cold connect | hold-for-context |
| 20260829T184410Z-beeper-a637 | beeper | self-only chat (no counterpart) | hold-for-context |
| 20260829T184410Z-beeper-cba5 | beeper | thin greeting, below new-person bar — user question pending | hold-for-context |
| 20260829T184410Z-beeper-e708 | beeper | group logistics chatter, no participant clears bar (checker-confirmed defensible) | hold-for-context |
| 20260831T223000Z-googlecalendar-37d5 | calendar (legacy) | malformed captured_at (future; retired lane copied event start); real upcoming event, will re-capture via calendar-in | **quarantined** |
| 20260907T000000Z-googlecalendar-e566 | calendar (legacy) | malformed captured_at; holiday, no participants | **quarantined** |

Fresh (post-manifest) events, all held: 6 calendar-in (3 holidays, 2 future
events, 1 solo past entry — 1 of these ambiguous pending a user identity
question), 1 beeper-in (automated OTP notices), 3 gmail-in (automated
security/login notices).

## Fix round (the plan's single dispatch round — used once)

- **Systemic date defect (store-data, fixed):** batches 3–4 filed
  interactions with `date` = filing date because legacy pre-1.2.0 events
  carry no `occurred_at` and the skill's documented fallback is
  `captured_at`. 9 interactions re-dated to their true touchpoint dates
  (derived from latest genuine message, bot/system notices excluded), files
  renamed, 9 people's `last-touch` recomputed, index/stats rebuilt.
  Batches 5–6 ran with an orchestrator date override and were correct at
  filing time.
- Two small store-data fixes: one over-generalized fact restated to its
  single supported instance; one person's name completed from a
  self-provided email (slug kept stable).
- 3 quarantine moves (table above) cleared all 3 baseline check-sync FAILs.

## Fresh-sweep round-trip

- **beeper: PROVEN end to end.** Today's sweep captured real chats →
  inbox → filed → `get_interaction` cites the capture id
  (`20260829T184410Z-beeper-3e3f` → `2026-08-23-khizar`). Manual trigger
  re-run: `ok chats=25 events=0` (lane reachable; no new traffic at that
  moment). A fresh beeper-in/WhatsApp capture (20:55Z) also landed and
  passed conformance.
- **gmail: capture→inbox→conformance PROVEN** (3 fresh gmail-in events,
  check-sync clean). The filed→query leg has no specimen: every gmail event
  in the real corpus (15 legacy + 3 fresh) is automated/marketing — no
  human interaction to file. Pending: a real human email (user-assisted)
  or explicit accept-and-ship (recorded below when decided).

## Query shakedown (six for six)

All six `spomni-query` tools returned real, cited answers against the filed
store via a freshly spawned server: search matches by slug/stats; person
records carry provenance tags; interaction records cite real capture ids;
stats rollups match the ledger; reachout suggestions carry transparent score
breakdowns citing store files. Evidence transcripts (contain PII) in the
private companion note.

## Known issues (ship with these)

1. **Query server boot-time snapshot:** the MCP server refreshes
   index/stats only at startup (`packages/query/server/src/store/staleness.ts`
   — `ensureFresh` runs once in `src/index.ts`). A long-lived session serves
   stale search/list/stats after new filings (observed live: 4 of 6 tools
   stale until reconnect). Workaround: reconnect the MCP server. Post-ship
   fix candidate: re-run staleness check per call or on an interval.
2. **Debrief skill date fallback:** with `occurred_at` absent the skill
   files at `captured_at` (sweep time), which misdates thread interactions
   (root cause of the fix round above). Post-ship: derive touchpoint date
   from latest genuine message when `occurred_at` is absent. Legacy-only
   for capture; new lanes emit `occurred_at`.
3. **Filing never builds `stats.json`:** skill §5c rebuilds the index only;
   stats existed nowhere until built manually this run. Post-ship: add
   `build-stats.sh` to §5c (or rely on the query server's cache once
   issue 1 is fixed).
4. **launchd beeper schedule TCC-blocked** on ~/Documents (chunk 19 note);
   sweeps run manually/via scheduler sessions today. Pending user TCC grant
   or repo relocation.
5. **Legacy composio-era defects** (all contained): wrapper leak in 1
   event, future `captured_at` in 2 calendar events — all quarantined; the
   composio-in teardown itself is chunk 17 (in progress in a parallel
   worktree, uncommitted at run time).
6. **Roadmap manifest drift:** roadmap's "46 events incl. 1 quarantine" did
   not match observed 45 + 0; observed manifest used as baseline.
7. Possible dupes/mis-merges: 2 identity questions open (a cold-pitch
   sender vs. an existing person; an attendee email vs. an existing
   person); person-level detail in the private note. No confirmed dupes.

## Gate verdict (as of 2026-08-29, end of run)

- [x] 100% of manifest accounted (15 filed / 27 hold / 3 quarantined)
- [x] `check-sync.sh` exit 0
- [x] `validate-store.sh` exit 0
- [x] Fresh-sweep round-trip — beeper (full); gmail capture-leg proven,
      filed→query leg awaiting a human-email specimen or user accept
- [x] All six query tools: real cited answers (fresh server)
- [x] Ship notes written (this file)
- [x] Zero data loss (manifest superset check, snapshot intact)

**No NO-GO condition present** (no data loss). Outstanding for the user:
the gmail filed→query specimen decision, the open identity questions, and
the user pass over the people list — none are loss-class.

## GO decision (2026-08-29, user)

**GO — merged.** The gmail filed→query leg is **accepted as a known gap**
(closes naturally with chunk 17's lanes + the first human email). Identity
questions remain open in the private note; held events stay held (no-guilt).
Follow-ups adopted into the roadmap: chunk 22 (live-data query sync &
verification — query-chat test; mostly satisfied by this run's Phase 5), and
**chunk 24** — onboarding deep backfill (configurable window, default 6
months) & participation-signal priority seeding (interaction/event boosts;
unanswered or non-participating contacts seeded very low). Chunk-20 examples
feeding 24's design are recorded in the private companion note.
