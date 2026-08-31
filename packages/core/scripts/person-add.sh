#!/usr/bin/env bash
# person-add.sh — validated creator for people/<slug>.md
# (packages/core/contracts/person.md 1.4.0).
#
# Usage:
#   person-add.sh <store-dir> --name "<Display Name>" [--slug <slug>] \
#       [--kind <kind> --kind-source stated-by-user|derived] \
#       [--tier <tier> --tier-source stated-by-user|derived] \
#       [--tag <tag>]... [--fact "<provenance-tagged fact line>"]...
#
# Algorithm:
#   1. Slug defaults to the kebab-cased name; --slug overrides. If
#      people/<slug>.md already exists -> exit 3 with a message pointing at
#      person-merge.sh (this script never overwrites).
#   2. Emits frontmatter + the three fixed sections per contracts/person.md
#      (schema_version 1.4.0; Facts / Open threads / Personal details, with
#      the _none_ empty-section shape where a section has no content).
#   3. Every Facts bullet carries a provenance marker; a --fact that lacks a
#      leading **[...]** marker gets **[told-by-user]** prepended.
#   4. --kind requires --kind-source and also writes kind_note (default
#      rationale) + kind_updated (today, UTC), since the contract makes
#      those required whenever kind is set. --kind scheduling is rejected
#      (it requires kind_expires, which is person-set-kind.sh's job).
#      --tier requires --tier-source.
#   5. After writing, runs validate-store.sh on the store; on failure the
#      just-written file is deleted (never leave an invalid file behind)
#      and the script exits 1.
#
# Prints one line on success: `person-add: created people/<slug>.md`.
# Exit codes: 0 created, 1 usage/validation failure, 3 slug already exists.
#
# Portable to bash 3.2: no associative arrays, no mapfile.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"

usage() {
  cat >&2 <<EOF
Usage: ${SCRIPT_NAME} <store-dir> --name "<Display Name>" [--slug <slug>] \\
    [--kind <kind> --kind-source stated-by-user|derived] \\
    [--tier <tier> --tier-source stated-by-user|derived] \\
    [--tag <tag>]... [--fact "<provenance-tagged fact line>"]...

Creates people/<slug>.md conforming to packages/core/contracts/person.md,
then validates the store; a file that fails validation is deleted again.
Refuses (exit 3) if people/<slug>.md already exists — use person-merge.sh
to combine two person files instead.
EOF
  exit 1
}

STORE_DIR=""
NAME=""
SLUG=""
KIND=""
KIND_SOURCE=""
TIER=""
TIER_SOURCE=""
TAGS=""
TAGS_COUNT=0
FACTS=""
FACTS_COUNT=0

if [ "$#" -lt 1 ]; then
  usage
fi

STORE_DIR="$1"
shift

if [ -z "${STORE_DIR}" ]; then
  usage
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --name)
      [ "$#" -ge 2 ] || usage
      NAME="$2"
      shift 2
      ;;
    --slug)
      [ "$#" -ge 2 ] || usage
      SLUG="$2"
      shift 2
      ;;
    --kind)
      [ "$#" -ge 2 ] || usage
      KIND="$2"
      shift 2
      ;;
    --kind-source)
      [ "$#" -ge 2 ] || usage
      KIND_SOURCE="$2"
      shift 2
      ;;
    --tier)
      [ "$#" -ge 2 ] || usage
      TIER="$2"
      shift 2
      ;;
    --tier-source)
      [ "$#" -ge 2 ] || usage
      TIER_SOURCE="$2"
      shift 2
      ;;
    --tag)
      [ "$#" -ge 2 ] || usage
      if [ -z "${TAGS}" ]; then
        TAGS="$2"
      else
        TAGS="${TAGS}
$2"
      fi
      TAGS_COUNT=$((TAGS_COUNT + 1))
      shift 2
      ;;
    --fact)
      [ "$#" -ge 2 ] || usage
      if [ -z "${FACTS}" ]; then
        FACTS="$2"
      else
        FACTS="${FACTS}
$2"
      fi
      FACTS_COUNT=$((FACTS_COUNT + 1))
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

# --- Validation ---

if [ ! -d "${STORE_DIR}" ]; then
  echo "Store directory does not exist: '${STORE_DIR}'" >&2
  usage
fi

if [ -z "${NAME}" ]; then
  echo "Missing required --name" >&2
  usage
fi

