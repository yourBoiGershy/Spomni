#!/bin/bash
# resolve-backfill-window.sh <data-dir>
#
# Resolves the onboarding-backfill window from
# <data-dir>/config/onboarding-backfill.tsv (see
# packages/core/contracts/onboarding-backfill.md) so all three lane backfill
# modes share one window-resolution path.
#
# Output on success: exactly one line to stdout —
#   <window_start_iso><TAB><window_months>
# where window_start_iso is now (UTC) minus window_months months, in
# ISO-8601 (YYYY-MM-DDTHH:MM:SSZ).
#
# Fail-closed: unknown key, malformed row, or non-integer / < 1
# window_months -> non-zero exit, one-line reason on stderr, no stdout.
# Missing file or missing window_months key -> default 6.
#
# bash 3.2 compatible; detects BSD (darwin) vs GNU date at runtime, no
# external deps beyond POSIX + date.

set -u

data_dir="${1:-}"

if [ -z "$data_dir" ]; then
  echo "resolve-backfill-window: usage: resolve-backfill-window.sh <data-dir>" >&2
  exit 1
fi

config_file="${data_dir}/config/onboarding-backfill.tsv"

window_months=""

if [ -f "$config_file" ]; then
  lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))

    case "$line" in
      ''|'#'*)
        continue
        ;;
    esac

    key="${line%%	*}"
    value="${line#*	}"

    if [ "$key" = "$line" ]; then
      echo "resolve-backfill-window: ${config_file}:${lineno}: malformed row (expected key<TAB>value)" >&2
      exit 1
    fi

    case "$key" in
      self)
        # Repeatable, ignored here — only window_months matters to this script.
        ;;
      window_months)
        case "$value" in
          ''|*[!0-9]*)
            echo "resolve-backfill-window: ${config_file}:${lineno}: window_months must be a positive integer, got '${value}'" >&2
            exit 1
            ;;
        esac
        if [ "$value" -lt 1 ]; then
          echo "resolve-backfill-window: ${config_file}:${lineno}: window_months must be >= 1, got '${value}'" >&2
          exit 1
        fi
        window_months="$value"
        ;;
      *)
        echo "resolve-backfill-window: ${config_file}:${lineno}: unknown key '${key}'" >&2
        exit 1
        ;;
    esac
  done < "$config_file"
fi

if [ -z "$window_months" ]; then
  window_months=6
fi

if date -u -d '@0' +%s >/dev/null 2>&1; then
  DATE_MODE=gnu
else
  DATE_MODE=bsd
fi

if [ "$DATE_MODE" = "gnu" ]; then
  window_start_iso="$(date -u -d "-${window_months} months" +%Y-%m-%dT%H:%M:%SZ)"
else
  window_start_iso="$(date -u -v-"${window_months}"m +%Y-%m-%dT%H:%M:%SZ)"
fi

if [ -z "$window_start_iso" ]; then
  echo "resolve-backfill-window: failed to compute window start date" >&2
  exit 1
fi

printf '%s\t%s\n' "$window_start_iso" "$window_months"
