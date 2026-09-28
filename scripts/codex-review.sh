#!/usr/bin/env bash
#
# Reviewer adapter: OpenAI Codex CLI.
#
# Runs with OPENAI_API_KEY stripped so Codex authenticates with the ChatGPT
# login and the review is charged to the subscription, not to the API. Set
# REVIEW_LOOP_KEEP_API_KEY=1 to opt back into API billing.

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

# Flags live in one overridable variable: Codex CLI renames them between
# releases, and a rename should be a config change, not a patch. Verified
# against codex-cli 0.157.1; check yours with `codex exec --help`.
flags=${REVIEW_LOOP_CODEX_FLAGS:---sandbox read-only --color never}
[ -n "${REVIEW_LOOP_CODEX_MODEL:-}" ] && flags="$flags -m ${REVIEW_LOOP_CODEX_MODEL}"

runner=(env)
[ -n "${REVIEW_LOOP_KEEP_API_KEY:-}" ] || runner=(env -u OPENAI_API_KEY)

# codex exec prints a session banner and progress to stdout, which would make
# the first line of the report something other than CLEAN. -o writes just the
# final message; everything else is kept on stderr for debugging.
last_message=$(mktemp "${TMPDIR:-/tmp}/review-loop-codex.XXXXXX")
trap 'rm -f "$last_message"' EXIT

# stdin MUST be closed. codex exec takes the prompt as an argument, but when
# stdin is not a terminal it also waits to append whatever is piped in - and a
# hook's stdin never sends EOF, so the review hangs until the hook times out.
# shellcheck disable=SC2086
"${runner[@]}" codex exec $flags -o "$last_message" "$prompt" >&2 </dev/null
rc=$?

cat "$last_message"
exit "$rc"
