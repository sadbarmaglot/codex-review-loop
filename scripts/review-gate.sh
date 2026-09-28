#!/usr/bin/env bash
#
# Stop hook: do not let a turn end on a change nobody has looked at.
#
# The gate reviews nothing and waits for nothing. It asks one question - does
# this exact state have a review - and if the answer is no it refuses to end the
# turn until Claude starts one as a background task. Claude Code tracks that
# task and wakes the session with its output when it finishes, so the findings
# arrive in full, in the conversation, while the hook holds nothing open.
#
# That is the whole design, and it is small because the runtime owns the hard
# parts. An earlier version ran reviews itself: detaching them, keeping them out
# of the hook's process group, tracking pids, cancelling superseded ones,
# guarding against reused pids. All of it existed to reimplement, worse, what
# background tasks already do.
#
# Every failure path lets the turn end. A review tool that can trap you in a
# turn is worse than no review tool.

set -uo pipefail

# The state directory holds patches of your source. On a machine where $TMPDIR
# is the shared /tmp, the default umask would leave them readable by every
# local account.
umask 077

MAX_ROUNDS=${REVIEW_LOOP_MAX_ROUNDS:-3}
MAX_TEST_ROUNDS=${REVIEW_LOOP_MAX_TEST_ROUNDS:-3}
MAX_REPORT_BYTES=${REVIEW_LOOP_MAX_REPORT_BYTES:-20000}

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/diff.sh
. "$here/diff.sh"

allow() { exit 0; }

# Let the turn end, but say why on the user's screen.
allow_with_notice() {
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg m "[review-loop] $1" '{systemMessage: $m}'
  fi
  exit 0
}

payload=$(cat)

command -v jq >/dev/null 2>&1 || exit 0
field() { jq -r --arg k "$1" '.[$k] // ""' <<<"$payload"; }

[ -n "${REVIEW_LOOP_DISABLE:-}" ] && allow

session=$(field session_id)
prompt_id=$(field prompt_id)
cwd=$(field cwd)

if [ -n "$cwd" ]; then cd "$cwd" || allow; fi
repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root=""
if [ -z "$repo_root" ]; then
  # A session opened above its repositories edits files in the children, and
  # this used to be an unconditional, silent allow - indistinguishable from a
  # clean tree that had been reviewed. Say so when there is something below.
  dirty_below=$(find "${cwd:-.}" -maxdepth 3 -name .git -maxdepth 3 2>/dev/null |
    while read -r d; do
      r=$(dirname "$d")
      [ -n "$(git -C "$r" status --porcelain 2>/dev/null)" ] && printf '%s ' "$(basename "$r")"
    done)
  [ -n "$dirty_below" ] &&
    allow_with_notice "not inside a repository, so nothing was reviewed - but there are changes below: $dirty_below"
  allow
fi

state_dir=$(state_root)
results=$state_dir/results
mkdir -p "$results" || allow
# Keyed by session and repository both. Round budgets and the pending hash
# belong to one repository: a session that moves between two used to carry
# A's exhausted budget into B, and B's first stop was then released without
# ever being asked about.
state=$state_dir/${session:-nosession}-$(repo_key "$repo_root").state

# Only the hook is told where the session transcript lives, and the review is
# started by Claude, not by the hook. Leave the path where the review can find
# it; whether any of it is ever sent anywhere is a separate, opt-in decision.
# Keyed by repository. One file for the whole machine meant the last session to
# end a turn anywhere left its pointer for everyone: a project that had opted
# in to sharing its conversation could pick up, and send, the conversation of a
# project that had not.
transcript=$(field transcript_path)
[ -n "$transcript" ] &&
  printf '%s' "$transcript" >"$state_dir/transcript-$(repo_key "$repo_root").path"

# The working tree as a tree object, which is both what identifies this state
# and what a snapshot can later be checked against.
base=$(base_rev "$repo_root") || allow
tree=$(work_tree_sha "$repo_root" "$state_dir/index-$$") || allow
rm -f "$state_dir/index-$$"

