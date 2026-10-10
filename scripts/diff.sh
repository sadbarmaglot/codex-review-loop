#!/usr/bin/env bash
#
# What is under review, and its identity. Shared so the gate and the review
# agree on both: a review filed under an identity the gate would not compute is
# a review nobody ever finds.

# state_root
#
# One stable place, shared by the hook and the review with no plumbing between
# them. The session scratchpad was the earlier default and it cannot be: the
# hook learns it from its payload and nothing else can, so the review filed its
# results where the hook never looked and every review passed unnoticed.
state_root() {
  printf '%s' "${REVIEW_LOOP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.cache}}/review-loop"
}

# repo_key <repo-root>
#
# A short, stable name for a repository, for the per-repository files kept
# beside the results.
repo_key() {
  printf '%s' "$1" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-16
}

# base_rev <repo-root>
#
# HEAD, or git's empty tree where there is no commit yet, so a project's very
# first files are reviewable like any other change. Computed rather than
# pasted: the empty tree's hash differs between SHA-1 and SHA-256 repositories.
base_rev() {
  git -C "$1" rev-parse --verify -q HEAD >/dev/null 2>&1 &&
    { git -C "$1" rev-parse HEAD; return 0; }
  git -C "$1" hash-object -t tree /dev/null
}

# work_tree_sha <repo-root> <scratch-index-path>
#
# The working tree as a git tree object: tracked changes, staged or not, and
# every untracked file that is not ignored. A temporary index means the real
# one is never staged into.
#
# This, and not the text of a diff, is what identifies a state. Text was the
# earlier choice and it could not be verified: the reviewer reads a snapshot
# commit, and no amount of comparing diffs before and after taking one proves
# the snapshot holds the state the result will be filed under. A tree can be
# compared with a snapshot's tree directly, and either they are equal or they
# are not.
work_tree_sha() {
  local root=$1 index=$2 base
  base=$(base_rev "$root") || return 1
  GIT_INDEX_FILE=$index git -C "$root" read-tree "$base" >/dev/null 2>&1 || return 1
  GIT_INDEX_FILE=$index git -C "$root" add -A >/dev/null 2>&1 || return 1
  GIT_INDEX_FILE=$index git -C "$root" write-tree
}

# submodule_state <repo-root>
#
# A submodule's uncommitted contents are invisible to `git add -A`, which
# records only the unchanged gitlink: a change made entirely inside one leaves
# the tree identical to its base. Without this such a change reads as a clean
# tree and is never reviewed at all. Empty, and free, where there are none.
submodule_state() {
  git -C "$1" submodule status --recursive 2>/dev/null
  # Its content, written to a tree of its own - not the text of its status. Two
  # different edits to an already-dirty file leave the same porcelain line, and
  # hashing that line gave both of them the same identity, so a result for the
  # first silenced review of the second.
  # One traversal, carrying both what identifies a submodule and whether it is
  # dirty. Asking twice left a window: a submodule clean by the second question
  # let a review complete an identity that had been hashed while it was dirty.
  git -C "$1" submodule foreach --quiet --recursive \
    'i=$(mktemp); GIT_INDEX_FILE=$i git read-tree HEAD >/dev/null 2>&1;
     GIT_INDEX_FILE=$i git add -A >/dev/null 2>&1;
     dirty=0; git status --porcelain | grep -q . && dirty=1;
     printf "%s %s dirty=%s\n" "$sm_path" "$(GIT_INDEX_FILE=$i git write-tree 2>/dev/null)" "$dirty";
     rm -f "$i"' 2>/dev/null
  return 0
}

# dirty_submodules <submodule-state>
#
# Read out of the state that went into the identity, never asked again.
dirty_submodules() {
  printf '%s' "$1" | sed -n 's/^\(.*\) [0-9a-f]* dirty=1$/\1/p'
}

