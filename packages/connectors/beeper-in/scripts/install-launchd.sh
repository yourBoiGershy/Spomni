#!/bin/bash
# Renders the beeper-in launchd plist template and installs it as a per-user
# launchd agent (gui/$UID). Idempotent: re-running bootout's the previous
# instance before bootstrapping the new one. Read-only against the repo
# except for creating the runtime log dir on real installs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

LABEL="com.relationship-agent.beeper-in"
INTERVAL=900
DRY_RUN=0
UNINSTALL=0

usage() {
	echo "Usage: $0 [--interval N] [--uninstall] [--dry-run]" >&2
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
		--interval)
			[ $# -ge 2 ] || usage
			INTERVAL="$2"
			shift 2
			;;
		--uninstall)
			UNINSTALL=1
			shift
			;;
		--dry-run)
			DRY_RUN=1
			shift
			;;
		*)
			usage
			;;
	esac
done

TEMPLATE="$SCRIPT_DIR/../launchd/com.relationship-agent.beeper-in.plist.template"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"

render_plist() {
	sed \
		-e "s#__REPO_ROOT__#$REPO_ROOT#g" \
		-e "s#__LABEL__#$LABEL#g" \
		-e "s#__INTERVAL__#$INTERVAL#g" \
		"$TEMPLATE"
}

if [ "$UNINSTALL" -eq 1 ]; then
	if [ "$DRY_RUN" -eq 1 ]; then
		echo "Would run: launchctl bootout gui/$UID/$LABEL"
		echo "Would remove: $PLIST_DEST"
		exit 0
	fi
	launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
	rm -f "$PLIST_DEST"
	echo "Uninstalled $LABEL (bootout + removed $PLIST_DEST)"
	exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
	render_plist
	exit 0
fi

DATA_DIR="$REPO_ROOT/data/connectors/beeper-in"
if [ ! -d "$DATA_DIR" ]; then
	echo "Creating runtime data dir: $DATA_DIR"
	mkdir -p "$DATA_DIR"
fi

mkdir -p "$HOME/Library/LaunchAgents"
render_plist > "$PLIST_DEST"

# Idempotent re-install: bootout any existing instance first.
launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID" "$PLIST_DEST"

echo "Installed $LABEL -> $PLIST_DEST (interval=${INTERVAL}s)"
