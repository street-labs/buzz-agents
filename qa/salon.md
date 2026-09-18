# Salon Mode - QA

Test cases trace to `product/salon.md` acceptance criteria.

## Compatibility (highest priority)

| Case | Trace | Steps | Expected |
|---|---|---|---|
| Flag-off identical | AC-salon-flagoff-identical | Run eligibility filter over fixture message set with `AGENT_SALON_CHANNELS` unset | Output identical to pre-salon baseline (golden file) |
| Mixed channels | AC-salon-nonsalon-untouched | Salon on for A; feed messages to B | B's behavior identical to baseline |

## Arbiter

| Case | Trace | Steps | Expected |
|---|---|---|---|
| Banter -> silence | AC-salon-silence-default | Fixture banter/FYI messages | verdict nobody |
| Direct question -> tap | AC-salon-one-winner | "@borg is the budget right?" | exactly one tap (borg) |
| Low confidence -> silence | AC-salon-silence-default | Mock low-confidence verdict | nobody |
| No Jev key -> LLM rung | AC-salon-nojev-llm | Unset key, mock harness | one-shot call made, verdict parsed |
| No Jev, no harness | AC-salon-floor | Unset key + harness unavailable | summon-only behavior |

## Tap / turn

| Case | Trace | Steps | Expected |
|---|---|---|---|
| Silent tap | AC-salon-silent-tap | Tap a winner | DM sent; blackboard record; no salon-channel message |
| Late joiner | FR-salon-late-join | Tap agent with no slot in thread | cold spawn seeded with thread + blackboard |

## Send gate

| Case | Trace | Steps | Expected |
|---|---|---|---|
| Direct question never dropped | AC-salon-no-ghosting | Slow turn answering a direct ask, newer msgs present | posts (possibly adapted), never drops |
| Drop on answered-elsewhere | FR-salon-drop-quiet | Mock gate verdict answered_elsewhere=high | no post; blackboard note written |
| Fail-open | AC-salon-send-failopen | Gate backend unavailable | reply posts unchanged |
