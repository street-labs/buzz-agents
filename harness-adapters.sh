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
#   $1=harness (claude|pi|goose|codex|cursor)
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

  # Claude Code is the only harness of the four with a headless compaction control:
  # --autocompact <auto|tokens> (auto, or 100k-1M). Opt-in via AGENT_AUTOCOMPACT so the
  # default stays whatever the CLI does today -- turning it on is a config decision, not
  # something to change under a running agent.
  [ -n "${AGENT_AUTOCOMPACT:-}" ] && base_cmd="$base_cmd --autocompact \"\$AGENT_AUTOCOMPACT\""

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

# Codex adapter
# Model format: gpt-5.4-codex, gpt-5.4-codex-mini (OpenAI model ids, passed through)
# Session management: `codex exec resume <uuid>` replays a persisted session. The id comes
# out of the --json event stream; see extract_harness_field.
#
# Two shape differences from the other harnesses:
#   - `resume` is a SUBCOMMAND of `exec`, and it takes no -C/--cd, so both paths cd into
#     work_dir in the subshell rather than passing a flag.
#   - there is no --append-system-prompt. `-c developer_instructions=` is the equivalent
#     (verified against 0.149.1 with --strict-config; `experimental_instructions_file` and
#     `base_instructions` are NOT valid keys in this version). Codex also reads AGENTS.md
#     from the working directory, which in a repo worktree is the REPO's file — so the
#     agent's own prompt has to come through the flag, not a file.
invoke_codex() {
  local out_file="$1" prompt="$2" model="$3" sid="$4" work_dir="$5" system_prompt="$6"

  # --output-last-message gives the final text directly, so extract_harness_field does not
  # have to reassemble it from the event stream.
  local last_file="${out_file}.last"
  rm -f "$last_file"

  local flags="--json --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox"
  flags="$flags --model \"\$model\" -o \"\$last_file\""
  flags="$flags -c developer_instructions=\"\$system_prompt\""

  if [ -n "$sid" ]; then
    ( cd "$work_dir" && eval "codex exec resume $flags \"\$sid\" \"\$prompt\"" >"$out_file" 2>/dev/null </dev/null )
  else
    ( cd "$work_dir" && eval "codex exec $flags \"\$prompt\"" >"$out_file" 2>/dev/null </dev/null )
  fi
}


# Cursor adapter
# Model format: Cursor's own slugs (sonnet-4.5-thinking, gpt-5, ...). `cursor-agent models`
# is the authoritative list for the logged-in account -- do not invent names here, same trap
# as codex.
# Session management: `--resume <chatId>` reopens a chat. The id arrives as `session_id` in
# the result object.
#
# Two shape differences worth knowing:
#   - There is NO system-prompt flag. Cursor reads `.cursor/rules` and `AGENTS.md` from the
#     workspace, which in a repo worktree is the REPO's file, not the agent's. So the agent
#     prompt is prepended to the turn text instead.
#     ponytail: prepend rather than writing a rules file into the worktree -- a rules file
#     there would get committed into a PR by accident.
#   - It DOES report usage, and better than the others: inputTokens / outputTokens /
#     cacheReadTokens / cacheWriteTokens broken out. Codex folds cache into inputTokens and
#     the claude path currently records nothing at all, so this is the cleanest accounting
#     of the three.
invoke_cursor() {
  local out_file="$1" prompt="$2" model="$3" sid="$4" work_dir="$5" system_prompt="$6"

  local combined
  combined="$(printf '%s\n\n---\n\n%s' "$system_prompt" "$prompt")"

  # --force: allow tool calls without prompting, the equivalent of codex's
  # --dangerously-bypass-approvals-and-sandbox. Without it the turn blocks on approval and
  # times out headlessly.
  local flags="--print --output-format json --force --model \"\$model\""

  if [ -n "$sid" ]; then
    ( cd "$work_dir" && eval "cursor-agent $flags --resume \"\$sid\" \"\$combined\"" >"$out_file" 2>/dev/null </dev/null )
  else
    ( cd "$work_dir" && eval "cursor-agent $flags \"\$combined\"" >"$out_file" 2>/dev/null </dev/null )
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
    codex)
      invoke_codex "$out_file" "$prompt" "$model" "$sid" "$work_dir" "$system_prompt"
      ;;
    cursor)
      invoke_cursor "$out_file" "$prompt" "$model" "$sid" "$work_dir" "$system_prompt"
      ;;
    *)
      echo "Unknown harness: $harness (expected claude|pi|goose|codex|cursor)" >&2
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
    codex)
      # codex exec --json emits JSONL events. The final text is written separately by
      # -o/--output-last-message, so prefer that file and only fall back to the stream.
      if [ "$field" = "result" ]; then
        if [ -s "${json_file}.last" ]; then
          cat "${json_file}.last"
        else
          # Fallback: the stream carries the reply as item.completed / agent_message.
          python3 -c "
import json
text = ''
for line in open('$json_file'):
    try: ev = json.loads(line)
    except: continue
    item = ev.get('item') or {}
    if ev.get('type') == 'item.completed' and item.get('type') == 'agent_message':
        text = item.get('text', '')
