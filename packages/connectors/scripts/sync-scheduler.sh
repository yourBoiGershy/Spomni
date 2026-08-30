#!/bin/bash
# sync-scheduler.sh — CLI for the plan-19 sync scheduler: renders and manages
# one launchd agent per enabled capture lane, and reports lane status.
#
# Usage:
#   sync-scheduler.sh run <lane> [--data-dir <dir>]
#   sync-scheduler.sh init [--force] [--data-dir <dir>]
#   sync-scheduler.sh resolve <lane> [--data-dir <dir>]
#   sync-scheduler.sh install [--dry-run] [--data-dir <dir>]
#   sync-scheduler.sh uninstall <lane>|--all [--dry-run] [--data-dir <dir>]
#   sync-scheduler.sh status [--data-dir <dir>]
#
# Config lives at <data-dir>/connectors/sync-scheduler/lanes.tsv (contract:
# packages/core/contracts/sync-lanes.md). All lane/state/log primitives are
# implemented by sync-lib.sh (sourced by path, sync-lanes 1.1.0 API — adds
# {{...}} placeholder expansion for lane commands).
#
# `run <lane>` is the launchd entrypoint: it delegates straight to
# sync_run_lane, which records state, appends to the lane log, and exits with
# the lane command's exit code.
#
# `init` copies packages/core/templates/sync-lanes.tsv verbatim to the data
# dir's config path, creating parent dirs as needed. Refuses to overwrite an
# existing config unless `--force` is given.
#
# `resolve <lane>` prints the lane's command with {{REPO_ROOT}}/{{DATA_DIR}}/
# {{PRIVATE_DATA_ROOT}}/{{STORE_DIR}}/{{CLAUDE_BIN}} placeholders expanded,
# without running it — for debugging routing.
#
# `install` renders one launchd agent per *enabled* configured lane from
# launchd/com.spomni.sync.plist.template, writes it to
# ~/Library/LaunchAgents, boots any prior instance out (ignoring failure),
# then bootstraps the new one. It is idempotent. After installing the
# current lane set it prunes any previously-installed
# com.spomni.sync.* agent whose lane no longer has a config row, then
# unconditionally retires (bootout + remove) any installed pre-rename
# com.relationship-agent.sync.* legacy agent.
# `--dry-run` prints the rendered plists and the actions that would be taken
# (including prune and legacy retirement) without touching disk,
# ~/Library/LaunchAgents, or launchctl.
#
# `uninstall <lane>` boots out and removes that lane's agent. `uninstall
# --all` does the same for every currently-installed
# com.spomni.sync.* agent, regardless of config. `--dry-run`
# prints the actions without performing them.
#
# `status` prints one row per configured lane (enabled or not) with columns
# LANE ENABLED INTERVAL INSTALLED LAST_RUN LAST_EXIT NEXT_RUN, plus one extra
# ORPHAN row per installed com.spomni.sync.* agent that has no
# matching config row, plus one LEGACY row per installed pre-rename
# com.relationship-agent.sync.* agent (old label prefix — detected, never
# auto-removed). Never silent: every configured lane gets exactly one
# row. Only fails (exit 1) if the config itself cannot be parsed, since rows
# can't be enumerated in that case; otherwise always exits 0 (it's a report).
#
# bash 3.2 (macOS default) — no associative arrays, no mapfile.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SYNC_REPO_ROOT="$REPO_ROOT"
# shellcheck source=./sync-lib.sh
. "$SCRIPT_DIR/sync-lib.sh"

TEMPLATE="$SCRIPT_DIR/launchd/com.spomni.sync.plist.template"
LABEL_PREFIX="com.spomni.sync."
LEGACY_LABEL_PREFIX="com.relationship-agent.sync."

usage() {
	echo "Usage: $0 run <lane> [--data-dir <dir>]" >&2
	echo "       $0 init [--force] [--data-dir <dir>]" >&2
	echo "       $0 resolve <lane> [--data-dir <dir>]" >&2
	echo "       $0 install [--dry-run] [--data-dir <dir>]" >&2
	echo "       $0 uninstall <lane>|--all [--dry-run] [--data-dir <dir>]" >&2
	echo "       $0 status [--data-dir <dir>]" >&2
	exit 1
}

