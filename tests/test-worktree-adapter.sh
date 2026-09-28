#!/usr/bin/env bash
#
# The worktree adapter is the one that writes things, so what it must not write
# is worth asserting: not HEAD, not the index, not a leftover worktree. `codex`
# is stubbed, so this runs offline in a second.

set -uo pipefail

# The ambient environment is not the test's. A REVIEW_LOOP_* variable left in
# a shell - a setup command for another repository, say - silently changes
# what is being tested; one such leak made this suite fail against correct
# code. Everything is cleared, and the suite sets what it means to set.
for v in $(env | sed -n 's/^\(REVIEW_LOOP_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
adapter=$(dirname "$here")/scripts/codex-worktree-review.sh

work=$(cd "$(mktemp -d)" && pwd -P)   # physical path: /var is a symlink on macOS
trap 'rm -rf "$work"' EXIT

# A `codex` that records what it was asked to review and prints a report.
bin=$work/bin
mkdir -p "$bin"
cat >"$bin/codex" <<'STUB'
#!/usr/bin/env bash
{ echo "argv: $*"; echo "cwd: $PWD"
  echo "--- AGENTS.md as the reviewer would read it ---"
  cat AGENTS.md 2>/dev/null
  echo "--- end AGENTS.md ---"; } >>"$STUB_LOG"
while [ $# -gt 0 ]; do
  [ "$1" = "--commit" ] && { echo "sha: $2" >>"$STUB_LOG"; git show --stat --oneline "$2" >>"$STUB_LOG" 2>&1; }
  shift
done
echo "stub review says: one finding"
# Reviewers name files by where they read them - inside the throwaway checkout.
echo "$PWD/src/a.py:3 - a finding with a path"
STUB
chmod +x "$bin/codex"
export PATH=$bin:$PATH
export STUB_LOG=$work/stub.log

repo=$work/repo
mkdir -p "$repo/src"
git -C "$repo" init -q
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name test
echo "committed" >"$repo/src/a.py"
git -C "$repo" add -A
git -C "$repo" commit -qm base

# The project's own instructions, which the review must not lose.
echo "Project rule: never use tabs." >"$repo/AGENTS.md"
git -C "$repo" add AGENTS.md
git -C "$repo" commit -q -m agents -- AGENTS.md

# The state the adapter must preserve: an edit, an untracked file, a staged file.
echo "edited" >>"$repo/src/a.py"
echo "brand new" >"$repo/src/new.py"
echo "staged" >"$repo/src/staged.py"
git -C "$repo" add src/staged.py

head_before=$(git -C "$repo" rev-parse HEAD)
status_before=$(git -C "$repo" status --porcelain)
reflog_before=$(git -C "$repo" reflog | wc -l | tr -d ' ')

journal=$work/journal.md
cat >"$journal" <<'J'
## Round of earlier

- [P2] something about paths

## The author, on the findings above

Fixed the first; declined the second, the field is documented.
J

cd "$repo"
report=$("$adapter" /dev/null "$journal" 2>"$work/err")
rc=$?

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

check "the adapter succeeds" 0 "$rc"
contains "the report reaches stdout" "one finding" "$report"

# A path into the throwaway checkout cannot be opened and will not exist in a
# minute, so the report must name the tree the author is editing.
contains "paths point at the real working tree" "$repo/src/a.py:3" "$report"
case $report in
  *review-loop-wt*)
    fail=$((fail + 1)); printf 'FAIL the throwaway path leaked into the report\n' ;;
  *)
    pass=$((pass + 1)); printf 'ok   %s\n' "and the throwaway path is gone" ;;
esac

check "HEAD did not move" "$head_before" "$(git -C "$repo" rev-parse HEAD)"
check "the index and worktree are untouched" "$status_before" "$(git -C "$repo" status --porcelain)"
check "no ref was written, so the reflog is unchanged" "$reflog_before" "$(git -C "$repo" reflog | wc -l | tr -d ' ')"
check "no worktree was left behind" 1 "$(git -C "$repo" worktree list | wc -l | tr -d ' ')"
check "no branch was created" 1 "$(git -C "$repo" branch --list | wc -l | tr -d ' ')"

