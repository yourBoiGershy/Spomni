#!/usr/bin/env bash
# store-sync.sh — the one write-discipline entry point every runtime (laptop,
# launchd lane, phone/cloud session) uses against a git-backed spomni store.
#
# Usage: store-sync.sh [<store-dir>] <status|pull|commit|push|tick> [-m "<msg>"] [<store-dir>]
#
# The store-dir positional may come either before the subcommand or after
# it (both forms are equivalent, e.g. sibling skills/docs invoke it as
# `store-sync.sh commit -m "<msg>" <store-dir>`); at most one store-dir
# positional is accepted. Resolution: that positional if given; else
# $SPOMNI_STORE; else <repo-root>/data/store.
#
# Subcommands:
#   status  — one-line summary: store=<path> git=<yes|no> branch=<b>
#             ahead=<n> behind=<n> dirty=<n files>
#   pull    — fetch + fast-forward merge (falls back to a plain merge; never
#             rebases; a real conflict is left for a human to resolve by
#             hand and reported distinctly from any other merge failure,
#             whose git stderr is echoed)
#   commit  — reindex, validate-store.sh (refuses to stage on failure), then
#             git add -A + commit; no-op if nothing changed; if the only
#             staged change is index.json/stats.json's generated_at
#             timestamp bump (build-index.sh/build-stats.sh stamp a fresh
#             one every run), the staged+worktree change is reverted and
#             treated as nothing-to-commit rather than a noise commit
#   push    — git push origin HEAD; on rejection, pulls once and retries once
#   tick    — pull, then commit, then (if anything landed) push, in one call;
#             quiet when there's nothing to do. Prints a one-line summary:
#             "store-sync: tick pulled=<ff|merge|none|skipped>
#             committed=<sha|none> pushed=<yes|no|skipped>". Does not accept
#             -m — the commit message is a fixed "store: sync tick <UTC iso>".
#
# Git identity: every git invocation that can create a commit (commit
# itself, and pull's merges) falls back to -c user.name/-c user.email
# (${SPOMNI_GIT_NAME:-Spomni} / ${SPOMNI_GIT_EMAIL:-spomni@localhost}) when
# the store has no configured user.name — never writes global config.
#
# Refuses (exit 2, "FAIL:") if the resolved store's git toplevel is the same
# repository as this code checkout — that's someone about to commit their
# people into the public repo (same check as init-store.sh).
#
# A non-git store dir is a no-op (exit 0) for every subcommand but status.
#
# Portable to bash 3.2: no associative arrays, no mapfile.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

usage() {
    echo "usage: store-sync.sh [<store-dir>] <status|pull|commit|push|tick> [-m \"<msg>\"] [<store-dir>]" >&2
}

if [ "$#" -lt 1 ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    usage
    exit 2
fi

# Resolve store-dir and subcommand. If the first arg is a known subcommand,
# there's no leading store-dir and it (if given at all) is a remaining
# positional after the subcommand/-m; otherwise the first arg is the
# store-dir and the subcommand is the second arg.
case "$1" in
    status|pull|commit|push|tick)
        store_dir=""
        sub="$1"
        shift
        ;;
    *)
        store_dir="$1"
        sub="${2:-}"
        shift 2 2>/dev/null || { usage; exit 2; }
        ;;
esac

case "$sub" in
    status|pull|commit|push|tick) ;;
    *)
        usage
        exit 2
        ;;
esac

# Any remaining args are -m "<msg>" (commit only) and/or a single trailing
# store-dir positional (only if one wasn't already given in leading form).
commit_msg=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -m)
            if [ "$sub" != "commit" ]; then
                usage
                exit 2
            fi
            commit_msg="${2:-}"
            shift 2
            ;;
        -*)
            usage
            exit 2
            ;;
        *)
            if [ -n "$store_dir" ]; then
                usage
                exit 2
            fi
            store_dir="$1"
            shift
            ;;
    esac
done

if [ -z "$store_dir" ]; then
    store_dir="${SPOMNI_STORE:-$REPO_ROOT/data/store}"
fi

if [ ! -e "$store_dir" ]; then
    echo "FAIL: store-dir ${store_dir} does not exist" >&2
    exit 2
fi

# Resolve symlinks (data/store is typically a symlink into a private repo).
abs_store_dir="$(cd "$store_dir" && pwd -P)"

# Safety check: refuse if store-dir is the same git repository as this code
# checkout — other people's data must never live inside the public repo.
store_toplevel="$(git -C "$abs_store_dir" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$store_toplevel" ] && [ "$store_toplevel" = "$REPO_ROOT" ]; then
    echo "FAIL: ${abs_store_dir} is the code checkout itself (same git repo as ${REPO_ROOT}) — refusing to sync a store here; other people's data must never live inside the public code repo"
    exit 2
fi

is_git="no"
if git -C "$abs_store_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    is_git="yes"
fi

if [ "$is_git" = "no" ] && [ "$sub" != "status" ]; then
    echo "store-sync: ${abs_store_dir} is not a git repo — ${sub} is a no-op"
    exit 0
