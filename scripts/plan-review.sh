#!/usr/bin/env bash
#
# Check a plan against the code it proposes to change, before it is written.
#
#   plan-review.sh <plan file>
#
# Read-only `codex exec` in the working tree: no snapshot, no worktree, no
# tests. Billed to the ChatGPT subscription unless REVIEW_LOOP_KEEP_API_KEY=1.

set -uo pipefail


plan_file=${1:?plan file required}
# A readable regular file: -s alone passes a directory, and an unread plan
# must not come back as a clean verdict.
[ -f "$plan_file" ] && [ -r "$plan_file" ] || {
  echo "not a readable file: $plan_file" >&2
  exit 2
}
[ -s "$plan_file" ] || {
  echo "the plan is empty: $plan_file" >&2
  exit 2
}

command -v codex >/dev/null 2>&1 || {
  echo "codex CLI not found on PATH" >&2
  exit 127
}

# The prompt is one argument; Linux caps an argument at about 128 KiB.
max_bytes=${REVIEW_LOOP_MAX_DIFF_BYTES:-100000}
read_failed() {
  echo "could not read the plan: $plan_file" >&2
  exit 2
}
if [ "$max_bytes" = 0 ]; then
  plan_text=$(cat "$plan_file") || read_failed
else
  plan_text=$(head -c "$max_bytes" "$plan_file") || read_failed
  [ "$(wc -c <"$plan_file")" -gt "$max_bytes" ] && plan_text="$plan_text
[plan truncated at $max_bytes bytes; the whole plan is at $plan_file]"
fi

prompt=$(cat <<EOF
You are reading a plan for changing the repository you are in, before any of it
is written. Read whatever of the code you need to judge it.

Report ONLY where the plan is wrong about this repository:
- it builds something the repository already has - name the file
- it breaks a caller, a migration, a test or a configuration it never mentions
- a step cannot work as described, or the order of two steps is wrong
- it rests on an assumption about the code that is false

Say nothing about style, wording, how the plan is written, or an approach you
would have preferred. Those are not defects.

Read the repository; do not run it. No tests, no build, no linters, no
installing anything. The sandbox stops you writing, not running, and a plan is
judged by reading the code it talks about - running the suite tells you nothing
about a change that has not been made yet, and costs minutes.

Format each remark as one entry:
<file or plan section> - what is wrong, and what it costs.

If the plan holds up against the code, reply with nothing at all: an empty
response is how you say so. Do not write that it looks good.

--- plan ---
$plan_text
--- end plan ---
EOF
)

# Fixed on purpose: this runs in the author's checkout, so the sandbox is not
# configurable and REVIEW_LOOP_CODEX_FLAGS is not read. Effort is pinned
# because Codex otherwise inherits it from the user's config.
flags=(--sandbox read-only --color never -c model_reasoning_effort="medium")
[ -n "${REVIEW_LOOP_CODEX_MODEL:-}" ] && flags+=(-m "$REVIEW_LOOP_CODEX_MODEL")

runner=(env)
[ -n "${REVIEW_LOOP_KEEP_API_KEY:-}" ] || runner=(env -u OPENAI_API_KEY)

# -o writes only the final message.
last_message=$(mktemp "${TMPDIR:-/tmp}/review-loop-plan.XXXXXX")

trap 'rm -f "$last_message"' EXIT

# stdin MUST be closed: codex exec waits on a non-terminal stdin, and in the
# foreground nothing closes it for us. Codex's own chatter goes to stderr.
"${runner[@]}" codex exec "${flags[@]}" -o "$last_message" "$prompt" >&2 </dev/null
rc=$?

cat "$last_message"
exit "$rc"
