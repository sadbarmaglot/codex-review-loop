#!/usr/bin/env bash
#
# Stand-in reviewer for the gate tests. Mode comes from FAKE_MODE:
# empty | dirty | fail. Every call appends a line to FAKE_LOG.

set -uo pipefail

diff_file=${1:-}
prev_report=${2:-}

# What the reviewer was actually handed, kept where the test can read it: the
# context file is deleted when the run ends, and rightly so - it holds the
# conversation.
[ -n "${FAKE_PREV_DUMP:-}" ] && [ -s "${prev_report:-}" ] && cp "$prev_report" "$FAKE_PREV_DUMP"

[ -n "${FAKE_LOG:-}" ] &&
  printf 'call diff=%s prev=%s snapshot=%s\n' \
    "$diff_file" "$prev_report" "${REVIEW_LOOP_SNAPSHOT:-none}" >>"$FAKE_LOG"

case ${FAKE_MODE:-dirty} in
  empty) : ;;
  slow)
    sleep "${FAKE_SLEEP:-5}"
    echo "src/a.py:12 - off-by-one on the last row, empty input returns None"
    ;;
  fail)
    echo "reviewer exploded" >&2
    exit 3
    ;;
  *) echo "src/a.py:12 - off-by-one on the last row, empty input returns None" ;;
esac
