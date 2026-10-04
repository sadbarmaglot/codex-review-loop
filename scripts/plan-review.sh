#!/usr/bin/env bash
#
# Check a plan against the code it proposes to change, before any of it is
# written.
#
#   plan-review.sh <plan file>
#
# Nothing like the code path: no snapshot, no throwaway worktree, no dependency
# install, no test run. A plan needs the repository readable, not runnable -
# which is why this costs a minute or two rather than the minutes a code review
# spends in the suite.
#
# Runs with OPENAI_API_KEY stripped so Codex authenticates with the ChatGPT
# login and the check is charged to the subscription, not to the API. Set
# REVIEW_LOOP_KEEP_API_KEY=1 to opt back into API billing.

set -uo pipefail


plan_file=${1:?plan file required}
# A regular file, readable, before anything else. -s alone passes a directory,
# whose size is never zero: the read below then fails, the plan text is empty,
# and a quiet reviewer turns that into "the plan is sound" without a plan ever
# having been read. A false clean is the one answer this must not give.
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

# The whole prompt goes as one argument, and Linux caps a single argument at
# about 128 KiB. Same limit, same variable as the diff it shares the adapter
# shape with.
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

# Narrow on purpose. A plan invites opinions, and opinions are what make a
# check like this worthless: the only useful answer is where the plan is wrong
# about the code that is actually there.
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

# Not configurable, on purpose. This adapter runs in the checkout the author
# is editing, so read-only is a property of the command rather than a default
# to be overridden, and the effort is pinned because Codex otherwise takes it
# from ~/.codex/config.toml, which is set for writing code - `high` there made
# the first run of this check four minutes long.
#
# REVIEW_LOOP_CODEX_FLAGS is deliberately not read here. It is shared with the
# adapters that review a snapshot in a throwaway worktree, where a wider
# sandbox costs nothing, and honouring it here meant guarding against every
# spelling of --sandbox, -s, --sandbox=, --config=sandbox_mode and the rest -
# a guard that grew longer than the adapter and would have to grow again with
# the next CLI release. Not reading the variable is shorter and cannot be got
# round. Model still comes from REVIEW_LOOP_CODEX_MODEL, which changes nothing
# about what the reviewer may touch.
flags=(--sandbox read-only --color never -c model_reasoning_effort="medium")
[ -n "${REVIEW_LOOP_CODEX_MODEL:-}" ] && flags+=(-m "$REVIEW_LOOP_CODEX_MODEL")

runner=(env)
[ -n "${REVIEW_LOOP_KEEP_API_KEY:-}" ] || runner=(env -u OPENAI_API_KEY)

# -o keeps the session banner and the progress chatter off stdout, so the
# report is the whole of it.
last_message=$(mktemp "${TMPDIR:-/tmp}/review-loop-plan.XXXXXX")

trap 'rm -f "$last_message"' EXIT

# No process handling here, deliberately. The code adapters background the
# reviewer and take its tree down on a signal because they hold a throwaway
# worktree and run a test suite in it for minutes. This one reads, read-only,
# for a minute or two and holds nothing: cancelling it leaves Codex to finish
# and spend that much quota, which is cheaper than the machinery that would
# stop it.
#
# stdin MUST be closed. codex exec takes the prompt as an argument but still
# waits on a non-terminal stdin, and a background caller's pipe never sends
# EOF - that is a real hang, and in the foreground nothing closes stdin for us.
#
# Codex's own stdout goes to stderr: the banner and the progress chatter are
# worth reading while it runs, and stdout belongs to the report alone.
"${runner[@]}" codex exec "${flags[@]}" -o "$last_message" "$prompt" >&2 </dev/null
rc=$?

cat "$last_message"
exit "$rc"
