#!/usr/bin/env bash
#
# What is under review and its identity, shared by the gate and the review so
# both compute the same thing.

# Where state lives: one stable place both the hook and the review can find.
state_root() {
  printf '%s' "${REVIEW_LOOP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.cache}}/review-loop"
}

# repo_key <repo-root>: a short stable name for per-repository files.
repo_key() {
  printf '%s' "$1" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-16
}

# base_rev <repo-root>: HEAD, or git's empty tree before the first commit.
base_rev() {
  git -C "$1" rev-parse --verify -q HEAD >/dev/null 2>&1 &&
    { git -C "$1" rev-parse HEAD; return 0; }
  git -C "$1" hash-object -t tree /dev/null
}

# work_tree_sha <repo-root> <scratch-index-path>
#
# The working tree as a git tree object: tracked changes and every untracked,
# non-ignored file. A tree identifies a state and can be compared with a
# snapshot's tree directly. The real index is never touched.
work_tree_sha() {
  local root=$1 index=$2 base
  base=$(base_rev "$root") || return 1
  GIT_INDEX_FILE=$index git -C "$root" read-tree "$base" >/dev/null 2>&1 || return 1
  GIT_INDEX_FILE=$index git -C "$root" add -A >/dev/null 2>&1 || return 1
  GIT_INDEX_FILE=$index git -C "$root" write-tree
}

# submodule_state <repo-root>
#
# Uncommitted submodule contents are invisible to `git add -A`, so they are
# hashed here: one line per submodule with a tree of its content and whether
# it is dirty, from a single traversal. Empty where there are none.
submodule_state() {
  git -C "$1" submodule status --recursive 2>/dev/null
  git -C "$1" submodule foreach --quiet --recursive \
    'i=$(mktemp); GIT_INDEX_FILE=$i git read-tree HEAD >/dev/null 2>&1;
     GIT_INDEX_FILE=$i git add -A >/dev/null 2>&1;
     dirty=0; git status --porcelain | grep -q . && dirty=1;
     printf "%s %s dirty=%s\n" "$sm_path" "$(GIT_INDEX_FILE=$i git write-tree 2>/dev/null)" "$dirty";
     rm -f "$i"' 2>/dev/null
  return 0
}

# dirty_submodules <submodule-state>: read from the state, never asked again.
dirty_submodules() {
  printf '%s' "$1" | sed -n 's/^\(.*\) [0-9a-f]* dirty=1$/\1/p'
}

# embedded_repos <repo-root> <tree-sha>
#
# Undeclared git repositories inside the tree, NUL-delimited. `git add -A`
# records one as a gitlink, so its contents are in neither the identity nor
# the snapshot.
embedded_repos() {
  local root=$1 tree=$2 declared path
  declared=$(git -C "$root" config --file "$root/.gitmodules" \
    --get-regexp '^submodule\..*\.path$' 2>/dev/null | cut -d' ' -f2-)

  # NUL in and out: a path may hold spaces or newlines.
  git -C "$root" ls-tree -r -z "$tree" 2>/dev/null |
    while IFS= read -r -d '' entry; do
      case $entry in
        *" commit "*) ;;
        *) continue ;;
      esac
      path=${entry#*$'\t'}
      printf '%s\n' "$declared" | grep -qxF "$path" || printf '%s\0' "$path"
    done
  return 0
}

# state_identity <repo-root> <tree-sha> [base-rev] [submodule-state]
#
# Repository and base are part of the identity: one results directory serves
# every project. Pass the submodule state already held, so the identity and
# any decision about submodules come from one reading.
state_identity() {
  local root=$1 tree=$2 base=${3:-} subs=${4:-__ask__}
  [ -n "$base" ] || base=$(base_rev "$root")
  [ "$subs" = __ask__ ] && subs=$(submodule_state "$root")
  if command -v shasum >/dev/null 2>&1; then
    printf '%s\n%s\n%s\n%s' "$root" "$base" "$tree" "$subs" | shasum -a 256 | cut -d' ' -f1
  else
    printf '%s\n%s\n%s\n%s' "$root" "$base" "$tree" "$subs" | sha256sum | cut -d' ' -f1
  fi
}

