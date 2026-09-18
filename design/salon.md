# Salon Mode - Design

See `product/salon.md` for requirements (FR-salon-*, AC-salon-*). This doc
fixes the shape, not the code.

## Components

1. **Salon config** (`agent-watcher.sh` env): `AGENT_SALON_CHANNELS` (space-
   separated ids), `AGENT_SALON_ROLES` (per channel: which agent arbitrates).
   Default empty => existing path.
2. **Arbiter** (`salon-arbiter.py`, sibling of `jev-triage.py`): stateless
   one-call decision helper. Same fail-open contract as jev-triage.py: prints a
   JSON verdict or nothing. Backends in order: Jev endpoint -> harness one-shot
   (executed by the watcher, not the script) -> nothing (deterministic floor
   lives in the watcher).
   - Tap call questions: `who_next` (choice: roster + human + nobody), `why`
     (choice: asked / correcting / expertise / social / nothing_to_me),
     `depth` (score: message / thread / session), `speak_now` (noul).
   - Send-gate call questions: `outcome` (choice: send / adapt / defer / drop),
     `answered_elsewhere` (noul). Only run when turn was slow or new messages
     arrived.
3. **Salon path in the watcher**: when a message arrives in a salon channel,
   the arbiter (the designated agent's watcher) decides and taps by DM
   (`buzz dms`/`messages send` to the agent's DM channel) with a machine-
   readable instruction (thread root, depth). Every participant watcher honors
   taps and treats "not tapped" as skip. Tap records + dropped drafts post to
   the blackboard channel (a dedicated scratch channel per salon channel).
4. **Slots**: reuse the existing per-thread session/worktree mapping, keyed
   additionally by agent identity (agents already have their own state dirs,
   so no data change - only the tap source differs from mention rules).

## Decision rules (deterministic edges)

- Explicit @mention/p-tag in a salon channel: tap that agent, skip arbiter
  latency (fast path; record it as `why=asked`).
- `why` in {social, nothing_to_me}: nobody, regardless of speak_now.
- `speak_now` below `SALON_SPEAK_MIN` (default 0.8): nobody.
- Low confidence on any answer: nobody (tap side) / send unchanged (gate side).

## Loop safety

- Only the arbiter grants turns. Watchers never self-elect in salon channels.
- Tap DMs are machine-tagged so the tapped watcher answers in-thread without
  re-arbitrating its own tap.
- The arbiter never taps for messages it itself generated.

## Deliberately out of scope (first cut)

- Typing indicators (needs relay change; the tap ack stays the 👀 reaction).
- Cross-thread arbiter memory beyond the blackboard.
- Agent-to-agent multi-turn rallies without a human message in between
  (each agent turn must trace to a human message or an arbiter re-tap).
