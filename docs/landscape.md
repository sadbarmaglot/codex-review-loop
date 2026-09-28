# What else exists

Surveyed 2026-09-26. The filter throughout: **subscription-only** — a project
qualifies only if the reviewer runs as a logged-in CLI, not behind a provider
API key.

## Passes the filter

**[hamelsmu/claude-review-loop](https://github.com/hamelsmu/claude-review-loop)**
— the closest thing to this plugin. Stop hook blocks the exit, writes a runner
script, and instructs Claude to run it; Codex writes findings to
`reviews/review-<id>.md` and Claude reads them back. Spawns up to four parallel
Codex sub-agents depending on project type (diff, holistic, Next.js, UX) and
deduplicates their findings. Single round: task → review → fixes → exit. Install
via `claude plugin marketplace add hamelsmu/claude-review-loop`.

Worth stealing: the specialist split and the dedup step. Not adopted wholesale
because one round is not a loop, and because routing findings through a file
that Claude is *asked* to read is weaker than making them the continuation
reason.

**[sdsrss/loop_eng](https://github.com/sdsrss/loop_eng)** — `/autoloop` drives
builder/checker cycles, `/polish` runs adversarial review. Stop-hook enforced
with six stop rules, explicitly hardened against self-grading leniency,
verifier theater and infinite fix loops. The most thought-through cycle design
of the bunch; also the most opinionated, and it brings a whole methodology.

**Codex-CLI-as-MCP wrappers** — several, all subscription-safe because they
shell into `codex exec`:
[kky42/codex-as-mcp](https://github.com/kky42/codex-as-mcp),
[tuannvm/codex-mcp-server](https://github.com/tuannvm/codex-mcp-server),
[Intellegam/codex-mcp](https://github.com/Intellegam/codex-mcp) (stateful, keeps
a Codex session across calls — the one to look at for two-way review dialogue),
[ogmios2/claude-code-codex-mcp](https://github.com/ogmios2/claude-code-codex-mcp).

**[lukaso/review-loop](https://github.com/lukaso/review-loop)** — a Stop hook
that reviews nothing. It detects whether the tree changed since the last ask
(hashed `git status --porcelain`) and asks *the user* whether the work has been
reviewed. Useful as a reference for turn-scoped change detection, not as a
reviewer.

## Fails the filter

**[PAL MCP Server](https://github.com/BeehiveInnovations/zen-mcp-server)**
(formerly Zen MCP, ~11.8k stars, active) — the heavyweight of cross-model
collaboration: `codereview`, `precommit`, `consensus`, `debug`, `thinkdeep`,
with conversation threading that carries context between models. Providers are
Gemini, OpenAI, Azure, X.AI, OpenRouter, DIAL, Ollama — all key-billed. Its
`clink` tool does bridge to external CLIs, so a subscription-only setup is
possible, but then almost nothing of the project is left in play.

**[OpenRouter's automatic code review cookbook](https://openrouter.ai/docs/cookbook/coding-agents/automatic-code-review)**
— the same hook pattern, reviewed through OpenRouter. Per-token by definition.

## Background

- [Auto-Reviewing Claude's Code](https://www.oreilly.com/radar/auto-reviewing-claudes-code/) — Nick Tune, the pattern in prose
- [Three levels of Claude × Codex review automation](https://smartscope.blog/en/blog/claude-code-codex-review-loop-automation-2026/) — SKILL.md, plugin, pipeline
- Codex CLI's own Stop hook is fire-and-forget and cannot feed structured output back into the model's context, so the gate direction only works with Claude Code as the author.
