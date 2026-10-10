#!/usr/bin/env bash
#
# The gate asks for a review and gets out of the way. It never runs one, never
# waits, and never fails a turn shut. These assertions are about what it asks
# for, when it stops asking, and every path by which the turn still ends.

set -uo pipefail

# The ambient environment is not the test's. A REVIEW_LOOP_* variable left in
# a shell - a setup command for another repository, say - silently changes
# what is being tested; one such leak made this suite fail against correct
# code. Everything is cleared, and the suite sets what it means to set.
for v in $(env | sed -n 's/^\(REVIEW_LOOP_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")
gate=$root/scripts/review-gate.sh

work=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$work"' EXIT

export REVIEW_LOOP_STATE_DIR=$work/state
results=$work/state/review-loop/results

repo=$work/repo
mkdir -p "$repo/src"
git -C "$repo" init -q
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name test
echo "original" >"$repo/src/a.py"
git -C "$repo" add -A
git -C "$repo" commit -qm base

pass=0 fail=0
check() {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf 'ok   %s\n' "$1"
  else
    fail=$((fail + 1)); printf 'FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"
  fi
}
contains() {
  case $3 in
    *"$2"*) pass=$((pass + 1)); printf 'ok   %s\n' "$1" ;;
    *) fail=$((fail + 1)); printf 'FAIL %s: [%s] not in [%s]\n' "$1" "$2" "$3" ;;
  esac
}

out="" err="" rc=0
run_gate() { # run_gate <session> <prompt_id>
  local payload ef
  payload=$(jq -n --arg s "$1" --arg p "$2" --arg c "$repo" --arg d "$work/scratch" \
    '{session_id:$s, prompt_id:$p, cwd:$c, scratchpad_dir:$d, hook_event_name:"Stop"}')
  ef=$(mktemp "$work/err.XXXX")
  out=$(printf '%s' "$payload" | "$gate" 2>"$ef")
  rc=$?
  err=$(cat "$ef")
}

edit() { echo "$1" >>"$repo/src/a.py"; }

# The hash the gate will compute, so a result can be planted for exactly it.
current_hash() {
  ( . "$root/scripts/diff.sh"; i=$(mktemp); state_identity "$repo" "$(work_tree_sha "$repo" "$i")"; rm -f "$i" )
}

# --- a clean tree is nobody's business ----------------------------------------
run_gate s1 p1
check "a clean tree ends the turn" 0 "$rc"

# --- an unreviewed change is not let through ----------------------------------
edit changed
run_gate s1 p1
check "an unreviewed change blocks the turn" 2 "$rc"
contains "and the review command is named" "run-review.sh" "$err"
contains "with the instruction to background it" "run_in_background" "$err"
# The gate and the runner share one default state directory rather than
# plumbing it through: the session scratchpad could never work, because only
# the hook learns it, so every review was filed where the hook never looked.
check "the gate and the runner agree on where results live" \
  "$( . "$root/scripts/diff.sh"; state_root )" "$work/state/review-loop"
contains "and a warning against applying findings unread" "confidently wrong" "$err"
# The user sees a completion notice, not the review output. Unless it is quoted
# they get the reading and never what was actually said.
contains "and the instruction to retell every finding" "nothing merged" "$err"

# --- the conversation named belongs to this session --------------------------
# The pointer file is keyed by repository, which stops one project reading
# another's. It does not stop two sessions in one repository from overwriting
# each other, so when sharing is on the transcript is named in the request.
err_before=$err
payload=$(jq -n --arg c "$repo" --arg t "$work/this-session.jsonl" \
  '{session_id:"sX", prompt_id:"pX", cwd:$c, transcript_path:$t, hook_event_name:"Stop"}')
ef=$(mktemp "$work/err.XXXX")
printf '%s' "$payload" | REVIEW_LOOP_SHARE_TRANSCRIPT=1 "$gate" >/dev/null 2>"$ef"
contains "the request names this session's transcript" \
  "REVIEW_LOOP_TRANSCRIPT=$work/this-session.jsonl" "$(cat "$ef")"

ef=$(mktemp "$work/err.XXXX")
printf '%s' "$payload" | "$gate" >/dev/null 2>"$ef"
case $(cat "$ef") in
  *REVIEW_LOOP_TRANSCRIPT*)
    fail=$((fail + 1)); printf 'FAIL the transcript is named even when sharing is off\n' ;;
  *) pass=$((pass + 1)); printf 'ok   %s\n' "and is not named when sharing is off" ;;
esac
err=$err_before

