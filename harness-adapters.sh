#!/usr/bin/env bash
# Harness abstraction layer for Buzz agents.
#
# Provides a uniform interface to invoke different AI harnesses (Claude Code, pi, Goose)
# with the right flags and conventions. Each harness adapter:
#   - Takes the same inputs (prompt, model, session_id, work_dir, system_prompt, output_file)
#   - Handles the harness-specific CLI flags and session management
#   - Writes JSON output to the specified file
#
# Usage: source this file, then call invoke_harness with:
#   $1=harness (claude|pi|goose)
#   $2=output_file
#   $3=prompt
#   $4=model (provider-specific ID)
#   $5=session_id (empty for new session)
#   $6=work_dir
#   $7=system_prompt
#
# Returns: exit code from the harness subprocess

set -uo pipefail

# Claude Code adapter
# Model format: claude-sonnet-4-5, claude-opus-4-8, claude-haiku-4-5
invoke_claude() {
  local out_file="$1" prompt="$2" model="$3" sid="$4" work_dir="$5" system_prompt="$6"

  local base_cmd="claude -p \"\$prompt\" --model \"\$model\" --append-system-prompt \"\$system_prompt\" --permission-mode bypassPermissions --output-format json"

  if [ -n "$sid" ]; then
    ( cd "$work_dir" && eval "$base_cmd --resume \"\$sid\"" >"$out_file" 2>/dev/null </dev/null )
  else
    ( cd "$work_dir" && eval "$base_cmd" >"$out_file" 2>/dev/null </dev/null )
  fi
}

# Pi adapter
# Model format: provider/model (e.g., ppq/claude-sonnet-4.6, ppq/claude-opus-4.8)
# Session management: pi uses conversation files in ~/.pi/conversations/<id>.json
invoke_pi() {
  local out_file="$1" prompt="$2" model="$3" sid="$4" work_dir="$5" system_prompt="$6"

  # Pi's --model takes provider/model format (e.g., ppq/claude-sonnet-4.6)
  # System prompt is appended via --system-append
  # Session resumption uses --continue <conversation-id>
  # Output format: --mode json

  # Only export PPQ_API_KEY if it's already set; otherwise let pi use auth.json.
  # Use :- so this survives `set -u` when the var is unset (agents launched by
  # launched from a bare tmux server env may lack PPQ_API_KEY;
  # pi then authenticates from ~/.pi/agent/auth.json). See 2026-07-17 empty-reply outage.
  local key_export=""
  [ -n "${PPQ_API_KEY:-}" ] && key_export="export PPQ_API_KEY=\"\$PPQ_API_KEY\"; "

  local base_cmd="${key_export}pi -p \"\$prompt\" --model \"\$model\" --append-system-prompt \"\$system_prompt\" --mode json"

  if [ -n "$sid" ]; then
    ( cd "$work_dir" && eval "$base_cmd --session \"\$sid\"" >"$out_file" 2>&1 </dev/null )
  else
    ( cd "$work_dir" && eval "$base_cmd" >"$out_file" 2>&1 </dev/null )
  fi
}

# Compact a pi session through RPC mode. Prints:
#   ok\ttokens_before\ttokens_after\tmessage
#   noop\t0\t0\tmessage
#   error\t0\t0\tmessage
compact_pi_session() {
  local sid="$1" model="$2" work_dir="$3" instructions="${4:-}"
  [ -n "$sid" ] || { printf 'error\t0\t0\tno session id\n'; return 1; }

  python3 - "$sid" "$model" "$work_dir" "$instructions" <<'PY'
import json
import os
import select
import subprocess
import sys
import time

sid, model, work_dir, instructions = sys.argv[1:5]
cwd = work_dir if work_dir and os.path.isdir(work_dir) else None
cmd = ["pi", "--mode", "rpc", "--session", sid]
if model:
    cmd += ["--model", model]

try:
    proc = subprocess.Popen(
        cmd,
        cwd=cwd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )
except OSError as exc:
    message = " ".join(str(exc).split()).replace("\t", " ")
    print(f"error\t0\t0\t{message}")
    sys.exit(1)
request = {"id": "compact-1", "type": "compact"}
if instructions:
    request["customInstructions"] = instructions

try:
    proc.stdin.write(json.dumps(request) + "\n")
    proc.stdin.flush()
except BrokenPipeError:
    pass

response = None
deadline = time.time() + 180
while time.time() < deadline and proc.poll() is None:
    ready, _, _ = select.select([proc.stdout], [], [], 1)
    if not ready:
        continue
    line = proc.stdout.readline()
    if not line:
        break
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    if event.get("type") == "response" and event.get("command") == "compact" and event.get("id") == "compact-1":
        response = event
        break

if proc.poll() is None:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)

