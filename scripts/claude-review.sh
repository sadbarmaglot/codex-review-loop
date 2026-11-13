#!/usr/bin/env bash
#
# Reviewer adapter: `claude -p`, read-only, billed to the Claude subscription.

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/review-prompt.sh
. "$here/review-prompt.sh"

diff_file=${1:?diff file required}
prev_report=${2:-}

command -v claude >/dev/null 2>&1 || {
  echo "claude CLI not found on PATH" >&2
  exit 127
}

# The prompt goes in on stdin, so the argv size cap does not apply.
export REVIEW_LOOP_MAX_DIFF_BYTES=0

prompt=$(build_prompt "$diff_file" "$prev_report")

model=${REVIEW_LOOP_CLAUDE_MODEL:-sonnet}

# Runs in the repository itself, so writing must be impossible, not merely
# unpermitted: --tools removes Edit/Write/Bash, --allowed-tools permits the rest.
flags=${REVIEW_LOOP_CLAUDE_FLAGS:---tools Read,Grep,Glob --allowed-tools Read,Grep,Glob --strict-mcp-config}

# The CLI refuses to start under CLAUDECODE=1.
runner=(env -u CLAUDECODE)
[ -n "${REVIEW_LOOP_KEEP_API_KEY:-}" ] || runner+=(-u ANTHROPIC_API_KEY)

# Prompt on stdin: variadic tool flags would swallow it as an argument.
# REVIEW_LOOP_DISABLE keeps the nested session from starting its own gate.
# shellcheck disable=SC2086
printf '%s' "$prompt" |
  "${runner[@]}" REVIEW_LOOP_DISABLE=1 claude -p --model "$model" $flags
