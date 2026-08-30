# Plan 28: Sync timing & autonomous runtime

Status: Built — U1–U4 landed (suites store 10 / capture 116 / beeper 109 /
scheduler 92 green; fix round 1: watchdog subshell reaped its own sleep so
`$(...)` callers no longer block); U5.1 done; U5.2–U5.5 live verification
(preflight, first scheduled ticks, fetch-only proof = plan-26 U12.3,
reboot sim) awaits a user session with the first-party connectors. SETUP.md
§5a added (U5.6).
Package: connectors (headless-tick wrapper + scheduler-suite extension) +
core (sync-lanes template rows, one editorial contract note) + docs
(SETUP.md ops steps — orchestrator-editable)
Depends-on: 19 (sync-lanes 1.0.0 + scheduler, live under launchd), 26
(import-pipeline 1.0.0 — fetch-to-file, page-budgeted sweeps); extends 09
(always-on runtime, Later)
Branch: chunk-28-autonomous-sync

## Objective

gmail and calendar join `lanes.tsv` and fire on schedule with **no manual
step**. The only reason they can't today: their fetch stage is a first-party
claude.ai MCP tool call, which exists only inside a live Claude session —
launchd alone can't provide one. After chunk 26 the in-session requirement
shrank to exactly the fetch call (everything from the saved tool-result file
onward is cp/jq/scripts), so a scheduled session is thin and cheap. This
chunk builds that session: a headless-tick wrapper a lane row's command can
point at, which runs `claude -p` invoking the sweep skill under hard cost
caps; per-lane intervals chosen deliberately (each tick is a model session);
catch-up on wake inherited from 19; testable end to end against a stub
`claude` binary.

## Context (what already exists — workers do not rebuild)

- **Scheduler (19):** `sync-scheduler.sh` runs any lane whose row is
  `lane<TAB>interval_seconds<TAB>enabled<TAB>command` in
  `<data-dir>/connectors/sync-scheduler/lanes.tsv`; command is an
  absolute-path invocation run via `/bin/bash -c` under launchd's minimal
  env (`PATH=/usr/bin:/bin:/usr/sbin:/sbin`, no shell profile). State
  (`state/<lane>.tsv`), log rotation, `status` (LANE ENABLED INTERVAL
  INSTALLED LAST_RUN LAST_EXIT NEXT_RUN), install/uninstall/prune, and
  reboot survival all apply to any lane for free. Catch-up on wake:
  launchd coalesces missed `StartInterval`s to one run; lane
  cursors/checkpoints absorb the gap. Config is fail-closed; skip
  conditions exit 0.
- **Sweeps (26):** `gmail-sweep` and `calendar-sweep` SKILLs are already
  fetch-to-file conformant: step 0 enumerates the `mcp__claude_ai_Gmail__*`
  / `mcp__claude_ai_Google_Calendar__*` tools and **stops on mismatch**
  (fail-closed); step 1 fetches at max page sizes under an explicit
  **per-run page budget**; steps 2+ are cp/jq/scripts on the saved
  tool-result file. Hard rule (import-pipeline 1.0.0): raw item bodies are
  never transcribed by the model — only ids, dates, counts, page tokens,
  file paths transit model context.
- **Template:** `packages/core/templates/sync-lanes.tsv` already carries
  commented gmail/calendar placeholder rows.
- **Tests:** `packages/connectors/tests/run-scheduler-tests.sh` — 64 tests,
  bash 3.2, never calls launchctl (dry-run only). New scheduler-adjacent
  work extends this harness in the same style.
- Residual U12.3 (plan 26): live gmail/calendar fetch-to-file page proof —
  **this chunk's first scheduled live tick doubles as that proof.**

## Decisions (made here, binding on all units)