if response is None:
    print("error\t0\t0\tno compact response from pi rpc")
    sys.exit(1)

if response.get("success"):
    data = response.get("data") or {}
    before = data.get("tokensBefore", 0) or 0
    after = data.get("estimatedTokensAfter", 0) or 0
    print(f"ok\t{before}\t{after}\tcompacted")
    sys.exit(0)

error = str(response.get("error") or response.get("errorMessage") or "compact failed")
error = " ".join(error.split()).replace("\t", " ")
status = "noop" if "nothing" in error.lower() or "empty" in error.lower() else "error"
print(f"{status}\t0\t0\t{error}")
sys.exit(2 if status == "noop" else 1)
PY
}

# Goose adapter
# Model format: model name (provider set via GOOSE_PROVIDER env or --provider flag)
# Session management: Goose uses sessions DB at ~/.local/share/goose/sessions/sessions.db
# Sessions are named (not ID-based); we use the thread root ID as the session name
invoke_goose() {
  local out_file="$1" prompt="$2" model="$3" sid="$4" work_dir="$5" system_prompt="$6"

  # Goose uses --model for the model, --provider for the provider (or GOOSE_PROVIDER env)
  # --text for the prompt, --system for system instructions
  # --output-format json for JSON output
  # Session resumption: --resume --name <session-name>
  # --no-session for one-shot (but we want sessions for thread memory)
  # --quiet suppresses non-response output

  local base_cmd="goose run --text \"\$prompt\" --model \"\$model\" --system \"\$system_prompt\" --output-format json --quiet"

  if [ -n "$sid" ]; then
    # Resume session by name
    ( cd "$work_dir" && eval "$base_cmd --resume --name \"\$sid\"" >"$out_file" 2>/dev/null </dev/null )
  else
    # New session with explicit name (the thread root ID)
    # Note: goose run without --resume creates a new session; we pass --name to name it
    ( cd "$work_dir" && eval "$base_cmd --name \"\$sid\"" >"$out_file" 2>/dev/null </dev/null )
  fi
}

# Main dispatch: invoke the right harness adapter
# $1=harness name, $2=out_file, $3=prompt, $4=model, $5=sid, $6=work_dir, $7=system_prompt
invoke_harness() {
  local harness="$1" out_file="$2" prompt="$3" model="$4" sid="$5" work_dir="$6" system_prompt="$7"

  case "$harness" in
    claude)
      invoke_claude "$out_file" "$prompt" "$model" "$sid" "$work_dir" "$system_prompt"
      ;;
    pi)
      invoke_pi "$out_file" "$prompt" "$model" "$sid" "$work_dir" "$system_prompt"
      ;;
    goose)
      invoke_goose "$out_file" "$prompt" "$model" "$sid" "$work_dir" "$system_prompt"
      ;;
    *)
      echo "Unknown harness: $harness (expected claude|pi|goose)" >&2
      return 1
      ;;
  esac
}

# Compact the current harness session when the harness supports it.
# $1=harness $2=session_id $3=model $4=work_dir $5=custom_instructions
compact_harness_session() {
  local harness="$1" sid="$2" model="$3" work_dir="$4" instructions="${5:-}"
  case "$harness" in
    pi) compact_pi_session "$sid" "$model" "$work_dir" "$instructions" ;;
    *) printf 'noop\t0\t0\tcompaction not supported for %s\n' "$harness"; return 2 ;;
  esac
}

