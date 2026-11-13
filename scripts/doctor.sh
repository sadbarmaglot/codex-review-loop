#!/usr/bin/env bash
#
# Check the things that make the loop silently wrong: a missing reviewer, and
# an API key that quietly moves the billing off the subscription.

set -uo pipefail

ok=0
say() { printf '%-28s %s\n' "$1" "$2"; }
bad() { ok=1; say "$1" "$2"; }

command -v jq >/dev/null 2>&1 &&
  say "jq" "found" ||
  bad "jq" "MISSING - the gate is inert without it"

git rev-parse --show-toplevel >/dev/null 2>&1 &&
  say "git repo" "$(git rev-parse --show-toplevel)" ||
  say "git repo" "not inside one - the gate stays out of the way"

if command -v codex >/dev/null 2>&1; then
  say "codex" "$(codex --version 2>/dev/null || echo 'found')"
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    say "OPENAI_API_KEY" "set - stripped per review, so reviews stay on the subscription"
  else
    say "OPENAI_API_KEY" "unset"
  fi
  echo
  echo "codex login status:"
  codex login status 2>&1 | sed 's/^/  /'
else
  bad "codex" "not on PATH - install it, or point REVIEW_LOOP_REVIEWER at claude-review.sh"
fi

if command -v claude >/dev/null 2>&1; then
  say "claude" "$(claude --version 2>/dev/null || echo 'found')"
  [ -n "${ANTHROPIC_API_KEY:-}" ] &&
    say "ANTHROPIC_API_KEY" "set - stripped per review" ||
    say "ANTHROPIC_API_KEY" "unset"
fi

echo
# Read off run-review.sh, so the reported default cannot go stale.
default_reviewer=$(sed -n 's/^REVIEWER=\${REVIEW_LOOP_REVIEWER:-\$here\/\(.*\)}$/\1/p' \
  "$(dirname "${BASH_SOURCE[0]}")/run-review.sh")
say "reviewer" "${REVIEW_LOOP_REVIEWER:-<default: ${default_reviewer:-unknown}>}"
say "reviewers at once" "${REVIEW_LOOP_FANOUT:-3} (fan-out adapter only)"
say "max rounds" "${REVIEW_LOOP_MAX_ROUNDS:-3}"
say "state dir" "$( . "$(dirname "${BASH_SOURCE[0]}")/diff.sh"; state_root )"
[ -n "${REVIEW_LOOP_SETUP_CMD:-}" ] &&
  say "setup cmd" "$REVIEW_LOOP_SETUP_CMD" ||
  say "setup cmd" "unset - the reviewer reads but cannot run the code"
[ -n "${REVIEW_LOOP_DISABLE:-}" ] && say "gate" "DISABLED by REVIEW_LOOP_DISABLE"

exit "$ok"