tree_is_clean "$repo_root" "$tree" "$base" && { rm -f "$state"; allow; }

diff_hash=$(state_identity "$repo_root" "$tree" "$base")

# --- state --------------------------------------------------------------------

# Four lines: prompt_id, reviews asked for, test blocks spent, hash last asked.
rounds=0 test_rounds=0 last_prompt="" asked_hash="" asked_at=0
if [ -f "$state" ]; then
  { read -r last_prompt; read -r rounds; read -r test_rounds; read -r asked_hash; read -r asked_at; } <"$state" || true
fi
case $asked_at in ''|*[!0-9]*) asked_at=0 ;; esac
case $rounds in ''|*[!0-9]*) rounds=0 ;; esac
case $test_rounds in ''|*[!0-9]*) test_rounds=0 ;; esac

save_state() { # save_state <rounds> <test_rounds> <asked_hash>
  printf '%s\n%s\n%s\n%s\n%s\n' "$prompt_id" "$1" "$2" "$3" "$(date +%s)" >"$state"
}

# The gate decides invisibly, inside a hook. Without a line per invocation a
# surprising decision is unreconstructable after the fact.
trace() {
  printf '%s prompt=%s rounds=%s/%s tests=%s hash=%.12s %s\n' \
    "$(date -u +%H:%M:%S)" "$prompt_id" "$rounds" "$MAX_ROUNDS" "$test_rounds" \
    "$diff_hash" "$1" >>"$state_dir/decisions.log"
}

# The budgets are per user turn, not per session.
if [ "$last_prompt" != "$prompt_id" ]; then
  rounds=0
  test_rounds=0
  asked_hash=""
  asked_at=0
fi

# --- already reviewed, or already asked for ------------------------------------

if [ -f "$results/$diff_hash.done" ]; then
  trace "allow: this state has been reviewed"
  allow
fi

# A review of this state is already running. Its own marker is what counts, not
# the gate's memory of having asked: that memory lives in the turn's state and
# resets with every new user message, so the gate used to demand a second review
# of a state the first one was still working on.
# Any invocation still working on this state. Each writes its own marker, and
# a marker is believed only while its owner is alive: killed with SIGKILL, or
# gone with the machine, a run leaves one behind that no trap will clear, and
# the gate used to honour it for half an hour on the strength of its timestamp.
in_flight=""
for marker in "$results/$diff_hash".started.*; do
  [ -e "$marker" ] || continue
  owner=${marker##*.}
  case $owner in ''|*[!0-9]*) rm -f "$marker"; continue ;; esac
  written=$(cat "$marker" 2>/dev/null)
  case $written in ''|*[!0-9]*) written=0 ;; esac
  if owner_is_ours "$owner" "$written"; then
    in_flight=$owner
  else
    rm -f "$marker"
  fi
done
if [ -n "$in_flight" ]; then
  trace "allow: a review of this state is already running"
  allow
fi

# Asked moments ago, before the task had a chance to write its marker. Only
# moments: an ask that produced no running review is not a review, and treating
# it as one meant the round budget never bought a second ask for a state that
# had not moved.
if [ "$asked_hash" = "$diff_hash" ] &&
  [ $(( $(date +%s) - asked_at )) -lt "${REVIEW_LOOP_LAUNCH_GRACE:-120}" ]; then
  trace "allow: review requested moments ago, still starting"
  allow
fi

if [ "$rounds" -ge "$MAX_ROUNDS" ]; then
  save_state "$rounds" "$test_rounds" "$diff_hash"
  trace "allow: round budget spent"
  allow_with_notice "no review was started after $MAX_ROUNDS asks; this change went unreviewed"
fi

# --- tests first, run by Claude ------------------------------------------------

