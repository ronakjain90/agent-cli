<p align="center">
  <img src="images/mascot.svg" alt="Borgator mascot: a cyborg alligator head in profile" width="460">
</p>

# Borgator

A terminal-based coding agent written in Ruby. Borgator gives you an interactive
TUI — built on [Charm Ruby](https://github.com/charmbracelet) (Bubble Tea + Lip
Gloss) — where you chat with a model that can read, write, and edit files and run
shell commands on your behalf, confined to your project directory.

```
┌ you ──────────────────────────────┐   ┌ diff  [ / ] ──────────────┐
│ refactor the input drain module   │   │ @@ -12,4 +12,6 @@          │
│                                   │   │ + def flush_buffer         │
│ Borgator · claude-opus-5 · anth   │   │ +   drain until empty      │
└───────────────────────────────────┘   └───────────────────────────┘
```

- **Sandboxed by default.** Every shell command runs inside an OS sandbox and
  file writes are confined to the project root. There is no switch to disable it.
- **Multi-agent.** The top-level *manager* agent delegates focused subtasks to
  fresh *worker* agents, running independent subtasks in parallel.
- **Multi-provider.** Anthropic, OpenAI, OpenRouter, Google Gemini, Groq, Ollama,
  and OpenCode behind a single native tool-use loop.
- **Stateful.** Last provider/model, named model sets, and the per-command
  permission allowlist persist across sessions.

## Install

Requires Ruby (see `.ruby-version` → `ruby-4.0.0`).

```bash
gem build borgator.gemspec     # → borgator-<version>.gem
gem install ./borgator-*.gem   # installs the `borgator` command + deps
```

Run it from inside any project — the agent operates on the current working
directory, so no per-project setup is required:

```bash
cd ~/code/some-project
borgator
```

To run from a checkout without installing:

```bash
gem install bubbletea lipgloss
ruby borgator.rb
```

Type `/providers` to connect and pick a model; your choice is remembered. To skip
the picker at boot, set the provider and model through the environment:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
AGENT_PROVIDER=anthropic AGENT_MODEL=claude-opus-4-8 borgator

# Workers on a cheaper model, or a different provider entirely
AGENT_WORKER_MODEL=claude-haiku-4-5 borgator
AGENT_WORKER_PROVIDER=groq AGENT_WORKER_MODEL=llama-3.3-70b-versatile borgator

# Local servers
ollama serve && ollama pull llama3.1
AGENT_PROVIDER=ollama AGENT_MODEL=llama3.1 borgator

