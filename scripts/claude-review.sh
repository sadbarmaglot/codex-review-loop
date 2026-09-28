#!/usr/bin/env bash
#
# Reviewer adapter: Claude Code in print mode.
#
# The fallback when Codex is not installed. Same subscription rule: strip
# ANTHROPIC_API_KEY so the run goes through the logged-in subscription.
# A different model than the author is the point - two runs of the same model
# share their blind spots.

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

# stdin carries the prompt, so the per-argument limit does not apply here and
# truncating the diff would only lose defects the shared builder never showed.
export REVIEW_LOOP_MAX_DIFF_BYTES=0

prompt=$(build_prompt "$diff_file" "$prev_report")

model=${REVIEW_LOOP_CLAUDE_MODEL:-sonnet}

# This adapter runs in the repository itself, not in a throwaway copy, and
# `claude -p` inherits whatever the user's own permissions allow. A reviewer
# that can edit the tree it is judging invalidates the state its result is
# filed under, and contradicts the no-touch promise made for it.
#
# --tools decides what exists; --allowed-tools only decides what is permitted
# of what exists, so naming a read-only set there left Edit, Write and Bash in
# the session for any pre-authorised rule to reach. Both are given: the first
# takes the writers away, the second permits what remains without prompting,
# and --strict-mcp-config with no --mcp-config loads no MCP tools at all.
# The diff is in the prompt, so reading is all this needs anyway.
flags=${REVIEW_LOOP_CLAUDE_FLAGS:---tools Read,Grep,Glob --allowed-tools Read,Grep,Glob --strict-mcp-config}

# A hook inherits CLAUDECODE=1 and the CLI then refuses to start, warning that
# nested sessions share runtime resources and can crash the outer one. Unsetting
# it is the only way to review from inside a hook, and it is the reason Codex is
# the default reviewer: a separate binary has no such conflict. Untested from
# inside a live session - see docs/design.md.
runner=(env -u CLAUDECODE)
[ -n "${REVIEW_LOOP_KEEP_API_KEY:-}" ] || runner+=(-u ANTHROPIC_API_KEY)

# The prompt goes in on stdin, not in argv. `--disallowed-tools <tools...>` is
# variadic and swallows every following non-option argument, so a prompt placed
# after it was parsed as one more tool name and the review never happened.
# Feeding stdin sidesteps the option parser entirely, and sidesteps Linux's
# per-argument size limit with it. The pipe closes, which is what matters: the
# earlier `</dev/null` was there because a CLI left waiting on an open stdin
# hangs, and a closed pipe ends the same way.
#
# REVIEW_LOOP_DISABLE keeps the nested session from starting its own gate.
# shellcheck disable=SC2086
printf '%s' "$prompt" |
  "${runner[@]}" REVIEW_LOOP_DISABLE=1 claude -p --model "$model" $flags
