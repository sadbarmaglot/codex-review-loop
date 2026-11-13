#!/usr/bin/env bash
#
# run-review.sh is what Claude starts as a background task. It has to print the
# findings, because that printout is what Claude Code wakes the session with,
# and it has to file the result under exactly the hash the gate computes, or the
# gate will go on asking for a review that has already happened.

set -uo pipefail

# The ambient environment is not the test's. A REVIEW_LOOP_* variable left in
# a shell - a setup command for another repository, say - silently changes
# what is being tested; one such leak made this suite fail against correct
# code. Everything is cleared, and the suite sets what it means to set.
for v in $(env | sed -n 's/^\(REVIEW_LOOP_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")
runner=$root/scripts/run-review.sh

work=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$work"' EXIT

export REVIEW_LOOP_STATE_DIR=$work/state
export REVIEW_LOOP_REVIEWER=$here/fake-reviewer.sh
export FAKE_LOG=$work/calls.log
export FAKE_PREV_DUMP=$work/handed-over.md
results=$work/state/review-loop/results

repo=$work/repo
mkdir -p "$repo/src"
git -C "$repo" init -q
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name test
echo original >"$repo/src/a.py"
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

run() { (cd "$repo" && "$runner" 2>"$work/err"); }

# Signals go to this test's own process, found through it, never by name.
# `pkill -f run-review.sh` matches every review on the machine: it killed live
# reviews in another session for hours, and the regular interval that made it
# look like a timeout was just how often this suite was run.
signal_own() { # signal_own <pid of the subshell wrapping the runner>
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do kill -TERM "$child" 2>/dev/null; done
  kill -TERM "$1" 2>/dev/null
}

gate_hash() { ( . "$root/scripts/diff.sh"; i=$(mktemp); state_identity "$repo" "$(work_tree_sha "$repo" "$i")"; rm -f "$i" ); }

# --- nothing to do -------------------------------------------------------------
out=$(run); rc=$?
check "a clean tree is not reviewed" 0 "$rc"
contains "and says so" "nothing to review" "$out"

# --- the ordinary run ----------------------------------------------------------
echo changed >>"$repo/src/a.py"
export FAKE_MODE=dirty
h=$(gate_hash)
out=$(run); rc=$?
check "a review succeeds" 0 "$rc"
contains "the findings are printed, which is how they reach the session" "off-by-one" "$out"
contains "carrying the instruction to retell them in the reviewer shape" "one entry per finding" "$out"
check "the result is filed under the gate's hash" "ok" "$(cat "$results/$h.done" 2>/dev/null)"
# The marker says a review is in flight, so a finished run clears it and the
# completion marker speaks instead. It is asserted while running, further down.
check "a finished run leaves no in-flight marker" "0" "$(ls "$results/$h".started.* 2>/dev/null | wc -l | tr -d ' ')"
contains "and kept for the gate to find" "off-by-one" "$(cat "$results/$h.out" 2>/dev/null)"

# --- the reviewer is handed a snapshot of the tree it is judging ---------------
snap=$(sed -n 's/.*snapshot=//p' "$FAKE_LOG" | head -1)
if [ -n "$snap" ] && [ "$snap" != none ] && git -C "$repo" cat-file -e "$snap^{commit}" 2>/dev/null; then
  pass=$((pass + 1)); printf 'ok   %s\n' "a snapshot commit is handed to the reviewer"
else
  fail=$((fail + 1)); printf 'FAIL no usable snapshot: [%s]\n' "$snap"
fi
contains "and it holds the change" "changed" "$(git -C "$repo" show "$snap:src/a.py" 2>/dev/null)"

# --- the next round knows what happened in the last ---------------------------
# The reviewer has no memory. Without the journal it re-raises what the author
# already declined, and cannot tell whether a fix it asked for was made.
journal=$(ls "$results"/journal-*.md 2>/dev/null | head -1)
contains "the first round's findings are journalled" "off-by-one" "$(cat "$journal" 2>/dev/null)"

echo "second round" >>"$repo/src/a.py"
: >"$FAKE_LOG"
out=$( (cd "$repo" && "$runner" --after "fixed the off-by-one; declined the other, the field is documented" 2>"$work/err") ); rc=$?
check "a second review succeeds" 0 "$rc"
contains "and the reviewer is handed the journal" "prev=$journal" "$(cat "$FAKE_LOG")"
contains "which carries the author's answer" "declined the other" "$(cat "$journal")"
contains "and still carries what was said before it" "off-by-one" "$(cat "$journal")"

# --- results are not readable by other local users ----------------------------
# The patch is your source, and $TMPDIR is the shared /tmp on many machines.
# stat speaks differently on the two systems this is meant to run on.
perms() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
check "the results directory is private" "700" "$(perms "$results")"
world=$(find "$results" -type f -perm -o+r | head -1)
check "and so is everything in it" "" "$world"

# --- silence is a result too ---------------------------------------------------
echo quiet >>"$repo/src/a.py"
export FAKE_MODE=empty
h=$(gate_hash)
out=$(run); rc=$?
check "an empty review succeeds" 0 "$rc"
contains "and says nothing was found" "found nothing" "$out"
check "it still counts as reviewed" "ok" "$(cat "$results/$h.done" 2>/dev/null)"

# --- a crash is not silence ----------------------------------------------------
echo crashing >>"$repo/src/a.py"
export FAKE_MODE=fail
h=$(gate_hash)
out=$(run); rc=$?
check "a failed review fails loudly" 3 "$rc"
# Nothing is filed at all. The gate reads the presence of .done as proof the
# state was reviewed, so a transient failure must not leave one behind - nor a
# start marker, which would make the state look like a review in flight.
check "no completion marker is left behind" "" "$(cat "$results/$h.done" 2>/dev/null)"
check "and no start marker either, so the next turn asks again" \
  "" "$(cat "$results/$h.started" 2>/dev/null)"
contains "with the reviewer's own words kept" "exploded" "$(cat "$work/err")"

# --- the identity is the tree, and the snapshot is checked against it ---------
# Text was the earlier identity and could not be verified: no comparison of
# diffs before and after taking a snapshot proves the snapshot holds the state
# the result is filed under. Two trees either are equal or they are not.
echo "identity check" >>"$repo/src/a.py"
h=$(gate_hash)
: >"$FAKE_LOG"
out=$(run)
snap=$(sed -n 's/.*snapshot=//p' "$FAKE_LOG" | head -1)
check "the snapshot holds exactly the state that was filed" \
  "$(git -C "$repo" rev-parse "$snap^{tree}")" \
  "$( . "$root/scripts/diff.sh"; i=$(mktemp); work_tree_sha "$repo" "$i"; rm -f "$i" )"

# An untracked file is part of the state, and must be in what the adapter reads.
echo "brand new" >"$repo/src/fresh.py"
: >"$FAKE_LOG"
out=$(run)
patch=$(sed -n 's/^call diff=//; s/ prev=.*//p' "$FAKE_LOG" | head -1)
contains "an untracked file reaches the adapter's patch" "src/fresh.py" "$(cat "$patch")"
rm -f "$repo/src/fresh.py"

# --- the conversation is shared only when the project opts in ----------------
# It is the richest context there is and it is also the user's conversation
# leaving the machine, so it is a per-project decision, not a default.
fake_transcript=$work/transcript.jsonl
cat >"$fake_transcript" <<'T'
{"type":"user","message":{"content":[{"type":"text","text":"make the widget faster"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"cached the lookup"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_result","text":"NOISE: tool output"}]}}
T
export FAKE_MODE=dirty
echo "opt-in check" >>"$repo/src/a.py"
: >"$FAKE_LOG"
out=$(run)
: >"$FAKE_PREV_DUMP"
case $(cat "$FAKE_PREV_DUMP" 2>/dev/null) in
  *"### user"*) fail=$((fail + 1)); printf 'FAIL the conversation was shared without opting in\n' ;;
  *) pass=$((pass + 1)); printf 'ok   %s\n' "nothing of the conversation is shared by default" ;;
esac

echo "opt-in check two" >>"$repo/src/a.py"
: >"$FAKE_LOG"
out=$(cd "$repo" && REVIEW_LOOP_SHARE_TRANSCRIPT=1 REVIEW_LOOP_TRANSCRIPT="$fake_transcript" \
  "$runner" 2>"$work/err")
handed=$(cat "$FAKE_PREV_DUMP" 2>/dev/null)
contains "with the switch on, the talk reaches the reviewer" "make the widget faster" "$handed"
contains "and who said it" "### user" "$handed"
case $handed in
  *"NOISE: tool output"*) fail=$((fail + 1)); printf 'FAIL tool output was shared too\n' ;;
  *) pass=$((pass + 1)); printf 'ok   %s\n' "but not the tool output, which is 97% of the file" ;;
esac

# --- the author's note outlives a reviewer that keeps only the tail ----------
# The context used to be journal first, conversation last, and a prompt-driven
# adapter keeps the last 20 KB: with sharing on, the Claude reviewer got the
# end of the talk and none of the journal, the --after note included.
echo "ordering check" >>"$repo/src/a.py"
(cd "$repo" && REVIEW_LOOP_SHARE_TRANSCRIPT=1 REVIEW_LOOP_TRANSCRIPT="$fake_transcript" \
  "$runner" --after "DECIDED: declined the second finding" >/dev/null 2>&1)
handed=$(cat "$FAKE_PREV_DUMP" 2>/dev/null)
contains "the journal comes after the conversation" "DECIDED: declined" "${handed##*"### assistant"}"

# And an adapter on stdin has no cap to apply at all.
( . "$root/scripts/review-prompt.sh"
  hist=$work/long-history.md
  { echo "EARLY-DECISION"; head -c 30000 /dev/zero | tr '\0' 'x'; echo; echo "LATE"; } >"$hist"
  : >"$work/empty.patch"
  REVIEW_LOOP_MAX_DIFF_BYTES=0 build_prompt "$work/empty.patch" "$hist" >"$work/prompt-stdin.txt"
  build_prompt "$work/empty.patch" "$hist" >"$work/prompt-argv.txt" )
check "a stdin adapter is handed the whole history" 1 "$(grep -c 'EARLY-DECISION' "$work/prompt-stdin.txt")"
check "an argv adapter still keeps only the tail" 0 "$(grep -c 'EARLY-DECISION' "$work/prompt-argv.txt")"

# --- an interrupted review must not look like a running one ------------------
# Several reviews were cancelled tonight, and each used to leave its marker
# behind: the gate then treated a review that no longer existed as in flight
# for half an hour, and the state went unreviewed in silence.
export FAKE_MODE=slow FAKE_SLEEP=30
echo "interrupt check" >>"$repo/src/a.py"
ih=$(gate_hash)
(cd "$repo" && "$runner" >/dev/null 2>&1) &
victim=$!
for i in $(seq 1 50); do ls "$results/$ih".started.* >/dev/null 2>&1 && break; sleep 0.1; done
check "the marker is there while it runs" "1" "$(ls "$results/$ih".started.* >/dev/null 2>&1 && echo 1 || echo 0)"
signal_own "$victim"
wait "$victim" 2>/dev/null
for i in $(seq 1 30); do ls "$results/$ih".started.* >/dev/null 2>&1 || break; sleep 0.1; done
check "and gone once it is interrupted" "0" "$(ls "$results/$ih".started.* >/dev/null 2>&1 && echo 1 || echo 0)"
# The marker disappearing is not enough: a trapped signal does not stop the
# shell by itself, and a script that carried on could file the cancelled
# review as complete.
sleep 1
check "and the cancelled review is not recorded as done" \
  "" "$(cat "$results/$ih.done" 2>/dev/null)"
pkill -f "$here/fake-reviewer.sh" 2>/dev/null
unset FAKE_SLEEP
export FAKE_MODE=dirty

# --- cancelling the runner takes the reviewer with it ------------------------
# The marker went, the reviewer did not. run_killable puts the reviewer in the
# background, so handlers that only exit leave it running its tests, holding a
# worktree and writing into the paths cleanup has just deleted.
#
# What is watched is the reviewer's own child, by a sleep duration nothing else
# on this machine will use. Watching the reviewer script proved nothing: the
# block above ends by pkill-ing it, which hid exactly this defect.
kids() { pgrep -f 'sleep 31338' 2>/dev/null | wc -l | tr -d ' '; }
export FAKE_MODE=slow FAKE_SLEEP=31338
echo "cancel check" >>"$repo/src/a.py"
(cd "$repo" && "$runner" >/dev/null 2>&1) &
victim=$!
for i in $(seq 1 60); do [ "$(kids)" -ge 1 ] && break; sleep 0.1; done
check "the reviewer has work of its own running" 1 "$(kids)"
signal_own "$victim"
wait "$victim" 2>/dev/null
for i in $(seq 1 40); do [ "$(kids)" = 0 ] && break; sleep 0.1; done
check "and cancelling the runner takes it down too" 0 "$(kids)"
pkill -f 'sleep 31338' 2>/dev/null
unset FAKE_SLEEP
export FAKE_MODE=dirty

# --- two reviews of one state do not share an output file --------------------
# The reviewer's stdout was named after the state, and two sessions reviewing
# the same tree agree on that name: one run could truncate the other's report,
# and whichever finished first deleted the file before the other had read it.
export FAKE_MODE=slow FAKE_SLEEP=15
echo "concurrent check" >>"$repo/src/a.py"
ch=$(gate_hash)
stdouts() { ls "$results/$ch".*.stdout 2>/dev/null | wc -l | tr -d ' '; }
(cd "$repo" && "$runner" >/dev/null 2>&1) & one=$!
(cd "$repo" && "$runner" >/dev/null 2>&1) & two=$!
for i in $(seq 1 100); do [ "$(stdouts)" -ge 2 ] && break; sleep 0.1; done
check "each run writes a report file of its own" 2 "$(stdouts)"
signal_own "$one"; signal_own "$two"
wait "$one" "$two" 2>/dev/null
pkill -f "$here/fake-reviewer.sh" 2>/dev/null
unset FAKE_SLEEP
export FAKE_MODE=dirty

# --- the Claude reviewer cannot reach the tools that write -------------------
# --allowed-tools only permits what exists; --tools decides what exists at all,
# and without it Edit, Write and Bash stayed in the session for any
# pre-authorised rule to reach.
defaults=$(sed -n 's/^flags=${REVIEW_LOOP_CLAUDE_FLAGS:-\(.*\)}$/\1/p' "$root/scripts/claude-review.sh")
case $defaults in
  *--tools*) pass=$((pass + 1)); printf 'ok   %s\n' "the writing tools are taken out of the session" ;;
  *) fail=$((fail + 1)); printf 'FAIL only permissions are set, the tools remain: [%s]\n' "$defaults" ;;
