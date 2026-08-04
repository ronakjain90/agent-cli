# AGENTS.md

# agent-cli

## 1. Purpose & Main Features

`agent-cli` is a **terminal-based coding agent** built in Ruby. It presents an interactive TUI (Charm Ruby / Bubble Tea front-end) where you chat with a model and it can read, write, and edit files as well as run shell commands on your behalf.

Key features:

- **Pluggable LLM providers** with a native tool-use loop:
  - `anthropic` — Claude via Anthropic Messages API (native tool use)
  - `openai` / `openrouter` / `google` / `groq` / `ollama` — OpenAI-compatible Chat Completions with function calling
  - `opencode` — talks to a local `opencode serve` HTTP server (which owns its own editing tools)
- **Multi-agent orchestration**: the top-level agent runs as a *manager* with normal file/shell tools **plus** a `delegate` tool that spawns fresh worker agents for focused subtasks. Independent subtasks delegated in one turn run in parallel (capped at `Agents::MAX_PARALLEL = 6`). Workers recurse up to `Agents::MAX_DEPTH = 2`.
- **Provider auto-config**: remembers your last provider/model in `~/.config/agent-cli/preferences.json`, saves named "model sets" switchable via `/models`, and lets workers run on a different (e.g. cheaper) model.
- **Shell safety**: destructive commands prompt for permission (`y`/`a`/`p`/`n`); read-only `git` commands are auto-allowed. Persist command prefixes to skip future prompts.
  - `--yolo` skips all permission prompts.
- `/init` can analyze the repo and write an `AGENTS.md`.

## 2. Architecture / Components

```
agent-cli.rb            # entrypoint: resolves provider, boots Bubbletea TUI
lib/
  agent_cli.rb          # root require file
  agent_cli/
    agent_app.rb        # TUI model (init/update/view) — Elm architecture
    agents.rb           # multi-agent system prompts + tool set + depth/parallel caps
                        # + the `Delegation` module (delegate dispatch, worker spawn, parallel exec)
    tools.rb            # built-in tools (read/write/edit/list_files/run_command) + permission gating
    commands.rb         # slash commands /providers /worker /models /init /help
    preferences.rb     # persisted provider/model/worker/model sets/allowlist
    settings.rb         # API keys (~/.agent-cli/settings.json)
    usage.rb            # token-usage normalization + footer meter
    diff.rb             # minimal unified-diff generator for write/edit results
    input_drain.rb      # patches Bubbletea input to drain full buffer + bracketed paste
    prompt_history.rb   # cross-session up/down prompt recall
    pub_sub.rb          # PubSub broker — thread-safe pub/sub for manager/worker messaging + UI events
    model.rb            # selectable Model (id/label/other)
    constants.rb        # MAX_TOKENS, MAX_STEPS loop cap
    sandbox.rb          # filesystem sandbox for worker agents
    errors.rb              # Errors (< StandardError) for tool failures

  provider.rb           # loads all Providers
  provider/
    base.rb             # Provider metadata + factory + worker attachment
    anthropic.rb        # AnthropicProvider — native Messages API loop
    openai.rb           # OpenaiProvider — OpenAI-compatible base (shared by openrouter/google/groq/ollama/gemini)
    openrouter.rb       # OpenrouterProvider < OpenaiProvider
    google.rb           # GoogleProvider   < OpenaiProvider  (also aliased as `gemini`)
    gemini.rb           # GeminiProvider   < OpenaiProvider
    groq.rb             # GroqProvider     < OpenaiProvider
    ollama.rb           # OllamaProvider   < OpenaiProvider
    opencode.rb         # OpencodeProvider — talks to local `opencode serve` HTTP server
```

**Flow:** TUI (`AgentApp`) runs the provider's `run_turn` on a worker thread; the provider drives an `agent_run` loop (shared loop logic lives in the `Delegation` module in `lib/agent_cli/agents.rb`, which `AnthropicProvider` and `OpenaiProvider` mix in) that POSTs to the provider API, emits events (assistant text, tool calls, usage, diffs) back through a `Queue`, and the TUI's `Poll`/`drain_events` renders them. Tool calls go through `Tools.call`; `delegate` calls go through `Delegation#dispatch_tool` → `Delegation#run_worker`, which constructs a fresh worker model + tool set (and reports back). `PubSub` is the thread-safe pub/sub broker available for manager↔worker messaging and UI event streaming.

## 3. How to Run / Test

```bash
gem install bubbletea lipgloss     # deps
ruby agent-cli.rb                  # interactive TUI
```

Run headless (no TUI) via env to let a model drive:
```bash
ruby agent-cli.rb <<< "your prompt"
```
or set at boot time to skip the provider picker:
```bash
export ANTHROPIC_API_KEY=...
AGENT_PROVIDER=anthropic AGENT_MODEL=claude-opus-4-8 ruby agent-cli.rb
```

**Providers & required keys:**

| provider   | default model           | env var            |
|------------|-------------------------|--------------------|
| anthropic  | claude-opus-4-8         | ANTHROPIC_API_KEY  |
| openai     | gpt-4o                  | OPENAI_API_KEY     |
| openrouter | openai/gpt-oss-20b:free | OPENROUTER_API_KEY |
| google     | gemini-3.6-flash        | GEMINI_API_KEY     |
| groq       | llama-3.3-70b-versa.    | GROQ_API_KEY       |
| ollama     | llama3.1                | none (local server)|
| opencode   | (set via /providers)    | none (local server)|

