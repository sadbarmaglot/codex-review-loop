#!/usr/bin/env bash
#
# Review the working tree and print what comes back.
#
# Claude runs this as a background task, and Claude Code wakes the session
# with the output. The result is filed under the gate's hash, so the gate
# stops asking about this state.

set -uo pipefail

# The results directory holds patches of the user's source and reviewer logs.
umask 077

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/diff.sh
. "$here/diff.sh"
# shellcheck source=scripts/snapshot.sh
. "$here/snapshot.sh"

REVIEWER=${REVIEW_LOOP_REVIEWER:-$here/codex-worktree-review.sh}
# A bare name is one of the plugin's own adapters: "fanout", "claude".
REVIEWER=$(resolve_reviewer "$REVIEWER" "$here")

# --after "<what I did with the last findings>"
#
# The reviewer has no memory between rounds; this note goes into the journal
# so it knows what was fixed and what was declined.
after=""
while [ $# -gt 0 ]; do
  case $1 in
    --after)
      # A bare --after would loop for ever: shift 2 fails with one argument.
      [ $# -ge 2 ] || {
        echo "usage: run-review.sh [--after \"what you did with the last findings\"]" >&2
        exit 64
      }
      after=$2
      shift 2
      ;;
    --after=*) after=${1#--after=}; shift ;;
    *) shift ;;
  esac
done

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "not inside a git repository" >&2
  exit 1
}

state_dir=$(state_root)
results=$state_dir/results
mkdir -p "$results" || exit 1
chmod 700 "$state_dir" "$results" 2>/dev/null

# First, so a marker left by a dead review does not look like a duplicate.
prune_results "$results"

# The base is read once and carried through, snapshot included.
base=$(base_rev "$repo_root") || exit 1
tree=$(work_tree_sha "$repo_root" "$results/index-$$") || {
  echo "could not read the working tree" >&2
  exit 1
}
rm -f "$results/index-$$"

if tree_is_clean "$repo_root" "$tree" "$base"; then
  echo "nothing to review: the working tree matches HEAD"
  exit 0
fi
# Submodules are read once, for both the identity and the decision.
sub_state=$(submodule_state "$repo_root")
hash=$(state_identity "$repo_root" "$tree" "$base" "$sub_state")
dirty_subs=$(dirty_submodules "$sub_state")

# Tells the gate a review of this state is running. One marker per invocation.
printf '%s\n' "$(date +%s)" >"$results/$hash.started.$$"

started_marker=$results/$hash.started.$$
# Only the generated context file; `context` may be the journal itself.
temp_context=""
cleanup() {
  rm -f "$started_marker" ${temp_context:+"$temp_context"}
}

# The signal handlers exit, and take the reviewer's process tree down first.
kill_child() {
  [ -n "${KILLABLE_PID:-}" ] && kill_tree "$KILLABLE_PID"
  return 0
}
trap 'kill_child; cleanup' EXIT
trap 'kill_child; cleanup; exit 130' INT
trap 'kill_child; cleanup; exit 143' TERM

# Frozen before the reviewer starts, so it reads the tree this is filed under.
snapshot=$(make_snapshot "$repo_root" "$results/index-$$" "$base") || snapshot=""
rm -f "$results/index-$$"
if [ -z "$snapshot" ]; then
  echo "could not snapshot the working tree; nothing was reviewed" >&2
  exit 1
fi

# The snapshot must hold exactly this state: same tree, same parent. No parent
# means no commit yet, and the base is then the empty tree.
snap_parent=$(git -C "$repo_root" rev-parse -q --verify "$snapshot^1" 2>/dev/null ||
  git -C "$repo_root" hash-object -t tree /dev/null)
if [ "$(git -C "$repo_root" rev-parse "$snapshot^{tree}")" != "$tree" ] ||
  { [ "$snap_parent" != "$base" ] &&
    [ "$snap_parent" != "$(git -C "$repo_root" rev-parse "$base" 2>/dev/null)" ]; }; then
  echo "the tree or HEAD moved while the review was starting; nothing was reviewed" >&2
  exit 1
fi

diff_file=$results/$hash.patch
patch_of "$repo_root" "$snapshot" "$base" >"$diff_file"

export REVIEW_LOOP_SNAPSHOT=$snapshot

# Embedded repositories and dirty submodules are refused: their contents are
# in no snapshot, and the review would come back clean about unseen code.
# Counted from the NUL stream; the joined form is for the message only.
embedded_count=0
embedded_list=""
while IFS= read -r -d '' nested; do
  embedded_count=$((embedded_count + 1))
  embedded_list="${embedded_list:+$embedded_list }$(printf '%s' "$nested" | tr '\n' '?')"
done < <(embedded_repos "$repo_root" "$tree")
if [ "$embedded_count" -gt 0 ]; then
  printf 'a directory here is a git repository of its own, so its contents are in no snapshot: %s\n' \
    "$embedded_list" >&2
  echo "commit it there, register it as a submodule, or ignore it." >&2
  exit 1
fi

if [ -n "$dirty_subs" ]; then
  printf 'uncommitted changes inside submodules cannot be snapshotted, so this state cannot be reviewed: %s\n' \
    "$(printf '%s' "$dirty_subs" | tr '\n' ' ')" >&2
  echo "commit them inside the submodule, or review it there." >&2
  exit 1
fi

[ -x "$REVIEWER" ] || {
  echo "reviewer $REVIEWER is not executable" >&2
  exit 1
}

# One journal per repository: every round, and what the author did about it.
journal=$results/journal-$(repo_key "$repo_root").md

