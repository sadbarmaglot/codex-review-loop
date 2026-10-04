---
description: Check a plan against the code before writing any of it
---

For the usual case: existing code with a problem, a short plan for changing it,
and the wish to hear what the reviewer thinks before any of it is written.

Write the plan to a file — the scratchpad directory is the place for it — and
run:

```
${CLAUDE_PLUGIN_ROOT}/scripts/plan-review.sh <plan file>
```

Run it with `run_in_background: true`. It is far quicker than a code review,
seconds rather than minutes, because it runs nothing: the reviewer reads the
repository, it does not build or test it. Backgrounding it still costs nothing
and keeps the session answerable while it runs.

Nothing here gates a turn. This is asked for, never triggered: no marker, no
budget, no `.done`. The `Stop` hook still wants a code review of whatever gets
written afterwards, and a plan check does not satisfy it.

When the remarks arrive, **retell them to the user first**, before acting, in
the reviewer's shape: one entry each, what it names and what is wrong — your
own words and the user's language, nothing dropped and no two merged. Then
judge them. A plan check is cheaper to get wrong than a code review and the
reviewer is freer with its opinions here, so weigh each remark against the code
yourself rather than folding them all into the plan.

An empty report means the plan holds up against the code. Say so plainly.

$ARGUMENTS, when given, names the plan file. Without it, use the plan under
discussion: the plan-mode file if the session has one, otherwise what you just
wrote, saved to the scratchpad.
