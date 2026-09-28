---
description: Review the current change now, without waiting for the turn to end
---

Start the review as a **background task** and carry on:

```
${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh
```

Run it with `run_in_background: true`. It takes a few minutes and prints nothing
until it finishes, so a foreground run blinds the session for its whole length.
In the background Claude Code tracks it and wakes the session with the findings.

While it runs, its output file carries the reviewer's stages — snapshotting,
installing dependencies, reviewing — so progress can be read rather than
guessed at.

When the findings arrive, **retell them to the user first**, before acting,
keeping the reviewer's shape: the one-line summary, then one entry per finding
with its severity, file and line, and what goes wrong — in your own words and
the user's language, with nothing dropped and no two findings merged. Then
judge each one: fix what is
a real defect, and say plainly why the rest is not. This reviewer is
confidently wrong about APIs often enough that applying its findings unread is
a mistake. Change nothing it did not name.

**Then tell the next round what you did.** The reviewer has no memory between
rounds, so without this it re-raises what you already declined and cannot tell
whether a fix it asked for was made:

```
${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh --after "fixed 1 and 3; declined 2, the field is in the payload and documented"
```

The result is filed where the `Stop` hook looks, so a review started this way
also satisfies the gate and the turn ends cleanly.

$ARGUMENTS, when given, belongs in the `--after` note: say what to pay attention
to. The review itself always covers the whole working tree — the default adapter
reviews a snapshot of it, and there is no per-path scope to pass through.