For local servers: `ollama serve` / `opencode serve --port 4096`. API keys can also be entered in the TUI (saved to `~/.agent-cli/settings.json`).

Worker model override:
```bash
AGENT_WORKER_PROVIDER=groq AGENT_WORKER_MODEL=llama-3.3-70b-versatile ruby agent-cli.rb
```

TUI keys: `ctrl+c` quit · `↑/↓` navigate · `enter` select · `esc` back · `/` slash commands. During a turn press `esc` to interrupt; diffs view with `[`/`]`.

Ruby version: `ruby-4.0.0` (`.ruby-version`).

## 4. Conventions / Patterns

- **Threading**: the provider loop runs on a dedicated `Thread`; TUI stays responsive via a polling `Poll` message and a `Queue` event channel. Thread-locals (`active_system`/`active_tools`) isolate per-step system prompt & tools across parallel workers.
- **Event-driven**: `update`/`view` Elm-style messages; only the TUI thread mutates UI state. Events are pushed from the worker thread and drained on the next `Poll` tick.
- **`Tools.call`** returns a 2- or 3-tuple `[summary, result, diff?]`; diffs are rendered in the TUI's right panel.
- **Errors are model-actionable**: tool argument errors raise `ArgumentError` with guidance so a model can retry; `edit_file` reports exact counts when `old_string` is missing/ambiguous and requires verbatim matches.
- **Rescue discipline**: rescue against `StandardError` explicitly (`rescue StandardError => e`) — not a bare `rescue => e`, which would also swallow `SystemExit`/`Interrupt`/`SignalException`. `Errors` (in `lib/agent_cli/errors.rb`) inherits from `StandardError` so tool failures can be caught distinctly from programming bugs.
- **Frozen literals**: every file is annotated `# frozen_string_literal: true`; strings are treated as frozen by default, so avoid in-place mutation of shared string constants.
- **Allowlist safety**: shell commands are auto-allowed only if they match a built-in or persisted prefix and contain no shell metacharacters (`; & | > < $(/newline)`); subcommand tools (`git …`, `npm …`, `docker …`) persist a 2-token prefix.
- **File layout**: keep requires relative within `lib/`; `Provider` (the top-level class in `lib/provider/base.rb`) is a metadata/factory class — its subclasses (`Provider::Anthropic`, `Provider::Openai`, `Provider::Openrouter`, `Provider::Google`, `Provider::Gemini`, `Provider::Groq`, `Provider::Ollama`, `Provider::Opencode`) register ids/models and `build(model_id)` a runnable provider. The runnable provider instances are `AnthropicProvider`, `OpenaiProvider`, `OpenrouterProvider`, `GoogleProvider`, `GeminiProvider`, `GroqProvider`, `OllamaProvider` (all on the OpenAI-compatible shape; `OpenaiProvider` is the shared base they inherit from), and `OpencodeProvider` (talks to `opencode serve`). The `Delegation` module in `lib/agent_cli/agents.rb` is mixed into `AnthropicProvider` and `OpenaiProvider` to provide the shared `agent_run` loop and `delegate` tool dispatch; `OpencodeProvider` does not include `Delegation` and bypasses `Tools.call` (it reads edits from the server via `/session/:id/diff`). Shared tool-loop logic therefore does not live in a separate `tool_use_loop.rb` file — it lives in `lib/agent_cli/agents.rb` via the `Delegation` module.

## 5. Agent-Specific Guidance

This repo *is itself* a coding agent — treat changes through the lens of how an agent uses the tool surface:

- When editing existing files, use `edit_file` with an **exact verbatim `old_string`**; never rewrite files wholesale with `write_file` unless creating them. Match whitespace/indentation exactly — anchors must be unique (or use `replace_all`).
- When running shell commands you author while developing: prefer git read-only subcommands (`git status`, `git diff`, …) which need no prompt; for anything else use `--yolo` or be ready to approve.
- The `delegate` tool (and the multi-agent caps `MAX_DEPTH = 2`, `MAX_PARALLEL = 6`) are exposed by the `Delegation` module in `lib/agent_cli/agents.rb`, which `AnthropicProvider` and `OpenaiProvider` mix in; `OpencodeProvider` does not — do not raise unbounded fan-out without lowering `MAX_PARALLEL`.
- The `opencode` provider **owns its own edit tools** — it does *not* use `Tools.call`; it reads diffs from the server via `/session/:id/diff` and reports them as `:diff` events for the panel.
- Provider `build(model_id)` may raise `Settings::MissingApiKeyError` — the TUI routes this to the in-TUI key entry; preserve that contract.
- `MAX_STEPS = 25` is the safety cap on the tool-loop per turn; long agentic tasks should rely on the manager/worker split, not a single turn.
- `Usage` meters assume 4 chars/token for rough context-fill estimation when the provider doesn't report usage (important for Ollama/opencode).
- `.ruby-lsp/` and `.idea/` are git-ignored dev artifacts; don't touch `.claude/settings.local.json` (local sandbox perms, not committed).