# embedded_repos <repo-root> <tree-sha>
#
# A directory that is itself a git repository is recorded by `git add -A` as a
# gitlink, not as its files, so its contents are in neither the identity nor
# the snapshot - and an edit that leaves its HEAD alone reuses the identity and
# is suppressed by the existing result. Registered submodules are accounted for
# separately; these are the ones nobody declared.
embedded_repos() {
  local root=$1 tree=$2 declared path
  # Whole paths, not fields. A submodule called "deps good" and an undeclared
  # repository called "deps bad" both collapse to "deps" once awk has had
  # them, and the undeclared one then passes for declared.
  declared=$(git -C "$root" config --file "$root/.gitmodules" \
    --get-regexp '^submodule\..*\.path$' 2>/dev/null | cut -d' ' -f2-)

  # ls-tree -z ends each record with NUL and separates the path with a tab, so
  # neither spaces nor newlines in a name can split it.
  git -C "$root" ls-tree -r -z "$tree" 2>/dev/null |
    while IFS= read -r -d '' entry; do
      case $entry in
        *" commit "*) ;;
        *) continue ;;
      esac
      path=${entry#*$'\t'}
      # NUL out as well as in. Printing these newline-separated undid the care
      # taken reading them: a directory whose name contains a newline came back
      # as two paths, each of which exists nowhere, so every caller checking
      # them found nothing wrong and let the change through.
      printf '%s\n' "$declared" | grep -qxF "$path" || printf '%s\0' "$path"
    done
  return 0
}

# state_identity <repo-root> <tree-sha>
#
# The repository and its base revision belong in the identity, not just the
# content. One results directory serves every project: two checkouts with the
# same tree, or the same edit made on two branches, are different states, and
# the reviewer reads the whole tree rather than a patch.
state_identity() {
  local root=$1 tree=$2 base=${3:-} subs=${4:-__ask__}
  [ -n "$base" ] || base=$(base_rev "$root")
  # The caller may pass the submodule state it already holds, so that identity
  # and any decision taken about submodules come from one reading.
  [ "$subs" = __ask__ ] && subs=$(submodule_state "$root")
  if command -v shasum >/dev/null 2>&1; then
    printf '%s\n%s\n%s\n%s' "$root" "$base" "$tree" "$subs" | shasum -a 256 | cut -d' ' -f1
  else
    printf '%s\n%s\n%s\n%s' "$root" "$base" "$tree" "$subs" | sha256sum | cut -d' ' -f1
  fi
}

# tree_is_clean <repo-root> <tree-sha> <base-rev>
#
# Nothing to review: the tree matches its base and no submodule is dirty.
tree_is_clean() {
  local root=$1 tree=$2 base=$3 path
  [ "$tree" = "$(git -C "$root" rev-parse "$base^{tree}" 2>/dev/null)" ] || return 1
  [ -z "$(git -C "$root" submodule foreach --quiet --recursive \
    'git status --porcelain | grep -q . && echo dirty' 2>/dev/null)" ] || return 1

  # An embedded repository nobody declared is a gitlink too, and an edit inside
  # one leaves the superproject tree identical. Checked here rather than later:
  # the clean shortcut used to return first, and such a change was silently
  # treated as nothing to review.
  embedded_repos "$root" "$tree" | while IFS= read -r -d '' path; do
    [ -n "$path" ] || continue
    [ -n "$(git -C "$root/$path" status --porcelain 2>/dev/null)" ] && exit 1
  done || return 1
  return 0
}

# patch_of <repo-root> <tree-or-commit>
#
# The change as one diff, taken from the snapshot rather than the live tree, so
# what the adapters are handed is the same state everything else refers to.
patch_of() {
  local root=$1 rev=$2 base=${3:-}
  # The frozen base when the caller has one. Resolving HEAD again here would
  # produce a patch against a revision the result is not filed under.
  [ -n "$base" ] || base=$(base_rev "$root")
  git -C "$root" diff --no-color "$base" "$rev" 2>/dev/null
  return 0
}

# kill_tree <pid>
#
# Depth first, so a child is signalled before the parent that would otherwise
# outlive the knowledge of it. Killing by name would be simpler and is how a
# live review in another session was killed for hours.
kill_tree() {
  local p=$1 child
  for child in $(pgrep -P "$p" 2>/dev/null); do kill_tree "$child"; done
  kill "$p" 2>/dev/null
}

