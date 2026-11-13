#!/usr/bin/env bash
#
# Stop hook: do not let a turn end on a change nobody has looked at.
#
# It reviews nothing itself. If this exact state has no review, it refuses the
# stop and names the command for Claude to run as a background task. Every
# failure path lets the turn end.

set -uo pipefail

# The state directory holds patches of the user's source.
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
  # A session rooted above its repositories: say so if any below are dirty.
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
# Per session and repository: budgets must not cross between repositories.
state=$state_dir/${session:-nosession}-$(repo_key "$repo_root").state

# Left where the review can find it, keyed by repository. Sharing is opt-in.
transcript=$(field transcript_path)
[ -n "$transcript" ] &&
  printf '%s' "$transcript" >"$state_dir/transcript-$(repo_key "$repo_root").path"

base=$(base_rev "$repo_root") || allow
tree=$(work_tree_sha "$repo_root" "$state_dir/index-$$") || allow
rm -f "$state_dir/index-$$"

tree_is_clean "$repo_root" "$tree" "$base" && { rm -f "$state"; allow; }

diff_hash=$(state_identity "$repo_root" "$tree" "$base")

# --- state --------------------------------------------------------------------

# Five lines: prompt_id, reviews asked, test asks, hash last asked, when.
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

# One line per decision, so a surprising one can be reconstructed.
trace() {
  printf '%s prompt=%s rounds=%s/%s tests=%s hash=%.12s %s\n' \
    "$(date -u +%H:%M:%S)" "$prompt_id" "$rounds" "$MAX_ROUNDS" "$test_rounds" \
    "$diff_hash" "$1" >>"$state_dir/decisions.log"
}

# Budgets are per user turn.
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

# Declined with /review-loop:skip: a different file, not a review.
if [ -f "$results/$diff_hash.skipped" ]; then
  trace "allow: this state was declined by the author"
  allow
fi

# No shortcut for changes that look like documents: it was tried and removed,
# see docs/design.md. The decline above covers that case.

# A review of this state is running: its marker counts while its owner lives.
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

# Asked moments ago, before the task could write its marker.
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

# Opt-in: the gate does not guess a project's test command. Claude runs it and
# leaves the outcome in a file.
if [ -n "${REVIEW_LOOP_REQUIRE_TESTS:-}" ]; then
  evidence=$state_dir/tests-$diff_hash.txt
  verdict=""
  [ -s "$evidence" ] && verdict=$(head -n1 "$evidence" | tr -d '\r' | tr '[:lower:]' '[:upper:]')

  case $verdict in
    PASS*) : ;;
    *)
      # Its own budget, checked after reading the evidence.
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
  # The transcript is named in the command when sharing is on, and --after
  # whenever a journal exists. Paths are quoted with %q.
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
