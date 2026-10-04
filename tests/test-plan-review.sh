#!/usr/bin/env bash
#
# The plan check is the one adapter that runs nothing and guards nothing. What
# matters is that the plan reaches the reviewer, that the report is the
# reviewer's last message and not its chatter, and that a reviewer which dies
# is not mistaken for one with nothing to say.

set -uo pipefail

# The ambient environment is not the test's. A REVIEW_LOOP_* variable left in
# a shell - a setup command for another repository, say - silently changes
# what is being tested; one such leak made another suite fail against correct
# code. Everything is cleared, and the suite sets what it means to set.
for v in $(env | sed -n 's/^\(REVIEW_LOOP_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
adapter=$(dirname "$here")/scripts/plan-review.sh

work=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$work"' EXIT

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

plan=$work/plan.md
cat >"$plan" <<'PLAN'
# Add a cache to the resolver

Add an in-memory cache in src/resolve.py, keyed by the user id.
PLAN

# A `codex` that records the prompt it was given and answers through the file
# named by -o, as the real one does. STUB_MODE picks what it does.
bin=$work/bin
mkdir -p "$bin"
cat >"$bin/codex" <<'STUB'
#!/usr/bin/env bash
out=""
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out=$a
  prev=$a
done
printf '%s\n' "$*" >"$STUB_LOG"
printf 'key=%s\n' "${OPENAI_API_KEY-<unset>}" >>"$STUB_LOG"
echo "codex banner: thinking out loud" # stdout chatter, must not reach the report
case ${STUB_MODE:-ok} in
  crash)
    echo "half a remark" >"$out"
    echo "codex exploded" >&2
    exit 7
    ;;
  quiet) : >"$out" ;;
  *) echo "src/resolve.py - the resolver is already memoised in resolve_cached()" >"$out" ;;
esac
STUB
chmod +x "$bin/codex"
cp "$bin/codex" "$work/codex.orig"   # the cancellation test replaces it, then puts it back
export PATH=$bin:$PATH
export STUB_LOG=$work/stub.log

# --- the ordinary case --------------------------------------------------------
out=$(STUB_MODE=ok "$adapter" "$plan" 2>"$work/err"); rc=$?
check "a plan with remarks succeeds" 0 "$rc"
contains "the report is the reviewer's answer" "already memoised" "$out"
excludes "and not its chatter" "banner" "$out"
contains "the plan reached the reviewer" "in-memory cache in src/resolve.py" "$(cat "$STUB_LOG")"
contains "with instructions to judge it against the code" "wrong about this repository" "$(cat "$STUB_LOG")"
# read-only stops the reviewer writing, not running. Nothing but the prompt
# keeps it out of the test suite, and the first real run spent minutes there.
contains "and told not to run the repository" "do not run it" "$(cat "$STUB_LOG")"
contains "read-only by default" "--sandbox read-only" "$(cat "$STUB_LOG")"
# Unpinned, Codex takes the effort from the user's config, which is set for
# writing code. The first real run of this check inherited `high` and spent six
# minutes reading the repository.
contains "and the effort is pinned, not inherited" 'model_reasoning_effort=medium' "$(cat "$STUB_LOG")"

# --- the shared flags variable does not reach this adapter --------------------
# It did for a while, and guarding it meant catching every spelling of
# --sandbox, -s, --sandbox=, --config=sandbox_mode and whatever the next CLI
# release adds - a guard longer than the adapter. Not reading the variable is
# shorter and cannot be got round, which is the whole assertion here.
REVIEW_LOOP_CODEX_FLAGS='-s workspace-write --full-auto' STUB_MODE=ok \
  "$adapter" "$plan" >/dev/null 2>&1
contains "read-only survives a hostile override" "--sandbox read-only" "$(cat "$STUB_LOG")"
excludes "and the override is not passed on at all" "workspace-write" "$(cat "$STUB_LOG")"
excludes "nor any part of it" "full-auto" "$(cat "$STUB_LOG")"

# --- stdin never reaches the reviewer -----------------------------------------
# codex exec takes the prompt as an argument but still waits on a non-terminal
# stdin, so a background caller's pipe, which never sends EOF, hangs the check
# for ever. The reviewer runs in the foreground here, and nothing closes stdin
# for a foreground child - the redirection is the whole of the protection.
cat >"$bin/codex" <<'STDIN_STUB'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out=$a; prev=$a; done
[ -p /dev/stdin ] && kind=pipe || kind=closed
printf 'stdin=%s\n' "$kind" >"$STUB_LOG"
: >"$out"
STDIN_STUB
chmod +x "$bin/codex"
: | "$adapter" "$plan" >/dev/null 2>&1        # called down a pipe, as a task is
check "a caller's pipe does not reach the reviewer" "stdin=closed" "$(cat "$STUB_LOG")"
cp "$work/codex.orig" "$bin/codex"

# --- billing stays on the subscription ---------------------------------------
# A key left in the environment silently moves the charge to the API.
OPENAI_API_KEY=sk-should-not-survive STUB_MODE=ok "$adapter" "$plan" >/dev/null 2>&1
contains "the API key is stripped before exec" "key=<unset>" "$(cat "$STUB_LOG")"
OPENAI_API_KEY=sk-kept REVIEW_LOOP_KEEP_API_KEY=1 STUB_MODE=ok "$adapter" "$plan" >/dev/null 2>&1
contains "unless billing is opted back in" "key=sk-kept" "$(cat "$STUB_LOG")"

# --- silence is silence -------------------------------------------------------
out=$(STUB_MODE=quiet "$adapter" "$plan" 2>/dev/null); rc=$?
check "a sound plan succeeds" 0 "$rc"
check "and says nothing" "" "$out"

# --- a crash is not a verdict -------------------------------------------------
out=$(STUB_MODE=crash "$adapter" "$plan" 2>/dev/null); rc=$?
check "a reviewer that dies fails the check" 7 "$rc"

# --- nothing to check ---------------------------------------------------------
: >"$work/empty.md"
out=$("$adapter" "$work/empty.md" 2>"$work/err"); rc=$?
check "an empty plan is refused" 2 "$rc"
contains "and says why" "the plan is empty" "$(cat "$work/err")"

# --- a path that is not a readable plan is refused, not reviewed --------------
# -s passes a directory, whose size is never zero. The read then failed, the
# plan text came out empty, and a quiet reviewer turned that into a clean
# verdict on a plan nobody had read. A false clean is the one answer this must
# never give.
mkdir -p "$work/adir/something"
out=$("$adapter" "$work/adir" 2>"$work/err"); rc=$?
check "a directory is refused" 2 "$rc"
contains "and says what is wrong with it" "not a readable file" "$(cat "$work/err")"
check "and nothing is reported as reviewed" "" "$out"

printf 'a plan nobody may read\n' >"$work/locked.md"
chmod 000 "$work/locked.md"
if [ -r "$work/locked.md" ]; then
  printf 'skip unreadable-file check: running with privileges that ignore the mode\n'
else
  out=$("$adapter" "$work/locked.md" 2>"$work/err"); rc=$?
  check "an unreadable plan is refused" 2 "$rc"
  contains "and says so" "not a readable file" "$(cat "$work/err")"
fi
chmod 644 "$work/locked.md"

# --- no reviewer installed ----------------------------------------------------
rc=$(PATH=/usr/bin:/bin "$adapter" "$plan" >/dev/null 2>&1; echo $?)
check "a missing codex is a missing reviewer, not a clean plan" 127 "$rc"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