fi

do_status() {
    if [ "$is_git" = "no" ]; then
        echo "store=${abs_store_dir} git=no"
        return 0
    fi
    branch="$(git -C "$abs_store_dir" symbolic-ref --short -q HEAD || echo "HEAD")"
    ahead=0
    behind=0
    if git -C "$abs_store_dir" rev-parse -q --verify "@{u}" >/dev/null 2>&1; then
        counts="$(git -C "$abs_store_dir" rev-list --left-right --count HEAD...@{u} 2>/dev/null || echo "0 0")"
        ahead="$(echo "$counts" | awk '{print $1}')"
        behind="$(echo "$counts" | awk '{print $2}')"
    fi
    dirty="$(git -C "$abs_store_dir" status --porcelain | wc -l | tr -d ' ')"
    echo "store=${abs_store_dir} git=yes branch=${branch} ahead=${ahead} behind=${behind} dirty=${dirty} files"
}

has_origin() {
    git -C "$abs_store_dir" remote get-url origin >/dev/null 2>&1
}

# git_ident — echoes -c user.name=.../-c user.email=... when the store has
# no configured user.name (e.g. CI, a bare launchd runtime), else nothing.
# Used on every git invocation that can create a commit (commit itself, and
# pull's merges) so a missing identity never surfaces as "empty ident name".
git_ident() {
    if [ -z "$(git -C "$abs_store_dir" config user.name || true)" ]; then
        printf -- '-c user.name=%s -c user.email=%s' \
            "${SPOMNI_GIT_NAME:-Spomni}" "${SPOMNI_GIT_EMAIL:-spomni@localhost}"
    fi
}

do_pull() {
    if ! has_origin; then
        echo "store-sync: no origin remote, pull skipped"
        return 0
    fi
    git -C "$abs_store_dir" fetch origin
    branch="$(git -C "$abs_store_dir" symbolic-ref --short -q HEAD || echo "")"
    if [ -z "$branch" ]; then
        echo "FAIL: ${abs_store_dir} is not on a branch — resolve by hand, never rebase"
        return 1
    fi
    # shellcheck disable=SC2046
    if git -C "$abs_store_dir" $(git_ident) merge --ff-only "origin/${branch}" 2>/dev/null; then
        return 0
    fi
    merge_err_file="$(mktemp)"
    # shellcheck disable=SC2046
    if git -C "$abs_store_dir" $(git_ident) merge --no-edit "origin/${branch}" 2>"$merge_err_file"; then
        rm -f "$merge_err_file"
        return 0
    fi
    merge_err="$(cat "$merge_err_file" 2>/dev/null || true)"
    rm -f "$merge_err_file"
    conflicted="$(git -C "$abs_store_dir" diff --name-only --diff-filter=U)"
    if [ -n "$conflicted" ]; then
        echo "FAIL: merge conflict in ${abs_store_dir} — resolve by hand, never rebase"
    else
        echo "$merge_err" >&2
        echo "FAIL: merge failed in ${abs_store_dir} for a reason other than a conflict (see stderr above) — resolve by hand, never rebase"
    fi
    return 1
}

reindex() {
    # plan 38 (in flight) may add reindex.sh as the single reindex entry
    # point; until it lands (or if unreadable), fall back to running
    # build-index.sh then build-stats.sh directly.
    if [ -e "$SCRIPT_DIR/reindex.sh" ] && [ -r "$SCRIPT_DIR/reindex.sh" ]; then
        bash "$SCRIPT_DIR/reindex.sh" "$abs_store_dir"
    else
        "$SCRIPT_DIR/build-index.sh" "$abs_store_dir"
        "$SCRIPT_DIR/build-stats.sh" "$abs_store_dir"
    fi
}

