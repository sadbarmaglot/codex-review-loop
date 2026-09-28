#!/usr/bin/env bash
#
# Reviewer adapter: `codex review` inside a throwaway worktree of the change.
#
# This is the only adapter that lets the reviewer run the code it is judging.
# `codex review` executes the project's tests and linters, which is worth having
# and must not happen in the tree Claude is editing - so the change is snapshot
# into its own worktree and the reviewer is let loose there instead.
#
# The snapshot touches neither the index, nor HEAD, nor any ref: a temporary
# index builds a tree, commit-tree hangs a commit off HEAD, and the worktree is
# checked out at that commit. The commit belongs to no branch and is collected
# as garbage in its own time. Because the change arrives as a commit rather than
# as working-tree noise, `codex review --commit` describes it exactly.
#
# argv[1], the diff file, is ignored: the snapshot is the subject. argv[2] is
# the journal of earlier rounds, and is passed to the reviewer as its prompt.

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/diff.sh
. "$here/diff.sh"
# shellcheck source=scripts/snapshot.sh
. "$here/snapshot.sh"

# Stages go to stderr, which lands in the background task's output file, so a
# run in flight can be read rather than guessed at.
stage() { printf '[review-loop] %s\n' "$1" >&2; }

command -v codex >/dev/null 2>&1 || {
  echo "codex CLI not found on PATH" >&2
  exit 127
}
git rev-parse --show-toplevel >/dev/null 2>&1 || {
  echo "not inside a git repository" >&2
  exit 1
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/review-loop-wt.XXXXXX")
# The physical path: on macOS /var is a symlink to /private/var, so a process
# that cd's here reports the resolved form and string matching on the original
# silently fails. Rewriting the reviewer's paths depends on the two agreeing.
tmp=$(cd "$tmp" && pwd -P)
wt=$tmp/wt

# No global `git worktree prune` here: it would also drop registrations for the
# user's own worktrees whose directories happen to be missing at that moment.
cleanup() {
  if [ -d "$wt" ]; then
    git worktree remove --force "$wt" >/dev/null 2>&1 ||
      echo "review-loop: could not remove worktree $wt; run 'git worktree prune'" >&2
  fi
  rm -rf "$tmp"
}
# Cleanup on EXIT; the handlers exit, because a trapped signal replaces
# bash's default and a script that only cleans up carries on - here, far
# enough to return success for a review that was cancelled.
# The child goes too. Bash defers a trap while it waits on a foreground child,
# so a handler that only exits leaves Codex running its tests and holding this
# worktree long after the review was cancelled.
kill_child() {
  [ -n "${KILLABLE_PID:-}" ] && kill_tree "$KILLABLE_PID"
  return 0
}
trap 'kill_child; cleanup' EXIT
trap 'kill_child; cleanup; exit 130' INT
trap 'kill_child; cleanup; exit 143' TERM

stage "snapshotting the change"

# Taken by the gate while it still held the turn, when it is set. Detached, this
# script runs minutes later, and photographing the tree then would review a
# state nobody recorded a hash for.
sha=${REVIEW_LOOP_SNAPSHOT:-}
if [ -z "$sha" ]; then
  repo=$(git rev-parse --show-toplevel 2>/dev/null) || exit 1
  sha=$(make_snapshot "$repo" "$tmp/index") || exit 1  # no frozen base here: this path runs alone
fi

git worktree add --detach -q "$wt" "$sha" || exit 1

# Without a setup command the reviewer still reads everything; it just cannot
# run anything, because a fresh worktree has no virtualenv. For this repo:
#   REVIEW_LOOP_SETUP_CMD='cd proactive-agents && env -u UV_PROJECT_ENVIRONMENT uv sync'
if [ -n "${REVIEW_LOOP_SETUP_CMD:-}" ]; then
  stage "installing dependencies"
  # A reviewer that promised a runnable checkout and got a broken one is worse
  # than no reviewer: it reports that the tests pass when they never ran.
  if ! (cd "$wt" && eval "$REVIEW_LOOP_SETUP_CMD") >&2 2>&1; then
    echo "REVIEW_LOOP_SETUP_CMD failed; the checkout cannot run anything" >&2
    exit 1
  fi
fi

runner=(env)
[ -n "${REVIEW_LOOP_KEEP_API_KEY:-}" ] || runner=(env -u OPENAI_API_KEY)

# Without this the review inherits model_reasoning_effort from the user's own
# ~/.codex/config.toml. Theirs says high, which turned two-minute reviews into
# eight-minute ones; a review is not the place that setting was chosen for.
flags=${REVIEW_LOOP_CODEX_FLAGS:--c model_reasoning_effort="medium"}
[ -n "${REVIEW_LOOP_CODEX_MODEL:-}" ] && flags="$flags -m ${REVIEW_LOOP_CODEX_MODEL}"

stage "reviewing"
root=$(git rev-parse --show-toplevel 2>/dev/null)

# sed reads both sides as expressions: an & in the replacement stands for the
# whole match, and a | would end the s command early. A repository path is not
# ours to choose, so escape it rather than hope.
esc_pat=$(printf '%s' "$wt/" | sed 's/[][\\.*^$|&/]/\\&/g')
esc_rep=$(printf '%s' "${root:+$root/}" | sed 's/[\\&|/]/\\&/g')

# What earlier rounds said and what the author did about it.
#
# Not as an argument: `codex review` refuses a prompt alongside any scope flag,
# `--commit` included, however much its usage line suggests otherwise. The
# channel it does read is AGENTS.md - it goes looking for one itself, as its own
# command log shows. The worktree is thrown away afterwards, so writing there
# costs nothing, and this appends rather than replaces: the project's own
# instructions are part of what the reviewer should know.
# One worker of a fan-out installs the dependencies and runs the suite; the
# rest are told plainly to leave it alone, because a checkout without
# dependencies produces failures that look like findings.

# add_instructions <file>
#
# Append to the reviewer's instruction files inside the throwaway worktree.
# Both names, because Codex looks for AGENTS.md and AGENTS.override.md and
# which of them wins is documented nowhere I could check; a symlink is replaced
# by a copy of its content first, or the append would follow it out of the
# worktree and into a file the cleanup never touches.
#
# Everything that has something to tell the reviewer goes through here. The
# second writer that did not was exactly how both of those faults came back.
add_instructions() {
  local src=$1 target content
  for target in "$wt/AGENTS.md" "$wt/AGENTS.override.md"; do
    # An override this repository does not have is not ours to invent: it may
    # outrank the instructions it already has.
    [ -e "$target" ] || [ "$target" = "$wt/AGENTS.md" ] || continue
    if [ -L "$target" ]; then
      content=$(cat "$target" 2>/dev/null)
      rm -f "$target"
      printf '%s\n' "$content" >"$target"
    fi
    cat "$src" >>"$target"
  done
}

if [ -n "${REVIEW_LOOP_NO_TESTS:-}" ]; then
  {
    printf '\n\n# Do not run this project\x27s tests or build tools\n\n'
    printf 'Another reviewer is running them against this same change. This\n'
    printf 'checkout deliberately has no dependencies installed, so anything you\n'
    printf 'run here fails for reasons that are not defects. Review by reading.\n'
  } >"$tmp/no-tests.md"
  add_instructions "$tmp/no-tests.md"
fi

journal=${2:-}
if [ -n "$journal" ] && [ -s "$journal" ]; then
  # Worded as background, deliberately. An earlier version said "check the fix
  # rather than take the author's word", and this file is standing instructions
  # for the whole session rather than a note read once: the reviewer took it as
  # a running duty and re-ran the project's test suite eighteen times, once per
  # claim it wanted to confirm, for ten minutes. Read once, verified by reading.
  {
    printf '\n\n# Review history (background, read once)\n\n'
    printf 'Earlier rounds of review on this repository, and the author'"'"'s answer\n'
    printf 'to each, are below. This is background, not a task: do not re-run the\n'
    printf 'project'"'"'s tests or tools to confirm it, and judge any claimed fix by\n'
    printf 'reading the code you are already reviewing.\n\n'
    printf 'It is context, not a limit on what you may report: any defect you find\n'
    printf 'is in scope, raised before or not. Where the author declined a finding\n'
    printf 'and gave a reason, do not raise it again unless that reason is wrong -\n'
    printf 'and then say why it is wrong.\n\n'
    cat "$journal"
  } >"$tmp/history.md"
  add_instructions "$tmp/history.md"
fi

cd "$wt" || exit 1
# `codex review --commit` takes no --color and no --sandbox; its usage is
# `codex review --commit <SHA> [PROMPT]`, so options go before it.
#
# The reviewer names files by where it read them, which is the throwaway
# checkout: a path that cannot be opened and will not exist in a minute. Point
# them back at the working tree the author is actually editing.
# shellcheck disable=SC2086
# Backgrounded through run_killable so the wait is interruptible; the sed that
# rewrites paths runs afterwards, on the captured output.
raw=$tmp/review.out
run_killable "$raw" "$tmp/review.err" "${runner[@]}" codex review $flags --commit "$sha"
rc=$?
cat "$tmp/review.err" >&2
sed "s/$esc_pat/$esc_rep/g" <"$raw"
sed_rc=$?
status=("$rc" "$sed_rc")
# Either half failing is a failed review. Taking only the reviewer's status once
# let a broken sed pass an empty report off as a clean one - and the literal
# zero that stood here said the same thing in a way the comment hid.
[ "${status[0]}" -ne 0 ] && exit "${status[0]}"
exit "${status[1]}"
