# buzz-agents

Run a team of AI agents on a [Buzz](https://github.com/ldstreet/buzz) relay. One
watcher script, many agents. Each agent is a full harness instance (Claude Code, pi,
or Goose) scoped to a project repo, with per-thread memory, concurrent workers, and
isolated git worktrees per thread.

Distilled from a production multi-agent workspace. All operator-specific config
(relay URLs, keys, bot names, machine paths) has been replaced with placeholders.

## What you get

| File | Role |
|---|---|
| `agent-watcher.sh` | The generic, config-driven watcher. One script runs every agent. Polls for @mentions, spawns a worker per message (up to `MAX_WORKERS`), gives each thread its own worktree + resumed harness session, posts replies back to the channel. |
| `harness-adapters.sh` | Uniform interface over Claude Code / pi / Goose. Sourced by the watcher; switch harnesses per-agent with two env lines. |
| `base-agent-prompt.md` | Operating rules appended to every turn: verify-before-claim, git guardrail, progress updates, token economy, multi-agent etiquette, context controls. |
| `new-agent.sh` | Scaffolder: mints/reuses a bot key, creates the channel, adds owner + bot as members (verified), sets up the worktree, writes the config, launches in tmux, verifies. |
| `scoped-agent.sh` | Community-relay variant: fresh scoped key, invite-claim membership (no local admin key needed), `sandbox-exec` seatbelt profile (writes denied outside the worktree), hardened non-technical-audience persona. Prints the macOS-user steps it cannot do for you. |
| `example.env` | Annotated agent config template. Copy to `<name>.env` and edit. |
| `Justfile` | `just setup` installs everything and checks prerequisites. |

## Prerequisites

- A running [Buzz](https://github.com/ldstreet/buzz) relay and the `buzz` CLI on
  PATH (or symlinked into `~/.buzz/bin`).
- [`nak`](https://github.com/fiatjaf/nak) (Nostr key tool).
- `flock` (`brew install flock`), `tmux`, `python3`, `git`.
- One AI harness CLI: `claude`, `pi`, or `goose`.
- [`just`](https://just.systems) (`brew install just`).
- macOS keychain if you use the optional PPQ (ppq.ai) billing integration.

## Quickstart

```bash
git clone <this-repo> && cd buzz-agents
just setup                                    # checks deps, installs to ~/.buzz/agents

export BUZZ_RELAY_URL="http://localhost:3000" # your relay
export OWNER="$(nak key public <your-nsec>)"  # your hex pubkey

just new-agent myproject ~/code/myproject glm-5.3
```

`new-agent.sh` mints the bot key, creates the channel, adds you and the bot as
members (and verifies), installs the config, launches the watcher in tmux, and
verifies it is running. Then @mention the bot in its channel.

Useful commands after that: `just status`, `just logs myproject`,
`just stop myproject`.

## How a watcher works

1. Main loop polls the relay for new @mentions of the bot.
2. Each message spawns a worker process (capped at `MAX_WORKERS`, default 8).
3. Each thread maps to its own git worktree (`agent/<name>-<thread>` branch), so
   concurrent threads never share a working copy or mix commits.
4. First message in a thread starts a harness session; later messages resume it,
   so the agent remembers what it already did.
5. The reply is posted back into the originating thread automatically.
6. Context controls: the owner can send `/fresh` (drop harness memory for the
   thread, keep the worktree) or `/compact [focus]` (summarize and continue).
   Agents can also schedule these via hidden `[[WATCHER: fresh]]` /
   `[[WATCHER: compact: ...]]` directives in their replies. All of this is
   handled by the watcher itself - nothing external to install.

## Config (the .env file)

See `example.env` for the annotated full set. The minimum:

```bash
AGENT_NAME="myproject"
AGENT_KEY_FILE="$HOME/.buzz/agents/myproject-bot.key"
AGENT_REPO="$HOME/code/myproject"
AGENT_HARNESS="pi"          # claude | pi | goose
AGENT_MODEL="glm-5.3"       # no default - must be explicit
```

Notable knobs:

- `AGENT_GUARDRAIL="branch-pr"` (default): agent works on `agent/<name>`, opens PRs,
  never touches main. `"direct-main"` for single-writer repos.
- `AGENT_HOME_CHANNELS="<id> <id> ..."`: channels where the agent is primary and
  follows threads. Everywhere else it is summon-only (answers a direct @mention,
  then bows out). New channels are summon-only by default.
- `AGENT_PERSONA_FILE`: extra prompt text appended after the base prompt.
- `MAX_WORKERS`, `MODEL_TIMEOUT`, `BOOT_GRACE`: concurrency and timing.

## Worktree slots

Each thread works in its own worktree under `<repo>-worktrees/<agent>-slot-N`. Slots
are recycled rather than deleted: the path is what makes a build incremental, because
build systems key their caches on absolute source paths and package managers install
into the tree itself. Handing the next thread the same path keeps all of that warm.

If no slot is free a new one is cut, so a busy day never blocks a thread from
starting. A slot is only reclaimed when it is clean and every commit is on a remote;
one that has gone quiet for `SLOT_STALE_DAYS` (default 3) is reclaimed too, but its
uncommitted work is committed first and its branch kept, so nothing is lost. A thread
that comes back after its slot was recycled is checked out onto its own branch again,
recorded in `slot-archive.tsv`.

### Warming slots ahead of time (optional)

`warm-slots.sh <agent>` builds one *unclaimed* slot at `origin/main` so the thread
that claims it next gets an incremental build rather than a cold one. Run it from a
timer.

It does not know how to build anything. If the repo has an executable
`tools/agent-warm-slot.sh`, it runs that from the slot root; if not, it exits quietly.
Projects that want warming write that one script; every other project is unaffected.

The contract for `tools/agent-warm-slot.sh`:

- it is run from the slot root, already reset to `origin/main`
- exit 0 only if the slot is genuinely warm
- on success write the built commit to `$(git rev-parse --absolute-git-dir)/agent-warmed-sha`

That marker is compared against `origin/main` to decide whether a rewarm is due.
There is no time-based throttle: rewarming an already-warm slot is itself incremental,
and the idle check is what keeps it off a busy machine.

What it refuses to touch: a slot a live thread has claimed, a slot with uncommitted
changes, and a slot holding commits that are not on a remote. It also skips entirely
when load is at or above core count or another build is running — `WARM_FORCE=1`
overrides that for a manual run. One warm at a time across all agents, via `flock`.

Warming a slot a thread is *using* would not help: two builds on one cache path
serialise, so the agent would just wait out the warm build. Only free slots are warmed.

`test-worktree-slots.sh` and `test-warm-slots.sh` cover both halves.

## Multi-agent

Run several agents in one workspace and they coordinate: the watcher names the other
agents in the system prompt (from `~/.buzz/agents/roster.tsv`, `pubkey<TAB>name` per
line, optional) so a message aimed at one bot is background context, not an
instruction, to the others. Pubkeys listed in `~/.buzz/agents/assist.txt` (optional)
never claim a thread's follow-up slot.

## PPQ billing (optional)

If you use ppq.ai as your model provider, the watcher can resolve a PPQ API key from
the macOS keychain (service `buzz-agents-ppq`, or `buzz-agents-ppq-<agent>` for
per-agent attribution). Without the optional `ppq-billing.sh` helper these hooks are
no-ops. Any other provider credentials are handled by your harness as usual.

## Hardening already baked in

- Singleton guard: a second watcher for the same agent refuses to start (atomic
  mkdir mutex with PID-liveness stale-lock recovery). No duplicate replies.
- Fail-closed model config: no silent fallback to an expensive default model.
- Keychain self-healing for API keys when launched from a bare tmux environment.
- Boot grace: only history older than `BOOT_GRACE` seconds is suppressed on restart;
  recent unanswered mentions survive.
- At-most-once message claiming, so a watcher restart never re-answers a message.
- Verify-before-claim and no-double-posting rules in the base prompt.
