#!/usr/bin/env bash
#
# Reviewer adapter: prompt-driven `codex exec`, read-only, billed to the
# ChatGPT subscription. REVIEW_LOOP_KEEP_API_KEY=1 opts back into API billing.

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/review-prompt.sh
. "$here/review-prompt.sh"

diff_file=${1:?diff file required}
prev_report=${2:-}

command -v codex >/dev/null 2>&1 || {
  echo "codex CLI not found on PATH" >&2
  exit 127
}

prompt=$(build_prompt "$diff_file" "$prev_report")

# Overridable: the CLI renames flags between releases.
flags=${REVIEW_LOOP_CODEX_FLAGS:---sandbox read-only --color never}
[ -n "${REVIEW_LOOP_CODEX_MODEL:-}" ] && flags="$flags -m ${REVIEW_LOOP_CODEX_MODEL}"

runner=(env)
[ -n "${REVIEW_LOOP_KEEP_API_KEY:-}" ] || runner=(env -u OPENAI_API_KEY)

# -o writes only the final message; the banner and progress go to stderr.
last_message=$(mktemp "${TMPDIR:-/tmp}/review-loop-codex.XXXXXX")
trap 'rm -f "$last_message"' EXIT

# stdin MUST be closed: codex exec waits on a non-terminal stdin.
# shellcheck disable=SC2086
"${runner[@]}" codex exec $flags -o "$last_message" "$prompt" >&2 </dev/null
rc=$?

cat "$last_message"
exit "$rc"
