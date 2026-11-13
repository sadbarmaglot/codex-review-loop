#!/usr/bin/env bash
#
# Reviewer adapter: `codex review --commit` inside a throwaway worktree of the
# change, so the reviewer can run tests without touching the author's tree.
#
# argv[1], the diff file, is ignored: the snapshot is the subject. argv[2] is
# the journal of earlier rounds, handed over through AGENTS.md.

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/diff.sh
. "$here/diff.sh"
# shellcheck source=scripts/snapshot.sh
. "$here/snapshot.sh"

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
# Physical path: /var is a symlink on macOS, and path rewriting matches text.
tmp=$(cd "$tmp" && pwd -P)
wt=$tmp/wt

# No global `git worktree prune`: it would drop the user's own registrations.
cleanup() {
  if [ -d "$wt" ]; then
    git worktree remove --force "$wt" >/dev/null 2>&1 ||
      echo "review-loop: could not remove worktree $wt; run 'git worktree prune'" >&2
  fi
  rm -rf "$tmp"
}
# The signal handlers exit, and take the reviewer's process tree down first.
kill_child() {
  [ -n "${KILLABLE_PID:-}" ] && kill_tree "$KILLABLE_PID"
  return 0
}
trap 'kill_child; cleanup' EXIT
trap 'kill_child; cleanup; exit 130' INT
trap 'kill_child; cleanup; exit 143' TERM

stage "snapshotting the change"

# Normally taken by run-review.sh, so the review covers the state it is filed
# under.
sha=${REVIEW_LOOP_SNAPSHOT:-}
if [ -z "$sha" ]; then
  repo=$(git rev-parse --show-toplevel 2>/dev/null) || exit 1
  sha=$(make_snapshot "$repo" "$tmp/index") || exit 1  # no frozen base here: this path runs alone
fi

git worktree add --detach -q "$wt" "$sha" || exit 1

# Without a setup command the reviewer can read the code but not run it.
if [ -n "${REVIEW_LOOP_SETUP_CMD:-}" ]; then
  stage "installing dependencies"
  # A broken checkout fails the review rather than reporting tests that never ran.
  if ! (cd "$wt" && eval "$REVIEW_LOOP_SETUP_CMD") >&2 2>&1; then
    echo "REVIEW_LOOP_SETUP_CMD failed; the checkout cannot run anything" >&2
    exit 1
  fi
fi

runner=(env)
[ -n "${REVIEW_LOOP_KEEP_API_KEY:-}" ] || runner=(env -u OPENAI_API_KEY)

# Pinned: otherwise the effort comes from the user's ~/.codex/config.toml.
flags=${REVIEW_LOOP_CODEX_FLAGS:--c model_reasoning_effort="medium"}
[ -n "${REVIEW_LOOP_CODEX_MODEL:-}" ] && flags="$flags -m ${REVIEW_LOOP_CODEX_MODEL}"

stage "reviewing"
root=$(git rev-parse --show-toplevel 2>/dev/null)

# Escaped for sed: a repository path may hold & | / and the rest.
esc_pat=$(printf '%s' "$wt/" | sed 's/[][\\.*^$|&/]/\\&/g')
esc_rep=$(printf '%s' "${root:+$root/}" | sed 's/[\\&|/]/\\&/g')

# add_instructions <file>
#
# Append to the reviewer's instruction files in the worktree. `codex review`
# takes no prompt beside a scope flag, so AGENTS.md is the channel. A symlink
# is replaced by a copy first, or the append would land outside the worktree.
add_instructions() {
  local src=$1 target content
  for target in "$wt/AGENTS.md" "$wt/AGENTS.override.md"; do
    # An override file is appended to only where the repository has one.
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
  # Worded as background: as a standing instruction to verify, it made the
  # reviewer re-run the test suite once per claim.
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
# Backgrounded so the wait is interruptible. The reviewer names files inside
# the worktree; sed points them back at the author's tree.
# shellcheck disable=SC2086
raw=$tmp/review.out
run_killable "$raw" "$tmp/review.err" "${runner[@]}" codex review $flags --commit "$sha"
rc=$?
cat "$tmp/review.err" >&2
sed "s/$esc_pat/$esc_rep/g" <"$raw"
sed_rc=$?
status=("$rc" "$sed_rc")
# Either half failing is a failed review.
[ "${status[0]}" -ne 0 ] && exit "${status[0]}"
exit "${status[1]}"