do_commit() {
    reindex

    set +e
    validate_out="$("$SCRIPT_DIR/validate-store.sh" "$abs_store_dir" 2>&1)"
    validate_status=$?
    set -e
    if [ "$validate_status" -ne 0 ]; then
        echo "$validate_out"
        echo "FAIL: store-sync commit refused — validate-store.sh reported errors"
        return 1
    fi

    git -C "$abs_store_dir" add -A

    if git -C "$abs_store_dir" diff --cached --quiet; then
        echo "store-sync: nothing to commit"
        return 0
    fi

    # build-index.sh/build-stats.sh stamp a fresh generated_at on every run,
    # so a commit whose only staged change is that timestamp bump in
    # index.json/stats.json is not a real change — revert it and treat it
    # as nothing-to-commit rather than creating a noise commit.
    staged_paths="$(git -C "$abs_store_dir" diff --cached --name-only)"
    only_index_stats="yes"
    old_ifs="$IFS"
    IFS='
'
    for p in $staged_paths; do
        case "$p" in
            index.json|stats.json) ;;
            *) only_index_stats="no" ;;
        esac
    done
    IFS="$old_ifs"

    if [ "$only_index_stats" = "yes" ]; then
        timestamp_only="no"
        set +e
        i_err="$(git -C "$abs_store_dir" diff --cached -I '"generated_at"' --quiet 2>&1)"
        i_rc=$?
        set -e
        if printf '%s' "$i_err" | grep -qi "unknown option\|unrecognized"; then
            # git -I (needs >= 2.30) unsupported: fall back to a manual diff
            # scan for any changed line that isn't a generated_at line.
            other_lines="$(git -C "$abs_store_dir" diff --cached | grep '^[-+]' | grep -v '^[-+][-+]' | grep -v generated_at || true)"
            if [ -z "$other_lines" ]; then
                timestamp_only="yes"
            fi
        elif [ "$i_rc" -eq 0 ]; then
            timestamp_only="yes"
        fi
        if [ "$timestamp_only" = "yes" ]; then
            if git -C "$abs_store_dir" restore --staged --worktree index.json stats.json 2>/dev/null; then
                :
            else
                git -C "$abs_store_dir" checkout -- index.json stats.json 2>/dev/null || true
                git -C "$abs_store_dir" reset -q -- index.json stats.json 2>/dev/null || true
            fi
            echo "store-sync: nothing to commit (index/stats timestamps only)"
            return 0
        fi
    fi

    n_files="$(git -C "$abs_store_dir" diff --cached --name-only | wc -l | tr -d ' ')"

    if [ -z "$commit_msg" ]; then
        commit_msg="store: sync $(date -u +%Y-%m-%dT%H:%M:%SZ) UTC"
    fi

    # shellcheck disable=SC2046
    git -C "$abs_store_dir" $(git_ident) commit -q -m "$commit_msg"

    short_sha="$(git -C "$abs_store_dir" rev-parse --short HEAD)"
    echo "store-sync: committed ${short_sha} (${n_files} files)"
}

do_push() {
    if ! has_origin; then
        echo "store-sync: no origin remote, push skipped"
        return 0
    fi
    push_err_file="$(mktemp)"
    if git -C "$abs_store_dir" push origin HEAD 2>"$push_err_file"; then
        rm -f "$push_err_file"
        return 0
    fi
    err_out="$(cat "$push_err_file" 2>/dev/null || true)"
    rm -f "$push_err_file"
    echo "$err_out" >&2
    if ! do_pull; then
        return 1
    fi
    if git -C "$abs_store_dir" push origin HEAD; then
        return 0
    fi
    echo "FAIL: push rejected twice in ${abs_store_dir} — pull/merge by hand"
    return 1
}

do_tick() {
    commit_msg="store: sync tick $(date -u +%Y-%m-%dT%H:%M:%SZ) UTC"

    pulled="skipped"
    if has_origin; then
        head_before="$(git -C "$abs_store_dir" rev-parse HEAD 2>/dev/null || echo "")"

        set +e
        pull_out="$(do_pull)"
        pull_status=$?
        set -e
        if [ "$pull_status" -ne 0 ]; then
            echo "$pull_out"
            echo "store-sync: tick aborted at pull"
            return 1
        fi

        head_after="$(git -C "$abs_store_dir" rev-parse HEAD 2>/dev/null || echo "")"
        if [ "$head_before" = "$head_after" ]; then
            pulled="none"
        elif git -C "$abs_store_dir" rev-parse -q --verify HEAD^2 >/dev/null 2>&1; then
            pulled="merge"
        else
            pulled="ff"
        fi
    fi

    set +e
    commit_out="$(do_commit)"
    commit_status=$?
    set -e
    if [ "$commit_status" -ne 0 ]; then
        echo "$commit_out"
        echo "store-sync: tick aborted at commit"
        return 1
    fi

    committed="$(printf '%s\n' "$commit_out" | sed -n 's/^store-sync: committed \([^ ]*\).*/\1/p' | head -1)"
    if [ -z "$committed" ]; then
        committed="none"
    fi

    ahead=0
    if has_origin && git -C "$abs_store_dir" rev-parse -q --verify "@{u}" >/dev/null 2>&1; then
        counts="$(git -C "$abs_store_dir" rev-list --left-right --count HEAD...@{u} 2>/dev/null || echo "0 0")"
        ahead="$(echo "$counts" | awk '{print $1}')"
    fi

    pushed="skipped"
    if has_origin; then
        if [ "$committed" != "none" ] || [ "$ahead" -gt 0 ]; then
            set +e
            push_out="$(do_push)"
            push_status=$?
            set -e
            if [ "$push_status" -ne 0 ]; then
                echo "$push_out"
                echo "store-sync: tick aborted at push"
                return 1
            fi
            pushed="yes"
        else
            pushed="no"
        fi
    fi

    echo "store-sync: tick pulled=${pulled} committed=${committed} pushed=${pushed}"
}

case "$sub" in
    status)
        do_status
        exit 0
        ;;
    pull)
        do_pull
        exit $?
        ;;
    commit)
        do_commit
        exit $?
        ;;
    push)
        do_push
        exit $?
        ;;
    tick)
        do_tick
        exit $?
        ;;
esac
