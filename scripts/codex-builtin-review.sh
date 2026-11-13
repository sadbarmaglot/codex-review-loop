#!/usr/bin/env bash
#
# Reviewer adapter: `codex review` in place. It reads the working tree itself
# and ignores both arguments; scope is set by flags, and there is no follow-up
# mode. Never use it from the gate: it runs where Claude is working.

set -uo pipefail

command -v codex >/dev/null 2>&1 || {
  echo "codex CLI not found on PATH" >&2
  exit 127
}

# REVIEW_LOOP_CODEX_SCOPE: "--base main" or "--commit <sha>" instead.
scope=${REVIEW_LOOP_CODEX_SCOPE:---uncommitted}
flags=${REVIEW_LOOP_CODEX_FLAGS:-}
[ -n "${REVIEW_LOOP_CODEX_MODEL:-}" ] && flags="$flags -m ${REVIEW_LOOP_CODEX_MODEL}"

runner=(env)
[ -n "${REVIEW_LOOP_KEEP_API_KEY:-}" ] || runner=(env -u OPENAI_API_KEY)

# stdin closed: the CLI hangs waiting on a pipe that never ends.
# shellcheck disable=SC2086
exec "${runner[@]}" codex review $scope $flags </dev/null
