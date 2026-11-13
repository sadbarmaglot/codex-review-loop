#!/usr/bin/env bash
#
# Review the working tree and print what comes back.
#
# This is what Claude runs as a background task. Claude Code tracks it, and
# wakes the session with this output when it finishes - which is the whole
# reason the plugin does not run reviews inside the hook. A hook can only speak
# when it exits; a tracked task speaks whenever it is done.
#
# Run it in the background. Run it in the foreground and the session sits blind
# for as long as the review takes, which is the failure this replaced.
#
# It also files the result under the gate's hash, so the gate knows this state
# has been reviewed and stops asking.

set -uo pipefail

# The results directory holds patches of your source, the reviewer's output and
# its logs, which quote the code freely. Where $TMPDIR is the shared /tmp, the
# default umask would leave all of it readable by every local account.
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
# The reviewer has no memory between rounds. Without this it re-raises what was
# already declined - three rounds running it insisted a hook payload field did
# not exist, and the answer never reached it - and it cannot tell whether a fix
# it asked for was made or refused. Claude is the only one who knows, so Claude
# says, and the journal carries it forward.
after=""
while [ $# -gt 0 ]; do
  case $1 in
    --after)
      # `shift 2` with one argument left fails and shifts nothing, and there is
      # no `set -e` to stop the loop: a bare --after spins for ever.
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

# Before anything else, so a marker left by a review that no longer exists does
# not make this one look like a duplicate.
prune_results "$results"

# One base, read once and carried through. Read again for the snapshot, a HEAD
# that moved in between would parent the snapshot elsewhere and the reviewer
# would judge a different diff than the identity describes.
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
# One reading of the submodules, used both to identify the state and to decide
# about it. Two readings left a window in which a submodule went clean between
# them, and a review then completed an identity hashed while it was dirty.
sub_state=$(submodule_state "$repo_root")
hash=$(state_identity "$repo_root" "$tree" "$base" "$sub_state")
dirty_subs=$(dirty_submodules "$sub_state")

# Evidence that this state is being looked at, for the gate to find. The gate's
# own memory of having asked lives in the turn's state and resets with every new
# user message, so without this it asks again while the review is still running.
# The marker carries who owns it. Two runs of one state share the path, and
# whichever left first used to clear it for both - the gate then saw nothing in
# flight and started a third.
# One marker per invocation. A shared file meant the second run overwrote the
# first, and whichever failed first cleared it for both.
printf '%s\n' "$(date +%s)" >"$results/$hash.started.$$"

# Removed however this run ends, signals included. Cancelled reviews - and
# several were cancelled tonight - used to leave the marker behind, and the
# gate then treated a review that no longer existed as running for half an
# hour. The context file, which holds the conversation, goes the same way.
started_marker=$results/$hash.started.$$
# Only the generated one. `context` itself defaults to the journal, which is
# the accumulated history and must outlive every run.
temp_context=""
cleanup() {
  rm -f "$started_marker" ${temp_context:+"$temp_context"}
}

# A trapped signal replaces bash's default, so handling INT or TERM without
# exiting leaves the script running: it could go on to record a cancelled
# review as completed, or launch a duplicate now that the marker is gone. The
# handlers exit; cleanup hangs off EXIT and so runs for every path alike.
# The reviewer goes with them. run_killable left it in the background, so a
# handler that only exits leaves it running its tests and writing into the
# paths cleanup has just deleted - the same defect the adapter was fixed for,
# one level up.
kill_child() {
  [ -n "${KILLABLE_PID:-}" ] && kill_tree "$KILLABLE_PID"
  return 0
}
trap 'kill_child; cleanup' EXIT
trap 'kill_child; cleanup; exit 130' INT
trap 'kill_child; cleanup; exit 143' TERM

# Frozen before the reviewer starts, so what it reads and what this result is
# filed under are the same tree. Left to the reviewer, minutes could pass first.
snapshot=$(make_snapshot "$repo_root" "$results/index-$$" "$base") || snapshot=""
rm -f "$results/index-$$"
if [ -z "$snapshot" ]; then
  echo "could not snapshot the working tree; nothing was reviewed" >&2
  exit 1
fi

# The snapshot must hold the state this result will be filed under - not a
# state that resembled it before or after. Comparing the two directly settles
# it; comparing diffs at the edges of the window never could.
# No parent means the repository had no commit, and the base for that is the
# empty tree - not, as it briefly was, the snapshot's own tree, which made
# every first review of a new repository fail.
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

# A dirty submodule is recorded as its gitlink and nothing more, so its edits
# are absent from the snapshot the reviewer reads. Say so rather than let the
# review come back clean about code it never saw.
# Counted from the NUL stream, not from a formatted copy of it. Squashing the
# records to newlines first and testing that for emptiness lost a path made
# only of newlines: the terminator became one more newline and command
# substitution took the lot, so the refusal never fired and the state was
# filed as reviewed. The message still reads them on one line; the decision no
# longer comes from it.
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
  # Refused rather than noted. The snapshot holds the gitlink and nothing of
  # what changed inside, so the reviewer would see an empty diff, come back
  # clean, and the completion marker would record contents nobody inspected.
  printf 'uncommitted changes inside submodules cannot be snapshotted, so this state cannot be reviewed: %s\n' \
    "$(printf '%s' "$dirty_subs" | tr '\n' ' ')" >&2
  echo "commit them inside the submodule, or review it there." >&2
  exit 1
