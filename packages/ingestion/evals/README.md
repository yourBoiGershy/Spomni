# Ingestion evals

These T3 (skill-tier) cases wrap the six existing stated-preference goldens
(`packages/ingestion/tests/goldens/preferences/*`) as executable evals —
each case's `store`/`expected` frontmatter fields point at a golden's
`before/`/`expected/` directories rather than copying them, so the golden
fixtures stay the single source of truth for expected deltas. All six carry
`runnable-when: "03"` and report `SKIP` from `eval-run-skill.sh` until plan
03's filing engine exists; once it lands, drop `runnable-when` from each
case's frontmatter to flip them from SKIP to live, must-pass cases.
