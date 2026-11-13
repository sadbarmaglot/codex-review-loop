#!/usr/bin/env bash
#
# Build the reviewer prompt. Sourced by the reviewer adapters so every backend
# is judged on the same instructions.
#
#   build_prompt <diff_file> [prev_report]  -> prompt on stdout

build_prompt() {
  local diff_file=$1 prev_report=${2:-}
  # The prompt is one argument, and Linux caps an argument at about 128 KiB;
  # diff and history share it. Zero means no cap, for adapters using stdin.
  local max_bytes=${REVIEW_LOOP_MAX_DIFF_BYTES:-100000}
  local max_prev=${REVIEW_LOOP_MAX_PREV_BYTES:-20000}
  local diff_text size

  if [ "$max_bytes" = 0 ]; then
    diff_text=$(cat "$diff_file")
    size=0
    max_bytes=0
  else
    diff_text=$(head -c "$max_bytes" "$diff_file")
    size=$(wc -c <"$diff_file")
  fi
  if [ "$max_bytes" != 0 ] && [ "$size" -gt "$max_bytes" ]; then
    diff_text="$diff_text
[diff truncated at $max_bytes bytes; the whole diff is at $diff_file]"
  fi

  cat <<EOF
You are reviewing a diff written by another engineer. Judge only what the diff
changes; the surrounding code is context, not your subject.

Report ONLY defects: logic that yields a wrong result, a crash, data loss, a
race, a resource leak, an unhandled error path, a security hole, or a test that
cannot fail. Style, naming, formatting, architecture taste, "consider
extracting" and missing-documentation notes are out of scope and must not be
reported.

Format each defect as one entry:
<file>:<line> - what breaks, and the input or state that triggers it.

No preamble, no summary, no praise, no restating the diff.
EOF

  if [ -n "$prev_report" ] && [ -f "$prev_report" ]; then
    cat <<EOF

Earlier rounds on this repository, and the author's answer to each, are below.
Treat them as context, not as a limit on what you may report: any defect you
find is in scope, raised before or not.

Where the author says a finding was fixed, check the fix rather than take their
word. Where the author declined one and gave a reason, do not raise it again
unless the reason is wrong - and then say why it is wrong.

--- history ---
$(tail -c "$max_prev" "$prev_report")
--- end history ---
EOF
  fi

  cat <<EOF

If there is nothing to fix, reply with nothing at all: an empty response is how
you say the change is sound. Do not write that it looks good.

--- diff ---
$diff_text
--- end diff ---
EOF
}
