# Design

## The constraint that shaped everything

Reviews must be charged to a subscription, not to an API. That rules out every
MCP server that takes provider keys, and leaves exactly one mechanism: shell out
to a CLI that is already logged in. `codex exec` and `claude -p` both qualify.

The trap is quieter than it looks. Both CLIs prefer API-key authentication when
a key is present in the environment, so a `OPENAI_API_KEY` exported in a shell
profile turns every "free" review into a metered one with no visible difference.
The adapters therefore `env -u` the key before exec, and `doctor.sh` reports
which auth is actually in play.

## Why a Stop hook and not a tool

An MCP tool or a skill is a *channel*: Claude decides when to use it. In a long
turn it forgets, and the review that was supposed to be mandatory silently does
not happen.

The `Stop` hook is a *gate*: it fires when Claude tries to end the turn, and
exit code 2 is the one path by which a hook's stderr enters the model's context
rather than the user's log. That is the whole mechanism — the findings become
the reason the turn may not end, so the model has to deal with them.

The two compose. `/review-loop:review` is the channel for mid-work questions;
the gate makes sure the review happens whether or not anyone remembered.

## The hook asks; the runtime runs

The gate does not review. It refuses the stop and names a command for Claude to
start as a background task, and Claude Code does the rest: it tracks the task
and wakes the session with its output when it finishes.

That last part is the whole reason the design looks like this. A hook can only
speak when it exits, the status line is not repainted while one blocks, and in
the VS Code extension there is no status line at all — so a review run inside
the hook is minutes of silence with no way to see into it, and its findings can
only surface when some later turn ends. A tracked background task speaks the
moment it is done, into the conversation, with the session idle.

An earlier version ran reviews itself. It detached them, kept them out of the
hook's process group so Claude Code would not wait on the group, wrote pid
files, cancelled reviews superseded within the same repository, guarded against
pid reuse, and carried a progress file with a status-line renderer. Every line
of it existed to reimplement, worse, what background tasks already do. Deleting
it removed four of the five findings the reviewer had just raised, because it
removed the code they were in.

What is given up: a review only happens while there is a session to start one,
and Claude has to actually follow the instruction — a foreground run brings the
silence straight back. The gate can require a review; it can no longer perform
one.

## Failure modes it is built against

**Endless findings.** A reviewer asked to "review this diff" every round keeps
finding new things forever, because there is always another opinion. Rounds
after the first are handed the previous report and asked a narrower question:
which of *these* are still unfixed, and did the fixes break anything new.
Raising fresh unrelated opinions is explicitly disallowed in the prompt.

**Style noise.** The prompt lists what counts as a defect (wrong result, crash,
data loss, race, leak, unhandled error path, security hole, test that cannot
fail) and names what is out of scope. Without that, a review loop turns into a
refactoring loop and the diff never converges.

**Trapping the user.** Every failure path lets the turn end: no `jq`, not a git
repo, no changes, reviewer missing, reviewer not executable, reviewer exits
non-zero. A blocked turn the user cannot escape is a worse bug than an
unreviewed diff. The round budget exists for the same reason and is per user
turn, keyed on `prompt_id`, so a new instruction always gets a fresh budget.

**Re-reviewing what was already reviewed.** A result is filed under an identity
made of the repository, its base revision and the patch text - not the patch
alone. Two checkouts with the same diff, or the same edit made on two branches,
are different states, and the reviewer reads the whole tree rather than the
patch. A second `Stop` on a state that already has a result costs nothing.

**Untracked files.** `git diff HEAD` does not show a brand-new file, which is
exactly where a defect hides. Collection appends `git diff --no-index` output
for every untracked, non-ignored file - and runs from the repository root,
because `git ls-files --others` is scoped to the current directory and a session
started in a subdirectory would otherwise call the tree clean.

**Parallel specialist reviewers.** Built: `fanout-review.sh` runs several at
once, for the measured reason that one misses a real defect about half the
time.

## What is deliberately not here

**A stateful conversation with the reviewer.** One-shot `codex exec` cannot be
asked "why do you think that branch is unreachable". A stateful Codex MCP server
would allow it. It is a real improvement and it is not built, because the flag
and subcommand surface could not be verified without the CLI installed.

**Specialist reviewers.** `hamelsmu/claude-review-loop` gives each copy a
different brief - diff, holistic, framework, UX - and deduplicates. The fan-out
here runs identical copies instead, which buys coverage of the reviewer's
own variance but not of blind spots it has consistently.

**Dirty submodules.** `git add -A` records a submodule's gitlink and not its
uncommitted contents, so a snapshot can be empty for a change that exists.
`run-review.sh` detects this and says so rather than reporting the change clean.

**Anything that reads the transcript.** The hook uses only the payload and git.
Transcript parsing breaks on every format change.

## What the plugin found in itself

