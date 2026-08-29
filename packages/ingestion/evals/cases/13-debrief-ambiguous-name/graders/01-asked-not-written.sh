#!/bin/bash
# $1 = worked store dir, $2 = result.json — the skill must have asked a
# clarifying question (result text contains "?") AND left the store
# byte-identical to before/ (no guessed write).
"$RA_GRADER_ASKED" "$1" "$2"