opencode serve --port 4096
AGENT_PROVIDER=opencode AGENT_MODEL=anthropic/claude-opus-4-8 borgator
```

## Providers

All providers drive a native tool-use loop. Anthropic uses the Messages API;
OpenAI, OpenRouter, Google, Groq, and Ollama use OpenAI-compatible Chat
Completions with function calling; OpenCode talks to a local server that owns its
own editing tools.

| Provider   | Default model             | API key env var      | Notes |
|------------|---------------------------|----------------------|-------|
| anthropic  | `claude-opus-4-8`         | `ANTHROPIC_API_KEY`  | Native Messages API |
| openai     | `gpt-4o`                  | `OPENAI_API_KEY`     | |
| openrouter | `openai/gpt-oss-20b:free` | `OPENROUTER_API_KEY` | Free and paid gateway |
| google     | `gemini-3.6-flash`        | `GEMINI_API_KEY`     | AI Studio, OpenAI-compatible |
| groq       | `llama-3.3-70b-versatile` | `GROQ_API_KEY`       | LPU inference |
| ollama     | `llama3.1`                | — (local)            | `ollama serve` |
| opencode   | set via `/providers`      | — (local)            | `opencode serve --port 4096` |

API keys can be supplied as environment variables or entered in the TUI, in which
case they are saved to `~/.borgator/settings.json`.

## Sandboxing

Confinement is mandatory: it cannot be disabled, and the writable root can never
be widened beyond the directory you launched from. Two layers cooperate in
`lib/borgator/sandbox.rb`:

| Layer | Covers | Mechanism |
|-------|--------|-----------|
| In-process write guard | `write_file`, `edit_file` | Refuses any path resolving outside the project root, resolving symlinks so an in-root symlink cannot redirect a write out. Cross-platform, always on. |
| OS sandbox | `run_command` | macOS → `sandbox-exec` (Seatbelt) with a deny-file-write profile. Linux → `bubblewrap` with the project bound read-write and system dirs read-only. |

The sandbox fails closed: if the OS backend is unavailable, shell commands are
refused rather than run unconfined. On Linux, install `bubblewrap` (`apt-get
install bubblewrap`, `dnf install bubblewrap`, or `pacman -S bubblewrap`) to
enable shell execution.

Reads and network access stay open so compilers, test runners, and package
managers keep working; only writes outside the project are blocked.

Beyond the OS sandbox, `run_command` gates execution with a permission prompt.
Read-only `git` commands (`git status`, `git log`, `git diff`, …) are
auto-allowed; anything else prompts for `y` (once), `a` (session), `p`
(permanently), or `n` (deny). Permanent approvals persist to an allowlist so
future runs skip the prompt — this applies only to commands free of shell
metacharacters (`; & | > < $( )` and newlines), and subcommand tools such as
`git`, `npm`, and `docker` persist a two-token prefix. Launching with `--yolo`
skips all prompts; the OS sandbox still applies.

## Multi-agent orchestration

The top-level agent runs as a manager with the normal file and shell tools plus a
`delegate` tool that spawns fresh worker agents for focused, self-contained
subtasks (`lib/borgator/agents.rb`). Multiple `delegate` calls in one turn run
concurrently, capped at `MAX_PARALLEL = 6`. A worker may itself delegate, forming
a manager → worker tree up to `MAX_DEPTH = 2`. Workers can be given a
smaller, faster model or a different provider via `/worker`.

Worker activity is shown indented in the chat log. Type `/agents` for details.

## Tools

| Tool | Purpose |
|------|---------|
| `read_file`   | Read a file, optionally a line range |
| `write_file`  | Create or overwrite a file, write-guarded to the project root |
| `edit_file`   | Exact verbatim string replacement, with clear errors on missing or ambiguous matches |
| `list_files`  | List directory contents |
| `run_command` | Run a shell command inside the OS sandbox |
| `delegate`    | Manager only — hand a subtask to a worker agent |

Results from `write_file` and `edit_file` render as unified diffs in the
right-hand panel.

## Slash commands

| Command      | Action |
|--------------|--------|
| `/providers` | Switch provider and model |
| `/worker`    | Set the provider and model workers use |
| `/models`    | Manage saved model sets |
| `/init`      | Read or create `AGENTS.md`, referencing `CLAUDE.md` if present |
| `/help`      | List available commands |

Type `/` in chat to see and complete the available commands.

## Keys

| Context      | Keys |
|--------------|------|
| Chat         | `enter` send · `esc` interrupt a running turn · `/` slash commands · `ctrl+c` quit |
| Diff panel   | `[` / `]` cycle through diffs |
| Pickers      | `↑`/`↓` move · `enter` select · `esc` back |
| Permission   | `y`/`enter` allow once · `a` session · `p` permanently · `n`/`esc` deny |

The composer supports word-wise navigation (`opt/alt+←`/`→`, `ctrl+←`/`→`) and
cross-session prompt history (`↑`/`↓`).

## Configuration and state

| Path | Contents |
|------|----------|
| `~/.config/borgator/preferences.json` | Last provider/model, worker override, named model sets, command allowlist |
| `~/.borgator/settings.json` | API keys entered via the TUI |
| `AGENTS.md` (in the repo) | Project context loaded into new sessions; generated by `/init` |

## Architecture

```
borgator.rb             # entrypoint: resolves provider, boots the Bubbletea TUI
lib/borgator/
  agent_app.rb          # TUI model (init/update/view) — Elm architecture
  agents.rb             # multi-agent system prompts, tool set, depth/parallel caps
  tools.rb              # built-in tools + permission gating
  sandbox.rb            # write guard + macOS/Linux OS sandbox wrappers
  commands.rb           # slash commands
  preferences.rb        # persisted provider/model/worker/model sets/allowlist
  settings.rb           # API-key storage
  usage.rb              # token-usage normalization + context meter
  diff.rb               # unified-diff generator for write/edit results
  input_drain.rb        # full-buffer input drain + bracketed paste
  prompt_history.rb     # cross-session prompt recall
  pub_sub.rb            # thread-safe pub/sub broker
lib/provider/           # Provider::Base + anthropic / openai / openrouter /
                        # google / groq / ollama / opencode
```

The TUI runs the provider's turn on a worker thread. The provider drives a
tool-use loop — capped at `MAX_STEPS = 25` iterations per turn, and a turn that
hits the cap says so rather than going quiet — that calls the model, dispatches
tool calls through `Tools.call` (or `delegate` → `run_worker`), and emits events
for assistant text, tool results, usage, and diffs back through a `Queue`. The
TUI drains those events on each poll tick and renders them. Only the TUI thread
mutates UI state.

## License

MIT — see [LICENSE](LICENSE).
