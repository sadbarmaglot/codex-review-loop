#!/usr/bin/env bash
#
# Freeze the working tree into a commit that belongs to no branch.
#
#   make_snapshot <repo-root> <scratch-index-path>   -> prints the commit sha
#
# A temporary index means the real one is never staged into; commit-tree writes
# a commit that appears in no branch and no reflog, collected as garbage in its
# own time. The parent is HEAD, so the commit's own diff is exactly the
# uncommitted work - which is what `codex review --commit` wants.
#
# It has to happen while the hook still holds the turn. Taken later, in a
# detached review, `git add -A` would photograph whatever the tree has become by
# then and file the result under a hash describing a different state.

# The base is passed in, not read here. Read again at snapshot time, a HEAD
# that moved since the identity was computed would parent the commit elsewhere,
# and `codex review --commit` would then judge a different diff than the one
# the result is filed under.
make_snapshot() { # make_snapshot <repo-root> <index-path> [base-rev]
  local root=$1 index=$2 base=${3:-} tree sha
  local parent=()

  [ -n "$base" ] || {
    base=HEAD
    git -C "$root" rev-parse --verify -q HEAD >/dev/null 2>&1 ||
      base=$(git -C "$root" hash-object -t tree /dev/null) || return 1
  }

  # An empty tree as the base means there is no commit to hang this off. The
  # array stays empty then, and an empty array under `set -u` is an error to
  # expand plainly - hence the guarded form at the call below.
  if [ "$base" != "$(git -C "$root" hash-object -t tree /dev/null)" ]; then
    parent=(-p "$base")
  fi

  GIT_INDEX_FILE=$index git -C "$root" read-tree "$base" >/dev/null 2>&1 || return 1
  GIT_INDEX_FILE=$index git -C "$root" add -A >/dev/null 2>&1 || return 1
  tree=$(GIT_INDEX_FILE=$index git -C "$root" write-tree) || return 1

  # An identity of its own: this commit is scaffolding, and a machine with no
  # user.name configured must not lose its review to "Author identity unknown".
  sha=$(GIT_AUTHOR_NAME=review-loop GIT_AUTHOR_EMAIL=review-loop@localhost \
    GIT_COMMITTER_NAME=review-loop GIT_COMMITTER_EMAIL=review-loop@localhost \
    git -C "$root" commit-tree "$tree" ${parent[@]+"${parent[@]}"} -m 'review-loop snapshot') || return 1

  printf '%s' "$sha"
}
