#!/usr/bin/env bash
#
# Decline the review of the state the gate is asking about.
#
#   skip-review.sh ["why"]
#
# The gate decides mechanically and cannot know what a turn was about. When its
# rules misjudge one - a change the author has no intention of reviewing, work
# that belongs to someone else, a turn that only read - this records the answer
# for this exact state, and the gate stops asking until the tree moves.
#
# Declined is not reviewed. The marker has its own name, the gate says
# "declined" rather than "reviewed", and the decision goes to the log, so
# nothing downstream can mistake one for the other.

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/diff.sh
. "$here/diff.sh"

why=${1:-}

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root=""
[ -n "$repo_root" ] || {
  echo "not inside a git repository; there is nothing for the gate to ask about" >&2
  exit 2
}

state_dir=$(state_root)
results=$state_dir/results
mkdir -p "$results" || {
  echo "cannot write to $results" >&2
  exit 2
}
chmod 700 "$state_dir" "$results" 2>/dev/null

index=$results/index-skip-$$
base=$(base_rev "$repo_root") || base=""
tree=$(work_tree_sha "$repo_root" "$index") || tree=""
rm -f "$index"
[ -n "$base" ] && [ -n "$tree" ] || {
  echo "could not read the working tree" >&2
  exit 2
}

# Nothing to decline. Said plainly rather than writing a marker for a state the
# gate would have let through anyway.
if tree_is_clean "$repo_root" "$tree" "$base"; then
  echo "the working tree matches HEAD; the gate is not asking about anything"
  exit 0
fi

# Refused where a review would be refused, and for the same reason. The
# identity hashes a dirty submodule or embedded repository as its gitlink and
# nothing more, so a later edit inside one that leaves its HEAD alone keeps
# this hash - and a marker written now would go on suppressing the question
# after the state had moved. A decline that outlives what it declined is worse
# than no decline at all.
#
# One reading of the submodules, used both for the refusal and for the hash
# below. Read twice, a submodule that turned dirty between the two readings
# passed the check and then went into the identity, and the gate honours
# .skipped before it asks anything about submodules - so that change would
# have been declined without anyone deciding to.
subs=$(submodule_state "$repo_root")
dirty=$(dirty_submodules "$subs" | tr '\n' ' ')
if [ -n "${dirty// /}" ]; then
  printf 'uncommitted changes inside submodules are not part of this state: %s\n' "$dirty" >&2
  echo "a decline recorded now would outlive further edits there; commit them first." >&2
  exit 2
fi
# Any embedded repository, dirty or not, exactly as run-review.sh refuses any.
# Clean is no comfort: its contents are outside the identity either way, so an
# edit inside one tomorrow leaves this hash standing and the marker written
# today would answer for code written after it.
while IFS= read -r -d '' nested; do
  [ -n "$nested" ] || continue
  printf 'a directory here is a git repository of its own, so its contents are in no state this marker could speak for: %s\n' "$nested" >&2
  echo "a decline recorded now would answer for edits made inside it later." >&2
  echo "commit it there, register it as a submodule, or ignore it." >&2
  exit 2
done < <(embedded_repos "$repo_root" "$tree")

hash=$(state_identity "$repo_root" "$tree" "$base" "$subs")
printf '%s\n' "${why:-declined by the author}" >"$results/$hash.skipped"
printf '%s skip hash=%.12s %s\n' \
  "$(date -u +%H:%M:%S)" "$hash" "${why:-declined by the author}" \
  >>"$state_dir/decisions.log"

echo "the gate will not ask about this state again until the tree changes"
[ -n "$why" ] && echo "recorded: $why"
exit 0
