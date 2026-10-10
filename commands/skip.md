---
description: Tell the gate this change is not for reviewing
---

```
${CLAUDE_PLUGIN_ROOT}/scripts/skip-review.sh "$ARGUMENTS"
```

Runs in a second; no need to background it.

For when the gate is asking about something nobody means to review: a turn that
only read, a change that belongs to another piece of work, uncommitted files
that were already there when the session started. The gate decides by rules and
cannot know what the turn was about — you can, so record it and it stops asking
until the tree changes.

`$ARGUMENTS` is the reason, in a few words, and it goes to `decisions.log`.
Worth writing: a bare marker six hours later says nothing about why.

**Declined is not reviewed.** The marker is a different file from a review's,
the gate says so, and a real review of the same state still files its own
result. Do not reach for this to get a turn to end — if the change is code the
session wrote, it has earned its review, and the round budget already releases
the turn after a few asks.
