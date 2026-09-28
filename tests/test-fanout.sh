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

# --- progress is readable while it runs ---------------------------------------
# Stages go to stderr, which lands in the background task's output file: that is
# how a review in flight can be read instead of guessed at.
run "ok ok" >/dev/null
contains "each finishing reviewer is reported" "2 of 2 reviewers done" "$(cat "$work/err")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