**D1 — Runtime: headless `claude -p` under the existing launchd scheduler.
Cloud/scheduled agent REJECTED.** Rationale: (a) local-first doctrine — the
people-store and data dir live on this machine and never leave it; a cloud
agent cannot reach them, and shipping them up is a standing-principles
violation, not an option; (b) chunk 19's runner needs zero changes — a lane
command is just a string, so the entire feature is one wrapper script the
gmail/calendar rows point at; state, logs, status, reboot-safety, and
catch-up are inherited; (c) an always-on/cloud runtime is chunk 09/Later
territory — building it here would be scope theft from a chunk that owns
the portability story. The cloud option is recorded as the rejected
alternative; nothing in this design forecloses it (a future 09 runtime
would swap the wrapper's interior, not the lane rows).

**D2 — The wrapper: `packages/connectors/scripts/mcp-lane-tick.sh`.** One
script, two subcommands, bash 3.2, no jq needed. It is the lane command for
every MCP lane; the scheduler treats it like any other command (stdout+
stderr into the lane log, exit code into state).

`tick` — the scheduled entrypoint:

```
mcp-lane-tick.sh tick \
  --claude-bin <abs-path> \            # required; launchd PATH won't find claude
  --prompt "<slash-command line>" \    # e.g. "/gmail-sweep pages=4"
  --allowed-tools "<csv>" \            # required; pinned per lane, see D3
  [--max-turns N]      \               # default 50; passed to claude -p
  [--timeout-seconds N] \              # default 900; wrapper-enforced watchdog
  [--expect <regex>]                   # default 'sweep-ok'; summary-line gate
```

Behavior: exec `"$CLAUDE_BIN" -p "$PROMPT" --permission-mode
acceptEdits --allowedTools <csv> --max-turns N` in the background with
output captured; a watchdog subshell (bash 3.2 portable — background child
+ `sleep`/`kill`, SIGTERM then SIGKILL after a 15s grace; macOS ships no
GNU `timeout`) kills it at `--timeout-seconds`. On completion the wrapper
gates success on the sweep's own summary line: output must match
`--expect` (the sweeps end with `sweep-ok ...` per their SKILLs). Exit
codes, each with a distinct log line so silence is impossible: `0` =
claude exited 0 AND summary matched (`tick-ok`); `3` = watchdog kill
(`tick-fail reason=timeout`); `4` = claude exited 0 but no summary line
(`tick-fail reason=no-summary` — a session that chatted instead of
sweeping is a failure, not a success); otherwise claude's own nonzero exit
propagates (`tick-fail reason=exit=<n>` — includes the step-0 tool-
mismatch stop and max-turns cap-hit). Every failure lands in
`state/<lane>.tsv` as a nonzero `last_exit` and shows in `status` — the
guardrail is *visible*, not just enforced.

`preflight` — one-shot connector verification (ops step, not per-tick):

```
mcp-lane-tick.sh preflight --claude-bin <abs> --lane gmail|calendar
```

Runs a minimal `claude -p` probe (`--max-turns 4`, same allowed-tools
pinning) whose prompt is: enumerate available tools, print the ones
matching the lane's MCP prefix, one per line, and nothing else. The
wrapper checks the lane's required tool names appear (gmail:
`search_threads`/`get_thread` family; calendar: `list_calendars`/
`list_events`) — missing → exit 2, `preflight-fail` line naming the absent
tools. This is the gmail-sweep step-0 mismatch rule surfaced as a cheap
shell-checkable probe, run before enabling a lane and whenever a tick
fails with the mismatch signature. Per-tick, the skill's own step 0
remains the fail-closed enforcement.

**D3 — Cost guardrail is three independent caps, all pure config in the
lane row.** (1) **Page budget** — carried in the prompt (`pages=<N>`),
bounds fetch volume; the sweep's checkpoint only advances on a fully
drained window, so a small budget trades latency, never coverage. (2)
**`--max-turns`** — bounds session length; a sweep that hasn't finished in
N turns is wedged or drifting, and the cap-hit exits nonzero into state.
(3) **Wall-clock watchdog** — bounds a hung tool call or stalled session
that turns can't catch. All three live in the `lanes.tsv` command string:
changing a budget is a config edit + nothing (the command is read per
run), same zero-code-edit bar as intervals. Allowed-tools pinning rides
here too: gmail lane gets exactly
`mcp__claude_ai_Gmail__*,Bash,Read,Write`; calendar
`mcp__claude_ai_Google_Calendar__*,Bash,Read,Write` — the file tools the
fetch-to-file mechanics need, and nothing else (no other MCP servers, no
web tools).

**D4 — Intervals: gmail 3600s, calendar 7200s, beeper unchanged at 900s.**
Deliberate, not inherited: beeper's 15 min is free (pure bash against
localhost); an MCP tick is a model session with real latency and spend.
Hourly email is well inside the product's cadence — Spomni nudges and
drafts, a human sends; nothing downstream is minute-sensitive. Calendar
mutates slower still, and the wake-up sweeps that consume it run daily.
Worst-case ceiling at these defaults: 24 + 12 = 36 model sessions/day,
each triple-capped per D3 — a bounded, predictable daily spend. These are
**template defaults only**; the numbers live in `lanes.tsv` (user-edited,
per sync-lanes 1.0.0) and the contract's interval floor (≥60) is
unchanged.

**D5 — What CI proves vs. what live verification proves.** Tests never
invoke a real `claude` binary or launchctl (harness rule). The suite drives
the wrapper against a **stub `claude` on PATH** that records its argv and
plays scripted behaviors (emit summary + exit 0; exit 0 without summary;
exit nonzero; sleep past the watchdog; print a tool list for preflight).
That proves: flag construction (allowed-tools/max-turns/permission-mode
present and exact), all four tick exit paths, watchdog kill, preflight
pass/fail, and scheduler integration (a stub-backed lane row runs under
`sync_run_lane`, state + log recorded). The **live** firing — real launchd
tick, real MCP fetch, conformant events, no manual step — is a documented
post-merge verification step exactly like plan 19's live section, and its
first gmail/calendar tick doubles as plan 26's deferred U12.3
fetch-to-file live proof (note the linkage in the close-out).