esac

# --- completion is published only once the findings are out -----------------
# Interrupted after the marker but before the report, a run used to leave the
# state looking reviewed while the session never saw a finding.
echo "ordering check" >>"$repo/src/a.py"
oh=$(gate_hash)
out=$(run)
# .out holds the report and .done is written after it, so if both exist the
# order held; the interruption case is covered by the signal test above.
check "the report is stored" "1" "$([ -s "$results/$oh.out" ] && echo 1 || echo 0)"
check "and the completion marker with it" "ok" "$(cat "$results/$oh.done" 2>/dev/null)"
check "and no in-flight marker survives" "0" "$(ls "$results/$oh".started.* 2>/dev/null | wc -l | tr -d ' ')"

# --- overlapping runs keep their own markers ---------------------------------
# One shared file meant the second run overwrote the first, and whichever
# failed first cleared it for both, letting the gate start a third review.
export FAKE_MODE=slow FAKE_SLEEP=30
echo "ownership check" >>"$repo/src/a.py"
mh=$(gate_hash)
(cd "$repo" && "$runner" >/dev/null 2>&1) &
owner=$!
for i in $(seq 1 50); do ls "$results/$mh".started.* >/dev/null 2>&1 && break; sleep 0.1; done
# A second invocation of the same state, standing in for another session.
printf '%s\n' "$(date +%s)" >"$results/$mh.started.$$"
signal_own "$owner"
wait "$owner" 2>/dev/null
sleep 0.5
check "the interrupted run takes only its own marker" "1" \
  "$([ -f "$results/$mh.started.$$" ] && echo 1 || echo 0)"
