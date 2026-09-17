# Salon Mode - Engineering

Implements `product/salon.md` per `design/salon.md`.

## Tasks

1. **Config + docs** `ENG-salon-config`: `AGENT_SALON_CHANNELS`,
   `AGENT_SALON_ARBITER` (name of the arbitrating agent), `SALON_SPEAK_MIN`,
   `JEV_CONF_MIN` reuse; example.env + README entries.
2. **Arbiter helper** `ENG-salon-arbiter`: `salon-arbiter.py` (stdlib only),
   Jev backend, fail-open (empty output, exit 1), same shape as
   `jev-triage.py`. Roster passed as reference state.
3. **LLM rung** `ENG-salon-llm-rung`: watcher-side one-shot harness call that
   prompts for the same JSON verdict; used when the Jev call returns nothing.
   Reuse `invoke_harness` with a minimal prompt; parse JSON defensively.
4. **Deterministic floor** `ENG-salon-floor`: in-salon fast paths (explicit
   mention -> tap; else silence when no arbiter verdict exists).
5. **Tap transport** `ENG-salon-tap`: DM the tapped agent with a
   machine-readable tap message; tapped watcher processes it in-thread (reuses
   existing worker spawn with depth from the tap). Tap + drops recorded on the
   blackboard channel.
6. **Send gate** `ENG-salon-send-gate`: pre-send hook in the worker reply
   pipeline: if turn slow or new thread messages since start, run gate call;
   apply outcome; drop writes a blackboard note instead of posting. Direct
   questions are never dropped (only adapt).
7. **Install wiring** `ENG-salon-install`: Justfile + new-agent.sh ship
   `salon-arbiter.py`.
8. **Compatibility tests** `ENG-salon-tests`:
   - `test-salon-flagoff.sh`: filter behavior with flag unset == baseline.
   - Arbiter unit tests: fixture verdicts (banter -> nobody, direct question ->
     tap, low confidence -> nobody).
   - Send-gate unit tests: direct-question never dropped; fail-open posts.

## Order

1 -> 2 -> 8 (unit) -> 4 -> 5 -> 6 -> 3 -> 7. Ship the flag + arbiter + taps as
the first PR slice; send gate and LLM rung can follow within the same feature
branch.
