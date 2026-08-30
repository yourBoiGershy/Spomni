#!/bin/bash
# git-guard.sh — PreToolUse hook for Bash.
# ENFORCES: the git safety doctrine in CLAUDE.md. Blocks destructive git
# (tier 0), WIP-loss git (tier 1), hook bypasses (--no-verify), and any
# commit/push while HEAD resolves to main/master — the last two scoped to
# the machinery repo only (see repo-scoping below). Also runs a pre-push
# secrets scan (oss-guard.sh --only secrets) before any git push out of the
# machinery repo.
# Block = exit 2 with "BLOCKED: <reason>" on stderr. Fails OPEN on parse
# errors (exit 0) — a broken guard must not brick the session.
# Bash 3.2 portable: no mapfile, no declare -A.
#
# Repo-scoping (plan 09 §7): the never-on-main / no-push-main rules apply
# only when cwd's `origin` remote matches the machinery repo (default regex:
# relationship-agent|Spomni, excluding a `-data` suffix — data repos use a
# direct-to-main flow and must not be blocked). Override the pattern via
# HARNESS_MACHINERY_REMOTE (extended regex matched against the origin URL).
# No origin at all (scratch repos) is treated as machinery (safe default).
# Destructive tiers 0/1 and --no-verify stay global/unscoped.
#
# HARNESS_ALLOW_MAIN=1 skips both main-branch checks (push-to-main and the
# commit/push-while-on-main guard) for the one legitimate case — destructive
# tiers stay in force regardless. Document any use of this, don't rely on it
# silently.

INPUT=$(cat 2>/dev/null) || exit 0
[ -z "$INPUT" ] && exit 0

if command -v jq >/dev/null 2>&1; then
  CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
else
  # crude fallback: first "command" string value (sufficient to stay useful without jq)
  CMD=$(printf '%s' "$INPUT" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | head -1)
fi
[ -z "$CMD" ] && exit 0

# fast path: nothing git-like in the command
printf '%s' "$CMD" | grep -q 'git' || exit 0

block() {
  echo "BLOCKED: $1" >&2
  exit 2
}

has() { printf '%s' "$CMD" | grep -qE "$1"; }

# grep matches anywhere in the string, so commands hidden after && ; || are
# matched exactly like the first command. [^|;&]* keeps a pattern from
# spanning across a separator into an unrelated command.

# cwd resolution (same for the main-branch checks and the pre-push secrets
# scan): .cwd from the hook's JSON, else CLAUDE_PROJECT_DIR, else ".".
DIR=""
if command -v jq >/dev/null 2>&1; then
  DIR=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
fi
[ -z "$DIR" ] && DIR="${CLAUDE_PROJECT_DIR:-}"
[ -z "$DIR" ] && DIR="."

# is_machinery_repo: true (0) when the never-on-main / no-push-main /
# pre-push-secrets-scan rules should apply to $DIR. No origin at all
# (scratch repos) is treated as machinery — safe default. A "-data" suffix
# on the machinery names (Spomni-data, relationship-agent-data) is a data
# repo and is excluded, since data repos use a direct-to-main flow.
is_machinery_repo() {
  origin=$(git -C "$DIR" remote get-url origin 2>/dev/null)
  [ -z "$origin" ] && return 0
  pattern="${HARNESS_MACHINERY_REMOTE:-relationship-agent|Spomni}"
  printf '%s' "$origin" | grep -qE "$pattern" || return 1
  printf '%s' "$origin" | grep -qE '(relationship-agent|Spomni)-data(\.git)?/?$' && return 1
  return 0
}

# ---- Tier 0: destructive ----
has 'git[^|;&]* push[^|;&]* (--force|--force-with-lease)' && block "force push"
has 'git[^|;&]* push[^|;&]* -[a-zA-Z]*f' && block "force push (-f)"
if [ "${HARNESS_ALLOW_MAIN:-}" != "1" ] && is_machinery_repo; then
  has 'git[^|;&]* push[^|;&]* (origin|upstream)[[:space:]]+(main|master)([[:space:]]|$|:)' && block "push to main/master"
fi
has 'git[^|;&]* push[^|;&]* (--delete|-d)([[:space:]]|$)' && block "remote branch delete via push"
has 'git[^|;&]* reset[^|;&]* --hard' && block "git reset --hard"
has 'git[^|;&]* clean[^|;&]* -[a-zA-Z]*f' && block "git clean -f"
has 'git[^|;&]* (checkout|restore)[^|;&]* \.([[:space:]]|$)' && block "checkout/restore . (discards working tree)"
has 'git[^|;&]* branch[^|;&]* -D([[:space:]]|$)' && block "branch -D"
has 'git[^|;&]* filter-branch' && block "filter-branch"
has 'git[^|;&]* remote[[:space:]]+(add|set-url|remove|rm)([[:space:]]|$)' && block "remote mutation"
if has 'git[^|;&]* stash([[:space:]]|$)' && ! has 'git[^|;&]* stash[[:space:]]+(list|show)'; then
  block "mutating git stash (list/show allowed)"
fi

# ---- Tier 1: WIP loss ----
if has 'git[^|;&]* rebase([[:space:]]|$)' && ! has 'git[^|;&]* rebase[[:space:]]+--(abort|continue|skip)'; then
  block "rebase (only --abort/--continue/--skip allowed)"
fi
has 'git[^|;&]* checkout[^|;&]* -[a-zA-Z]*(f|B)([[:space:]]|$)' && block "checkout -f/-B"
has 'git[^|;&]* switch[^|;&]* (-f|--force|--discard-changes)([[:space:]]|$)' && block "switch -f"
has 'git[^|;&]* commit[^|;&]* --amend' && block "commit --amend (replace with a new commit)"
has 'git[^|;&]* pull[^|;&]* --rebase' && block "pull --rebase (merge instead)"

# ---- Integrity ----
has 'git[^|;&]* (commit|push|merge)[^|;&]* --no-verify' && block "--no-verify (hook bypass)"

# ---- Branch guard: commit/push while on main/master ----
if [ "${HARNESS_ALLOW_MAIN:-}" != "1" ] && is_machinery_repo; then
  if has 'git[^|;&]* (commit|push)([[:space:]]|$)'; then
    BR=$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
    case "$BR" in
      main|master) block "commit/push while HEAD is $BR — branch first" ;;
    esac
  fi
fi

# ---- Pre-push secrets scan (any branch, machinery repo only) ----
if has 'git[^|;&]* push([[:space:]]|$)' && is_machinery_repo; then
  ROOT="${CLAUDE_PROJECT_DIR:-$(dirname "$0")/../..}"
  GUARD="$ROOT/.claude/scripts/oss-guard.sh"
  if [ -f "$GUARD" ]; then
    GUARD_OUT=$(cd "$DIR" 2>/dev/null && bash "$GUARD" --only secrets 2>&1)
    GUARD_RC=$?
    if [ $GUARD_RC -ne 0 ]; then
      printf '%s\n' "$GUARD_OUT" >&2
      block "push refused — oss-guard --only secrets found findings (see output)"
    fi
  fi
fi

exit 0