rm -f "$results/$mh".started.*
pkill -f "$here/fake-reviewer.sh" 2>/dev/null
unset FAKE_SLEEP
export FAKE_MODE=dirty

# --- a malformed invocation must fail, not spin -------------------------------
# `shift 2` with one argument left shifts nothing and there is no `set -e`, so
# a bare --after used to loop for ever on the same argument.
(cd "$repo" && "$runner" --after >/dev/null 2>&1) &
probe=$!
for i in $(seq 1 50); do kill -0 "$probe" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$probe" 2>/dev/null; then
  kill "$probe" 2>/dev/null
  fail=$((fail + 1)); printf 'FAIL a bare --after hangs instead of failing\n'
else
  wait "$probe"; code=$?
  check "a bare --after is a usage error" 64 "$code"
fi

# --- the Claude adapter's no-touch promise is enforced, not just claimed ------
# It runs in the repository itself and `claude -p` inherits the user's own
# permissions. A deny list of built-in tools was not enough: a pre-authorised
# MCP tool could still write, and those cannot be enumerated in advance.
defaults=$(sed -n 's/^flags=${REVIEW_LOOP_CLAUDE_FLAGS:-\(.*\)}$/\1/p' "$root/scripts/claude-review.sh")
case $defaults in
  *--allowed-tools*)
    pass=$((pass + 1)); printf 'ok   %s\n' "the Claude reviewer is held to an allowlist" ;;
  *)
    fail=$((fail + 1)); printf 'FAIL no allowlist, so anything pre-authorised can write: [%s]\n' "$defaults" ;;