print(text)
" 2>/dev/null
        fi
      elif [ "$field" = "session_id" ]; then
        # Verified against 0.149.1: the stream opens with
        #   {"type":"thread.started","thread_id":"<uuid>"}
        # and `codex exec resume <uuid>` reopens that same thread with its history intact.
        # The alternate key names are kept because Codex spells this differently across its
        # own surfaces; thread_id is the one exec --json actually emits.
        python3 -c "
import json, re
UUID = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', re.I)
KEYS = ('thread_id', 'session_id', 'conversation_id', 'threadId', 'sessionId', 'conversationId')
def find(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k in KEYS and isinstance(v, str) and UUID.match(v):
                return v
            r = find(v)
            if r: return r
    elif isinstance(o, list):
        for v in o:
            r = find(v)
            if r: return r
    return None
for line in open('$json_file'):
    try: ev = json.loads(line)
    except: continue
    r = find(ev)
    if r:
        print(r); break
" 2>/dev/null
      elif [ "$field" = "cost" ]; then
        # Usage rides a ChatGPT subscription, so there is no dollar figure to report.
        # turn.completed.usage has no total_tokens field -- it breaks the count out, so
        # sum the parts. Keys verified against 0.149.1.
        python3 -c "
import json
total = 0
for line in open('$json_file'):
    try: ev = json.loads(line)
    except: continue
    if ev.get('type') != 'turn.completed': continue
    u = ev.get('usage') or {}
    total += sum(u.get(k, 0) or 0 for k in ('input_tokens', 'output_tokens', 'reasoning_output_tokens'))
print(f'0.0:{total}')
" 2>/dev/null || echo "0.0:0"
      fi
      ;;
    cursor)
      # `--print --output-format json` emits one result object:
      #   {"type":"result","subtype":"success","result":"...","session_id":"...", ...}
      # Some builds stream NDJSON instead, so try the whole file first and fall back to
      # scanning lines for the result event.
      if [ "$field" = "result" ] || [ "$field" = "session_id" ]; then
        python3 -c "
import json, sys
key = 'result' if '$field' == 'result' else 'session_id'
raw = open('$json_file').read()
val = ''
try:
    d = json.loads(raw)
    if isinstance(d, dict):
        val = d.get(key) or ''
except Exception:
    for line in raw.splitlines():
        try: ev = json.loads(line)
        except Exception: continue
        if isinstance(ev, dict) and ev.get('type') == 'result':
            val = ev.get(key) or ''
print(val)
" 2>/dev/null
      elif [ "$field" = "cost" ]; then
        # It DOES report usage, contrary to the stream-json feature request people cite:
        #   "usage":{"inputTokens":8224,"outputTokens":37,"cacheReadTokens":9600,
        #            "cacheWriteTokens":0}
        # Verified against 2026.08.25-3e8eec8. Sum all four so the number is comparable to
        # codex, whose inputTokens already has cached context folded in. No dollar figure --
        # usage rides a Cursor subscription.
        python3 -c "
import json
raw = open('$json_file').read()
u = {}
try:
    d = json.loads(raw)
    if isinstance(d, dict): u = d.get('usage') or {}
except Exception:
    for line in raw.splitlines():
        try: ev = json.loads(line)
        except Exception: continue
        if isinstance(ev, dict) and ev.get('type') == 'result':
            u = ev.get('usage') or {}
total = sum(u.get(k, 0) or 0 for k in
            ('inputTokens', 'outputTokens', 'cacheReadTokens', 'cacheWriteTokens'))
print(f'0.0:{total}')
" 2>/dev/null || echo "0.0:0"
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
    codex)
      # Slugs come from ~/.codex/models_cache.json, which is the only authoritative list --
      # do not invent names here. A ChatGPT-account login rejects anything not in it with a
      # 400 ("model is not supported when using Codex with a ChatGPT account"), and the
      # rejection only shows up on the first real turn.
      # Listed as of 0.149.1: gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna, gpt-5.5, gpt-5.4,
      # gpt-5.4-mini, gpt-5.3-codex-spark.
      case "$model" in
        codex) echo "gpt-5.6-terra" ;;      # verified end to end incl. session resume
        codex-mini) echo "gpt-5.4-mini" ;;
        codex-long) echo "gpt-5.4" ;;       # 1M context, for whole-diff review
        *) echo "$model" ;;
      esac
      ;;
    cursor)
      # `cursor-agent models` is the authoritative list for the logged-in account. Do not
      # invent slugs here -- same failure mode as codex, where an unlisted name is only
      # rejected on the first real turn.
      # Confirmed against `cursor-agent models` 2026-08-31. Aliases exist only for the
      # models the other agents already run, so a fallback is a one-word config change;
      # everything else passes through verbatim.
      case "$model" in
        cursor) echo "auto" ;;                              # Cursor routes it
        cursor-opus) echo "claude-opus-5-thinking-high" ;;  # matches builder's claude-opus-5
        cursor-terra) echo "gpt-5.6-terra-medium" ;;        # matches reviewer's codex default
        cursor-composer) echo "composer-2.5" ;;             # Cursor's own model
        *) echo "$model" ;;
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