[ $# -ge 1 ] || usage
SUBCOMMAND="$1"
shift

DATA_DIR="$REPO_ROOT/data"
DRY_RUN=0
FORCE=0
POSITIONAL=()

while [ $# -gt 0 ]; do
	case "$1" in
		--data-dir)
			[ $# -ge 2 ] || usage
			DATA_DIR="$2"
			shift 2
			;;
		--dry-run)
			DRY_RUN=1
			shift
			;;
		--force)
			FORCE=1
			shift
			;;
		*)
			POSITIONAL+=("$1")
			shift
			;;
	esac
done

CONFIG_FILE="$(sync_config_path "$DATA_DIR")"

# date-flavor detection (BSD vs GNU) — mirrors wakeup-queue.sh's parser.
if date -u -d '@0' +%s >/dev/null 2>&1; then
	DATE_MODE=gnu
else
	DATE_MODE=bsd
fi

# iso_to_epoch <YYYY-MM-DDTHH:MM:SSZ> — UTC epoch seconds, or "" on parse
# failure.
iso_to_epoch() {
	# $1 = ISO timestamp
	if [ "$DATE_MODE" = "gnu" ]; then
		TZ=UTC date -u -d "$1" +%s 2>/dev/null || echo ""
	else
		date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || echo ""
	fi
}

# epoch_to_iso <epoch> — formats an epoch as an ISO UTC timestamp.
epoch_to_iso() {
	# $1 = epoch seconds
	if [ "$DATE_MODE" = "gnu" ]; then
		TZ=UTC date -u -d "@$1" +"%Y-%m-%dT%H:%M:%SZ"
	else
		date -u -r "$1" +"%Y-%m-%dT%H:%M:%SZ"
	fi
}

label_for() {
	echo "${LABEL_PREFIX}$1"
}

plist_dest_for() {
	echo "$HOME/Library/LaunchAgents/$(label_for "$1").plist"
}

launchctl_available() {
	command -v launchctl >/dev/null 2>&1
}

is_installed() {
	# $1 = lane
	label="$(label_for "$1")"
	dest="$(plist_dest_for "$1")"
	[ -f "$dest" ] || return 1
	launchctl_available || return 1
	launchctl print "gui/$UID/$label" >/dev/null 2>&1
}

render_plist() {
	# $1 = lane, $2 = interval
	sed \
		-e "s#__LABEL__#$(label_for "$1")#g" \
		-e "s#__SCHEDULER__#$SCRIPT_DIR/sync-scheduler.sh#g" \
		-e "s#__LANE__#$1#g" \
		-e "s#__DATA_DIR__#$DATA_DIR#g" \
		-e "s#__INTERVAL__#$2#g" \
		-e "s#__WORKDIR__#$REPO_ROOT#g" \
		"$TEMPLATE"
}

