#!/usr/bin/env bash
#
# The fan-out runs several reviewers at once. What matters is that it quotes the
# ones that succeeded, quotes nobody who crashed, and survives some of them
# failing without costing the user their turn.

set -uo pipefail

# The ambient environment is not the test's. A REVIEW_LOOP_* variable left in
# a shell - a setup command for another repository, say - silently changes
# what is being tested; one such leak made this suite fail against correct
# code. Everything is cleared, and the suite sets what it means to set.
for v in $(env | sed -n 's/^\(REVIEW_LOOP_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fanout=$(dirname "$here")/scripts/fanout-review.sh

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# An inner reviewer whose behaviour is picked per copy by INNER_PLAN: a
# space-separated list of ok / crash / quiet, consumed one entry per call.
inner=$work/inner.sh
cat >"$inner" <<'INNER'
#!/usr/bin/env bash
# The copies run at once and are told nothing about which they are, so they take
# a number from a shared counter. mkdir is the lock: flock is absent on macOS.
while ! mkdir "$COUNTER.lock" 2>/dev/null; do :; done
n=$(( $(cat "$COUNTER" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$COUNTER"
rmdir "$COUNTER.lock"

read -r -a plan <<<"$INNER_PLAN"
case ${plan[$((n - 1))]:-ok} in
  crash)
    echo "partial thought before dying"
    echo "inner $n exploded" >&2
    exit 7
    ;;
  quiet) : ;;
  *) echo "finding from inner $n" ;;
esac
INNER
chmod +x "$inner"

export REVIEW_LOOP_FANOUT_REVIEWER=$inner
export COUNTER=$work/counter

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
excludes() {
  case $3 in
    *"$2"*) fail=$((fail + 1)); printf 'FAIL %s: [%s] should not be in [%s]\n' "$1" "$2" "$3" ;;
    *) pass=$((pass + 1)); printf 'ok   %s\n' "$1" ;;
  esac
}

run() { # run <plan>
  : >"$COUNTER"
  rmdir "$COUNTER.lock" 2>/dev/null
  INNER_PLAN=$1 REVIEW_LOOP_FANOUT=$(wc -w <<<"$1" | tr -d ' ') \
    "$fanout" /dev/null "" 2>"$work/err"
}

# --- every reviewer speaks ----------------------------------------------------
out=$(run "ok ok ok"); rc=$?
check "three good reviewers succeed" 0 "$rc"
contains "the first is quoted" "finding from inner 1" "$out"
contains "the third is quoted" "finding from inner 3" "$out"
check "each gets a heading" 3 "$(grep -c '^### Reviewer' <<<"$out")"

# --- a crash must not be passed off as a finding ------------------------------
out=$(run "ok crash ok"); rc=$?
check "one crash is survivable" 0 "$rc"
excludes "the crashed reviewer's half-thought is dropped" "partial thought" "$out"
check "only the survivors get headings" 2 "$(grep -c '^### Reviewer' <<<"$out")"
contains "the thinner review is declared" "1 of 3 reviewers failed" "$out"

# --- silence from everyone is silence -----------------------------------------
out=$(run "quiet quiet"); rc=$?
check "all-quiet succeeds" 0 "$rc"
check "and says nothing" "" "$out"

# --- nobody left standing is a reviewer failure -------------------------------
out=$(run "crash crash"); rc=$?
check "all reviewers failing is a failure" 1 "$rc"
check "and no report is offered" "" "$out"

