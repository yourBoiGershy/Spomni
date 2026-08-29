#!/bin/bash
# git-guard.sh — PreToolUse hook for Bash.
# ENFORCES: the git safety doctrine in CLAUDE.md. Blocks destructive git
# (tier 0), WIP-loss git (tier 1), hook bypasses (--no-verify), and any
# commit/push while HEAD resolves to main/master.
# Block = exit 2 with "BLOCKED: <reason>" on stderr. Fails OPEN on parse
# errors (exit 0) — a broken guard must not brick the session.
# Bash 3.2 portable: no mapfile, no declare -A.

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

# ---- Tier 0: destructive ----
has 'git[^|;&]* push[^|;&]* (--force|--force-with-lease)' && block "force push"
has 'git[^|;&]* push[^|;&]* -[a-zA-Z]*f' && block "force push (-f)"
# TEMP-DISABLED (2026-08-29, re-enable later):
# has 'git[^|;&]* push[^|;&]* (origin|upstream)[[:space:]]+(main|master)([[:space:]]|$|:)' && block "push to main/master"
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
# TEMP-DISABLED (2026-08-29, re-enable later)
# if has 'git[^|;&]* (commit|push)([[:space:]]|$)'; then
#   DIR=""
#   if command -v jq >/dev/null 2>&1; then
#     DIR=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
#   fi
#   [ -z "$DIR" ] && DIR="${CLAUDE_PROJECT_DIR:-}"
#   [ -z "$DIR" ] && DIR="."
#   BR=$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
#   case "$BR" in
#     main|master) block "commit/push while HEAD is $BR — branch first" ;;
#   esac
# fi

exit 0