esac
for writer in Edit Write Bash; do
  case $defaults in
    *"$writer"*) fail=$((fail + 1)); printf 'FAIL %s is on the allowlist\n' "$writer" ;;
    *) pass=$((pass + 1)); printf 'ok   %s\n' "$writer is not among the tools it may use" ;;
  esac
done
case $defaults in
  *--strict-mcp-config*)
    pass=$((pass + 1)); printf 'ok   %s\n' "and inherited MCP servers are not loaded" ;;
  *)
    fail=$((fail + 1)); printf 'FAIL inherited MCP tools are still loaded\n' ;;
esac

# --- a repository before its first commit ------------------------------------
# The snapshot has no parent there, and taking its own tree as the parent made
# every first review of a new project fail the verification.
unborn=$work/unborn
mkdir -p "$unborn/src"
git -C "$unborn" init -q
echo "the very first file" >"$unborn/src/a.py"
export FAKE_MODE=dirty
out=$( (cd "$unborn" && "$runner" 2>"$work/err") ); rc=$?
check "a repository with no commits can be reviewed" 0 "$rc"
contains "and the findings come back" "off-by-one" "$out"

# --- the transcript pointer belongs to one repository ------------------------
# A single pointer for the machine let a project that had opted in to sharing
# its conversation pick up the conversation of a project that had not.
theirs=$work/theirs.jsonl
printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"a private conversation"}]}}' >"$theirs"
mine=$work/mine.jsonl
printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"my own conversation"}]}}' >"$mine"

