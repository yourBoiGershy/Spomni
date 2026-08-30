#!/usr/bin/env bash
# link-user-skills.sh — exposes a user's private skills
# (<data-dir>/skills/<name>/SKILL.md, packages/core/contracts/user-skill.md)
# as personal-scope Claude Code skills by symlinking each skill dir into a
# target skills directory (default: $HOME/.claude/skills).
#
# Usage:
#   link-user-skills.sh <data-dir> [--target-dir <dir>] [--prune] [--dry-run]
#
# For each <data-dir>/skills/<name>/ containing SKILL.md whose frontmatter
# `name:` equals <name>, ensures <target>/<name> is an absolute symlink to
# that skill dir. Never overwrites a non-symlink or a symlink that doesn't
# resolve under <data-dir>/skills/ — such entries are reported as a skip
# conflict on stderr and the script exits 1 after processing everything
# else. --prune removes symlinks under <target> that resolve under
# <data-dir>/skills/ but whose target no longer has a SKILL.md. --dry-run
# reports what would happen and changes nothing.

set -eu

SCRIPT_NAME="$(basename "$0")"

usage() {
  cat >&2 <<EOF
Usage: ${SCRIPT_NAME} <data-dir> [--target-dir <dir>] [--prune] [--dry-run]

Symlinks each <data-dir>/skills/<name>/ (containing SKILL.md, per
packages/core/contracts/user-skill.md) into the target skills dir
(default \$HOME/.claude/skills, override with --target-dir) as
<target>/<name>.

--prune    remove stale symlinks under the target dir that resolve under
           <data-dir>/skills/ but no longer point at a valid skill.
--dry-run  print what would change; make no changes. Exits 0.

Exit codes: 0 on success (nothing skipped), 1 if any skill was skipped due
to a conflict or name mismatch, 2 if <data-dir> does not exist.
EOF
  exit 1
}

DATA_DIR=""
TARGET_DIR=""
PRUNE=0
DRY_RUN=0

if [ "$#" -lt 1 ]; then
  usage
fi

DATA_DIR="$1"
shift

if [ -z "${DATA_DIR}" ]; then
  usage
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target-dir)
      [ "$#" -ge 2 ] || usage
      TARGET_DIR="$2"
      shift 2
      ;;
    --prune)
      PRUNE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

if [ ! -d "${DATA_DIR}" ]; then
  echo "Data directory does not exist: '${DATA_DIR}'" >&2
  exit 2
fi

if [ -z "${TARGET_DIR}" ]; then
  TARGET_DIR="${HOME}/.claude/skills"
fi

ABS_DATA_DIR="$(cd "${DATA_DIR}" && pwd)"
SKILLS_DIR="${ABS_DATA_DIR}/skills"

if [ "${DRY_RUN}" -eq 0 ]; then
  mkdir -p "${TARGET_DIR}"
fi

CONFLICT=0

# --- Helpers -----------------------------------------------------------

# Extracts the `name:` value from a SKILL.md's YAML frontmatter. Prints
# nothing if the file has no frontmatter or no name field.
extract_name() {
  awk '
    NR == 1 && $0 != "---" { exit }
    NR == 1 { infm = 1; next }
    infm && $0 == "---" { exit }
    infm && $0 ~ /^name:[ \t]*/ {
      sub(/^name:[ \t]*/, "")
      gsub(/^"|"$/, "")
      gsub(/^'"'"'|'"'"'$/, "")
      print
      exit
    }
  ' "$1"
}

# Resolves a symlink's target to an absolute path (single-level; our own
# links are always absolute, so this only needs to handle a relative
# target defensively).
resolve_symlink() {
  link_path="$1"
  raw_target="$(readlink "${link_path}")"
  case "${raw_target}" in
    /*)
      printf '%s\n' "${raw_target}"
      ;;
    *)
      printf '%s\n' "$(dirname "${link_path}")/${raw_target}"
      ;;
  esac
}

# Describes what already occupies a path, for the conflict message.
describe_path() {
  p="$1"
  if [ -L "${p}" ]; then
    echo "symlink -> $(readlink "${p}")"
  elif [ -d "${p}" ]; then
    echo "directory"
  elif [ -f "${p}" ]; then
    echo "file"
  else
    echo "unknown"
  fi
}

# --- Link pass -----------------------------------------------------------

process_skill() {
  skill_dir="$1"
  name="$2"
  link_path="${TARGET_DIR}/${name}"

  if [ -L "${link_path}" ]; then
    resolved_target="$(resolve_symlink "${link_path}")"
    case "${resolved_target}" in
      "${SKILLS_DIR}"/*)
        if [ "${resolved_target}" = "${skill_dir}" ]; then
          echo "kept ${name}"
        elif [ "${DRY_RUN}" -eq 1 ]; then
          echo "would-link ${name}"
        else
          rm -f "${link_path}"
          ln -s "${skill_dir}" "${link_path}"
          echo "linked ${name}"
        fi
        ;;
      *)
        echo "skip ${name} (conflict: $(describe_path "${link_path}"))" >&2
        CONFLICT=1
        ;;
    esac
  elif [ -e "${link_path}" ]; then
    echo "skip ${name} (conflict: $(describe_path "${link_path}"))" >&2
    CONFLICT=1
  else
    if [ "${DRY_RUN}" -eq 1 ]; then
      echo "would-link ${name}"
    else
      ln -s "${skill_dir}" "${link_path}"
      echo "linked ${name}"
    fi
  fi
}

FOUND=0

if [ -d "${SKILLS_DIR}" ]; then
  for d in "${SKILLS_DIR}"/*/; do
    [ -d "${d}" ] || continue
    skill_md="${d}SKILL.md"
    [ -f "${skill_md}" ] || continue
    FOUND=1
    dir_name="$(basename "${d%/}")"
    abs_skill_dir="$(cd "${d}" && pwd)"
    fm_name="$(extract_name "${skill_md}")"
    if [ "${fm_name}" != "${dir_name}" ]; then
      echo "skip ${dir_name} (name mismatch)" >&2
      CONFLICT=1
      continue
    fi
    process_skill "${abs_skill_dir}" "${dir_name}"
  done
fi

if [ "${FOUND}" -eq 0 ]; then
  echo "no user skills found in ${DATA_DIR}/skills"
fi

# --- Prune pass ----------------------------------------------------------

if [ "${PRUNE}" -eq 1 ] && [ -d "${TARGET_DIR}" ]; then
  for entry in "${TARGET_DIR}"/*; do
    [ -e "${entry}" ] || [ -L "${entry}" ] || continue
    [ -L "${entry}" ] || continue
    ename="$(basename "${entry}")"
    resolved_target="$(resolve_symlink "${entry}")"
    case "${resolved_target}" in
      "${SKILLS_DIR}"/*)
        if [ ! -f "${resolved_target}/SKILL.md" ]; then
          if [ "${DRY_RUN}" -eq 1 ]; then
            echo "would-prune ${ename}"
          else
            rm -f "${entry}"
            echo "pruned ${ename}"
          fi
        fi
        ;;
      *)
        ;;
    esac
  done
fi

if [ "${DRY_RUN}" -eq 1 ]; then
  exit 0
fi

if [ "${CONFLICT}" -eq 1 ]; then
  exit 1
fi

exit 0