**D6 — Core changes are template + one editorial note; sync-lanes stays
1.0.0.** The contract's shape already covers this chunk (command is an
arbitrary absolute-path invocation). Template: uncomment/replace the
gmail/calendar placeholder rows with real `mcp-lane-tick.sh tick ...`
commands at D4 intervals, `enabled` **false** in the template (a fresh
user must run preflight and set `--claude-bin` before enabling — commented
guidance says so). Contract gains one editorial paragraph ("a lane command
may be a model session; interval choice is a cost decision — see the
template's MCP rows"), no schema change, no version bump.

## Work units

### Phase 1 — implementation + core config (one parallel message: one
connectors worker running U1→U2 serially, one core worker on U3)

**U1 [worker, connectors]. Wrapper tick path.** Depends-On: — |
Parallel-safe with U3.
Files: `packages/connectors/scripts/mcp-lane-tick.sh` (new).
Implement D2's `tick` subcommand exactly as pinned (flags, defaults,
watchdog, summary gate, exit codes 0/3/4/passthrough, one log line per
terminal state). bash 3.2 (`set -u`-safe, no assoc arrays), no deps beyond
/usr/bin — it must run under launchd's minimal PATH. Argument errors
(missing `--claude-bin`/`--prompt`/`--allowed-tools`) → exit 2 + usage on
stderr. Output discipline: everything to stdout/stderr, no files of its
own — the scheduler owns state and logs.
Brief carries: D2 + D3 verbatim; the sync-lanes command-environment rules
(minimal env, `/bin/bash -c`, skip-exits-0); the beeper lane row as the
existing-command exemplar.
Acceptance: `bash -n` clean; manual run against a fake `claude` (any
executable path) exercises exit 0/3/4 and passthrough; no bash-4isms.

**U2 [same warm connectors worker]. Preflight + manifests.**
Depends-On: U1.
Files: `packages/connectors/scripts/mcp-lane-tick.sh` (extend),
`packages/connectors/package.md` (provides row for the wrapper; note that
gmail/calendar lanes are scheduled headless via it),
`packages/connectors/gmail-in/package.md` +
`packages/connectors/calendar-in/package.md` (one line each: lane is
schedulable via mcp-lane-tick.sh; sweep semantics unchanged).
Implement D2's `preflight` subcommand: per-lane required-tool lists
inline in the script (gmail: the `search_threads`/`get_thread` tool
names; calendar: `list_calendars`/`list_events`), probe prompt, exit
2 + `preflight-fail` naming absent tools, exit 0 + `preflight-ok` with
the matched list. Manifest edits ride here per orchestration doctrine.
Brief carries: D2 preflight text verbatim; the exact
`mcp__claude_ai_Gmail__*` / `mcp__claude_ai_Google_Calendar__*` tool-name
prefixes; current connectors package.md Provides section.
Acceptance: preflight against a stub printing the full tool list exits 0;
against a stub omitting one required tool exits 2 naming it; manifests
updated, nothing else in them touched.

**U3 [worker, core]. Template rows + contract note.** Depends-On: — |
Parallel-safe with U1/U2.
Files: `packages/core/templates/sync-lanes.tsv`,
`packages/core/contracts/sync-lanes.md` (editorial note only, stays
1.0.0), `packages/core/package.md` (only if its template row text needs
the note — otherwise untouched).
Replace the commented gmail/calendar placeholders per D6: full
`mcp-lane-tick.sh tick` commands with D4 intervals (gmail 3600, calendar
7200), D3's allowed-tools strings, `pages=` budgets (gmail `pages=4`,
calendar `pages=2` as template defaults), `--max-turns 50
--timeout-seconds 900`, `enabled false`, and a comment block: run
`preflight` first, set `--claude-bin` to your absolute claude path, then
flip enabled + re-run `install`. Beeper row untouched. Add D6's one
editorial paragraph to the contract (no schema_version change — assert
this in the diff).
Brief carries: D3/D4/D6 verbatim; the template's current placeholder
block; the contract's command-column paragraph.
Acceptance: template still parses under `sync_lanes_list` semantics
(tabs, 4 fields, comments ignored); contract diff is prose-only,
version line unchanged.

### Phase 2 — tests (single worker; depends on Phase 1)

