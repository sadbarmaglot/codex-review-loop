#!/usr/bin/env bash
#
# `claude plugin validate <dir>` checks the marketplace manifest when a
# directory holds both, and says nothing about the plugin. That is how a
# hooks.json in the wrong shape - which would have stopped the gate from ever
# being registered - passed for a whole day. This validates each in turn.

set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cp -R "$root" "$tmp/plugin" 2>/dev/null
rm -rf "$tmp/plugin/.git"
rm -f "$tmp/plugin/.claude-plugin/marketplace.json"

fail=0

echo "== plugin manifest"
claude plugin validate "$tmp/plugin" || fail=1

echo
echo "== marketplace manifest"
claude plugin validate "$root" || fail=1

echo
echo "== hooks.json shape"
# Events live under a top-level "hooks" key, the same shape as settings.json.
if jq -e '.hooks | objects | has("Stop")' "$root/hooks/hooks.json" >/dev/null 2>&1; then
  echo "✔ Stop is under the top-level hooks key"
else
  echo "✘ hooks/hooks.json must be {\"hooks\": {\"Stop\": [...]}}"
  fail=1
fi

exit "$fail"
