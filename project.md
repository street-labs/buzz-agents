# <Project Name>

## What this is
TODO: 2-4 sentences. What the product does, who it's for.

## Platforms
TODO: the platforms this project targets (from pdeq.json).

## Tech stack
TODO: one paragraph or short list. The engineering choices the project made.

## Standing specs
Cross-cutting specs every builder MUST respect, regardless of feature.

| Spec | Lane / Path | Governs |
|---|---|---|

## How to operate
- **Build a feature:** `/pdeq-kickoff <description>` — product → design → engineering → QA, one lane at a time.
- **Cardinal rule:** markdown first, code second. Change the spec, then the code — never the reverse.
- **Decisions:** append to `decisions-pending.md`; the pre-commit hook merges into `decisions.md` at commit time.
- **Traceability:** update `index.md` when you create or reference a requirement slug.
- **Audits:** `./scripts/audit-traceability.sh` (and lane/structure/temporal/coverage audits). The pre-commit hook runs the blocking ones.