sdir=$work/state/review-loop
mkdir -p "$sdir"
key() { ( . "$root/scripts/diff.sh"; repo_key "$1" ); }
printf '%s' "$theirs" >"$sdir/transcript-$(key "$unborn").path"
printf '%s' "$mine"   >"$sdir/transcript-$(key "$repo").path"

echo "pointer check" >>"$repo/src/a.py"
: >"$FAKE_LOG"
out=$( (cd "$repo" && REVIEW_LOOP_SHARE_TRANSCRIPT=1 "$runner" 2>"$work/err") )
shared=$(cat "$FAKE_PREV_DUMP" 2>/dev/null)
contains "each repository gets its own conversation" "my own conversation" "$shared"
case $shared in
  *"a private conversation"*)
    fail=$((fail + 1)); printf 'FAIL another repository'"'"'s conversation was shared\n' ;;
  *) pass=$((pass + 1)); printf 'ok   %s\n' "and never a neighbour's" ;;
esac

# --- a change inside a submodule is a change ---------------------------------
# `git add -A` records only the gitlink, so the superproject tree is identical
# and the state used to read as clean. Hashing the submodule's status text was
# not enough either: two edits to an already-dirty file leave the same line.
if git -c protocol.file.allow=always --version >/dev/null 2>&1; then
  sub=$work/sub
  mkdir -p "$sub"; git -C "$sub" init -q
  git -C "$sub" config user.email t@example.com; git -C "$sub" config user.name test
  echo v1 >"$sub/f.txt"; git -C "$sub" add -A; git -C "$sub" commit -qm base

  par=$work/parent
  mkdir -p "$par"; git -C "$par" init -q
  git -C "$par" config user.email t@example.com; git -C "$par" config user.name test
  echo top >"$par/top.txt"; git -C "$par" add -A; git -C "$par" commit -qm base
  git -C "$par" -c protocol.file.allow=always submodule add -q "$sub" sub 2>/dev/null
  git -C "$par" commit -qm addsub

  ident() { ( . "$root/scripts/diff.sh"; i=$(mktemp); t=$(work_tree_sha "$par" "$i"); rm -f "$i"
              state_identity "$par" "$t" ); }
  clean=$(ident)
  echo v2 >"$par/sub/f.txt"; dirty1=$(ident)
  echo v3 >"$par/sub/f.txt"; dirty2=$(ident)

  [ "$clean" != "$dirty1" ] &&
    { pass=$((pass + 1)); printf 'ok   %s\n' "an edit inside a submodule is not a clean tree"; } ||
    { fail=$((fail + 1)); printf 'FAIL a submodule edit reads as clean\n'; }
  # A snapshot holds the gitlink and nothing of what changed inside it, so a
  # review of that state would come back clean about code it never saw.
  out=$( (cd "$par" && "$runner" 2>"$work/err") ); rc=$?
  check "a change only a submodule holds is refused, not reviewed" 1 "$rc"
  contains "and says why" "cannot be snapshotted" "$(cat "$work/err")"
  ph=$( . "$root/scripts/diff.sh"; i=$(mktemp); t=$(work_tree_sha "$par" "$i"); rm -f "$i"
        state_identity "$par" "$t" )
  check "leaving no completion marker behind" "" "$(cat "$results/$ph.done" 2>/dev/null)"

  # Identity and the decision about submodules come from one reading; asking
  # twice left a window for a submodule to go clean in between.
  st=$( . "$root/scripts/diff.sh"; submodule_state "$par" )
  contains "the submodule reading carries its dirtiness" "dirty=1" "$st"
  contains "and the dirty list is read out of that same text" "sub" \
    "$( . "$root/scripts/diff.sh"; dirty_submodules "$st" )"

  [ "$dirty1" != "$dirty2" ] &&
    { pass=$((pass + 1)); printf 'ok   %s\n' "and a second edit to the same file is a new state"; } ||
    { fail=$((fail + 1)); printf 'FAIL two different submodule contents share one identity\n'; }
