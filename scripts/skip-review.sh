#!/usr/bin/env bash
#
# Decline the review of the state the gate is asking about.
#
#   skip-review.sh ["why"]
#
# Writes <hash>.skipped, which the gate honours until the tree changes.
# Declined is not reviewed: a separate marker, and the reason goes to the log.

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

if tree_is_clean "$repo_root" "$tree" "$base"; then
  echo "the working tree matches HEAD; the gate is not asking about anything"
  exit 0
fi

# Refused where a review is refused: the identity holds a submodule or an
# embedded repository as its gitlink only, so a marker would outlive edits
# inside. Submodules are read once, for both the check and the hash.
subs=$(submodule_state "$repo_root")
dirty=$(dirty_submodules "$subs" | tr '\n' ' ')
if [ -n "${dirty// /}" ]; then
  printf 'uncommitted changes inside submodules are not part of this state: %s\n' "$dirty" >&2
  echo "a decline recorded now would outlive further edits there; commit them first." >&2
  exit 2
fi
# Any embedded repository, clean or not: its contents are outside the identity.
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