# The snapshot must carry every uncommitted shape, or the review is of the wrong code.
log=$(cat "$STUB_LOG")
contains "the reviewer was pointed at a commit" "sha: " "$log"

# The history reaches the reviewer through AGENTS.md, because `codex review`
# refuses a prompt alongside any scope flag however its usage line reads.
contains "the history reaches the reviewer" "declined the second" "$log"
contains "and so does the instruction on how to read it" "not a limit on what you may report" "$log"
# The file is standing instructions for the session, not a note read once. Told
# to verify claimed fixes it re-ran the test suite eighteen times in ten
# minutes, so the wording has to bound the work it invites.
contains "with the work it invites bounded" "do not re-run" "$log"
contains "without losing the project's own instructions" "never use tabs" "$log"
argv_line=$(grep -m1 '^argv: ' "$STUB_LOG")
case $argv_line in
  *"declined the second"*|*"not as a limit"*)
    fail=$((fail + 1)); printf 'FAIL the history went into argv, which codex refuses: %s\n' "$argv_line" ;;
  *) pass=$((pass + 1)); printf 'ok   %s\n' "and not as an argument codex would reject" ;;
esac
contains "the edit is in the snapshot" "src/a.py" "$log"
contains "the untracked file is in the snapshot" "src/new.py" "$log"
contains "the staged file is in the snapshot" "src/staged.py" "$log"
# Not compared against TMPDIR: the adapter resolves it, and on macOS that turns
# /var into /private/var. The name it gives its own checkout is the stable part.
contains "the reviewer ran inside a throwaway checkout" "review-loop-wt" "$log"
case $log in
  *"cwd: $repo"$'\n'*) fail=$((fail + 1)); printf 'FAIL the reviewer ran in the real repository\n' ;;
  *) pass=$((pass + 1)); printf 'ok   %s\n' "and not in the real repository" ;;
esac

# --- a secondary worker is told not to run the tests -------------------------
: >"$STUB_LOG"
(cd "$repo" && REVIEW_LOOP_NO_TESTS=1 "$adapter" /dev/null "" >/dev/null 2>&1)
contains "the no-test instruction reaches the reviewer" "Do not run this project" "$(cat "$STUB_LOG")"
: >"$STUB_LOG"
(cd "$repo" && "$adapter" /dev/null "" >/dev/null 2>&1)
case $(cat "$STUB_LOG") in
  *"Do not run this project"*)
    fail=$((fail + 1)); printf 'FAIL the primary worker is told not to run tests too\n' ;;
  *) pass=$((pass + 1)); printf 'ok   %s\n' "and the worker that has the dependencies is not" ;;
esac

# --- the no-test instruction takes the same safe path as the history ---------
# It was added as a second, separate writer and brought both faults back: it
# followed a symlink out of the worktree and skipped the override file.
echo "shared, not the reviewer's business" >"$work/outside-notests.md"
symn=$work/symrepo-notests
mkdir -p "$symn/src"
git -C "$symn" init -q
git -C "$symn" config user.email t@example.com
git -C "$symn" config user.name test
ln -s "$work/outside-notests.md" "$symn/AGENTS.md"
echo "override rules" >"$symn/AGENTS.override.md"
git -C "$symn" add -A
git -C "$symn" commit -qm base
echo "a change to review" >"$symn/src/a.py"
# A stub that shows both instruction files, since that is what is in question.
cat >"$bin/codex" <<'BOTH'
#!/usr/bin/env bash
{ echo "--- AGENTS.md ---"; cat AGENTS.md 2>/dev/null
  echo "--- AGENTS.override.md ---"; cat AGENTS.override.md 2>/dev/null; } >>"$STUB_LOG"