fi

# --- a secondary fan-out worker is told to leave the tests alone -------------
# Without the dependencies a reviewer that tries anyway reports the failures as
# findings: defects invented by the optimisation that skipped its setup.
echo "no-tests check" >>"$repo/src/a.py"
: >"$FAKE_LOG"
out=$( (cd "$repo" && REVIEW_LOOP_NO_TESTS=1 "$runner" 2>"$work/err") )
check "the run still succeeds" 0 "$?"

# --- the results directory is swept, and the journal survives it -------------
# One evening left a hundred files and nine megabytes: logs at 287KB apiece,
# patches of the user's source, and context files holding the conversation.
# The asynchronous layer used to sweep; deleting that layer took its
# housekeeping with it.
sweep=$work/sweep
mkdir -p "$sweep"
old() { touch -t "$(date -v-10d +%Y%m%d%H%M)" "$1" 2>/dev/null || touch -d '10 days ago' "$1"; }
oldish() { touch -t "$(date -v-2d +%Y%m%d%H%M)" "$1" 2>/dev/null || touch -d '2 days ago' "$1"; }

echo history >"$sweep/journal-abc.md"; old "$sweep/journal-abc.md"
echo talk >"$sweep/context-fresh-123.md"
# Named for a living process: a review still working, which has not yet read it.
echo talk >"$sweep/context-live-$$.md"
echo log >"$sweep/aaa.err"; oldish "$sweep/aaa.err"
echo patch >"$sweep/aaa.patch"; oldish "$sweep/aaa.patch"
echo log >"$sweep/bbb.err"
echo findings >"$sweep/aaa.out"; oldish "$sweep/aaa.out"
echo findings >"$sweep/ccc.out"; old "$sweep/ccc.out"
printf '%s\n' "$(date +%s)" >"$sweep/ddd.started.999999"
printf '%s\n' "$(date +%s)" >"$sweep/eee.started.$$"
# A decline is a decision, like the journal. Swept on age, the gate starts
# asking again about a tree that never moved, which is the opposite of what
# the command promises.
echo "not mine to review" >"$sweep/fff.skipped"; old "$sweep/fff.skipped"

