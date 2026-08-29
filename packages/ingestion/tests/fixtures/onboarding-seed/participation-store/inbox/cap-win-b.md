---
schema_version: 1.2.0
id: cap-win-b
source: gmail-in/gmail
captured_at: 2026-01-01T10:00:00Z
type: email
participant-hints:
  - "faye.fixture@example.com"
  - "me@example.com"
---
Subject: out-of-window self-authored

Out-of-window fixture email, self-authored — MUST be ignored by
derive-participation.sh when the run's window-start is after this date;
proves out-of-window interactions contribute nothing.