# Appends and the trim share one lock, or concurrent sessions lose entries.
# mkdir is the lock; flock is absent on macOS.
journal_lock=$journal.lock
with_journal_lock() {
  local waited=0
  while ! mkdir "$journal_lock" 2>/dev/null; do
    waited=$((waited + 1))
    # A lock held this long belongs to a run that died inside it.
    [ "$waited" -gt 300 ] && { rmdir "$journal_lock" 2>/dev/null; continue; }
    sleep 0.1
  done
  "$@"
  rmdir "$journal_lock" 2>/dev/null
}

if [ -n "$after" ]; then
  append_after() { printf '\n## The author, on the findings above\n\n%s\n' "$1" >>"$journal"; }
  with_journal_lock append_after "$after"
fi

# With REVIEW_LOOP_SHARE_TRANSCRIPT, the tail of the session's conversation is
# added to the context: the text only, never tool output. Opt-in, because it
# is the user's conversation leaving the machine.
context=$journal
if [ -n "${REVIEW_LOOP_SHARE_TRANSCRIPT:-}" ]; then
  t=${REVIEW_LOOP_TRANSCRIPT:-$(cat "$state_dir/transcript-$(repo_key "$repo_root").path" 2>/dev/null)}
  if [ -s "$t" ] && command -v jq >/dev/null 2>&1; then
    # Per invocation, so two sessions cannot overwrite each other's context.
    context=$results/context-$hash-$$.md
    temp_context=$context
    [ -s "$journal" ] && cat "$journal" >"$context" || : >"$context"
    {
      printf '\n\n## The conversation that produced this change\n\n'
      jq -r '
        select(.type=="user" or .type=="assistant")
        | .type as $role
        | (.message.content // empty)
        | if type=="string" then . else (.[]? | select(.type=="text") | .text) end
        | select(. != null and . != "")
        | "### \($role)\n\(.)"' "$t" 2>/dev/null |
        tail -c "${REVIEW_LOOP_MAX_TRANSCRIPT_BYTES:-60000}"
    } >>"$context"
  fi
fi

# argv[2] is empty when there is no history.
journal_arg=""
[ -s "$context" ] && journal_arg=$context

# Backgrounded so cancelling this run cancels the reviewer. Output files are
# per invocation: two sessions reviewing one state share the hash.
reviewer_out=$results/$hash.$$.stdout
reviewer_err=$results/$hash.$$.err
run_killable "$reviewer_out" "$reviewer_err" "$REVIEWER" "$diff_file" "$journal_arg"
rc=$?
report=$(cat "$reviewer_out" 2>/dev/null)
rm -f "$reviewer_out"
KILLABLE_PID=""

if [ "$rc" -ne 0 ]; then
  # No .done on failure, so the next turn asks again.
  echo "the reviewer failed (exit $rc); see $reviewer_err" >&2
  tail -c 400 "$reviewer_err" >&2
  exit "$rc"
fi

printf '%s\n' "$report" >"$results/$hash.out"

max_journal=${REVIEW_LOOP_MAX_JOURNAL_BYTES:-40000}
append_round() {
  {
    printf '\n## Round of %s\n\n' "$(date -u +'%Y-%m-%d %H:%M UTC')"
    if [ -z "${report//[$' \t\n\r']/}" ]; then
      printf 'Nothing found.\n'
    else
      printf '%s\n' "$report"
    fi
  } >>"$journal"

  # Trimmed to the recent rounds: it reaches the reviewer as one argument.
  if [ "$(wc -c <"$journal")" -gt "$max_journal" ]; then
    tail -c "$max_journal" "$journal" >"$journal.trim.$$" &&
      mv "$journal.trim.$$" "$journal"
    rm -f "$journal.trim.$$"
  fi
}
with_journal_lock append_round

# Reviews of this uncommitted change so far. Keyed by the base revision, so a
# commit starts the count over. Past REVIEW_LOOP_DOUBT_AFTER the report asks
# Claude whether the rounds are still worth it.
rounds_file=$results/rounds-$(repo_key "$repo_root")-${base:0:12}
bump_round() {
  round=$(cat "$rounds_file" 2>/dev/null)
  case $round in ''|*[!0-9]*) round=0 ;; esac
  round=$((round + 1))
  printf '%s\n' "$round" >"$rounds_file"
}
with_journal_lock bump_round
doubt_after=${REVIEW_LOOP_DOUBT_AFTER:-5}

if [ -z "${report//[$' \t\n\r']/}" ]; then
  echo "the reviewer found nothing."
else
  # The instruction rides with the report: the user sees only a notice.
  cat <<'EOF'
Retell the report below to the user before acting on any of it, keeping the
reviewer's shape: the one-line summary, then one entry per finding as its
severity, a short title, the file and line, and what actually goes wrong. Your
own words and the user's language, not a paste - but nothing dropped and no two
findings merged. Your own judgement comes after that, not mixed into it.

EOF
  if [ "$round" -ge "$doubt_after" ]; then
    cat <<EOF
This is review $round of the same uncommitted change, and nothing has been
committed since the first. Answer this for yourself before acting on anything
below - it is yours to settle, not a question to hand to the user.
Are we going round in circles, and is there a shape that would make these
findings stop arriving?

Settle it concretely. What did the last few rounds actually change, and what
did they leave alone? Have the findings been getting smaller while the design
stood still? Do any of them keep returning in new wording - not the same
defect twice, but the same direction?
Would a different approach retire a whole family of them: less configurable,
fewer moving parts, the boundary somewhere else?

Then act on your answer. If the work is converging and what is below is worth
fixing, fix it and carry on without ceremony. If it is not, change course or
stop and commit what is already good, and say in one line what you concluded
and why - the conclusion is worth the user's attention, the deliberation is
not. What you must not do is keep fixing because a report arrived.

EOF
  fi
  printf '%s\n' "$report"
fi

# Last of all, so an interrupted run never looks reviewed.
printf 'ok\n' >"$results/$hash.done"
