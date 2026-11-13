#!/usr/bin/env bash
#
# Reviewer adapter that runs several reviewers at once and hands back all of
# their reports.
#
# The reason is measured, not theoretical: over four runs against one unchanged
# diff, this reviewer found a real defect twice and declared the same code sound
# twice. One pass misses roughly half the time, three miss together roughly an
# eighth of the time. Wall clock barely moves, because the passes overlap.
#
# Each copy gets its own worktree - they run the project's test suite, and two
# suites in one checkout would collide. Reports are concatenated, never merged:
# the gate does not read them, and Claude is better placed to notice that two
# reviewers said the same thing than a third model would be.

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/diff.sh
. "$here/diff.sh"

# Stderr reaches the background task's output file, where progress can be read.
stage() { printf '[review-loop] %s\n' "$1" >&2; }

# One reviewer named means N copies of it, as before. Several named means one
# worker each, and the list decides the count, not REVIEW_LOOP_FANOUT. Two
# models disagree about different things, where two runs of one model mostly
# disagree about nothing.
#
#   REVIEW_LOOP_FANOUT_REVIEWER="codex-worktree:claude"
#
# Colon-separated, as PATH is. Splitting on whitespace broke every path with a
# space in it, the default included, and left no way to quote one. A name
# without a slash is one of the plugin's own adapters; a path is a path.
#
# Put the worktree adapter first: only the first worker is given the setup
# command, and it is the only kind that can use one.
reviewers=()
named=()
if [ -x "${REVIEW_LOOP_FANOUT_REVIEWER:-}" ] && [ ! -d "${REVIEW_LOOP_FANOUT_REVIEWER:-}" ]; then
  # One path, whatever characters it holds: a value that is itself an
  # executable is never parsed as a list.
  named=("$REVIEW_LOOP_FANOUT_REVIEWER")
else
  IFS=: read -r -a named <<<"${REVIEW_LOOP_FANOUT_REVIEWER:-}"
fi
for inner in ${named[@]+"${named[@]}"}; do
  # Blank entries are dropped, so "a::b" and a value of nothing but spaces
  # mean what they look like rather than naming a reviewer called "".
  # Trimmed, so "a : b" reads as it looks.
  inner=${inner#"${inner%%[![:space:]]*}"}
  inner=${inner%"${inner##*[![:space:]]}"}
  [ -n "$inner" ] && reviewers+=("$(resolve_reviewer "$inner" "$here")")
done
[ "${#reviewers[@]}" -gt 0 ] || reviewers=("$here/codex-worktree-review.sh")
n=${REVIEW_LOOP_FANOUT:-3}
case $n in ''|*[!0-9]*|0) n=1 ;; esac
if [ "${#reviewers[@]}" -gt 1 ]; then
  n=${#reviewers[@]}
else
  for ((i = 1; i < n; i++)); do reviewers+=("${reviewers[0]}"); done
fi

diff_file=${1:-/dev/null}
prev_report=${2:-}

for inner in "${reviewers[@]}"; do
  # Itself as a worker inherits this list and fans out again, without end.
  # By file, not by name, so a full path to this script is caught too.
  [ "$inner" -ef "${BASH_SOURCE[0]}" ] && {
    echo "the fan-out cannot be one of its own reviewers: $inner" >&2
    exit 1
  }
  [ -x "$inner" ] || {
    echo "fan-out reviewer $inner is not executable" >&2
    exit 1
  }
done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/review-loop-fan.XXXXXX")
# Cleanup on EXIT; the handlers exit, because a trapped signal replaces
# bash's default and a script that only cleans up carries on - here, far
# enough to return success for a review that was cancelled.
# The workers go down with it. A signal delivered to this shell alone left
# them running: Codex processes still grinding tests and holding worktrees for
# a review already cancelled, writing into paths already deleted.
pids=()

# By the tree, not by the group. Without job control a background child stays
# in this shell's process group rather than leading one of its own, so killing
# "-$pid" fails and only the wrapper dies - leaving the reviewer it was waiting
# on still running, still holding a worktree.
kill_tree() {
  local p=$1 child
  for child in $(pgrep -P "$p" 2>/dev/null); do kill_tree "$child"; done
  kill "$p" 2>/dev/null
}

cleanup() {
  local p
  for p in ${pids[@]+"${pids[@]}"}; do kill_tree "$p"; done
  for p in ${pids[@]+"${pids[@]}"}; do wait "$p" 2>/dev/null; done
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

stage "$n reviewers starting"

# Only the first copy installs the project's dependencies, and so only the
# first can run its tests. The suite is deterministic: running it in every
# worker buys the same answer N times, at N times the setup and N times the
# slowest part of the review. The others read the same snapshot without it.
pids=()
for i in $(seq 1 "$n"); do
  inner=${reviewers[$((i - 1))]}
  if [ "$i" = 1 ]; then
    "$inner" "$diff_file" "$prev_report" >"$tmp/out.$i" 2>"$tmp/err.$i" &
  else
    # Told not to run them, not merely left unable to. Without the
    # dependencies a reviewer that tries anyway reports the failures as
    # findings - defects invented by this optimisation - and where the
    # dependencies happen to be installed globally it runs the suite after all.
    env -u REVIEW_LOOP_SETUP_CMD REVIEW_LOOP_NO_TESTS=1 \
      "$inner" "$diff_file" "$prev_report" >"$tmp/out.$i" 2>"$tmp/err.$i" &
  fi
  pids+=($!)
done

failed=0
ok=()
for i in "${!pids[@]}"; do
  if wait "${pids[$i]}"; then
    ok+=("$((i + 1))")
  else
    failed=$((failed + 1))
  fi
  # Reaped, so no longer ours to signal. A number that has been waited for can
  # be handed to any process the system likes, and cleanup would then kill a
  # stranger and its children - the same mistake as killing by name.
  unset 'pids[$i]'

  stage "$((i + 1)) of $n reviewers done"
done

# Every reviewer failing is a failure; some failing is a thinner review, which
# is still worth having and must not cost the user their turn.
if [ "$failed" -ge "$n" ]; then
  echo "all $n reviewers failed; last error follows" >&2
  cat "$tmp/err.$n" >&2
  exit 1
fi

# Only reviewers that exited 0 are quoted. A crash can still have printed a
# half-finished thought, and passing that off as a finding would block the turn
# on something no reviewer stands behind.
said_something=0
for i in "${ok[@]}"; do
  body=$(cat "$tmp/out.$i" 2>/dev/null)
  [ -z "${body//[$' \t\n\r']/}" ] && continue
  said_something=1
  # Named, because with a mixed list who said it is part of the finding: two
  # models agreeing is evidence that two runs of one model are not.
  who=$(basename "${reviewers[$((i - 1))]}" .sh)
  printf '### Reviewer %s of %s (%s)\n\n%s\n\n' "$i" "$n" "$who" "$body"
done

# Said before the silence check, not after. Silence from the survivors of a
# partial failure is not the same as silence from a full complement: reported
# as clean, it records a state as reviewed that most of the reviewers never
# finished looking at.
if [ "$failed" -gt 0 ]; then
  printf '_%d of %d reviewers failed to run; this review is thinner than usual._\n' \
    "$failed" "$n"
fi

# Silence from all of them is silence, not a finding.
exit 0