Three reviewers were pointed at this repository's own 1401 lines, the work of a
single day. Between them they raised ten distinct items; seven were real.

The first was fatal and unanimous: `hooks/hooks.json` had `Stop` at the document
root, where the loader wants it under a top-level `hooks` key. Installed as a
plugin, the gate would never have been registered - a review tool that does not
review. It survived a day of work because `claude plugin validate` checks the
*marketplace* manifest when a directory holds both, and says nothing about the
plugin. `tests/validate-manifests.sh` now checks each in turn.

The rest: the prompt still told reviewers to answer `CLEAN` after the gate had
stopped treating that as silence, so every clean review would have blocked a
turn; `git commit-tree` fails with "Author identity unknown" on a machine with
no `user.name`, and the snapshot has no business needing the user's identity; a
repository with no commit at all has no `HEAD` to diff or to parent a snapshot
on; a failing `REVIEW_LOOP_SETUP_CMD` was ignored, so the reviewer would report
tests passing in a checkout where they never ran; the fan-out quoted the stdout
of reviewers that had crashed, presenting a half-finished thought as a finding;
and the test-evidence budget gave up before reading evidence that arrived on the
last ask, punishing exactly the user who complied.

Three items were wrong, and all three the same way: the reviewers insisted that
`prompt_id` and `scratchpad_dir` are not in a Stop payload. Both are, and are
documented. Confidently wrong about an API is what this reviewer does, which is
the argument for the author judging findings rather than applying them.

## There is no contract with the reviewer

An earlier version required the reviewer to answer `CLEAN` when it found
nothing, and the gate read that first line to decide whether to let the turn
end. The contract is gone. The reviewer writes whatever it likes; the gate never
reads it; Claude judges the findings and decides what to act on.

What replaced it as the termination rule is the diff itself. Findings acted on
produce a new diff, which earns one more look. Findings judged not to be defects
leave the diff untouched, and an untouched diff ends the turn. Changing nothing
is a valid answer, and the gate is told so by the absence of a change rather
than by a keyword.

This is what made `codex review` usable at all: it takes no custom prompt, so no
contract could have been imposed on it.

## The reviewer disagrees with itself

Three runs of the same reviewer over the same unchanged code. The first found
that `_norm()` uses Python's `str.strip()` while `SCOPE_SQL` uses PostgreSQL's
`trim()`, which removes only spaces, so the two disagree on a tab-padded owner
value. The second declared the opposite - that the logic "consistently applies
normalized, email-first matching in both Python and SQL". The third found the
divergence again, in the same words as the first.

The finding was real; reading the code settles it. So a single run misses a
genuine defect roughly a third of the time. Two consequences: the silence of one
review is not evidence, and the round budget is worth more than it looks - later
rounds re-examine the same code and catch what the first pass dropped.

## Two things that only showed up against the real CLI

**`codex exec` hangs on stdin.** It takes the prompt as an argument, but when
stdin is not a terminal it also waits to append whatever is piped in. A hook's
stdin never sends EOF, so the review blocks until the hook times out — ten
silent minutes on every turn. The log line is `Reading additional input from
stdin...` and it is the only clue. Both adapters close stdin with `</dev/null`.

**A working review is indistinguishable from a hung one.** With
`reasoning summaries: none` and the final message going to `-o`, Codex prints
nothing for the length of the run. The first real review took about a minute at
`model_reasoning_effort=medium`; on this repository, where the reviewer runs the
test suite, it is four or five. Three channels out of a running hook were tried
and none carries progress: stdout and stderr arrive only at exit, the status
line is not repainted while a hook blocks, and `/dev/tty` is not connected -
which rules out terminal titles, and would have been moot anyway, because the
VS Code extension shows no status line at all.

That is what pushed the review out of the hook entirely. Started as a background
task, its stages go to the task's output file, where they can be read while it
runs, and its findings wake the session when it is done.

## Letting the reviewer run the code, without letting it near yours

`codex review` runs the project's tests and linters, which is the difference
between a reviewer that asserts a test would fail and one that watched it fail.
It does that with a writable sandbox, and inside a Stop hook that means a second
agent writing the tree Claude just finished editing. The first time it ran here
it rebuilt a service's `.venv` down to three packages.

Codex has its own answer, `codex exec --worktree`, which runs the session in a
managed git worktree. It does not fit: the worktree is checked out at HEAD, so
the uncommitted work under review simply is not in it. A probe confirmed it -
`git status` clean, `owners.py` absent. It also registers that worktree in your
repository and leaves it there.

So the change has to be put somewhere the reviewer may wreck. `git` will do that
without touching anything of yours:

    GIT_INDEX_FILE=$tmp/index git read-tree HEAD
    GIT_INDEX_FILE=$tmp/index git add -A
    tree=$(GIT_INDEX_FILE=$tmp/index git write-tree)
    sha=$(git commit-tree "$tree" -p HEAD -m 'review-loop snapshot')
    git worktree add --detach "$dir" "$sha"