# Opt-in, because the gate has no business guessing a project's test command:
# one repository here splits Poetry and uv across services. Claude knows the
# command - it is in the project's own instructions - so Claude runs it and
# leaves the outcome. Self-reported evidence is not proof; it is a tool for
# yourself, not a defence against yourself.
if [ -n "${REVIEW_LOOP_REQUIRE_TESTS:-}" ]; then
  evidence=$state_dir/tests-$diff_hash.txt
  verdict=""
  [ -s "$evidence" ] && verdict=$(head -n1 "$evidence" | tr -d '\r' | tr '[:lower:]' '[:upper:]')

  case $verdict in
    PASS*) : ;;
    *)
      # Its own budget, so a stubborn suite cannot eat the review rounds. It
      # gives up only when usable evidence is still missing: reading the file
      # first means evidence that arrived on the last ask still counts.
      if [ "$test_rounds" -ge "$MAX_TEST_ROUNDS" ]; then
        save_state "$rounds" "$test_rounds" "$asked_hash"
        trace "allow: test evidence never arrived"
        allow_with_notice "no passing test evidence after $MAX_TEST_ROUNDS asks; this change went untested and unreviewed"
      fi

      save_state "$rounds" "$((test_rounds + 1))" "$asked_hash"
      if [ -s "$evidence" ]; then
        trace "block: tests are failing"
        {
          echo "The tests for this change are not passing, so it has not been sent for review."
          echo "Fix them, update $evidence, and finish again."
          echo
          head -c "$MAX_REPORT_BYTES" "$evidence"
        } >&2
      else
        trace "block: asking for test evidence"
        {
          echo "Before this change is reviewed, run the tests that cover it."
          echo "Use the project's own command, with the project's own quirks."
          echo "Then write the outcome to:"
          echo "  $evidence"
          echo "First line PASS or FAIL, then the command you ran and its summary."
        } >&2
      fi
      exit 2
      ;;
  esac
fi

# --- ask for the review --------------------------------------------------------

rounds=$((rounds + 1))
save_state "$rounds" "$test_rounds" "$diff_hash"
trace "block: asking for a background review"

{
  echo "This change has not been reviewed. Start the review now, then finish."
  echo
  # Named in the command when sharing is on, because only this invocation knows
  # which session it belongs to. The file beside the results is keyed by
  # repository and serves manual runs, but two sessions in one repository
  # overwrite it, and the review would then carry the wrong conversation.
  # Quoted, because neither path is ours to choose: a space in a home
  # directory or a project name splits the command, and a metacharacter in one
  # would be interpreted rather than passed. printf %q leaves an ordinary path
  # untouched, so the common case stays readable.
  # --after is named whenever a history exists, because nothing else names it.
  # A session that does not know to write it leaves the journal holding the
  # reviewer's half of the conversation and none of the author's, and the
  # reviewer goes back to raising what has already been declined. The history
  # outlives the session; the knowledge of how to add to it did not.
  after_hint=""
  [ -s "$results/journal-$(repo_key "$repo_root").md" ] &&
    after_hint=' --after "what you did with the last findings: fixed, or declined and why"'
  if [ -n "${REVIEW_LOOP_SHARE_TRANSCRIPT:-}" ] && [ -n "$transcript" ]; then
    printf '  REVIEW_LOOP_TRANSCRIPT=%q %q%s\n' "$transcript" "$here/run-review.sh" "$after_hint"
  else
    printf '  %q%s\n' "$here/run-review.sh" "$after_hint"
  fi
  echo
  echo "Run it with run_in_background: true. It takes a few minutes and prints"
  echo "nothing until it is done, so a foreground run blinds the session for its"
  echo "whole length; in the background Claude Code wakes you with the findings."
  echo
  echo "When they arrive, retell them to the user before acting, keeping the"
  echo "reviewer's shape: a one-line summary, then one entry per finding with its"
  echo "severity, file and line, and what goes wrong - your words, nothing"
  echo "dropped, nothing merged. Your judgement comes after. This reviewer is"
  echo "confidently wrong about APIs often enough that applying its findings"
  echo "unread is a mistake."
} >&2

exit 2
