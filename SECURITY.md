# Security policy

Spomni handles the most sensitive data a person has: who they know, what was
said, and what they promised. Reports that touch any of that get priority.

## What counts

Anything that violates a standing principle counts as a security issue, not
just classic vulnerabilities:

- **Data leaves the machine.** Any path by which the people-store, inbox, or
  derived index reaches a third party — including logs, crash reports, eval
  outputs, or a connector writing outside the user's data dir.
- **Something sends without a human.** Any code path that can send a message,
  email, or calendar response without the user pressing send.
- **Enrichment or scraping.** Any lookup of a third person against an external
  source that isn't a first-party account the user explicitly linked.
- **Secrets at rest.** Tokens (Beeper API token, OAuth material) written with
  permissive modes or into a tracked path.
- **Provenance mixing.** Told-by-the-user facts and inferred facts becoming
  indistinguishable.
- The usual: command injection through filenames/message content into the bash
  pipeline, path traversal out of the data dir, unsafe `eval`.

## Reporting

Please **do not open a public issue** for anything in the list above.

Use GitHub's private vulnerability reporting on this repository
(*Security → Report a vulnerability*). If that is unavailable, email the
maintainer address listed on the GitHub profile of the repository owner with
the subject `spomni security`.

Include: what you found, a minimal reproduction (synthetic data only — never
real people), and the commit you tested against.

You'll get an acknowledgement within 7 days and a fix or a plan within 30.
Credit is given in the release notes unless you ask otherwise.

## Scope notes

- Test fixtures and goldens must be synthetic. If you find a real person's
  data in the repo, that is a report — see above.
- The repo's own CI runs `.claude/scripts/oss-guard.sh` (data-dir tripwire,
  secret scan, PII scan, draft-never-send lint, enrichment-host denylist). A
  way to get past it silently is in scope.