if [ -n "${TIER}" ]; then
  case "${TIER}" in
    inner-circle|close|active|dormant) ;;
    *)
      echo "Invalid --tier: '${TIER}' (expected one of: inner-circle, close, active, dormant)" >&2
      usage
      ;;
  esac
  if [ -z "${TIER_SOURCE}" ]; then
    echo "--tier requires --tier-source stated-by-user|derived" >&2
    usage
  fi
  case "${TIER_SOURCE}" in
    stated-by-user|derived) ;;
    *)
      echo "Invalid --tier-source: '${TIER_SOURCE}' (expected stated-by-user or derived)" >&2
      usage
      ;;
  esac
elif [ -n "${TIER_SOURCE}" ]; then
  echo "--tier-source requires --tier" >&2
  usage
fi

if [ -n "${KIND}" ]; then
  case "${KIND}" in
    scheduling)
      echo "--kind scheduling requires a kind_expires date — set it via person-set-kind.sh, not at creation" >&2
      usage
      ;;
    friend|family|collaborator|professional|community|transactional|unsolicited|unknown) ;;
    *)
      echo "Invalid --kind: '${KIND}' (expected one of: friend, family, collaborator, professional, community, transactional, unsolicited, unknown)" >&2
      usage
      ;;
  esac
  if [ -z "${KIND_SOURCE}" ]; then
    echo "--kind requires --kind-source stated-by-user|derived" >&2
    usage
  fi
  case "${KIND_SOURCE}" in
    stated-by-user|derived) ;;
    *)
      echo "Invalid --kind-source: '${KIND_SOURCE}' (expected stated-by-user or derived)" >&2
      usage
      ;;
  esac
elif [ -n "${KIND_SOURCE}" ]; then
  echo "--kind-source requires --kind" >&2
  usage
fi

# --- Slug: default is the kebab-cased name (same rule as validate-store.sh) ---

if [ -z "${SLUG}" ]; then
  SLUG="$(printf '%s' "${NAME}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
fi

case "${SLUG}" in
  *[!a-z0-9-]*|''|-*|*-)
    echo "Invalid slug: '${SLUG}' (expected kebab-case: lowercase letters, digits, hyphens)" >&2
    usage
    ;;
esac

PEOPLE_DIR="${STORE_DIR}/people"
mkdir -p "${PEOPLE_DIR}"
TARGET_FILE="${PEOPLE_DIR}/${SLUG}.md"

if [ -e "${TARGET_FILE}" ]; then
  echo "FAIL: people/${SLUG}.md already exists — never overwritten; to combine two person files use person-merge.sh" >&2
  exit 3
fi

# --- Build tags YAML array ---

TAGS_YAML=""
if [ "${TAGS_COUNT}" -gt 0 ]; then
  OLD_IFS="${IFS}"
  IFS='
'
  for tag in ${TAGS}; do
    if [ -z "${TAGS_YAML}" ]; then
      TAGS_YAML="${tag}"
    else
      TAGS_YAML="${TAGS_YAML}, ${tag}"
    fi
  done
  IFS="${OLD_IFS}"
fi

TODAY="$(date -u +%Y-%m-%d)"

# --- Write the file ---

{
  echo "---"
  echo "schema_version: 1.4.0"
  echo "name: ${NAME}"
  echo "tags: [${TAGS_YAML}]"
  if [ -n "${TIER}" ]; then
    echo "tier: ${TIER}"
    echo "tier_source: ${TIER_SOURCE}"
  fi
  if [ -n "${KIND}" ]; then
    echo "kind: ${KIND}"
    echo "kind_note: added at creation via person-add.sh"
    echo "kind_source: ${KIND_SOURCE}"
    echo "kind_updated: ${TODAY}"
  fi
  echo "---"
  echo ""
  echo "## Facts"
  echo ""
  if [ "${FACTS_COUNT}" -gt 0 ]; then
    OLD_IFS="${IFS}"
    IFS='
'
    for fact in ${FACTS}; do
      case "${fact}" in
        "**["*)
          printf -- '- %s\n' "${fact}"
          ;;
        *)
          printf -- '- **[told-by-user]** %s\n' "${fact}"
          ;;
      esac
    done
    IFS="${OLD_IFS}"
  else
    echo "_none_"
  fi
  echo ""
  echo "## Open threads"
  echo ""
  echo "- _none_"
  echo ""
  echo "## Personal details"
  echo ""
  echo "_none_"
} > "${TARGET_FILE}"

# --- Validate; never leave an invalid file behind ---

set +e
validate_out="$("${SCRIPT_DIR}/validate-store.sh" "${STORE_DIR}" 2>&1)"
validate_status=$?
set -e

if [ "${validate_status}" -ne 0 ]; then
  rm -f "${TARGET_FILE}"
  echo "${validate_out}" >&2
  echo "FAIL: person-add refused — validate-store.sh reported errors; people/${SLUG}.md was removed again" >&2
  exit 1
fi

echo "person-add: created people/${SLUG}.md"