**U4 [worker, connectors/tests]. Scheduler-suite extension + stub
claude.** Depends-On: U1, U2, U3.
Files: `packages/connectors/tests/run-scheduler-tests.sh` (extend, 64
green today — same style: offline, bash 3.2, unique lane names, no
launchctl, no real claude), plus a stub `claude` fixture script the suite
places on PATH / passes via `--claude-bin` (lives under the tests dir).
Stub behaviors selected by env var: emit `sweep-ok pages=N
inline-spilled=0` + exit 0; exit 0 with no summary; exit 7; sleep 30;
print a tool list (full / one-missing) for preflight. Also record argv to
a file. Tests: (i) tick-ok path — exit 0, `tick-ok` logged; (ii) argv
contains `--allowedTools <exact csv>`, `--max-turns`, `--permission-mode`
as configured; (iii) no-summary → exit 4; (iv) claude exit 7 propagates;
(v) watchdog — sleeping stub with `--timeout-seconds 2` killed, exit 3,
`reason=timeout` logged, wall time bounded; (vi) preflight pass and fail
(exit 2, absent tool named); (vii) integration — a lanes.tsv row invoking
the wrapper with the stub runs via `sync_run_lane`: state records nonzero
on tick-fail, lane log carries the tick line; (viii) template file from
U3 passes config validation; (ix) missing required flag → exit 2 + usage.
Acceptance: suite green under bash 3.2; each new test fails under
momentary sabotage (then reverted); count reported.

### Phase 3 — verification + live proof (orchestrator-led)

**U5. Full suites, live firing, docs.** Depends-On: U4.
1. All suites green: store, capture, beeper-capture, scheduler
   (extended). No filing/eval surface touched → goldens/evals not re-run
   unless a collateral grep says otherwise.
2. **Live ops (user session, private data dir):** resolve the machine's
   absolute claude path; run `preflight` for both lanes (evidence: the
   `preflight-ok` tool lists); write the gmail+calendar rows into the
   live `lanes.tsv` (enabled true), `sync-scheduler.sh install`; verify
   `status` shows all three lanes with correct intervals.
3. **First scheduled ticks, no manual step:** wait out (or `launchctl
   kickstart`) one gmail and one calendar interval; evidence: state files
   show a run with exit 0, lane logs carry `tick-ok` + the sweep summary
   incl. `inline-spilled=<n>`, new events in `inbox/`, and
   `check-sync.sh <store>` clean.
4. **Fetch-only proof (doubles as plan-26 U12.3):** inspect the tick's
   session transcript/log — no message or event body appears in model
   output; saved tool-result file path + cp/jq actors visible. Record the
   U12.3 closure in this plan's close-out and the plan-26 memory note.
5. **Reboot-safety:** bootout + bootstrap the two new labels from their
   on-disk plists; confirm they reload and NEXT_RUN populates (plan 19's
   simulation, applied to the new lanes).
6. Cap-hit is stub-proven (U4); live cap-hit not required. `docs/SETUP.md`
   gains the enable-headless-lanes steps (claude path, preflight, enable,
   install) in the same commit as the fix per house rule — orchestrator
   edit, docs are orchestrator territory. ROADMAP row 28 → Done, memory
   note, plan Status → Done with evidence. Max 2 fix rounds; retry briefs
   carry diffs + failure output.

## Proof of done (maps to ROADMAP §28)

1. gmail + calendar rows in `lanes.tsv` fire under the scheduler with no
   manual step and land capture-event-1.2.0-conformant events —
   `check-sync.sh` clean (U3, U5.2–3).
2. `status` shows all lanes with last-run/next-run (U5.2).
3. A tick is proven fetch-only — no body transcription in the session
   transcript; plan-26 U12.3 residual closed by the same evidence (U5.4).
4. Reboot-safe like the rest of 19 (U5.5).
5. Cost guardrail proven: page budget + max-turns + watchdog all pure
   config; timeout-kill and cap-exit paths tested against the stub
   (U1, U4).
6. Scheduler suite extended and green alongside store/capture/beeper
   suites (U4, U5.1).

## Explicitly out of scope (adjacent chunks — do not pull in)

- **Chunk 09 / Later:** always-on box, cloud or scheduled-cloud agent
  runtime (D1's rejected alternative), remote store access.
- **Chunk 27:** sweep speed/cost optimization beyond the caps here; no
  changes to how sweeps fetch or file.
- **Chunk 29:** no new lanes, no contacts-in row.
- **Sweep skills themselves:** gmail-sweep / calendar-sweep SKILL.md are
  chunk-26 artifacts and are invoked as-is; if a live tick exposes a
  skill bug, that's a fix round with its own diff, not silent scope
  growth.
- **Scheduler internals:** `sync-scheduler.sh` / `sync-lib.sh` unchanged
  — the whole point of D1 is that they don't need to be.
- **Triage/judgment scheduling:** ticks end at the inbox (fetch +
  normalize); wiring triage or debrief into a schedule is not this chunk.
