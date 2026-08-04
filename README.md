# agent-cli

A terminal-based coding agent written in Ruby. It gives you an interactive TUI
(built on [Charm Ruby](https://github.com/charmbracelet) — Bubble Tea + Lip
Gloss) where you chat with a model that can **read, write, and edit files** and
**run shell commands** on your behalf — safely confined to your project
directory.

```
┌ you ──────────────────────────────┐   ┌ diff  [ / ] ──────────────┐
│ refactor the input drain module   │   │ @@ -12,4 +12,6 @@          │
│                                   │   │ + def flush_buffer         │
│ Agent · claude-opus-4-8 · anthro. │   │ +   drain until empty      │
└───────────────────────────────────┘   └───────────────────────────┘
```

---

## Highlights

- 🔒 **Sandboxed by default** — every shell command runs inside an OS sandbox
  (MacOS `sandbox-exec` / Linux `bubblewrap`), and file writes are confined to the
  project root. There is no switch to disable it.
- 🤖 **Multi-agent orchestration** — the top-level *manager* agent can `delegate`
  focused subtasks to fresh *worker* agents, and run independent subtasks in
  parallel.
- 🔌 **Multi-provider** — Anthropic, OpenAI, OpenRouter, Google Gemini, Groq,
  Ollama, and OpenCode, behind a single native tool-use loop.
- 💾 **Remembers your setup** — last provider/model, named model sets, and a
  per-command permission allowlist all persist across sessions.
- ⚡ **Cheap workers** — run sub-agents on a smaller/faster model (or a different
  provider entirely) than the manager.

---

## Sandboxing

Confinement is **mandatory** — it cannot be disabled, and the writable root can
never be widened beyond the directory you launched from. Two layers cooperate
(`lib/agent_cli/sandbox.rb`):

| Layer | Covers | Mechanism |
|-------|--------|-----------|
| **In-process write guard** | `write_file` / `edit_file` | Refuses any path that resolves outside the project root (resolving symlinks so an in-root symlink can't redirect a write out). Cross-platform, always on. |
| **OS sandbox** | `run_command` (arbitrary shells) | **macOS** → `sandbox-exec` (Seatbelt) with a deny-file-write profile. **Linux** → `bubblewrap` (`bwrap`) with the project bound read-write and system dirs read-only. |

**Fail closed:** if the OS sandbox backend isn't available, shell commands are
*refused* rather than run unconfined. On Linux, install bubblewrap to enable
shell execution:

```bash
sudo apt-get install bubblewrap   # Debian/Ubuntu
sudo dnf install bubblewrap       # Fedora/RHEL
sudo pacman -S bubblewrap         # Arch
```

Reads and network access stay open so toolchains (compilers, test runners,
package managers) keep working; only *writes* outside the project are blocked.

---

## Multi-agent orchestration

The top-level agent runs as a **manager** with the normal file/shell tools
**plus** a `delegate` tool that spawns fresh **worker** agents for focused,
self-contained subtasks (`lib/agent_cli/agents.rb`).

- **Parallel fan-out** — emit multiple `delegate` calls in one turn and the
  workers run concurrently (capped at `MAX_PARALLEL = 6`).
- **Bounded recursion** — a worker may itself delegate, forming a manager →
  worker tree, up to `MAX_DEPTH = 2`.
- **Cheaper workers** — give workers a smaller/faster model or a different
  provider via `/worker` (see below).

Worker activity is shown indented in the chat log. Type `/agents` for details.

---

## Providers

All providers drive a native tool-use loop. Anthropic uses the Messages API;
OpenAI/OpenRouter/Google/Groq/Ollama use OpenAI-compatible Chat Completions with
function calling; OpenCode talks to a local server that owns its own editing
tools.

| Provider   | Default model                    | API key env var      | Notes |
|------------|----------------------------------|----------------------|-------|
| anthropic  | `claude-opus-4-8`                | `ANTHROPIC_API_KEY`  | Native Messages API |
| openai     | `gpt-4o`                         | `OPENAI_API_KEY`     | |
| openrouter | `openai/gpt-oss-20b:free`        | `OPENROUTER_API_KEY` | Free + paid gateway |
| google     | `gemini-3.6-flash`               |  `GEMINI_API_KEY`    | AI Studio, OpenAI-compatible |
| groq       | `llama-3.3-70b-versatile`        | `GROQ_API_KEY`       | LPU inference |
| ollama     | `llama3.1`                       | — (local)            | `ollama serve` |
| opencode   | (set via `/providers`)           | — (local)            | `opencode serve --port 4096` |

API keys can be supplied via env vars **or** entered in the TUI (saved to
`~/.agent-cli/settings.json`).

---

## Install & run

Requires Ruby (see `.ruby-version` → `ruby-4.0.0`).

```bash
gem install bubbletea lipgloss   # dependencies
ruby agent-cli.rb                # launch the TUI
```

Type `/providers` to connect and pick a model (your choice is remembered).

**Skip the picker at boot** with env vars:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
AGENT_PROVIDER=anthropic AGENT_MODEL=claude-opus-4-8 ruby agent-cli.rb
```

**Run workers on a different model / provider:**

```bash
AGENT_WORKER_MODEL=claude-haiku-4-5 ruby agent-cli.rb
AGENT_WORKER_PROVIDER=groq AGENT_WORKER_MODEL=llama-3.3-70b-versatile ruby agent-cli.rb
```

**Local servers:**

```bash
ollama serve && ollama pull llama3.1
AGENT_PROVIDER=ollama AGENT_MODEL=llama3.1 ruby agent-cli.rb

opencode serve --port 4096
AGENT_PROVIDER=opencode AGENT_MODEL=anthropic/claude-opus-4-8 ruby agent-cli.rb
```

---

## Install as a gem (run it in any project)

Package agent-cli as a gem and install its `agent-cli` executable onto your
PATH, then run it from inside any project. The agent always operates on the
**current working directory**, so no per-project setup is needed. Global state
(API keys, model choice) lives in `~/.agent-cli/` and `~/.config/agent-cli/`.

**Build and install from this repo:**

```bash
gem build agent_cli.gemspec          # → agent_cli-<version>.gem
gem install ./agent_cli-*.gem        # installs the `agent-cli` command + deps
```

**Run it in another project:**

```bash
cd ~/code/some-other-project
agent-cli                            # same TUI, scoped to this directory
```

## Tools the model can call

| Tool | Purpose |
|------|---------|
| `read_file`   | Read a file (optionally a line range) |
| `write_file`  | Create/overwrite a file (write-guarded to the project root) |
| `edit_file`   | Exact verbatim string replacement, with clear errors on missing/ambiguous matches |
| `list_files`  | List directory contents |
| `run_command` | Run a shell command inside the OS sandbox |
| `delegate`    | (manager only) Hand a subtask to a worker agent |

`write_file` / `edit_file` results render as unified diffs in the right-hand
panel.

---

## Slash commands

| Command      | Action |
|--------------|--------|
| `/providers` | Switch provider and model |
| `/worker`    | Set the provider/model workers use |
| `/models`    | Manage saved model sets |
| `/init`      | Read or create `AGENTS.md` (references `CLAUDE.md` if present) |
| `/help`      | List available commands |

Type `/` in chat to see and complete the available commands.

---

## Shell-command safety

Beyond the OS sandbox, `run_command` gates execution with a permission prompt:

- **Read-only `git` commands** (`git status`, `git log`, `git diff`, …) are
  auto-allowed.
- Anything else prompts: **`y`** allow once · **`a`** allow this session ·
  **`p`** allow permanently · **`n`** deny.
- Permanently-allowed command prefixes persist to an allowlist so future runs
  skip the prompt. Auto-allow only applies to commands with no shell
  metacharacters (`; & | > < $( )` / newlines); subcommand tools like `git …`,
  `npm …`, `docker …` persist a two-token prefix.
- Launch with `--yolo` to skip all permission prompts (the OS sandbox still
  applies).

---

## Keys

| Context      | Keys |
|--------------|------|
| Chat         | type a request · `enter` send · `esc` interrupt a running turn · `/` slash commands · `ctrl+c` quit |
| Diff panel   | `[` / `]` cycle through diffs |
| Picker/menus | `↑`/`↓` move · `enter` select · `esc` back |
| Permission   | `y`/`enter` allow once · `a` session · `p` permanently · `n`/`esc` deny |

The composer supports word-wise navigation (`opt/alt+←`/`→`, `ctrl+←`/`→`) and
cross-session prompt history (`↑`/`↓`).

---

## Configuration & state

| Path | Contents |
|------|----------|
| `~/.config/agent-cli/preferences.json` | Last provider/model, worker override, named model sets, command allowlist |
| `~/.agent-cli/settings.json`           | API keys entered via the TUI |
| `AGENTS.md` (in the repo)              | Project context loaded into new sessions; generated by `/init` |

---

## Architecture

```
agent-cli.rb            # entrypoint: resolves provider, boots the Bubbletea TUI
lib/agent_cli/
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
  model.rb / constants.rb
lib/provider/           # Provider::Base + anthropic / openai / openrouter /
                        # google / groq / ollama / opencode
```

**Flow:** the TUI runs the provider's turn on a worker thread; the provider
drives a tool-use loop (capped at `MAX_STEPS = 25` iterations per turn; a turn
that hits the cap says so instead of going quiet) that
calls the model, dispatches tool calls through `Tools.call` (or `delegate` →
`run_worker`), and emits events — assistant text, tool results, usage, diffs —
back through a `Queue`. The TUI drains those events on each poll tick and
renders them. Only the TUI thread mutates UI state.