case "$SUBCOMMAND" in
	run)
		[ ${#POSITIONAL[@]} -eq 1 ] || usage
		sync_run_lane "$CONFIG_FILE" "$DATA_DIR" "${POSITIONAL[0]}"
		exit $?
		;;

	init)
		[ ${#POSITIONAL[@]} -eq 0 ] || usage
		TEMPLATE_SOURCE="$REPO_ROOT/packages/core/templates/sync-lanes.tsv"
		if [ ! -f "$TEMPLATE_SOURCE" ]; then
			echo "sync-scheduler: init: missing template $TEMPLATE_SOURCE" >&2
			exit 1
		fi

		if [ -f "$CONFIG_FILE" ] && [ "$FORCE" -ne 1 ]; then
			echo "sync-scheduler: init: $CONFIG_FILE exists — not overwriting (use --force)"
			exit 0
		fi

		mkdir -p "$(dirname "$CONFIG_FILE")"
		cp "$TEMPLATE_SOURCE" "$CONFIG_FILE"
		echo "Wrote $CONFIG_FILE"
		exit 0
		;;

	resolve)
		[ ${#POSITIONAL[@]} -eq 1 ] || usage
		LANE="${POSITIONAL[0]}"
		ROW="$(sync_lane_get "$CONFIG_FILE" "$LANE")"
		STATUS=$?
		if [ "$STATUS" -eq 2 ]; then
			echo "sync-scheduler: resolve: unknown lane '${LANE}'" >&2
			exit 2
		elif [ "$STATUS" -ne 0 ]; then
			echo "sync-scheduler: resolve: config invalid" >&2
			exit 1
		fi

		COMMAND="$(printf '%s' "$ROW" | awk -F'\t' '{
			out = $4
			for (i = 5; i <= NF; i++) out = out "\t" $i
			print out
		}')"
		sync_resolve_command "$DATA_DIR" "$COMMAND"
		exit 0
		;;

	install)
		[ ${#POSITIONAL[@]} -eq 0 ] || usage

		LANES_OUTPUT="$(sync_lanes_list "$CONFIG_FILE")" || {
			echo "sync-scheduler: install: config invalid, aborting" >&2
			exit 1
		}

		# Track enabled lane names for the prune pass.
		ENABLED_LANES=""

		if [ -n "$LANES_OUTPUT" ]; then
			while IFS="$(printf '\t')" read -r LANE INTERVAL ENABLED COMMAND; do
				[ -n "$LANE" ] || continue
				[ "$ENABLED" = "true" ] || continue
				ENABLED_LANES="$ENABLED_LANES $LANE"

				LABEL="$(label_for "$LANE")"
				DEST="$(plist_dest_for "$LANE")"

				if [ "$DRY_RUN" -eq 1 ]; then
					echo "# Would install $LABEL -> $DEST"
					render_plist "$LANE" "$INTERVAL"
					continue
				fi

				mkdir -p "$HOME/Library/LaunchAgents"
				render_plist "$LANE" "$INTERVAL" > "$DEST"
				launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
				launchctl bootstrap "gui/$UID" "$DEST"
				echo "Installed $LABEL -> $DEST (interval=${INTERVAL}s)"
			done <<EOF
$LANES_OUTPUT
EOF
		fi

		# Prune: any installed com.spomni.sync.* agent whose lane
		# is not currently enabled.
		if [ -d "$HOME/Library/LaunchAgents" ]; then
			for PLIST_PATH in "$HOME/Library/LaunchAgents/${LABEL_PREFIX}"*.plist; do
				[ -e "$PLIST_PATH" ] || continue
				BASENAME="$(basename "$PLIST_PATH" .plist)"
				LANE="${BASENAME#$LABEL_PREFIX}"
				case " $ENABLED_LANES " in
					*" $LANE "*)
						;;
					*)
						if [ "$DRY_RUN" -eq 1 ]; then
							echo "Would prune $BASENAME"
						else
							launchctl bootout "gui/$UID/$BASENAME" >/dev/null 2>&1 || true
							rm -f "$PLIST_PATH"
							echo "pruned $BASENAME"
						fi
						;;
				esac
			done
		fi

		# Retire legacy pre-rename agents unconditionally: a stale legacy
		# agent pointing at a dead checkout is exactly the bug being fixed.
		if [ -d "$HOME/Library/LaunchAgents" ]; then
			for LEGACY_PLIST_PATH in "$HOME/Library/LaunchAgents/${LEGACY_LABEL_PREFIX}"*.plist; do
				[ -e "$LEGACY_PLIST_PATH" ] || continue
				LEGACY_BASENAME="$(basename "$LEGACY_PLIST_PATH" .plist)"
				if [ "$DRY_RUN" -eq 1 ]; then
					echo "Would retire legacy $LEGACY_BASENAME"
				else
					launchctl bootout "gui/$UID/$LEGACY_BASENAME" >/dev/null 2>&1 || true
					rm -f "$LEGACY_PLIST_PATH"
					echo "retired legacy $LEGACY_BASENAME"
				fi
			done
		fi
		exit 0
		;;

	uninstall)
		[ ${#POSITIONAL[@]} -eq 1 ] || usage
		TARGET="${POSITIONAL[0]}"

		if [ "$TARGET" = "--all" ]; then
			if [ -d "$HOME/Library/LaunchAgents" ]; then
				for PLIST_PATH in "$HOME/Library/LaunchAgents/${LABEL_PREFIX}"*.plist; do
					[ -e "$PLIST_PATH" ] || continue
					BASENAME="$(basename "$PLIST_PATH" .plist)"
					if [ "$DRY_RUN" -eq 1 ]; then
						echo "Would run: launchctl bootout gui/$UID/$BASENAME"
						echo "Would remove: $PLIST_PATH"
					else
						launchctl bootout "gui/$UID/$BASENAME" >/dev/null 2>&1 || true
						rm -f "$PLIST_PATH"
						echo "Uninstalled $BASENAME (bootout + removed $PLIST_PATH)"
					fi
				done
			fi
			exit 0
		fi

		LANE="$TARGET"
		LABEL="$(label_for "$LANE")"
		DEST="$(plist_dest_for "$LANE")"

		if [ "$DRY_RUN" -eq 1 ]; then
			echo "Would run: launchctl bootout gui/$UID/$LABEL"
			echo "Would remove: $DEST"
			exit 0
		fi

		launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
		rm -f "$DEST"
		echo "Uninstalled $LABEL (bootout + removed $DEST)"
		exit 0
		;;

	status)
		[ ${#POSITIONAL[@]} -eq 0 ] || usage

		LANES_OUTPUT="$(sync_lanes_list "$CONFIG_FILE")" || {
			echo "sync-scheduler: status: config invalid, cannot enumerate lanes" >&2
			exit 1
		}

		printf "%-16s %-8s %-8s %-10s %-21s %-9s %-21s\n" \
			"LANE" "ENABLED" "INTERVAL" "INSTALLED" "LAST_RUN" "LAST_EXIT" "NEXT_RUN"

		CONFIGURED_LANES=""

		if [ -n "$LANES_OUTPUT" ]; then
			while IFS="$(printf '\t')" read -r LANE INTERVAL ENABLED COMMAND; do
				[ -n "$LANE" ] || continue
				CONFIGURED_LANES="$CONFIGURED_LANES $LANE"

				if is_installed "$LANE"; then
					INSTALLED="yes"
				else
					INSTALLED="no"
				fi

				STATE="$(sync_state_read "$DATA_DIR" "$LANE")"
				if [ "$STATE" = "NEVER_RUN" ]; then
					LAST_RUN="NEVER_RUN"
					LAST_EXIT="-"
					if [ "$INSTALLED" = "yes" ]; then
						NEXT_RUN="on-next-interval"
					else
						NEXT_RUN="-"
					fi
				else
					IFS="$(printf '\t')" read -r LAST_START LAST_END LAST_EXIT <<EOF
$STATE
EOF
					LAST_RUN="$LAST_START"
					if [ "$INSTALLED" = "yes" ]; then
						START_EPOCH="$(iso_to_epoch "$LAST_START")"
						if [ -n "$START_EPOCH" ]; then
							NEXT_EPOCH=$((START_EPOCH + INTERVAL))
							NEXT_RUN="$(epoch_to_iso "$NEXT_EPOCH")"
						else
							NEXT_RUN="-"
						fi
					else
						NEXT_RUN="-"
					fi
				fi

				printf "%-16s %-8s %-8s %-10s %-21s %-9s %-21s\n" \
					"$LANE" "$ENABLED" "$INTERVAL" "$INSTALLED" "$LAST_RUN" "$LAST_EXIT" "$NEXT_RUN"
			done <<EOF
$LANES_OUTPUT
EOF
		fi

		if [ -d "$HOME/Library/LaunchAgents" ]; then
			for PLIST_PATH in "$HOME/Library/LaunchAgents/${LABEL_PREFIX}"*.plist; do
				[ -e "$PLIST_PATH" ] || continue
				BASENAME="$(basename "$PLIST_PATH" .plist)"
				LANE="${BASENAME#$LABEL_PREFIX}"
				case " $CONFIGURED_LANES " in
					*" $LANE "*)
						;;
					*)
						if is_installed "$LANE"; then
							INSTALLED="yes"
						else
							INSTALLED="no"
						fi
						STATE="$(sync_state_read "$DATA_DIR" "$LANE")"
						if [ "$STATE" = "NEVER_RUN" ]; then
							LAST_RUN="NEVER_RUN"
							LAST_EXIT="-"
						else
							IFS="$(printf '\t')" read -r LAST_START LAST_END LAST_EXIT <<EOF
$STATE
EOF
							LAST_RUN="$LAST_START"
						fi
						printf "%-16s %-8s %-8s %-10s %-21s %-9s %-21s\n" \
							"$LANE" "ORPHAN" "-" "$INSTALLED" "$LAST_RUN" "$LAST_EXIT" "-"
						;;
				esac
			done
		fi

		# Legacy detection (pre-rename installs): report, never auto-remove.
		if [ -d "$HOME/Library/LaunchAgents" ]; then
			for PLIST_PATH in "$HOME/Library/LaunchAgents/${LEGACY_LABEL_PREFIX}"*.plist; do
				[ -e "$PLIST_PATH" ] || continue
				BASENAME="$(basename "$PLIST_PATH" .plist)"
				echo "LEGACY $BASENAME  (pre-rename install; remove with: launchctl bootout gui/\$UID/$BASENAME; rm $PLIST_PATH)"
			done
		fi

		exit 0
		;;

	*)
		usage
		;;
esac
