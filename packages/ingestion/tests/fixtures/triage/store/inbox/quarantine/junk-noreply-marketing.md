---
schema_version: 1.2.0
id: junk-noreply-marketing
source: gmail-in
captured_at: 2026-08-01T09:30:00Z
type: email
participant-hints:
  - "marketing@quarantined-brand.example.com"
---
Subject: This is a quarantined junk event

This event lives under inbox/quarantine/ (malformed-event convention) and
must never be scanned by triage-inbox.sh, even though it would otherwise
match noreply-marketing if it were a normal top-level inbox/ event.