echo "stub review says: one finding"
BOTH
chmod +x "$bin/codex"
: >"$STUB_LOG"
(cd "$symn" && REVIEW_LOOP_NO_TESTS=1 "$adapter" /dev/null "" >/dev/null 2>&1)
check "the symlink target is untouched by the no-test instruction" \
  "shared, not the reviewer's business" "$(cat "$work/outside-notests.md")"
check "and both instruction files carry it" 2 \
  "$(grep -c 'Do not run this project' "$STUB_LOG")"

# --- a symlinked AGENTS.md must not carry the write outside the worktree ------
# Cleanup removes the throwaway checkout and nothing else, so a followed link
# would leave a permanent edit in a file the review had no business touching.
outside=$work/shared-instructions.md
echo "shared, and none of the reviewer's business" >"$outside"
sym=$work/symrepo
mkdir -p "$sym/src"
git -C "$sym" init -q
git -C "$sym" config user.email t@example.com
git -C "$sym" config user.name test
ln -s "$outside" "$sym/AGENTS.md"
git -C "$sym" add -A
git -C "$sym" commit -qm base
echo "a change to review" >"$sym/src/a.py"
: >"$STUB_LOG"
(cd "$sym" && "$adapter" /dev/null "$journal" >/dev/null 2>&1)
check "the file the symlink pointed at is untouched" \
  "shared, and none of the reviewer's business" "$(cat "$outside")"
contains "and the history still reached the reviewer" "declined the second" "$(cat "$STUB_LOG")"

# --- an override file, where the repository has one ---------------------------
# Codex looks for AGENTS.md and AGENTS.override.md both, and which wins is
# documented nowhere I could check, so the history goes to both.
ovr=$work/ovrrepo
mkdir -p "$ovr/src"
git -C "$ovr" init -q
git -C "$ovr" config user.email t@example.com
git -C "$ovr" config user.name test
echo "base rules" >"$ovr/AGENTS.md"
echo "override rules" >"$ovr/AGENTS.override.md"
git -C "$ovr" add -A
git -C "$ovr" commit -qm base
echo "a change to review" >"$ovr/src/a.py"
cat >"$bin/codex" <<'STUB2'
#!/usr/bin/env bash
{ echo "--- AGENTS.md ---"; cat AGENTS.md 2>/dev/null
  echo "--- AGENTS.override.md ---"; cat AGENTS.override.md 2>/dev/null; } >>"$STUB_LOG"
echo "stub review says: one finding"
STUB2
chmod +x "$bin/codex"
: >"$STUB_LOG"
(cd "$ovr" && "$adapter" /dev/null "$journal" >/dev/null 2>&1)
log=$(cat "$STUB_LOG")
check "both instruction files carry the history" 2 "$(grep -c 'Review history' <<<"$log")"
contains "and neither loses the project's own rules" "override rules" "$log"

# --- a rewrite that fails is a failed review ----------------------------------
# The reviewer's status was taken and the other half written as a literal zero,
# so a sed that died handed back an empty report and the runner filed the state
# as reviewed. Only the rewriting sed is broken here - it is the one whose
# expression names the checkout - so the escaping calls above it still work.
badbin=$work/badbin
mkdir -p "$badbin"
cat >"$badbin/sed" <<'BADSED'
#!/usr/bin/env bash
case ${1-} in
  *review-loop-wt*) exit 1 ;;
esac
exec /usr/bin/sed "$@"
BADSED
chmod +x "$badbin/sed"
cat >"$bin/codex" <<'STUB3'
#!/usr/bin/env bash
echo "stub review says: one finding"
STUB3
chmod +x "$bin/codex"
echo "one more change" >>"$repo/src/a.py"
out=$(cd "$repo" && PATH=$badbin:$PATH "$adapter" /dev/null "" 2>/dev/null); rc=$?
check "a failed path rewrite fails the review" 1 "$rc"
check "and offers no report" "" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
