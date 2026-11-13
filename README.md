# review-loop

A Claude Code plugin that will not let a turn end on a change no second agent
has looked at.

The gate itself reviews nothing. When a turn ends on an unreviewed change it
refuses, and tells Claude to start the review as a **background task**. Claude
Code tracks that task and wakes the session with the findings when it finishes —
in full, in the conversation, while nothing is held open. Claude then judges
each finding: fixes what is a real defect, says why the rest is not.

The reviewer is a **CLI subprocess**, never an API call. Codex runs under the
ChatGPT login and `claude -p` under the Claude login, so reviews are charged to
a subscription. Every adapter strips `OPENAI_API_KEY` / `ANTHROPIC_API_KEY`
before exec, because a key left in the environment silently moves the billing to
the API.

## What it costs you

Worth knowing before you install it rather than after:

- **A review per stop.** Every turn that ends on a changed tree spends one
  review, and every fix earns another. With the default fan-out that is three
  Codex runs at a time, against your subscription's quota.
- **Minutes, not seconds.** The default adapter runs your test suite in a
  throwaway checkout, so a review takes about as long as the suite does.
- **The reviewer reads outside the repository.** It is a coding agent with a
  shell in a checkout of your code, not a diff viewer. With
  `REVIEW_LOOP_SHARE_TRANSCRIPT` it is handed part of the session conversation
  as well — off by default, and a judgement worth making deliberately.

## Install

You need `git`, `bash`, `jq`, and a logged-in reviewer CLI: `codex login` for
the default adapter, or a logged-in `claude` for the fallback one.

```bash
claude plugin marketplace add sadbarmaglot/codex-review-loop
claude plugin install review-loop@sadbarmaglot
```

Then check the surroundings:

```bash
~/.claude/plugins/*/review-loop/scripts/doctor.sh
```

It reports whether `jq` is present (the gate is inert without it), whether
`codex` is on `PATH`, and what `codex login status` says.

