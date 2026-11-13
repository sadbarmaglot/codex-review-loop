#!/usr/bin/env bash
#
# Freeze the working tree into a commit on no branch and in no reflog.
#
#   make_snapshot <repo-root> <scratch-index-path> [base-rev]  -> commit sha
#
# A temporary index keeps the real one untouched. The parent is the base, so
# the commit's own diff is exactly the uncommitted work.

# The base is passed in so the commit hangs off the revision the identity was
# computed against, even if HEAD has moved since.
make_snapshot() {
  local root=$1 index=$2 base=${3:-} tree sha
  local parent=()

  [ -n "$base" ] || {
    base=HEAD
    git -C "$root" rev-parse --verify -q HEAD >/dev/null 2>&1 ||
      base=$(git -C "$root" hash-object -t tree /dev/null) || return 1
  }

  # No parent when the base is the empty tree.
  if [ "$base" != "$(git -C "$root" hash-object -t tree /dev/null)" ]; then
    parent=(-p "$base")
  fi

  GIT_INDEX_FILE=$index git -C "$root" read-tree "$base" >/dev/null 2>&1 || return 1
  GIT_INDEX_FILE=$index git -C "$root" add -A >/dev/null 2>&1 || return 1
  tree=$(GIT_INDEX_FILE=$index git -C "$root" write-tree) || return 1

  # Its own identity: works without user.name configured.
  sha=$(GIT_AUTHOR_NAME=review-loop GIT_AUTHOR_EMAIL=review-loop@localhost \
    GIT_COMMITTER_NAME=review-loop GIT_COMMITTER_EMAIL=review-loop@localhost \
    git -C "$root" commit-tree "$tree" ${parent[@]+"${parent[@]}"} -m 'review-loop snapshot') || return 1

  printf '%s' "$sha"
}