# --- paths are not ours to choose --------------------------------------------
# A space in a home directory or a project name used to split the command the
# gate emits, so the review simply never started.
spacey="$work/a dir with spaces"
mkdir -p "$spacey"
cp -R "$root/scripts" "$spacey/scripts"
payload=$(jq -n --arg c "$repo" --arg t "$work/tr anscript.jsonl" \
  '{session_id:"sQ", prompt_id:"pQ", cwd:$c, transcript_path:$t, hook_event_name:"Stop"}')
ef=$(mktemp "$work/err.XXXX")
printf '%s' "$payload" | REVIEW_LOOP_SHARE_TRANSCRIPT=1 "$spacey/scripts/review-gate.sh" \
  >/dev/null 2>"$ef"
emitted=$(grep -o '  .*run-review.sh' "$ef" | head -1)
# The shell that runs it must recover the paths whole, not in pieces.
eval "parsed=($emitted)" 2>/dev/null || parsed=()
last=""
[ "${#parsed[@]}" -gt 0 ] && last=${parsed[$((${#parsed[@]} - 1))]}
check "the emitted command survives a path with spaces" \
  "$spacey/scripts/run-review.sh" "$last"
check "and so does the transcript path beside it" \
  "REVIEW_LOOP_TRANSCRIPT=$work/tr anscript.jsonl" "${parsed[0]:-}"

# --- asked once is enough -----------------------------------------------------
# The task is running and Claude Code will wake the session with it; repeating
# the instruction would only make the turn unendable.
run_gate s1 p1
check "the second stop of the same turn ends it" 0 "$rc"

# --- and a running review survives the next user message ----------------------
# The gate's memory of having asked resets with every new turn. Without the
# review's own marker it demanded a second review of a state the first was
# still working on - which is exactly what happened in use.
mkdir -p "$results"
# Written exactly as run-review.sh writes it, "<owner pid> <timestamp>". A test
# that invented its own one-field format let a parsing bug ship: the gate read
# the pair as one number, called every live review infinitely old, deleted the
# marker and asked for a duplicate.
# Named for a living process, as run-review.sh names it: <hash>.started.<pid>.
printf '%s\n' "$(date +%s)" >"$results/$(current_hash).started.$$"
run_gate s1 pNEW
check "a new turn does not re-ask while a review runs" 0 "$rc"
contains "and the reason is recorded" "already running" \
  "$(cat "$work/state/review-loop/decisions.log")"

# A marker whose owner is gone must not silence the gate at all, however
# recent: a run killed outright leaves one that no trap will ever clear.
rm -f "$results/$(current_hash).started."*
printf '%s\n' "$(date +%s)" >"$results/$(current_hash).started.4242"
run_gate s1 pNEW2
check "a marker with no live owner earns a fresh ask" 2 "$rc"
rm -f "$results/$(current_hash).started."*

# --- an ask that produced no review is not a review --------------------------
# Treating the request as the deed meant the round budget never bought a second
# ask for a state that had not moved: one ask, then silence for ever.
edit unlaunched
run_gate s1b p1b
check "the first ask blocks" 2 "$rc"
REVIEW_LOOP_LAUNCH_GRACE=0 run_gate s1b p1b
check "and with no review running, the next stop asks again" 2 "$rc"
run_gate s1b p1b
check "while moments later it waits instead" 0 "$rc"

# --- a session rooted above its repositories is not a clean tree -------------
above=$work/above
mkdir -p "$above"
cp -R "$repo" "$above/child"
echo "a change nobody will review" >>"$above/child/src/a.py"
payload=$(jq -n --arg c "$above" '{session_id:"sA", prompt_id:"pA", cwd:$c, hook_event_name:"Stop"}')
ef=$(mktemp "$work/err.XXXX")
notice=$(printf '%s' "$payload" | "$gate" 2>"$ef")
check "it still lets the turn end" 0 "$?"
contains "but says nothing was reviewed" "nothing was reviewed" "$notice"
contains "and names what is below it" "child" "$notice"

# --- a reviewed state passes ---------------------------------------------------
edit reviewed
mkdir -p "$results"
printf 'ok\n' >"$results/$(current_hash).done"
run_gate s2 p2
check "a state with a review ends the turn" 0 "$rc"

# --- a new turn asks again for a change that moved ----------------------------
edit moved
run_gate s2 p3
check "a new change is asked about" 2 "$rc"

# --- the ask has a budget ------------------------------------------------------
# Claude ignoring the instruction must not make the turn unendable.
edit again1
run_gate s3 p4
check "first ask blocks" 2 "$rc"
edit again2
run_gate s3 p4
check "second ask blocks" 2 "$rc"
edit again3
run_gate s3 p4
check "third ask blocks" 2 "$rc"
edit again4
run_gate s3 p4
check "the fourth ends the turn instead" 0 "$rc"
contains "and says the change went unreviewed" "went unreviewed" "$out"

# --- the budget belongs to a repository, not to a session --------------------
# One session can move between repositories inside a single turn. Keyed by the
# session alone, the state above travelled with it: the budget spent here was
# spent everywhere, and the next repository's first stop went through without
# the gate ever asking about it.
run_gate_in() { # run_gate_in <cwd> <session> <prompt_id>
  local payload ef
  payload=$(jq -n --arg s "$2" --arg p "$3" --arg c "$1" --arg d "$work/scratch" \
    '{session_id:$s, prompt_id:$p, cwd:$c, scratchpad_dir:$d, hook_event_name:"Stop"}')
  ef=$(mktemp "$work/err.XXXX")
  out=$(printf '%s' "$payload" | "$gate" 2>"$ef")
  rc=$?
  err=$(cat "$ef")
}
other=$work/other
mkdir -p "$other/src"
git -C "$other" init -q
git -C "$other" config user.email t@example.com
git -C "$other" config user.name test
echo "original" >"$other/src/b.py"
git -C "$other" add -A
git -C "$other" commit -qm base
echo "a change of its own" >>"$other/src/b.py"
run_gate_in "$other" s3 p4
check "the other repository is still asked about" 2 "$rc"

# --- a change outside the session's directory is still a change ---------------
# `git ls-files --others` is scoped to the current directory; started from a
# subdirectory the gate used to call the repository clean and skip the review.
git -C "$repo" add -A
git -C "$repo" commit -qm more
mkdir -p "$repo/deep/nested"
echo placeholder >"$repo/deep/nested/keep.py"
git -C "$repo" add -A
git -C "$repo" commit -qm nested

echo "new file at the top" >"$repo/top-level.py"
saved=$repo
repo=$repo/deep/nested
run_gate s4 p5
repo=$saved
check "a change elsewhere in the tree is noticed" 2 "$rc"
rm -f "$repo/top-level.py"

# --- a repository with no commits at all --------------------------------------
fresh=$work/fresh
mkdir -p "$fresh"
git -C "$fresh" init -q
echo "first file ever" >"$fresh/a.py"
saved=$repo
repo=$fresh
run_gate s5 p6
repo=$saved
check "the first files of a repository are asked about" 2 "$rc"

# --- tests before review, run by Claude ---------------------------------------
export REVIEW_LOOP_REQUIRE_TESTS=1
edit needs-tests
run_gate s6 pT1
check "no test evidence blocks before any review is asked for" 2 "$rc"
contains "the ask states the contract" "First line PASS or FAIL" "$err"
contains "and no review is requested yet" "" "$err"
case $err in
  *run-review.sh*) fail=$((fail + 1)); printf 'FAIL a review was requested before the tests passed\n' ;;
  *) pass=$((pass + 1)); printf 'ok   %s\n' "and no review is requested yet" ;;
esac

ev=$(printf '%s\n' "$err" | grep -o '/[^ ]*tests-[a-f0-9]*\.txt' | head -1)
printf 'FAIL\npytest: 1 failed, 12 passed\n' >"$ev"
run_gate s6 pT1
check "failing tests block too" 2 "$rc"
contains "and the failure itself is shown" "1 failed" "$err"

printf 'PASS\npytest: 13 passed\n' >"$ev"
run_gate s6 pT1
check "passing tests let the review be asked for" 2 "$rc"
contains "and now it is" "run-review.sh" "$err"

# Evidence that arrives on the last ask still counts.
edit late-evidence
run_gate s7 pT2
ev=$(printf '%s\n' "$err" | grep -o '/[^ ]*tests-[a-f0-9]*\.txt' | head -1)
run_gate s7 pT2
run_gate s7 pT2
check "the budget is spent" 2 "$rc"
printf 'PASS\npytest: 13 passed\n' >"$ev"
run_gate s7 pT2
contains "evidence on the last ask still earns the review" "run-review.sh" "$err"
unset REVIEW_LOOP_REQUIRE_TESTS

# --- a later session is told to keep the journal going -----------------------
# Nothing else names --after. A session that does not know to write it leaves
# the journal with the reviewer's half and none of the author's, and declined
# findings start coming back.
rk=$( . "$root/scripts/diff.sh"; repo_key "$repo" )
mkdir -p "$results"
echo "a history exists" >"$results/journal-$rk.md"
edit after-hint
run_gate sH pH
contains "with a history present, the request names --after" "--after" "$err"
rm -f "$results/journal-$rk.md"
edit no-history
run_gate sH2 pH2
case $err in
  *--after*) fail=$((fail + 1)); printf 'FAIL --after is suggested with no history to answer\n' ;;
  *) pass=$((pass + 1)); printf 'ok   %s\n' "and not on a first review, with nothing to answer" ;;
esac

# --- every way out -------------------------------------------------------------
edit kill-switch
REVIEW_LOOP_DISABLE=1 run_gate s8 p7
check "REVIEW_LOOP_DISABLE ends the turn" 0 "$rc"

plain=$work/plain
mkdir -p "$plain"
payload=$(jq -n --arg c "$plain" '{session_id:"s9", prompt_id:"p8", cwd:$c, hook_event_name:"Stop"}')
printf '%s' "$payload" | "$gate" >/dev/null 2>&1
check "outside a repository the turn ends" 0 "$?"

# --- the decisions are recorded -------------------------------------------------
log=$(cat "$work/state/review-loop/decisions.log" 2>/dev/null)
contains "asking is recorded" "asking for a background review" "$log"
contains "the budget is recorded" "round budget spent" "$log"
contains "a reviewed state is recorded" "has been reviewed" "$log"

# There are no assertions here for a documents-only change. The gate had a
# shortcut that released one unreviewed, and it is gone: five review rounds
# each found its allow-list wrong in a new way - .txt, whole directories,
# .mdx, file modes, this plugin's own commands/ and skills/, Copilot's
# instruction files - and the next one was always waiting. The decline below
# does the same job without guessing what a file means.
#
# run_gate_in, defined with the budget tests above, is still used by those.

# --- a declined state is not asked about again -------------------------------
# The gate decides by rules and cannot know what a turn was about. Once the
# session has said so, repeating the question is noise - that is where most of
# those 148 refusals came from.
skip=$(dirname "$here")/scripts/skip-review.sh
edit "a change nobody means to review"
run_gate_in "$repo" sS pS1
check "first it asks, as before" 2 "$rc"
(cd "$repo" && "$skip" "belongs to another piece of work" >/dev/null 2>&1)
run_gate_in "$repo" sS pS2
check "once declined it stays quiet" 0 "$rc"
sh=$(current_hash)
check "and the marker is a decline, not a review" "1" \
  "$([ -f "$results/$sh.skipped" ] && echo 1 || echo 0)"
check "nothing claims the state was reviewed" "0" \
  "$([ -f "$results/$sh.done" ] && echo 1 || echo 0)"
contains "the reason is on the record" "another piece of work" \
  "$(cat "$results/$sh.skipped")"

edit "and now it moves again"
run_gate_in "$repo" sS pS3
check "a tree that changes after a decline is asked about" 2 "$rc"

# A decline is refused where a review would be. The identity holds a dirty
# nested repository as its gitlink alone, so a marker written now would keep
# suppressing the question after further edits in there - a decline outliving
# what it declined.
deep=$repo/vendor/inner
mkdir -p "$deep"
git -C "$deep" init -q
git -C "$deep" config user.email t@example.com
git -C "$deep" config user.name test
echo "code" >"$deep/lib.py"
git -C "$deep" add -A
git -C "$deep" commit -qm base
git -C "$repo" add -A 2>/dev/null
git -C "$repo" commit -qm "embed inner" >/dev/null 2>&1
echo "uncommitted below" >>"$deep/lib.py"
serr=$( (cd "$repo" && "$skip" "while something below is dirty") 2>&1 >/dev/null ); src=$?
check "a decline is refused while a repository below is dirty" 2 "$src"
contains "and says what to do first" "register it as a submodule" "$serr"

# Clean is no comfort either. Its contents are outside the identity whatever
# their state, so a marker written now would answer for code written inside it
# tomorrow - which is why run-review.sh refuses every one of these, not just
# the dirty ones.
git -C "$deep" add -A
git -C "$deep" commit -qm "settle it"
edit "an outer change, with a clean repository below"
serr=$( (cd "$repo" && "$skip" "with a clean one below") 2>&1 >/dev/null ); src=$?
check "a decline is refused even when it is clean" 2 "$src"
contains "and says why a clean one still counts" "made inside it later" "$serr"
rm -rf "$repo/vendor"
git -C "$repo" rm -q -r --cached vendor 2>/dev/null
git -C "$repo" commit -qm "drop inner" >/dev/null 2>&1

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