While you are changing the plugin itself, don't install it: `claude --plugin-dir
<path>` loads it in place. Installing takes a copy into a version-keyed cache,
and `claude plugin update` compares versions — edits to the source never arrive
until the version in `plugin.json` changes.

## How a turn goes

1. Claude finishes and tries to stop.
2. The `Stop` hook writes the working tree to a git tree object — tracked
   changes and every untracked, non-ignored file — and identifies the state by
   repository, base revision and that tree. Not by the text of a diff: a tree
   can be compared with a snapshot's tree directly, and that is what lets the
   review prove it looked at the state its result is filed under.
3. Optionally (`REVIEW_LOOP_REQUIRE_TESTS`) it first asks Claude to run the
   tests and leave the outcome in a file. Red tests block the turn before a
   review is even asked for.
4. If that state has no review and none is running, the hook refuses the stop
   and names the command to run in the background. Claude starts it; the turn
   then ends. The review leaves a marker as it begins, so a state already being
   looked at is not asked about again when the next message arrives.
5. Minutes later the task finishes and Claude Code wakes the session with the
   findings, which Claude retells before acting on them. Claude then acts, or
   argues, and tells the next round which it did:
   `run-review.sh --after "fixed 1 and 3; declined 2 because ..."`.
   The reviewer has no memory of its own, so without that it re-raises what was
   already declined and cannot tell whether a fix it asked for was made.
6. Acting changes the diff, which is a new state, which earns its own review.
   Arguing changes nothing, and an unchanged reviewed state ends the turn.

The hook holds nothing open and runs nothing itself. After
`REVIEW_LOOP_MAX_ROUNDS` unanswered asks it releases the turn with a notice
rather than trapping you.

## When the gate stays quiet

Measured over one four-day session of mostly document work: the gate refused
148 times and ten reviews were started, once refusing 33 turns in a row. It
identifies a state by comparing the working tree with HEAD, which cannot tell a
turn that changed nothing from a turn that changed everything.

**A decline is remembered.**

```
/review-loop:skip "belongs to another piece of work"
```

The gate stops asking about that exact state until the tree changes. Use it for
what a hook cannot know: a turn that only read, a day spent on documents, work
that was already uncommitted when the session started, someone else's change.
The reason goes to `decisions.log`, and the marker outlives the usual sweep, as
the journal does.

This is deliberately the only way the gate goes quiet on a change that exists.
There was a second: a shortcut that released any turn whose changed files all
looked documentary. Five review rounds found its list wrong in a new way each
time — `.txt`, whole directories, `.mdx`, file modes, this plugin's own
`commands/` and `skills/`, then Copilot's instruction files — and the next one
was always waiting. Deciding what a file means is not something a hook can do
in milliseconds, and the session already knows.

Declined is not reviewed, and the two cannot be confused: a different file, a
different word in the trace, no completion marker, and a real review of the
same state still files its own result. A decline is refused where a review
would be — with a dirty submodule or an embedded repository below, whose
contents are outside the state identity, so a marker written now would answer
for code written inside it later.

## Checking a plan before writing it

The gate guards the diff. Everything upstream of it — the sketch of what to
change in code that already exists — is unguarded, and a plan that rebuilds
something the repository has, or forgets a caller, costs a full implementation
before anyone notices.

```
/review-loop:plan                       # the plan under discussion
/review-loop:plan docs/some-plan.md     # or one written down already
```

It hands the plan and the repository to `codex exec --sandbox read-only` and
prints the remarks: where the plan is wrong about the code that is there, not
whether it is a good plan. Nothing gates a turn, nothing fires on its own, and
a plan check does not satisfy the `Stop` hook — the code written afterwards
still earns its own review.

Reckon on a minute or two, not seconds. The reviewer reads a good deal of the
repository, and the prompt has to forbid it running the tests: `--sandbox
read-only` stops it writing, not executing, and the first run of this command
spent four minutes in the suite before being told not to.

## Configuration

Environment variables, all optional:

| Variable | Default | Meaning |
| --- | --- | --- |
| `REVIEW_LOOP_DISABLE` | unset | Any value turns the gate off |
| `REVIEW_LOOP_MAX_ROUNDS` | `3` | Asks per user turn before the gate gives up |
| `REVIEW_LOOP_REVIEWER` | `scripts/codex-worktree-review.sh` | Any executable following the reviewer contract |
| `REVIEW_LOOP_REQUIRE_TESTS` | unset | Any value makes Claude run the tests and leave evidence before a review is asked for |
| `REVIEW_LOOP_MAX_TEST_ROUNDS` | `3` | How many times the gate asks for that evidence |
| `REVIEW_LOOP_LAUNCH_GRACE` | `120` | Seconds a request counts as a review starting before the gate asks again |
| `REVIEW_LOOP_FANOUT` | `3` | Reviewers run at once by `fanout-review.sh` |
| `REVIEW_LOOP_FANOUT_REVIEWER` | `scripts/codex-worktree-review.sh` | What the fan-out runs. One adapter means `REVIEW_LOOP_FANOUT` copies of it; several, separated by colons as in `PATH`, means one worker each and the list sets the count. A value that is itself an executable is always one reviewer, so a single path may hold a colon; inside a list it may not |
| `REVIEW_LOOP_SETUP_CMD` | unset | Worktree adapter only: how to install dependencies in the throwaway checkout |
| `REVIEW_LOOP_CODEX_SCOPE` | `--uncommitted` | Built-in adapter only: `--base <branch>` or `--commit <sha>` instead |
| `REVIEW_LOOP_CODEX_FLAGS` | `-c model_reasoning_effort="medium"` | Flags passed to the Codex CLI. Without it a review inherits the effort from `~/.codex/config.toml`, which is chosen for writing code, not reviewing it — `high` there turned two-minute reviews into eight-minute ones. Not read by `plan-review.sh`: that one reviews in your own checkout, so its sandbox is part of the command rather than a default to override |
| `REVIEW_LOOP_SHARE_TRANSCRIPT` | unset | Any value adds the session's conversation — the talk, never the tool output — to what the reviewer reads |
| `REVIEW_LOOP_MAX_TRANSCRIPT_BYTES` | `60000` | How much of that conversation, counted from the most recent end |
| `REVIEW_LOOP_CODEX_MODEL` | unset | `-m` for the Codex CLI |
| `REVIEW_LOOP_CLAUDE_MODEL` | `sonnet` | Model for the `claude -p` adapter |
| `REVIEW_LOOP_KEEP_API_KEY` | unset | Opt back into API billing |
| `REVIEW_LOOP_MAX_DIFF_BYTES` | `100000` | `codex-review.sh` only: diff truncated past this, to stay under Linux's ~128 KiB per-argument execve limit. `claude-review.sh` feeds its prompt on stdin and is not bound by it |
| `REVIEW_LOOP_STATE_DIR` | `$XDG_STATE_HOME`, else `~/.cache` | Where state, results, the journal and `decisions.log` live, under `review-loop/` |
| `REVIEW_LOOP_DOUBT_AFTER` | `5` | Reviews of one uncommitted change before the report arrives with a question for Claude to settle first — are the findings still worth the rounds, or would a different shape stop them coming. Counted per base revision, so a commit starts it over, and so work discarded and replaced without a commit inherits the count: the question then comes early, which for a prompt to stop and think is the harmless direction |
| `REVIEW_LOOP_MAX_JOURNAL_BYTES` | `40000` | The journal is trimmed to its most recent rounds past this |
| `REVIEW_LOOP_KEEP_LOGS_DAYS` | `1` | How long reviewer logs and patches of your source are kept |
| `REVIEW_LOOP_KEEP_DAYS` | `7` | How long findings and completion markers are kept. The journal is never swept |
| `REVIEW_LOOP_MAX_PREV_BYTES` | `20000` | `codex-review.sh` only: how much history shares the argument with the diff, counted from the end. The journal is placed after the conversation, so the cut takes old talk before decisions. `claude-review.sh` reads its prompt on stdin and gets the history whole |

`REVIEW_LOOP_SETUP_CMD` is per project — a value that fails aborts the review,
so a global one would break every other repository. Put it in that repository's
own `.claude/settings.json`.

That is as far as it goes, though, and the limit has teeth: Claude Code applies
a project's `env` to the whole session, not to a directory. A session started in
one repository and reviewing a second uses the first one's setup command, which
fails in a checkout that has no such directory, and the review dies before the
reviewer starts. Until the command is read from the repository under review, a
session that crosses repositories has to do without it.

So is `REVIEW_LOOP_SHARE_TRANSCRIPT`, for a different reason. The reviewer goes
looking for the session transcript on its own — it was caught reading one
unprompted — and it is the best context available: why a thing was done, what
was tried and rejected, what was actually asked for. It is also the
conversation leaving the machine, and whether that is acceptable is a judgement
about the project, not about the tool.

### The reviewers

| Adapter | Runs the code? | Touches your tree? | Notes |
| --- | --- | --- | --- |
| `codex-worktree-review.sh` (default) | **yes** | no | Snapshots the change into a dangling commit, checks it out in a throwaway worktree, and turns `codex review --commit` loose in there. Tests and linters run, in a tree that is deleted afterwards |
| `codex-review.sh` | no | no | Prompt-driven `codex exec --sandbox read-only`. The only one that can review an arbitrary patch file, and the only one with a follow-up mode |
| `codex-builtin-review.sh` | yes | **yes** | `codex review --uncommitted` in place. Never from the gate: it writes where Claude is working |
| `claude-review.sh` | no | no | `claude -p`, with Edit, Write and Bash denied — it runs in the repository itself, so the no-touch promise has to be enforced rather than assumed. The fallback when Codex is not installed |
| `fanout-review.sh` | depends | depends | Runs `REVIEW_LOOP_FANOUT` copies of another adapter at once and hands back all their reports |

Fan-out exists because one reviewer is unreliable, not because more opinions are
nicer: over four runs against one unchanged diff this reviewer found a real
defect twice and called the same code sound twice. Three passes miss together
about an eighth of the time instead of half. They overlap, so the wall clock is
roughly one review, and each gets its own worktree — two test suites in one
checkout would collide. Only the first worker installs dependencies and runs
the tests: the suite is deterministic, and running it N times buys the same
answer at N times the cost of the slowest step. The others are told plainly to
leave the tests alone — merely withholding the dependencies is not enough, as a
reviewer that tries anyway reports the resulting failures as findings.

Copies of one reviewer cure its inconsistency and nothing else: they share its
blind spots. Naming two different adapters puts two models on the same change,

```
REVIEW_LOOP_REVIEWER=fanout
REVIEW_LOOP_FANOUT_REVIEWER=codex-worktree:claude
```

The plugin's own adapters go by short names — `codex-worktree`, `codex`,
`codex-builtin`, `claude`, `fanout` — so settings do not carry the install
path, which holds the version and stops existing at every update. Anything
else is taken as a path to your own reviewer.

and each report is headed with who wrote it, since two models agreeing is
evidence that two runs of one are not. Put the worktree adapter first — only
the first worker gets the setup command, and it is the only kind that can use
it. Worth knowing what the second opinion is: `claude -p` reviewing code Claude
wrote is a fresh session with none of the author's context, but it is the same
family of model, so it is a weaker check on the author than Codex is and a
useful check on Codex.

### Reviewer contract

Any executable can be the reviewer:

- `argv[1]` — path to the diff under review
- `argv[2]` — path to a previous report, empty on the first round
- stdout — the report, in whatever shape it likes; empty means nothing to say
- exit 0 — review completed; non-zero means the reviewer itself failed

## Status

Five suites, all offline against stubbed reviewers, plus a manifest check.
Each prints its own count:

```bash
bash tests/test-gate.sh              # asking, budgets, test stage, every bail-out
bash tests/test-run-review.sh        # results, hashes, snapshots, cancellation, failures
bash tests/test-fanout.sh            # crashes, silence, partial output, stages
bash tests/test-worktree-adapter.sh  # HEAD, index, reflog, branches, cleanup, paths
bash tests/test-plan-review.sh       # the plan reaches the reviewer, sandbox, billing, cancellation
bash tests/validate-manifests.sh     # plugin, marketplace and hooks.json shape
```

The totals used to be written out here and were wrong three times in one day,
always because the number was typed before the last assertion was added. A
count that has to be maintained by hand is a claim about the suite that the
suite does not check.

Every one of them was watched failing against the code before the fix. A test
written after the fact and never seen red is a test of nothing: two in this
suite passed for weeks against the defect they were named for.

Run `validate-manifests.sh` rather than `claude plugin validate .`: with both
manifests in one directory the latter checks the marketplace and says nothing
about the plugin, which is how a `hooks.json` that would never have registered
the gate went unnoticed for a day.

Exercised against codex-cli 0.157.1, logged in through ChatGPT. What that showed
beyond that it works:

- **The reviewer disagrees with itself.** Four runs over the same code; two
  found a real `str.strip()` / SQL `trim()` divergence, two declared the same
  code consistent. Silence from one review is not evidence.
- **Running the tests does not close that gap.** The worktree adapter ran the
  suite and the linter, both green, and still missed the divergence — no passing
  test covers the input that triggers it.
- **Review time is bounded below by the project's test suite**, because the
  reviewer runs it. On this repository that is minutes.

## Reading

- [`docs/design.md`](docs/design.md) — why it is shaped this way, and the
  failure modes it is built against
- [`docs/landscape.md`](docs/landscape.md) — the other projects in this space and
  which of them survive the subscription-only constraint
