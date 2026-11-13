#!/usr/bin/env bash
#
# Reviewer adapter that runs several reviewers at once and concatenates their
# reports under headings. One reviewer is inconsistent; copies cure that, and
# a second model adds a different view.

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/diff.sh
. "$here/diff.sh"

stage() { printf '[review-loop] %s\n' "$1" >&2; }

# REVIEW_LOOP_FANOUT_REVIEWER: one reviewer means REVIEW_LOOP_FANOUT copies of
# it; a colon-separated list ("codex-worktree:claude") means one worker each.
# Short names are the plugin's own adapters. Put the worktree adapter first:
# only the first worker gets the setup command.
reviewers=()
named=()
if [ -x "${REVIEW_LOOP_FANOUT_REVIEWER:-}" ] && [ ! -d "${REVIEW_LOOP_FANOUT_REVIEWER:-}" ]; then
  # A value that is itself an executable is one path, never a list.
  named=("$REVIEW_LOOP_FANOUT_REVIEWER")
else
  IFS=: read -r -a named <<<"${REVIEW_LOOP_FANOUT_REVIEWER:-}"
fi
for inner in ${named[@]+"${named[@]}"}; do
  # Trim, and drop blank entries.
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
  # Itself as a worker would fan out again without end. Compared by file.
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
pids=()

# By the tree: without job control a background child leads no process group.
kill_tree() {
  local p=$1 child
  for child in $(pgrep -P "$p" 2>/dev/null); do kill_tree "$child"; done
  kill "$p" 2>/dev/null
}

# The workers go down with this script; the signal handlers must exit.
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

# Only the first worker installs dependencies and runs the tests; the others
# are told not to, or they report the resulting failures as findings.
pids=()
for i in $(seq 1 "$n"); do
  inner=${reviewers[$((i - 1))]}
  if [ "$i" = 1 ]; then
    "$inner" "$diff_file" "$prev_report" >"$tmp/out.$i" 2>"$tmp/err.$i" &
  else
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
  # Reaped: the pid may be reused, so cleanup must not signal it.
  unset 'pids[$i]'

  stage "$((i + 1)) of $n reviewers done"
done

# All failing is a failure; some failing is a thinner review.
if [ "$failed" -ge "$n" ]; then
  echo "all $n reviewers failed; last error follows" >&2
  cat "$tmp/err.$n" >&2
  exit 1
fi

# Only reviewers that exited 0 are quoted, each under the adapter's name.
said_something=0
for i in "${ok[@]}"; do
  body=$(cat "$tmp/out.$i" 2>/dev/null)
  [ -z "${body//[$' \t\n\r']/}" ] && continue
  said_something=1
  who=$(basename "${reviewers[$((i - 1))]}" .sh)
  printf '### Reviewer %s of %s (%s)\n\n%s\n\n' "$i" "$n" "$who" "$body"
done

# Stated even when the survivors were silent: that is not a full clean.
if [ "$failed" -gt 0 ]; then
  printf '_%d of %d reviewers failed to run; this review is thinner than usual._\n' \
    "$failed" "$n"
fi

exit 0