# Extract field from JSON output
# Different harnesses may use different field names for the response and session ID
# $1=harness $2=json_file $3=field (result|session_id)
extract_harness_field() {
  local harness="$1" json_file="$2" field="$3"

  case "$harness" in
    claude)
      # Claude Code: {"result": "...", "session_id": "..."}
      if [ "$field" = "result" ]; then
        python3 -c "import sys, json; print(json.load(open('$json_file')).get('result', ''))" 2>/dev/null
      elif [ "$field" = "session_id" ]; then
        python3 -c "import sys, json; print(json.load(open('$json_file')).get('session_id', ''))" 2>/dev/null
      elif [ "$field" = "cost" ]; then
        # Claude Code doesn't expose cost data via JSON output
        echo "0.0:0"
      fi
      ;;
    pi)
      # Pi --mode json outputs streaming JSONL (one event per line)
      # Extract the final assistant message text from message_update events
      if [ "$field" = "result" ]; then
        python3 -c "
import sys, json
text = ''
for line in open('$json_file'):
    try:
        ev = json.loads(line)
        # pi >= 0.84: message_update carries assistantMessageEvent (text_end holds final text)
        if ev.get('type') == 'message_update':
            ame = ev.get('assistantMessageEvent') or {}
            if ame.get('type') == 'text_end' and isinstance(ame.get('content'), str):
                text = ame['content']
            # pi < 0.84: message_update carried the full assistant message
            msg = ev.get('message', {})
            if msg.get('role') == 'assistant':
                for c in msg.get('content', []):
                    if c.get('type') == 'text':
                        text = c.get('text', '')
        elif ev.get('type') == 'message_end':
            msg = ev.get('message', {})
            if msg.get('role') == 'assistant':
                for c in msg.get('content', []):
                    if c.get('type') == 'text':
                        text = c.get('text', '')
    except: pass
print(text)
" 2>/dev/null
      elif [ "$field" = "session_id" ]; then
        # Extract session ID from the session event at the start
        python3 -c "
import sys, json
for line in open('$json_file'):
    try:
        ev = json.loads(line)
        if ev.get('type') == 'session':
            print(ev.get('id', ''))
            break
    except: pass
" 2>/dev/null
      elif [ "$field" = "cost" ]; then
        # Compute cost from token counts + known PPQ rates (per-million).
        # pi's own cost computation is broken for PPQ: the ppq-provider.ts extension
        # pre-divides rates by 1M (perMillion()) but pi's calculateCost expects
        # per-million rates and divides again, producing ~1e-12 instead of ~1e-6.
        # Computing here from token counts is accurate and independent of that bug.
        # Rates sourced from the PPQ API (/v1/models pricing).
        python3 -c "
import sys, json

# PPQ per-million-token rates by model id (input, output, cacheRead).
# GLM/Kimi cache reads are billed. Rates measured from PPQ query history on 2026-08-01.
RATES = {
    'z-ai/glm-5.2':              (1.586, 4.9165, 0.1506),
    'z-ai/glm-5.3':              (1.477, 4.642, 0.1477),
    'deepseek/deepseek-v4-pro':  (0.458925, 0.91785, 0),
    'deepseek/deepseek-v4-flash':(0.10339, 0.20678, 0),
    'deepseek/deepseek-v4-flash-0731':(0.10339, 0.20678, 0),
    'qwen/qwen3-coder-flash':    (0.205725, 1.028625, 0),
    'claude-sonnet-4.6':         (3.165, 15.825, 0.3165),
    'claude-opus-4.8':           (5.275, 26.375, 0.5275),
    'claude-haiku-4.5':          (1.055, 5.275, 0.1055),
    'moonshotai/kimi-k2.6':      (1.00225, 4.22, 0),
    'moonshotai/kimi-k3':        (3.165, 15.825, 0.3165),  # via PPQ (review bot)
}
DEFAULT_RATE = (0, 0, 0)

total_cost = 0.0
total_tokens = 0
for line in open('$json_file'):
    try:
        ev = json.loads(line)
        if ev.get('type') == 'turn_end':
            msg = ev.get('message', {})
            usage = msg.get('usage', {})
            model_id = msg.get('model', '')
            inp, outp, cache_r = RATES.get(model_id, DEFAULT_RATE)
            t_in = usage.get('input', 0)
            t_out = usage.get('output', 0)
            t_cr = usage.get('cacheRead', 0)
            cost = (inp * t_in + outp * t_out + cache_r * t_cr) / 1_000_000
            total_cost += cost
            total_tokens += usage.get('totalTokens', 0)
    except: pass