( . "$root/scripts/diff.sh"; prune_results "$sweep" )

check "the journal outlives any sweep" "1" "$([ -f "$sweep/journal-abc.md" ] && echo 1 || echo 0)"
check "an orphaned context file goes whatever its age" "0" "$([ -f "$sweep/context-fresh-123.md" ] && echo 1 || echo 0)"
check "logs and patches go early" "0" "$([ -f "$sweep/aaa.err" ] || [ -f "$sweep/aaa.patch" ] && echo 1 || echo 0)"
check "but today's log stays" "1" "$([ -f "$sweep/bbb.err" ] && echo 1 || echo 0)"
check "findings outlast the logs that produced them" "1" "$([ -f "$sweep/aaa.out" ] && echo 1 || echo 0)"
check "and go once they are truly old" "0" "$([ -f "$sweep/ccc.out" ] && echo 1 || echo 0)"
check "a marker whose owner is gone is swept" "0" "$([ -f "$sweep/ddd.started.999999" ] && echo 1 || echo 0)"
check "a marker with a living owner is kept" "1" "$([ -f "$sweep/eee.started.$$" ] && echo 1 || echo 0)"
# Deleting every context took it out from under a review that had not read it.
check "a context belonging to a running review is left alone" "1" \
  "$([ -f "$sweep/context-live-$$.md" ] && echo 1 || echo 0)"
check "a decline outlives any sweep, as the journal does" "1" \
  "$([ -f "$sweep/fff.skipped" ] && echo 1 || echo 0)"

# --- two runs cannot lose each other's journal entries -----------------------
# Past its size limit the journal is rewritten on every run, so an append
# landing during someone else's rewrite goes into the replaced file and is
# lost - history and author decisions with it.
export REVIEW_LOOP_MAX_JOURNAL_BYTES=2000
jrepo=$work/jrepo
mkdir -p "$jrepo/src"
git -C "$jrepo" init -q
git -C "$jrepo" config user.email t@example.com
git -C "$jrepo" config user.name test
echo base >"$jrepo/src/a.py"; git -C "$jrepo" add -A; git -C "$jrepo" commit -qm base
jj=$results/journal-$( . "$root/scripts/diff.sh"; repo_key "$jrepo" ).md
head -c 3000 /dev/zero | tr '\0' 'x' >"$jj"