# --- only one worker installs dependencies, so only one runs the tests --------
# The suite is deterministic: running it in every worker buys the same answer N
# times, at N times the setup and N times the slowest part of the review.
cat >"$work/setup-spy.sh" <<'SPY'
#!/usr/bin/env bash
while ! mkdir "$COUNTER.lock" 2>/dev/null; do :; done
n=$(( $(cat "$COUNTER" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$COUNTER"
rmdir "$COUNTER.lock"
printf '%s\n' "setup=${REVIEW_LOOP_SETUP_CMD:-none}" >>"$SETUP_LOG"
echo "finding from inner $n"
SPY
chmod +x "$work/setup-spy.sh"
: >"$COUNTER"; rmdir "$COUNTER.lock" 2>/dev/null
export SETUP_LOG=$work/setup.log; : >"$SETUP_LOG"
REVIEW_LOOP_SETUP_CMD='echo installing' REVIEW_LOOP_FANOUT=3 \
  REVIEW_LOOP_FANOUT_REVIEWER=$work/setup-spy.sh "$fanout" /dev/null "" >/dev/null 2>&1
check "exactly one worker is given the setup command" 1 "$(grep -c 'setup=echo installing' "$SETUP_LOG")"
check "and the rest get none" 2 "$(grep -c 'setup=none' "$SETUP_LOG")"

# --- cancelling the fan-out takes its workers with it ------------------------
# A signal to this shell alone left the reviewers running: still working, still
# holding worktrees, writing into paths the parent had already deleted.
#
# The wrapper waits on a child, as a real adapter waits on Codex, and the child
# is what must die. Watching the wrapper proved nothing - it died either way.
# The child is counted by a duration nothing else on the machine will use;
# recording its pid from inside the worker was racy and left the assertion
# passing against the very bug it exists for.
cat >"$work/slow-inner.sh" <<'SLOW'
#!/usr/bin/env bash
sleep 31337 &
wait $!
echo "finding"
SLOW
chmod +x "$work/slow-inner.sh"
kids() { pgrep -f 'sleep 31337' 2>/dev/null | wc -l | tr -d ' '; }

REVIEW_LOOP_FANOUT=2 REVIEW_LOOP_FANOUT_REVIEWER=$work/slow-inner.sh \
  "$fanout" /dev/null "" >/dev/null 2>&1 &
fan=$!
for i in $(seq 1 60); do [ "$(kids)" -ge 2 ] && break; sleep 0.1; done
check "both reviewers have work of their own running" 2 "$(kids)"

kill -TERM "$fan" 2>/dev/null
wait "$fan" 2>/dev/null
for i in $(seq 1 40); do [ "$(kids)" = 0 ] && break; sleep 0.1; done
check "and cancelling the fan-out takes it down with them" 0 "$(kids)"
pkill -f 'sleep 31337' 2>/dev/null

# --- several reviewers named means one worker each ----------------------------
# Two runs of one model mostly agree with each other; a second model is what
# disagrees about something new. The list decides the count, and the heading
# says who spoke, because agreement between two models is evidence that
# agreement between two runs is not.
for who in alpha beta; do
  cat >"$work/$who-review.sh" <<MIXED
#!/usr/bin/env bash
printf '%s setup=%s notests=%s\n' "$who" "\${REVIEW_LOOP_SETUP_CMD:-none}" "\${REVIEW_LOOP_NO_TESTS:-0}" >>"\$MIX_LOG"
echo "finding from $who"
MIXED
  chmod +x "$work/$who-review.sh"
done
export MIX_LOG=$work/mix.log; : >"$MIX_LOG"
out=$(REVIEW_LOOP_FANOUT=5 REVIEW_LOOP_SETUP_CMD='echo installing' \
  REVIEW_LOOP_FANOUT_REVIEWER="$work/alpha-review.sh:$work/beta-review.sh" \
  "$fanout" /dev/null "" 2>/dev/null); rc=$?
check "a mixed list succeeds" 0 "$rc"
check "the list decides the count, not REVIEW_LOOP_FANOUT" 2 "$(wc -l <"$MIX_LOG" | tr -d ' ')"
check "each named reviewer runs exactly once" "1 1" \
  "$(grep -c '^alpha' "$MIX_LOG") $(grep -c '^beta' "$MIX_LOG")"
contains "the heading says who spoke" "(alpha-review)" "$out"
contains "for the second as well" "(beta-review)" "$out"
contains "the first is given the setup command" "alpha setup=echo installing notests=0" "$(cat "$MIX_LOG")"
contains "the second is told to leave the tests alone" "beta setup=none notests=1" "$(cat "$MIX_LOG")"

# One bad name fails the lot before anything starts, rather than quietly
# running a thinner review than was asked for.
: >"$MIX_LOG"
REVIEW_LOOP_FANOUT_REVIEWER="$work/alpha-review.sh:$work/no-such-review.sh" \
  "$fanout" /dev/null "" >/dev/null 2>"$work/err"; rc=$?
check "a list with a missing reviewer is refused" 1 "$rc"
check "and nothing was started" 0 "$(wc -l <"$MIX_LOG" | tr -d ' ')"

# A path with a space in it is one path. Both reviewers of the change that
# introduced the list found this independently: split on whitespace, the
# reviewer became two names, neither of which exists.
mkdir -p "$work/My Plugins"
cp "$work/alpha-review.sh" "$work/My Plugins/alpha-review.sh"
: >"$MIX_LOG"
out=$(REVIEW_LOOP_FANOUT=1 REVIEW_LOOP_FANOUT_REVIEWER="$work/My Plugins/alpha-review.sh" \
  "$fanout" /dev/null "" 2>/dev/null); rc=$?
check "a reviewer path with a space works" 0 "$rc"
contains "and is run as one reviewer" "finding from alpha" "$out"

# A name without a slash is one of the plugin's own adapters, so settings need
# not carry the install path - which holds the version and stops existing at
# every update. Checked on a copy of the scripts with stub adapters beside it.
short=$work/short
mkdir -p "$short"
cp "$(dirname "$fanout")/fanout-review.sh" "$(dirname "$fanout")/diff.sh" "$short/"
cp "$work/alpha-review.sh" "$short/codex-worktree-review.sh"
cp "$work/beta-review.sh" "$short/claude-review.sh"
: >"$MIX_LOG"
# Spaces round the colon included: it is how a list gets written by hand.
out=$(REVIEW_LOOP_FANOUT_REVIEWER="codex-worktree : claude" "$short/fanout-review.sh" /dev/null "" 2>/dev/null); rc=$?
check "short names resolve to the plugin's own adapters" 0 "$rc"
check "and each runs once" "1 1" "$(grep -c '^alpha' "$MIX_LOG") $(grep -c '^beta' "$MIX_LOG")"
REVIEW_LOOP_FANOUT_REVIEWER="codex-worktree:nosuch" "$short/fanout-review.sh" /dev/null "" >/dev/null 2>"$work/err"; rc=$?
check "an unknown short name is refused" 1 "$rc"
contains "by the name that was asked for" "nosuch" "$(cat "$work/err")"

# The list of names is closed. Matching any *-review.sh let "skip" run
# skip-review.sh as a reviewer: it records a decline, exits 0, and the runner
# files the state as reviewed.
cp "$work/alpha-review.sh" "$short/skip-review.sh"
: >"$MIX_LOG"
REVIEW_LOOP_FANOUT_REVIEWER="skip:claude" "$short/fanout-review.sh" /dev/null "" >/dev/null 2>&1; rc=$?
check "a script that is not an adapter is not a short name" 1 "$rc"
check "and it was not run" 0 "$(grep -c '^alpha' "$MIX_LOG")"

# The fan-out as its own worker inherits the list and fans out again, without
# end. Both reviewers of the change that added short names found it. Refused
# by file, so the name and the full path are the same mistake. The timeout is
# for the unfixed version, which never returns.
for self in fanout "$short/fanout-review.sh"; do
  : >"$MIX_LOG"
  REVIEW_LOOP_FANOUT_REVIEWER="claude:$self" "$short/fanout-review.sh" /dev/null "" >/dev/null 2>"$work/err" &
  fp=$!
  for i in $(seq 1 30); do kill -0 "$fp" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$fp" 2>/dev/null; then
    # Until none are left: one pass loses the race against a tree that is
    # still spawning, and left 162 of them behind when this was first run.
    while pgrep -f "$short/fanout-review.sh" >/dev/null 2>&1; do
      pkill -9 -f "$short/fanout-review.sh" 2>/dev/null
      sleep 0.2
    done
    rc=hung
  else
    wait "$fp"; rc=$?
  fi
  check "the fan-out refuses itself as a worker [$(basename "$self")]" 1 "$rc"
  check "before starting anyone [$(basename "$self")]" 0 "$(wc -l <"$MIX_LOG" | tr -d ' ')"
done
contains "and says why" "cannot be one of its own reviewers" "$(cat "$work/err")"

# A value that is itself an executable is one reviewer, colon and all. Any
# separator breaks some path; a single path must never be parsed as a list.
mkdir -p "$work/odd:dir"
cp "$work/alpha-review.sh" "$work/odd:dir/alpha-review.sh"
out=$(REVIEW_LOOP_FANOUT=1 REVIEW_LOOP_FANOUT_REVIEWER="$work/odd:dir/alpha-review.sh" \
  "$fanout" /dev/null "" 2>/dev/null); rc=$?
check "a single reviewer path with a colon works" 0 "$rc"
contains "and runs as one reviewer" "finding from alpha" "$out"

# Nothing but blanks names nobody, so the default adapter is used rather than
# a reviewer called "". The default is the real Codex adapter, so PATH is cut
# down to keep this offline: it fails for want of codex, which is not the
# failure being looked for.
(cd "$work" && PATH=/usr/bin:/bin REVIEW_LOOP_FANOUT=1 REVIEW_LOOP_FANOUT_REVIEWER=" : " \
  "$fanout" /dev/null "" >/dev/null 2>"$work/err")
excludes "a blank list does not name a reviewer called nothing" "reviewer  is not executable" "$(cat "$work/err")"
excludes "nor trip over an empty array" "unbound variable" "$(cat "$work/err")"

# --- progress is readable while it runs ---------------------------------------
# Stages go to stderr, which lands in the background task's output file: that is
# how a review in flight can be read instead of guessed at.
run "ok ok" >/dev/null
contains "each finishing reviewer is reported" "2 of 2 reviewers done" "$(cat "$work/err")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
