# Fixture: personalization overlay

Layers the plan-11 personalization artifacts (`profile.md`,
`ranking-weights.json`, wakeup v1.1 files) onto the 30-persona base store at
`packages/core/fixtures/store/`, for plan-12 T1/T2 evals that exercise
opt-outs, weights, and v1.1 wake-up fields. All dates are relative to
2026-08-29 (the eval harness's reference "today").

## How to overlay

```bash
tmp=$(mktemp -d)
cp -R packages/core/fixtures/store/. "$tmp/"
cp packages/query/tests/fixtures/personalization-overlay/profile.md "$tmp/"
cp packages/query/tests/fixtures/personalization-overlay/ranking-weights.json "$tmp/"
cp -R packages/query/tests/fixtures/personalization-overlay/wakeups/. "$tmp/wakeups/"
bash packages/core/scripts/validate-store.sh "$tmp"
rm -rf "$tmp"
```

Never overlay onto `packages/core/fixtures/store/` in place — always copy
first. This fixture set adds files only; it never modifies or removes any
base-store file (`james-okafor`'s existing `2026-09-05` pending wake-up in
particular is untouched — its primacy as the "most overdue" answer for the
`most-overdue` T2 case is load-bearing and must survive the overlay).

## Files and what each exercises

### `profile.md`

- `## Priorities`: one stated priority ("family first this quarter") for the
  `stated-outranks-revealed` T2 case — a personalization-aware answer should
  favor family-tagged contacts over work ones when the two conflict.
- `## Signal opt-outs`: `**[stated-by-user]** birthday — all` — the opt-out
  target. A personalization-aware `suggest_reachouts` must suppress every
  `signal-type: birthday` wake-up store-wide, not just for one person (`all`,
  not `[[slug]]`). No trailing date parenthetical on this bullet: unlike
  `## Priorities`/`## Cadence wishes`/`## Style notes`, the contract's grammar
  for opt-out bullets is stricter (`<signal-type> — all` or `<signal-type> —
  [[slug]]`, nothing after), and `validate-store.sh`'s opt-out regex rejects
  a trailing `(date)` — confirmed empirically while producing this fixture.
- `## Cadence wishes` and `## Style notes` are present but empty, per the
  contract's "empty is valid" allowance — the schema's fixed four sections
  are all still there for `validate-store.sh` to walk.

### `ranking-weights.json`

- `signal-types.birthday`: damped to `0.85` — a birthday-type signal that
  survives (e.g. in a build where opt-outs and weights compose, or in a
  future case that doesn't opt out but does calibrate) should rank lower.
  Rationale is dated and names the outcome pattern (dismiss history), per the
  interpretability contract.
- `tags.college-friend`: boosted to `1.15` — matches the `college-friend` tag
  on `priya-anand` (`packages/core/fixtures/store/people/priya-anand.md`) in
  the base store, so a weights-aware fallback score for her should multiply
  up rather than sit at the neutral `1.0` default.
- Both entries are well inside the `[0.25, 2.0]` clamp and the `<=0.15`
  per-step-from-neutral bound.

### `wakeups/` (schema_version 1.1.0, new ids — none collide with the base
store's existing `wakeups/*.md` filenames or `id` fields)

| File | Person (real store slug) | `status` | Exercises |
|---|---|---|---|
| `2026-09-10-marcus-chen--2.md` | `marcus-chen` (birthday `--09-10`, within 30d of 2026-08-29) | `pending` | **The opt-out suppression target.** `signal-type: birthday`, `origin: standing`. A personalization-aware `suggest_reachouts` must NOT surface this entry (opt-out applies at signal-type granularity, `all`). The base store already has a pre-1.1 birthday entry for the same person/date (`packages/core/fixtures/store/wakeups/2026-09-10-marcus-chen.md`, `schema_version: 1.0.0`, no `signal-type` field) — this overlay file is the explicit 1.1.0 version carrying the field the opt-out check needs, hence the distinct `--2` id per the contract's `[--<n>]` filename convention. |
| `2026-08-20-ravi-kapoor.md` | `ravi-kapoor` | `dismissed` | `dismiss-reason: not-this-signal-type` + `fired-on: 2026-08-20`. Exercises the 1.1.0 dismissed-must-carry-a-reason validator rule and gives calibration/ranking-weights context a concrete outcome record to point at (mirrors the `birthday` damping rationale's kind of evidence, one dimension over). |
| `2026-08-22-priya-anand.md` | `priya-anand` (tag `college-friend`, matches the boosted weight above) | `fired` | `fired-on: 2026-08-22` + `acted-on: true` — a fired, acted-on-within-window outcome record. |
| `2026-09-25-katarina-novak--2.md` | `katarina-novak` | `pending` | `snooze-count: 2` — exercises the snooze-history-survives-the-rewrite field; `due` reflects the post-snooze date per the contract's snooze convention. |

## Hand-derived expectations (for evals to assert against)

These are derived by hand from the files above, not read off any system
output, per `docs/DECISIONS.md#golden-tests-before-prompts`:

1. **Opt-out suppression:** with the overlay applied, `suggest_reachouts`
   should NOT include `marcus-chen`'s birthday wake-up
   (`2026-09-10-marcus-chen--2`) in its candidate set, because
   `profile.md`'s `birthday — all` opt-out applies store-wide. (It also
   should not surface the base store's own `2026-09-10-marcus-chen.md`,
   though that file predates the `signal-type` field and only carries
   `why: "birthday"` as text — a fully compliant suppression path keys off
   `signal-type`, so this pre-1.1 file is a secondary, text-only signal for
   a suppression implementation to also catch, not the primary assertion.)
2. **Weight multiplication:** a weights-aware fallback score for `priya-anand`
   (tag `college-friend`) should be `1.15x` the unweighted score; a
   weights-aware score for any surviving `birthday`-type signal (if opt-outs
   were not in play) would be `0.85x`.
3. **v1.1 field round-trip:** all six query tools must succeed against this
   overlay without error — `2026-08-20-ravi-kapoor.md`'s dismissed status
   with a non-null `dismiss-reason`, `2026-08-22-priya-anand.md`'s
   `acted-on: true`, and `2026-09-25-katarina-novak--2.md`'s
   `snooze-count: 2` are all valid 1.1.0 shapes per the contract and must
   round-trip through reads unchanged (store byte-identical after a read-only
   tool sweep).

## Known gap this fixture set backs (xfail until plan-13)

`suggest_reachouts` (all six query tools, per plan 08) does not yet read
`profile.md` or `ranking-weights.json` — expectations 1 and 2 above are
**xfail** cases (`xfail: plan-13 query-personalization integration`) until a
follow-on plan wires opt-out suppression and weight multiplication into
query's ranking path. Expectation 3 (v1.1 field round-trip) is must-pass
today: it exercises only the wakeup contract's frontmatter shape, not the
personalization integration gap. Flipping 1 and 2 to must-pass is plan-13's
proof of done (`docs/plans/2026-08-29-12-eval-harness.md`, "Known gap pinned
as xfail").