A temporary index means the real one is never staged into; `commit-tree` writes
a commit that belongs to no branch and appears in no reflog, collected as
garbage in its own time. The reviewer gets a real checkout it can install into
and run, and `codex review --commit <sha>` describes exactly the change, because
the snapshot's parent is HEAD.

Three things fell out of this that were not the point. The snapshot is atomic,
so a review can no longer straddle two states of a tree Claude is still editing.
`--commit` accepts a custom prompt where `--uncommitted` refuses one, so the
built-in review instructions and our own can be combined. And dependency setup
in a fresh worktree costs 1.2 seconds here, not the minutes assumed - uv hands
packages out of a global cache.

## The reviewer reads more than the diff

Under `--sandbox read-only` Codex opens files in the repository to check the
diff against the code around it. That is why the first run's log was full of
sources the diff never touched. It makes the review better — a call site the
diff does not show is still verified — and it means the diff is the subject of
the review, not the whole of its input. A reviewer running somewhere without
the repository checked out would be a weaker reviewer.

## Why Codex is the default reviewer, not Claude

Beyond the obvious — two runs of the same model share their blind spots — there
is a mechanical reason. A hook inherits `CLAUDECODE=1`, and `claude -p` refuses
to start under it:

```
Error: Claude Code cannot be launched inside another Claude Code session.
Nested sessions share runtime resources and will crash all active sessions.
```

`scripts/claude-review.sh` unsets the variable, which is the only way to start
it from inside a session. It has since run that way: five mixed fan-out rounds
launched as background tasks from a live session, each with a `claude -p`
worker beside a Codex one, and the outer session was unaffected. Codex stays
the default because it is a different model; Claude is the second opinion.

## Two models on one change

The fan-out can run different adapters side by side
(`REVIEW_LOOP_FANOUT_REVIEWER=codex-worktree:claude`). Over the five rounds
that reviewed that feature itself, the two models found the same defect twice
— whitespace as a list separator, and the fan-out naming itself as a worker —
and each found defects the other missed: Claude the blank list and the
untrimmed entries, Codex the short-name lookup that let `skip` pass for a
reviewer and the colon in a single path. Agreement between them was a stronger
signal than agreement between copies of one, and neither produced a finding
that was wrong.

## Decisions the code no longer explains

The scripts once carried their history in comments. It lives here now.

**No shortcut for changes that look like documents.** The gate once released a
turn whose changed files all had documentary extensions. Five review rounds
each found the allow-list wrong in a new way: `.txt` is how `requirements.txt`
spells itself; `docs/conf.py` builds the docs; `.mdx` compiles to an
application; a symlink can be called `README.md`; `commands/`, `skills/` and
`AGENTS.md` are behaviour; then Copilot's instruction files. Deciding what a
file means is not something a hook can do in milliseconds. `/review-loop:skip`
covers the case instead, with the judgement in the session.

**State is a tree, not diff text.** A tree can be compared with a snapshot's
tree directly, which is how a review proves it looked at the state it is filed
under. Repository and base revision are part of the identity, because one
results directory serves every project.

**Dirty submodules and embedded repositories are refused.** `git add -A`
records both as gitlinks. A registered submodule is still accounted for: its
content tree goes into the state identity, so a clean one is reviewed like
anything else. A dirty one is refused, because its uncommitted edits are in no
snapshot and the review would come back clean about code it never saw. An
embedded repository nobody declared is refused whether dirty or not: its
contents are outside the identity altogether, so a review or a decline would
outlive edits made inside. Submodule state is read once and used for both the
identity and the decision; two readings left a window. Paths are NUL-delimited
end to end.

**Signals.** A trapped signal replaces bash's default, so handlers exit. Bash
also defers a trap while waiting on a foreground child, so reviewers run
through `run_killable` and handlers kill the process tree. Processes are
killed by pid, never by name: a `pkill -f run-review.sh` in a test once killed
live reviews in another session for hours.

**One marker, one file per invocation.** Start markers, reviewer output and
context files carry the pid. Shared paths let one session truncate or delete
another's, and a marker is trusted only while its owner is alive and older
than the marker.

**The plan check is deliberately plain.** It does not read
`REVIEW_LOOP_CODEX_FLAGS`, because guarding every spelling of `--sandbox` was
longer than the adapter. It has no process handling, because it holds no
worktree and lasts a minute or two. That makes `</dev/null` load-bearing:
nothing else closes stdin for a foreground child.

**History is handed over as background.** `codex review` takes no prompt
beside a scope flag, so the journal goes in through `AGENTS.md`. Worded as an
instruction to verify fixes, it made the reviewer re-run the test suite once
per claim; worded as background, it does not.

**Retention.** Reviewer logs and patches were two thirds of the results
directory, so they go after a day; findings and markers after a week; the
journal and the declines never, because they are decisions.