print(f'{total_cost}:{total_tokens}')
" 2>/dev/null
      fi
      ;;
    goose)
      # Goose JSON output format: {"messages": [...], "metadata": {...}}
      # Extract the last assistant message as the result
      if [ "$field" = "result" ]; then
        python3 -c "
import sys, json
try:
    data = json.load(open('$json_file'))
    msgs = data.get('messages', [])
    # Find last assistant message
    for msg in reversed(msgs):
        if msg.get('role') == 'assistant':
            content = msg.get('content', [])
            for c in content:
                if c.get('type') == 'text':
                    print(c.get('text', ''))
                    sys.exit(0)
except: pass
print('')
" 2>/dev/null
      elif [ "$field" = "session_id" ]; then
        # Goose doesn't return session info in JSON output
        # Session name was passed in via --name flag, so we can't extract it
        # Return empty (the watcher will use the root ID it passed in)
        echo ""
      elif [ "$field" = "cost" ]; then
        # Goose doesn't expose cost data
        echo "0.0:0"
      fi
      ;;
    *)
      echo "" >&2
      return 1
      ;;
  esac
}

# Model mapping: convert a canonical model name to the harness-specific format
# $1=harness $2=canonical_model (e.g., sonnet-4.6, opus-4.8, haiku-4.5)
# Returns the harness-specific model ID
map_model_name() {
  local harness="$1" model="$2"

  # If model is already in harness-specific format (contains /), use it as-is
  case "$model" in
    */*) echo "$model"; return ;;
  esac

  # Otherwise, map canonical names to harness-specific IDs
  case "$harness" in
    claude)
      # Claude Code uses claude-<tier>-<version> format
      case "$model" in
        sonnet-4.6|sonnet) echo "claude-sonnet-4-5" ;;  # Latest Sonnet in Claude Code
        opus-4.8|opus) echo "claude-opus-4-8" ;;
        haiku-4.5|haiku) echo "claude-haiku-4-5" ;;
        *) echo "$model" ;;  # Pass through if already in right format
      esac
      ;;
    pi)
      # Pi uses provider/model format; router profiles use router/ prefix
      case "$model" in
        router-auto|router) echo "router/auto" ;;  # Intelligent routing with GLM-first open models
        router-open) echo "router/open" ;;  # GLM for all tiers
        router-quality) echo "router/quality" ;;  # Claude quality tier with GLM fallback
        sonnet-4.6|sonnet) echo "ppq/claude-sonnet-4.6" ;;
        opus-4.8|opus) echo "ppq/claude-opus-4.8" ;;
        haiku-4.5|haiku) echo "ppq/claude-haiku-4.5" ;;
        glm-5.3) echo "ppq/z-ai/glm-5.3" ;;  # GLM-5.3 via PPQ (z-ai provider)
        glm-5.2|glm) echo "ppq/z-ai/glm-5.3" ;;  # fleet default bumped to GLM-5.3 2026-08-19
        *) echo "ppq/$model" ;;  # Default to ppq provider
      esac
      ;;
    goose)
      # Goose provider is set via GOOSE_PROVIDER env (or --provider flag)
      # Model is just the model name without provider prefix
      # Default to openai provider for GLM-5.2 (via PPQ-compatible endpoint)
      case "$model" in
        sonnet-4.6|sonnet) echo "claude-sonnet-4-5" ;;  # Set GOOSE_PROVIDER=anthropic
        opus-4.8|opus) echo "claude-opus-4-8" ;;
        haiku-4.5|haiku) echo "claude-haiku-4-5" ;;
        glm-5.2|glm|glm-5.3) echo "glm-5.3" ;;  # Set GOOSE_PROVIDER=openai (PPQ endpoint)
        *) echo "$model" ;;  # Pass through
      esac
      ;;
    *)
      echo "$model"  # Unknown harness, pass through
      ;;
  esac
}
