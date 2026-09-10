# buzz-agents task runner
# Install: brew install just

set shell := ["bash", "-euo", "pipefail", "-c"]

# One-command setup: check deps, install scripts to ~/.buzz/agents, print next steps.
setup:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "== Checking prerequisites =="
    missing=0
    for cmd in buzz nak flock tmux python3 git; do
      if command -v "$cmd" >/dev/null 2>&1; then
        echo "  ok   $cmd"
      else
        echo "  MISS $cmd"
        missing=1
      fi
    done
    harness=0
    for h in claude pi goose codex; do
      command -v "$h" >/dev/null 2>&1 && { echo "  ok   harness: $h"; harness=1; }
    done
    [ "$harness" = 1 ] || { echo "  MISS harness: install claude, pi, goose, or codex"; missing=1; }
    if [ "$missing" = 1 ]; then
      echo ""
      echo "Install the missing pieces and re-run just setup."
      echo "  buzz CLI: build from the buzz repo, put on PATH (or symlink into ~/.buzz/bin)"
      echo "  nak:      https://github.com/fiatjaf/nak"
      echo "  flock:    brew install flock"
      exit 1
    fi
    echo ""
    echo "== Installing to ~/.buzz/agents =="
    mkdir -p ~/.buzz/agents
    install -m 755 agent-watcher.sh harness-adapters.sh new-agent.sh ~/.buzz/agents/
    install -m 644 base-agent-prompt.md example.env ~/.buzz/agents/
    echo "  installed agent-watcher.sh, harness-adapters.sh, new-agent.sh, base-agent-prompt.md, example.env"
    install -m 755 hooks/commit-msg .git/hooks/commit-msg
    echo "  installed commit-msg hook (denylist: ${BUZZ_DENYLIST_FILE:-~/.buzz/redact-denylist})"
    echo ""
    echo "== Next steps =="
    echo "1. export BUZZ_RELAY_URL=\"http://<your-relay-host>:3000\""
    echo "2. export OWNER=\"<your hex pubkey>\"   (run: nak key public <your-nsec>)"
    echo "3. just new-agent myproject ~/code/myproject glm-5.3"
    echo "4. @mention the bot in its channel."

# Scaffold + launch a new agent. Model is required (no silent expensive default).
# Usage: just new-agent <name> <repo-path> <model>
new-agent name repo model:
    #!/usr/bin/env bash
    set -euo pipefail
    args=("{{name}}" --repo "{{repo}}" --model "{{model}}")
    exec "$(dirname {{justfile()}})/new-agent.sh" "${args[@]}"

# List running watchers (tmux sessions named buzz-*).
status:
    @tmux ls 2>/dev/null | grep '^buzz-' || echo "No agent watchers running."

# Stop an agent watcher.
stop name:
    tmux kill-session -t "buzz-{{name}}" && echo "stopped {{name}}"

# Tail an agent's log.
logs name:
    tail -f "$HOME/.buzz/agents/{{name}}/watcher.log"

# Remove all installed files (does not touch keys, channels, or runtime state).
uninstall:
    rm -f ~/.buzz/agents/{agent-watcher.sh,harness-adapters.sh,new-agent.sh,base-agent-prompt.md,example.env}
    @echo "Removed scripts. Runtime state in ~/.buzz/agents/<name>/ and .env configs kept."