for n in 1 2 3; do
  echo "concurrent $n" >>"$jrepo/src/a.py"
  (cd "$jrepo" && "$runner" --after "MARK$n" >/dev/null 2>&1) &
done
wait
kept=0
for n in 1 2 3; do grep -q "MARK$n" "$jj" 2>/dev/null && kept=$((kept + 1)); done
# The oldest may fall off the end by design; losing one to a race is different
# from trimming it, and at least the last two must be there.
[ "$kept" -ge 2 ] &&
  { pass=$((pass + 1)); printf 'ok   %s\n' "concurrent notes survive the trim ($kept of 3 kept)"; } ||
  { fail=$((fail + 1)); printf 'FAIL concurrent notes were lost to the trim: %s of 3 kept\n' "$kept"; }
check "and no lock is left behind" "0" "$([ -d "$jj.lock" ] && echo 1 || echo 0)"
unset REVIEW_LOOP_MAX_JOURNAL_BYTES

# --- a repository inside the repository ---------------------------------------
# `git add -A` records it as a gitlink, so its contents are in neither the
# identity nor the snapshot, and an edit that leaves its HEAD alone reuses the
# identity and is suppressed by the result already filed.
nested=$work/nested
mkdir -p "$nested/src"
git -C "$nested" init -q
git -C "$nested" config user.email t@example.com
git -C "$nested" config user.name test
echo base >"$nested/src/a.py"; git -C "$nested" add -A; git -C "$nested" commit -qm base
mkdir -p "$nested/vendor"
git -C "$nested/vendor" init -q
echo inner >"$nested/vendor/thing.txt"
git -C "$nested/vendor" add -A
git -C "$nested/vendor" -c user.email=t@e -c user.name=t commit -qm inner
out=$( (cd "$nested" && "$runner" 2>"$work/err") ); rc=$?
check "a repository inside the repository is refused" 1 "$rc"
contains "and named" "vendor" "$(cat "$work/err")"

# There is no assertion here for a repository named only by newline
# characters, and the refusal is written so that one would pass. Three review
# rounds went into this family - dirty ones, clean ones, then odd names - and
# none of the seven repositories this plugin runs against has a gitlink or a
# .gitmodules at all. The blunt refusal above earns its place because the
# consequence is the bad kind: contents outside the snapshot, reviewed clean,
# filed as done. Chasing its spelling does not.

# --- outside a repository -------------------------------------------------------
plain=$work/plain
mkdir -p "$plain"
(cd "$plain" && "$runner" >/dev/null 2>&1)
check "outside a repository it declines" 1 "$?"

# --- after enough rounds the loop asks whether it is circling ----------------
# It has no sense of diminishing returns of its own: fed long enough it keeps
# finding smaller things and the author keeps fixing them. One change in this
# project reached a seventh round, by which point the findings had moved from
# the design to a file extension. The question is for Claude to settle, not to
# hand to the user, who wants the conclusion and not the deliberation.
export FAKE_MODE=dirty REVIEW_LOOP_DOUBT_AFTER=3
rm -f "$results"/rounds-*
echo "round one" >>"$repo/src/a.py"; out=$(run)
excludes "the first round raises no doubt" "going round in circles" "$out"
echo "round two" >>"$repo/src/a.py"; out=$(run)
excludes "nor the second" "going round in circles" "$out"
echo "round three" >>"$repo/src/a.py"; out=$(run)
contains "the third raises the question" "going round in circles" "$out"
contains "and names the round it has reached" "review 3" "$out"
contains "and asks for the alternative, not a formality" "retire a whole family" "$out"
contains "and leaves it to Claude rather than the user" "not a question to hand to the user" "$out"
contains "asking for the conclusion alone" "the deliberation is" "$out"

# Keyed by the base revision, so a commit starts the count over by giving it a
# new file. Nothing resets, which is one fewer thing to get wrong.
git -C "$repo" add -A
git -C "$repo" commit -qm "land what was good"
echo "after the commit" >>"$repo/src/a.py"; out=$(run)
excludes "committing starts the count again" "going round in circles" "$out"
unset REVIEW_LOOP_DOUBT_AFTER

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