# tree_is_clean <repo-root> <tree-sha> <base-rev>
#
# Nothing to review: the tree matches its base, and no submodule or embedded
# repository is dirty.
tree_is_clean() {
  local root=$1 tree=$2 base=$3 path
  [ "$tree" = "$(git -C "$root" rev-parse "$base^{tree}" 2>/dev/null)" ] || return 1
  [ -z "$(git -C "$root" submodule foreach --quiet --recursive \
    'git status --porcelain | grep -q . && echo dirty' 2>/dev/null)" ] || return 1

  embedded_repos "$root" "$tree" | while IFS= read -r -d '' path; do
    [ -n "$path" ] || continue
    [ -n "$(git -C "$root/$path" status --porcelain 2>/dev/null)" ] && exit 1
  done || return 1
  return 0
}

# patch_of <repo-root> <tree-or-commit> [base-rev]: the change as one diff,
# taken from the snapshot against the frozen base.
patch_of() {
  local root=$1 rev=$2 base=${3:-}
  [ -n "$base" ] || base=$(base_rev "$root")
  git -C "$root" diff --no-color "$base" "$rev" 2>/dev/null
  return 0
}

# kill_tree <pid>: depth first, by pid. Never kill by name.
kill_tree() {
  local p=$1 child
  for child in $(pgrep -P "$p" 2>/dev/null); do kill_tree "$child"; done
  kill "$p" 2>/dev/null
}

# run_killable <stdout-file> <stderr-file> <command...>
#
# Bash defers a trap while waiting on a foreground child. Backgrounded and
# waited for, the wait is interruptible and a handler can kill KILLABLE_PID.
run_killable() {
  local out=$1 err=$2; shift 2
  "$@" >"$out" 2>"$err" &
  KILLABLE_PID=$!
  wait "$KILLABLE_PID"
}

# owner_is_ours <pid> <marker-written-epoch>
#
# The pid is alive and old enough to have written the marker: a reused pid is
# younger than the marker that names it.
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
# Logs and patches go after REVIEW_LOOP_KEEP_LOGS_DAYS, everything else after
# REVIEW_LOOP_KEEP_DAYS. The journal and the declines are decisions and are
# never swept. Orphaned context files and start markers go whatever their age.
prune_results() {
  local dir=$1 days=${REVIEW_LOOP_KEEP_DAYS:-7} logdays=${REVIEW_LOOP_KEEP_LOGS_DAYS:-1} f owner
  [ -d "$dir" ] || return 0

  # context-<hash>-<pid>: only those whose run is gone.
  for f in "$dir"/context-*; do
    [ -e "$f" ] || continue
    owner=${f##*-}
    owner=${owner%.md}
    case $owner in
      ''|*[!0-9]*) rm -f "$f"; continue ;;
    esac
    kill -0 "$owner" 2>/dev/null || rm -f "$f"
  done

  find "$dir" -maxdepth 1 -type f \( -name '*.err' -o -name '*.patch' \) \
    -mtime +"$logdays" -delete 2>/dev/null
  find "$dir" -maxdepth 1 -type f ! -name 'journal-*' ! -name '*.skipped' \
    -mtime +"$days" -delete 2>/dev/null

  # <hash>.started.<pid>: one marker per invocation.
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

# resolve_reviewer <name-or-path> <scripts-dir>
#
# Short names for the plugin's own adapters, so settings need not carry the
# versioned install path. A closed list: only real adapters. Paths and unknown
# names are returned unchanged.
resolve_reviewer() {
  case $1 in
    codex-worktree|codex|codex-builtin|claude|fanout) printf '%s' "$2/$1-review.sh" ;;
    *) printf '%s' "$1" ;;
  esac
}