fi

# Before the marker would otherwise outlive it: the gate reads .started as "a
# review is running" for half an hour and quietly lets the state through.
[ -x "$REVIEWER" ] || {
  echo "reviewer $REVIEWER is not executable" >&2
  exit 1
}

# One journal per repository, carrying every round: what the reviewer said, and
# what the author then did about it. An earlier version guessed instead, handing
# over the newest report for the repository - which labelled an unrelated change
# a follow-up to it and told the reviewer to raise nothing new. History is
# context, never a restriction on what may be reported.
# The shared function, not a copy of its formula: the gate names the journal
# the same way, and two copies drift apart at the first edit.
journal=$results/journal-$(repo_key "$repo_root").md

# Appends and the trim happen under one lock. Two sessions reviewing the same
# repository - and there are two - could otherwise have one append while the
# other was rewriting the file, and the rewrite would drop the new entry:
# history and author decisions lost, the next reviewer raising what had been
# settled. The journal is past its size limit, so every run now rewrites it.
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

# The conversation that produced this change, when the project has opted in.
#
# The reviewer already reaches for it on its own - it was caught reading this
# session's transcript unprompted - and it is the richest context there is: why
# a thing was done, what was tried and rejected, what was actually asked for.
# It is also the user's conversation leaving the machine, which is why nothing
# happens here unless REVIEW_LOOP_SHARE_TRANSCRIPT says so, per project.
#
# Only the text is taken, never the tool output: on this session that was 282KB
# of talk inside 8MB of JSONL, and the rest is noise the reviewer would pay to
# read. The tail, because recent context is the context that matters.
context=$journal
if [ -n "${REVIEW_LOOP_SHARE_TRANSCRIPT:-}" ]; then
  t=${REVIEW_LOOP_TRANSCRIPT:-$(cat "$state_dir/transcript-$(repo_key "$repo_root").path" 2>/dev/null)}
  if [ -s "$t" ] && command -v jq >/dev/null 2>&1; then
    # Per invocation, not per state: two sessions reviewing the same state
    # wrote the same file, and one could overwrite it while the other adapter
    # was still starting - sending the wrong session's conversation.
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

# The contract says argv[2] is empty when there is no previous report, and a
# path to a file that does not exist is not empty.
journal_arg=""
[ -s "$context" ] && journal_arg=$context

# Backgrounded, so the wait is interruptible and cancelling this run actually
# cancels the reviewer instead of waiting politely for it to finish.
#
# Named after this invocation, not after the state. Two sessions reviewing the
# same tree agree on the hash, and a shared path let one truncate the other's
# report - or delete it, having finished first, before the other had read it.
reviewer_out=$results/$hash.$$.stdout
reviewer_err=$results/$hash.$$.err
run_killable "$reviewer_out" "$reviewer_err" "$REVIEWER" "$diff_file" "$journal_arg"
rc=$?
report=$(cat "$reviewer_out" 2>/dev/null)
rm -f "$reviewer_out"
KILLABLE_PID=""

if [ "$rc" -ne 0 ]; then
  # No completion marker, and the start marker goes too. The gate reads the
  # presence of .done as proof the state was reviewed, so a transient failure -
  # an expired login, a network blip - used to close the question for good.
  # Leaving both absent lets the next turn ask again.
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

  # It goes to the next reviewer as one argument, and Linux caps that at about
  # 128 KiB. Keep the recent rounds, drop the ancient ones. The temporary name
  # carries this process: a shared one is a second way to lose the same writes.
  if [ "$(wc -c <"$journal")" -gt "$max_journal" ]; then
    tail -c "$max_journal" "$journal" >"$journal.trim.$$" &&
      mv "$journal.trim.$$" "$journal"
    rm -f "$journal.trim.$$"
  fi
}
with_journal_lock append_round

# How many reviews this uncommitted change has had. Keyed by the base
# revision, so a commit starts the count over by giving it a new file - no
# resetting to get wrong, and the old ones age out with everything else.
#
# The loop has no sense of diminishing returns. Left alone it will keep finding
# smaller things for as long as it is fed, and the author keeps fixing them:
# one change in this project reached a seventh round, by which point the
# findings had moved from the design to a file extension. Past the threshold
# the report carries a question to put to the user, because that is a decision
# about the work and not a defect to fix.
rounds_file=$results/rounds-$(repo_key "$repo_root")-${base:0:12}
# Under the journal's lock, which is already held for the same kind of
# read-modify-write a few lines above. Two reviews finishing together read the
# same number and wrote the same increment, losing one of themselves and
# putting the threshold off by a round.
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
  # The instruction rides with the report so it arrives when it is needed. The
  # user sees a completion notice, not this output: unless it is quoted they
  # only ever get the reading, never what was actually said.
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

# Last of all. Interrupted after this, a run would have left the state looking
# reviewed while the session never saw a finding.
printf 'ok\n' >"$results/$hash.done"
