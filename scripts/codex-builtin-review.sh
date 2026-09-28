#!/usr/bin/env bash
#
# Reviewer adapter: Codex's own `codex review`.
#
# It picks the changes itself and brings its own review instructions, so it
# ignores the diff file the gate passes and reads the working tree directly.
# In exchange the report is better shaped than a hand-rolled prompt's - it
# carries severity labels and line ranges - and stdout holds the report alone,
# with the session chatter on stderr.
#
# Two consequences of `codex review` taking no custom prompt:
#   - review scope is set by flags, not by words: --uncommitted, --base, --commit
#   - there is no follow-up mode, so argv[2] is ignored too
# Use codex-review.sh when either matters.

set -uo pipefail

command -v codex >/dev/null 2>&1 || {
  echo "codex CLI not found on PATH" >&2
  exit 127
}

# --uncommitted covers staged, unstaged and untracked. REVIEW_LOOP_CODEX_SCOPE
# swaps in "--base main" to review a whole branch, or "--commit <sha>" for one.
scope=${REVIEW_LOOP_CODEX_SCOPE:---uncommitted}
flags=${REVIEW_LOOP_CODEX_FLAGS:-}
[ -n "${REVIEW_LOOP_CODEX_MODEL:-}" ] && flags="$flags -m ${REVIEW_LOOP_CODEX_MODEL}"

runner=(env)
[ -n "${REVIEW_LOOP_KEEP_API_KEY:-}" ] || runner=(env -u OPENAI_API_KEY)

# stdin closed: a CLI that waits on a piped prompt hangs forever under a hook.
# shellcheck disable=SC2086
exec "${runner[@]}" codex review $scope $flags </dev/null