# run_killable <stdout-file> <stderr-file> <command...>
#
# Bash defers a trap while it waits for a foreground child, so a handler that
# only exits does nothing until the reviewer finishes on its own - minutes of
# tests and a held worktree after the cancellation. Backgrounded and waited
# for, the wait is interruptible and the handler can take the child with it.
run_killable() {
  local out=$1 err=$2; shift 2
  "$@" >"$out" 2>"$err" &
  KILLABLE_PID=$!
  wait "$KILLABLE_PID"
}

# owner_is_ours <pid> <marker-written-epoch>
#
# `kill -0` only says the number is in use. A run killed without cleanup can
# have its number handed to something else, and the stale marker would then
# pass for a review in progress. A process younger than the marker that names
# it cannot be the one that wrote it.
owner_is_ours() {
  local pid=$1 written=$2 elapsed secs
  kill -0 "$pid" 2>/dev/null || return 1
  elapsed=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
  [ -n "$elapsed" ] || return 1
  # etime is [[dd-]hh:]mm:ss
  secs=$(printf '%s' "$elapsed" | awk -F'[-:]' '{
    if (NF==4) print (($1*24+$2)*60+$3)*60+$4;
    else if (NF==3) print (($1*60)+$2)*60+$3;
    else print $1*60+$2 }')
  case $secs in ''|*[!0-9]*) return 0 ;; esac
  [ "$secs" -ge "$(( $(date +%s) - written ))" ]
}

# prune_results <results-dir>
#
# The results directory keeps a patch of your source for every state ever
# reviewed, and it grew to a hundred files and nine megabytes in one evening.
# The asynchronous layer used to sweep it; that layer was deleted and its
# housekeeping went with it, which is how the litter came back.
#
# Two kinds of rubbish, two rules. Anything older than the keep window goes.
# A start marker whose owner is no longer running goes whatever its age: it
# describes a review that is not happening, and while it sits there the gate
# believes one is.
#
# The journal is never touched. It is the accumulated history, it is the one
# thing here meant to outlive everything, and a sweep that took it would undo
# the reason the reviewer stops repeating itself.
prune_results() {
  local dir=$1 days=${REVIEW_LOOP_KEEP_DAYS:-7} logdays=${REVIEW_LOOP_KEEP_LOGS_DAYS:-1} f owner
  [ -d "$dir" ] || return 0

  # A context file holds the conversation and belongs to one run, named
  # context-<hash>-<pid>. Only the orphans go: this sweep runs at the start of
  # every review, and deleting them all took the context out from under a run
  # that had not yet read it, which then reviewed without its history.
  for f in "$dir"/context-*; do
    [ -e "$f" ] || continue
    owner=${f##*-}
    owner=${owner%.md}
    case $owner in
      ''|*[!0-9]*) rm -f "$f"; continue ;;
    esac
    kill -0 "$owner" 2>/dev/null || rm -f "$f"
  done

  # Measured over one evening: the reviewer's raw logs were two thirds of the
  # directory at 287KB each, the patches of your source another fifth, and the
  # findings themselves 32KB in total. So the bulk goes early and the small,
  # useful part stays: .out says what was found and .done is what the gate
  # reads to know a state was looked at.
  find "$dir" -maxdepth 1 -type f \( -name '*.err' -o -name '*.patch' \) \
    -mtime +"$logdays" -delete 2>/dev/null
  # The journal and the declines are decisions, not results. A `.skipped`
  # marker says the author answered the question for this exact state, and
  # sweeping it on age makes the gate ask again about a tree that has not
  # moved - which is the opposite of what the command promises.
  find "$dir" -maxdepth 1 -type f ! -name 'journal-*' ! -name '*.skipped' \
    -mtime +"$days" -delete 2>/dev/null

  # Markers are named <hash>.started.<pid>: one per invocation, so two runs of
  # one state do not share a file and neither can remove the other's.
  for f in "$dir"/*.started.*; do
    [ -e "$f" ] || continue
    owner=${f##*.}
    case $owner in
      ''|*[!0-9]*) rm -f "$f"; continue ;;
    esac
    written=$(cat "$f" 2>/dev/null)
    case $written in ''|*[!0-9]*) written=0 ;; esac
    owner_is_ours "$owner" "$written" || rm -f "$f"
  done
  return 0
}
