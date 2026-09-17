# Salon Mode (multi-agent natural conversation)

## Overview

Salon mode lets multiple agents participate in a channel the way polite human
colleagues would: a per-message arbiter decides whether an agent should take a
turn, silently selects exactly one agent (or nobody), and each participant answers
from its own private working context with as much context as the selection
grants. It exists
so channels with several humans and several bots feel like one conversation
instead of a summon-only helpdesk - and so every buzz-agents setup without it
(or without Jev) behaves exactly as it does today.

## User Stories

- As a channel owner, I want agents to jump in only when they have something to
  contribute, so the channel reads like a natural conversation rather than bot
  chatter.
- As a human participant, I want agents to stay out of human-to-human
  conversation, so I can talk freely without bots piling on.
- As an agent operator without a TypeSafe key, I want salon mode to still work
  (less spontaneously), so my setup is never broken by missing services.
- As an agent operator, I want salon mode fully off by default, so existing
  setups are byte-for-byte unchanged until I opt a channel in.
- As a workspace operator, I want every selection decision auditable, so I can
  understand
  why an agent spoke or stayed silent.

## Requirements

### Opt-in & Compatibility

- **Off by default** `FR-salon-off-default`: Salon mode activates only for
  channels listed in `AGENT_SALON_CHANNELS` (default empty). All other channels
  use the existing deterministic eligibility path, unchanged.
- **Flag-off equivalence** `FR-salon-flagoff-equivalence`: With the flag unset,
  the watcher's message-eligibility decisions are identical to pre-salon
  behavior (verified by test).
- **Arbiter ladder** `FR-salon-arbiter-ladder`: Arbiter decisions resolve
  through: (1) Jev if a key is configured, (2) a one-shot LLM call via the
  agent's own harness otherwise, (3) the deterministic floor (explicit
  mention/p-tag = that bot answers; all else = silence). Each rung falls back
  to the next on error or missing prerequisites.
- **No-Jev safety** `FR-salon-nojev-safe`: A setup without a Jev key never
  errors, never crashes, and never changes non-salon behavior; salon channels
  degrade to the LLM rung or the deterministic floor.

### Arbiter (turn granting)

- **One arbiter per salon channel** `FR-salon-single-arbiter`: Exactly one
  participant's watcher arbitrates a salon channel (designated in config),
  so turn-grant decisions are made once, not per-agent.
- **Two-outcome decision** `FR-salon-two-outcomes`: For each message, the
  arbiter either (a) silently taps exactly one agent to take a turn, or
  (b) grants nobody a turn, leaving the room to humans.
- **One winner invariant** `FR-salon-one-winner`: At most one agent is tapped
  per message. Non-selected agents' watchers skip the message.
- **Silence floor** `FR-salon-silence-floor`: Social/no-op messages and any
  low-confidence arbiter verdict resolve to "nobody talks". Talking must earn
  high confidence; wrong silence is acceptable, wrong interruption is not.
- **Selection is silent** `FR-salon-silent-tap`: The turn grant is delivered
  privately to the selected agent (channel-invisible), with a selection record
  written to the
  thread's blackboard for auditability.
- **Arbiter inputs** `FR-salon-arbiter-inputs`: Each decision uses the message,
  thread context, agent roster with specialties, and recent blackboard notes as
  reference state. Decisions return who_next, why, depth, and speak_now.

### Context depth

- **Depth levels** `FR-salon-depth`: The arbiter grants context depth:
  `message` (current message only, cold spawn), `thread` (thread history in
  the prompt), or `session` (resume the tapped agent's per-thread session).
- **Per-agent slots** `FR-salon-slots`: Each agent keeps its own harness
  session and worktree keyed to the thread (the existing per-thread slot
  design, one slot per (thread, agent)). No shared harness session.
- **Late joiners** `FR-salon-late-join`: An agent tapped for a thread it has
  no slot in starts a fresh slot seeded with thread history + blackboard.

### Send gate

- **Pre-send check** `FR-salon-send-gate`: For slow turns (>~30s compose) or
  turns where new thread messages arrived while composing, the watcher runs one
  arbiter check over (draft reply, messages since turn start) and returns
  send / adapt / defer / drop.
- **No ghosting** `FR-salon-no-ghosting`: A tapped agent explicitly asked a
  direct question never drops its reply for staleness; drop is reserved for
  "already answered by someone else" or "made moot".
- **Fail-open send** `FR-salon-send-failopen`: Any send-gate failure (no Jev,
  error, low confidence) posts the reply unchanged.
- **Drop is quiet** `FR-salon-drop-quiet`: A dropped reply posts nothing to the
  channel; its content is recorded in the shared scratch store so the arbiter
  can select it
  later.

### Shared scratch (blackboard)

- **Thread-scoped blackboard** `FR-salon-blackboard`: Each salon thread has a
  shared scratch store (a scratch channel) that all participants read and write
  (decisions, artifact pointers, selection records, discarded replies).
- **Arbiter reads blackboard** `FR-salon-arbiter-reads-blackboard`: The
  arbiter includes recent blackboard notes in its reference state.

## Acceptance Criteria

- [ ] **Flag-off identical** `AC-salon-flagoff-identical`: With
      `AGENT_SALON_CHANNELS` unset, eligibility-filter output on a fixture
      message set matches pre-salon output exactly.
- [ ] **Non-salon channel untouched** `AC-salon-nonsalon-untouched`: A watcher
      with salon enabled for channel A behaves identically to today in channel B.
- [ ] **No-Jev LLM rung** `AC-salon-nojev-llm`: With no Jev key and salon on,
      arbiter calls route to the harness one-shot and taps still occur.
- [ ] **No-key no-harness floor** `AC-salon-floor`: With no Jev key and no
      usable harness for the arbiter, salon channels behave as summon-only.
- [ ] **One winner** `AC-salon-one-winner`: For any single message in a salon
      channel, at most one agent is tapped (testable from tap records).
- [ ] **Silence default** `AC-salon-silence-default`: On a fixture banter/FYI
      message set, the arbiter taps nobody for all of them.
- [ ] **Silent selection** `AC-salon-silent-tap`: A selection produces a
  private notification to the selected
      agent and a blackboard record, and no channel-visible message.
- [ ] **No ghosting** `AC-salon-no-ghosting`: On a slow turn replying to a
      direct question with newer messages present, the reply posts (adapt,
      not drop).
- [ ] **Fail-open send gate** `AC-salon-send-failopen`: With the send gate
      backend unavailable, replies post unchanged.
