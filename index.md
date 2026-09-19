# Traceability Index

This file maps every requirement slug to all files that define or reference it. It is the single source of truth for requirement traceability across the project.

**Slug types:**
- `FR-` — Functional requirements (defined in `product/`)
- `NFR-` — Non-functional requirements (defined in `product/`)
- `AC-` — Acceptance criteria (defined in `product/`)
- `TC-` — Test cases (defined in `qa/`)

**Agent rule:** Every agent must update this file when they create or reference a slug. This is not optional.

| Slug | Type | Spec | References | Code |
|---|---|---|---|---|
| FR-salon-off-default | FR | product/salon.md | engineering/salon.md |  |
| FR-salon-flagoff-equivalence | FR | product/salon.md | engineering/salon.md |  |
| FR-salon-arbiter-ladder | FR | product/salon.md | engineering/salon.md |  |
| FR-salon-nojev-safe | FR | product/salon.md | engineering/salon.md |  |
| FR-salon-single-arbiter | FR | product/salon.md | engineering/salon.md |  |
| FR-salon-two-outcomes | FR | product/salon.md | engineering/salon.md |  |
| FR-salon-one-winner | FR | product/salon.md | engineering/salon.md |  |
| FR-salon-silence-floor | FR | product/salon.md | engineering/salon.md |  |
| FR-salon-silent-tap | FR | product/salon.md | engineering/salon.md |  |
| FR-salon-arbiter-inputs | FR | product/salon.md | engineering/salon.md |  |
| FR-salon-next-speaker | FR | product/salon.md | engineering/salon.md |  |
| FR-salon-human-to-human | FR | product/salon.md | engineering/salon.md |  |
| FR-salon-agent-turn-cap | FR | product/salon.md | engineering/salon.md |  |
| FR-salon-depth | FR | product/salon.md | engineering/salon.md |  |
| FR-salon-slots | FR | product/salon.md | engineering/salon.md |  |
| FR-salon-late-join | FR | product/salon.md | engineering/salon.md |  |
| FR-salon-send-gate | FR | product/salon.md | engineering/salon.md |  |
| FR-salon-no-ghosting | FR | product/salon.md | engineering/salon.md |  |
| FR-salon-send-failopen | FR | product/salon.md | engineering/salon.md |  |
| FR-salon-drop-quiet | FR | product/salon.md | engineering/salon.md |  |
| FR-salon-blackboard | FR | product/salon.md | engineering/salon.md |  |
| FR-salon-arbiter-reads-blackboard | FR | product/salon.md | engineering/salon.md |  |
| AC-salon-flagoff-identical | AC | product/salon.md | qa/salon.md |  |
| AC-salon-nonsalon-untouched | AC | product/salon.md | qa/salon.md |  |
| AC-salon-nojev-llm | AC | product/salon.md | qa/salon.md |  |
| AC-salon-floor | AC | product/salon.md | qa/salon.md |  |
| AC-salon-one-winner | AC | product/salon.md | qa/salon.md |  |
| AC-salon-silence-default | AC | product/salon.md | qa/salon.md |  |
| AC-salon-silent-tap | AC | product/salon.md | qa/salon.md |  |
| AC-salon-no-ghosting | AC | product/salon.md | qa/salon.md |  |
| AC-salon-send-failopen | AC | product/salon.md | qa/salon.md |  |
