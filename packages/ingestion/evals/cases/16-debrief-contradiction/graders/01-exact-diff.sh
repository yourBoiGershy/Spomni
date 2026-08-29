#!/bin/bash
# $1 = worked store dir, $2 = result.json (unused — this grader diffs the
# worked store against expected/ via the runner's built-in byte-diff grader).
"$RA_GRADER_DIFF" "$1"
