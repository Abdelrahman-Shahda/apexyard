# PRD: DFN Subscription Cycle Audit

**Status**: Approved
**Author**: Abdelrahman Shahda (PM hat, drafted via `/write-spec`)
**Created**: 2026-05-13
**Last Updated**: 2026-05-13
**Source**: IDEA-003 (`projects/ideas-backlog.md`) · Tracking issue: [apessolutions/dfn#81](https://github.com/apessolutions/dfn/issues/81)
**Related**: DFN handover assessment (`projects/dfn/handover-assessment.md`)

---

## Overview

### Problem Statement

The DFN user-subscription lifecycle has been under heavy refactor pressure in the last sprint — six commits in eight days touch shift / lock / extend / renew semantics, one of which broke CI on 2026-05-05 before being fixed on the next push. The implementation spans **two state enums**, **six domain entities**, **eight services**, **four scheduled/queued jobs**, a **per-subscription renewal queue**, and **three controller surfaces** (web-api, mobile-api, org), plus a dedicated **QA controller** with `time-warp`, `trigger-renewal`, and `provision` endpoints — strong evidence that "is this behaving as intended?" has been a recurring question for the team already.

Today there is no canonical document that answers, for any given (subscription state × event), what the expected next state and side effects are. New behaviour changes are landing on top of an unwritten contract. That makes regressions easy to ship, slow to detect, and expensive to debug.

This PRD scopes an **audit + documentation initiative** (not a product feature) whose deliverable is a behaviour matrix, a state-machine diagram, a regression test plan, and a triaged list of bugs / AgDR gaps the audit surfaces.

### Target User

**Primary**: DFN engineers (backend + data) who modify subscription behaviour — currently 6 active contributors, dominated by Abdelrahman Shahda, mofarag-apes, and Mahmoud3mmarr. They benefit from a written contract that prevents the next "did this commit break renewals?" moment.

**Secondary**:
- **DFN QA / Product** — gets an acceptance-matrix to run regression checks against before each release.
- **DFN customer-support / ops** — gets a state diagram to reason about "why is this user's subscription stuck?" tickets.
- **Future Tech Lead onboarding** (per the handover assessment) — the audit doc becomes the entry point for understanding subscriptions.

### Goals

1. **Produce a single canonical subscription state-machine document** in `libs/user-subscription/docs/state-machine.md` containing a Mermaid `stateDiagram-v2` covering both `UserSubscription` (3 states) and `UserSubscriptionPeriod` (5 states), with annotated transitions and triggers.
2. **Produce a behaviour matrix** — `(state, event) → (next state, side effects, idempotency key, transactional boundary)` — covering every transition reachable from the API surface, cron jobs, and queue processors.
3. **Reach ≥ 80% e2e test coverage of the matrix rows** via tests under `apps/web-api-e2e` and `apps/mobile-api-e2e`. Every "Must" row in the matrix must be locked by at least one test.
4. **File and prioritise every gap** the audit surfaces as discrete GitHub Issues on `apessolutions/dfn`, with severity (P0/P1/P2) and a one-line repro.
5. **Capture three retro-AgDRs** for the decisions that future maintainers will most want to understand: (a) "why two state enums (subscription vs period) rather than one", (b) "why renewal runs as a separate BullMQ queue with per-subscription jobs rather than a single cron sweep", (c) "why the freeze model is capped at MAX_FREEZE_DAYS=30 + MAX_FREEZES_PER_PERIOD=2".

### Non-Goals (Out of Scope)

- **Refactoring the implementation** — bugs found are *filed*, not *fixed*, in this initiative. Fixes are separate tickets with their own PRs.
- **Changing the state model** — the audit documents what exists; if "should the model change?" comes up, it produces a follow-up AgDR, not a code change in this PRD.
- **Payment-provider behaviour** — anything past the call into `libs/payment-provider` is out of scope; the audit covers subscription state, not payment state. Cross-store consistency (Postgres subscription state ↔ payment-provider state) is a *follow-up* RFC if the audit raises it.
- **The freeze-feature redesign** — if the audit shows MAX_FREEZES_PER_PERIOD=2 is wrong for the product, that is a separate product call.
- **Mobile-app UX changes** — only API contract is audited.
- **Performance optimisation** — cron job duration, queue depth, etc. are out unless they're correctness-affecting.

### Success Metrics

| Metric | Target | How Measured |
|--------|--------|--------------|
| Matrix coverage of reachable transitions | 100% of API endpoints + 100% of @Cron jobs + 100% of @Process handlers | Manual cross-walk: every endpoint / job / processor maps to ≥ 1 matrix row |
| E2E test coverage of "Must" matrix rows | ≥ 80% | `pnpm nx affected:e2e --base=development`; matrix rows tagged with the covering test file |
| Bugs filed | Every reproducible gap surfaces an issue | `gh issue list --label subscription-audit` count |
| Retro-AgDRs landed | 3 | Files in `docs/agdr/` matching `*subscription*` |
| Time to first reproduction of a future regression | < 30 min from "something feels off" to "row X in the matrix is violated, here's the test that proves it" | Self-reported by the next engineer who hits a regression |

---

## User Stories

### US-1: Engineer documents the subscription state machine

> As a **DFN backend engineer**, I want to **read a single Mermaid diagram of UserSubscription + UserSubscriptionPeriod states and the transitions between them**, so that **I don't have to re-discover the model every time I touch the renewal code**.

**Acceptance Criteria**:

- [ ] `libs/user-subscription/docs/state-machine.md` exists and renders on GitHub
- [ ] Both enums are represented (`UserSubscriptionStatusEnum`: ACTIVE / CANCELLED / REFUNDED; `SubscriptionPeriodStatusEnum`: PENDING / ACTIVE / GENERATING / COMPLETED / CANCELLED)
- [ ] Every transition is labelled with the trigger (API endpoint, cron job, queue processor, or domain event)
- [ ] Terminal states (CANCELLED, REFUNDED, COMPLETED) are visually distinct
- [ ] The relationship between a `UserSubscription` and its `UserSubscriptionPeriod`s (1:N, lifecycle dependency) is shown or explained alongside

### US-2: Engineer reads the behaviour matrix before changing behaviour

> As a **DFN backend engineer**, I want **a `(state, event) → (next state, side effects)` matrix that tells me exactly what each transition is supposed to do**, so that **I can write or modify code with the contract in front of me and review my own diffs against it**.

**Acceptance Criteria**:

- [ ] Matrix in `libs/user-subscription/docs/behaviour-matrix.md`
- [ ] Columns: From State · Event · To State · Side Effects · Idempotency Key · Transactional? · Notes · Covering Test
- [ ] Every public API endpoint (`web-api`, `mobile-api`, `org`) maps to ≥ 1 row
- [ ] Every `@Cron` job maps to ≥ 1 row
- [ ] Every `@Process` handler on `RENEWAL_QUEUE` and `JOB_QUEUE` maps to ≥ 1 row
- [ ] "Covering Test" column links to a file path + test name, or marks "MISSING" → opens an issue

### US-3: QA runs the matrix as a regression suite before releases

> As **DFN QA**, I want **the behaviour matrix executable as an e2e suite**, so that **a release blocker can be pinpointed to a specific matrix row in under five minutes**.

**Acceptance Criteria**:

- [ ] At least one e2e test exists per "Must" row
- [ ] Tests are tagged so `pnpm nx run web-api-e2e:test --testPathPattern=subscription` runs the audit suite as a unit
- [ ] CI report names the matrix row when a test fails (e.g. via `describe('M-014: ACTIVE × cron-expiry-scan → renewal queued', …)`)
- [ ] The QA controller's `time-warp` endpoint is used to drive cron-triggered transitions deterministically

### US-4: Support resolves a stuck-subscription ticket using the diagram

> As **DFN customer support / ops**, I want **a state diagram I can point at**, so that **I can answer "why is this user's period stuck in `GENERATING`?" without escalating to engineering**.

**Acceptance Criteria**:

- [ ] State diagram is linked from the project README
- [ ] Every non-terminal state has a "how to inspect" note (which table / which field)
- [ ] At least three real recent support cases are walked through in `libs/user-subscription/docs/troubleshooting.md` using the diagram

### US-5: New engineer onboards via the audit doc

> As a **new DFN engineer**, I want **the audit doc to be the canonical entry point for the subscription module**, so that **I can ship my first subscription-related PR in week one rather than week three**.

**Acceptance Criteria**:

- [ ] `libs/user-subscription/README.md` opens with a link to the state machine + matrix
- [ ] The doc set is referenced from `projects/dfn/README.md` in the ApexYard ops repo

### Edge Cases (initial list — the audit will expand this)

| Scenario | Expected Behaviour (to verify in audit) |
|----------|-----------------------------------------|
| Auto-renewal cron runs while a user is freezing the same period | Freeze short-circuits renewal? Renewal proceeds and freeze is denied? Either is fine, but it must be one of them — documented + tested |
| Renewal job re-runs after a transient failure (BullMQ retry) | Idempotent — the second run is a no-op (no double-charge, no duplicate periods) |
| Admin cancels a subscription whose renewal job is already enqueued | Enqueued job sees CANCELLED status and exits cleanly (no orphan period created) |
| `time-warp` jumps the clock past `DAYS_BEFORE_EXPIRY` mid-cron-run | Defined behaviour — does the running cron still pick up the now-expired subscription? |
| Period in `GENERATING` for > N minutes (worker crashed mid-generation) | Recovered by `HandleSubscriptionPeriodGenerationJob` retrying? Stuck forever? Manual recovery? |
| User has MAX_FREEZES_PER_PERIOD = 2 freezes, then a period boundary rolls; new period inherits how many freezes? | Reset to 0 per new period (suggested by name) — must be confirmed |
| Refund issued in payment provider but `UserSubscription.status` not yet REFUNDED | Reconciliation job? Manual sync? Drift tolerated? |
| Concurrent: admin shifts period dates while user is mid-toggle-freeze API call | Locking? Last-write-wins? Optimistic concurrency? |
| Refill data POST during a period status transition | Refill applied to old period or new? |
| QA `reset` endpoint called on a user mid-active-subscription | Idempotent destructive reset, or does it leave orphans? |

---

## Requirements

### Functional Requirements

| ID | Requirement | Priority | Notes |
|----|-------------|----------|-------|
| FR-1 | Produce `libs/user-subscription/docs/state-machine.md` containing one Mermaid `stateDiagram-v2` per enum + a relationship explainer | Must | |
| FR-2 | Produce `libs/user-subscription/docs/behaviour-matrix.md` with the 8-column row format described in US-2 | Must | |
| FR-3 | Map every controller endpoint (web-api / mobile-api / org / org/qa) to ≥ 1 matrix row | Must | 22+ endpoints identified in initial scan |
| FR-4 | Map every `@Cron` job (auto-renewal, period generation, missed refills, completed periods) to ≥ 1 matrix row | Must | 4 jobs identified |
| FR-5 | Map every BullMQ `@Process` handler (RENEWAL_QUEUE.process-subscription-renewal, JOB_QUEUE.*) to ≥ 1 matrix row | Must | |
| FR-6 | Identify and document idempotency keys / transactional boundaries per transition | Must | `@Transactional()` decorator usage in `update-completed-subscription-periods-job` is a starting reference |
| FR-7 | File a GitHub issue per gap (missing test, ambiguous behaviour, suspected bug, missing AgDR) with label `subscription-audit` and severity P0/P1/P2 | Must | |
| FR-8 | Write e2e tests for every "Must" matrix row missing coverage, under `apps/web-api-e2e` and `apps/mobile-api-e2e` | Should | 80% target, not 100% — Tech Design Phase may scope down |
| FR-9 | Capture three retro-AgDRs (two-enum model, per-subscription renewal queue, freeze caps) under `docs/agdr/` | Should | |
| FR-10 | Produce `libs/user-subscription/docs/troubleshooting.md` with 3 walked-through support cases | Should | Pulls from existing support backlog if accessible |
| FR-11 | Add Mermaid sequence diagrams for the 3 most complex flows (renewal, period generation, freeze toggle) | Could | |
| FR-12 | Wire matrix rows to test IDs so a failing test names the matrix row in CI output | Could | Naming convention: `describe('M-NNN: …')` |

**Priority Key**: Must (required for the audit to be considered "done") · Should (important — defer with Tech-Lead sign-off only) · Could (stretch)

### Non-Functional Requirements

| Category | Requirement | Target |
|----------|-------------|--------|
| Documentation | Diagrams render natively on GitHub | Mermaid only, no PNGs or external tools |
| Test isolation | E2E tests don't leak between runs | Each test creates + cleans up its own user via the existing `qa/users/:userId/reset` + `provision` endpoints |
| Test determinism | Cron / time-based transitions are testable without sleeping | Use the existing `qa/:userSubscriptionId/time-warp` endpoint; never `setTimeout` in tests |
| Audit reversibility | No code in `libs/user-subscription/src/**` is modified by this initiative (only `docs/`, `*.spec.ts`, new test apps) | Reviewed at PR time — if implementation changes, split into a separate ticket |
| Discoverability | Audit docs are linked from `libs/user-subscription/README.md` and `projects/dfn/README.md` | Verified at PR review |

---

## Design

### Audit workflow (the process the engineer follows)

```
[ Start ]
    |
    v
[ 1. Catalogue surface: list every endpoint, cron, processor that touches subscriptions ]
    |
    v
[ 2. Draw the state machine from the enums + transition sites ]
    |
    v
[ 3. Cross-walk surface → state-machine: every event from step 1 maps to >= 1 transition ]
    |
    v
[ 4. Build the matrix row-by-row, marking "unknown" / "ambiguous" where the code doesn't tell a clear story ]
    |
    +---> [ Ambiguity / suspected bug ] ---> [ File issue, label subscription-audit, severity P0/P1/P2 ]
    |
    v
[ 5. For each "Must" matrix row: confirm or write the covering test ]
    |
    v
[ 6. Capture retro-AgDRs for the three load-bearing design decisions ]
    |
    v
[ 7. Link docs from README + project README; PR for review ]
    |
    v
[ Done — initiative wraps when all "Must" rows are tested or excused, and the doc set lands on `development` ]
```

### State machine — initial sketch (the audit will refine this)

```
UserSubscription:
  ACTIVE  --user.cancel-->        CANCELLED   (terminal)
  ACTIVE  --admin.refund-->       REFUNDED    (terminal)
  ACTIVE  --cron.auto-renewal-->  ACTIVE      (new period spawned, same parent stays ACTIVE)

UserSubscriptionPeriod:
  PENDING    --period-start-date reached / cron-->  GENERATING
  GENERATING --plan-generation-success-->           ACTIVE
  GENERATING --plan-generation-failure-->           ??? (audit TBD — retry? failed state?)
  ACTIVE     --period-end-date reached / cron-->    COMPLETED   (terminal-ish)
  ACTIVE     --user.toggle-freeze-->                ACTIVE      (with freeze record; counts toward MAX_FREEZES_PER_PERIOD)
  ACTIVE     --admin.shift-dates-->                 ACTIVE      (dates mutated)
  ACTIVE     --parent.cancel-->                     CANCELLED   (terminal)
  *          --admin.qa-reset-->                    (destroyed)
```

This is a hypothesis. The audit's first deliverable is to **confirm or correct** this sketch by reading the actual transition sites.

### Behaviour-matrix row template

| ID | From State | Event | To State | Side Effects | Idempotent? | Transactional? | Covering Test | Notes |
|----|------------|-------|----------|--------------|-------------|----------------|---------------|-------|
| M-001 | UserSubscription:ACTIVE | DELETE /v1/user-subscriptions/cancel | UserSubscription:CANCELLED | • All ACTIVE periods → CANCELLED<br>• Enqueued renewal jobs are no-ops | Yes — second call returns 200 with no change | Yes — wrapped in `@Transactional()` | _MISSING — file issue_ | |

---

## Technical Notes

### Dependencies

| Dependency | Type | Status | Owner |
|------------|------|--------|-------|
| `libs/user-subscription` source code | Internal | Ready (read-only) | DFN backend |
| QA controller endpoints (`time-warp`, `trigger-renewal`, `provision`, `reset`) | Internal | Ready | DFN backend |
| `libs/transaction`, `libs/payment-provider` | Internal | Read-only — used to confirm payment side-effect boundaries | DFN backend |
| Postgres (TypeORM) + Mongo (Mongoose) | Internal | Local docker-compose | DFN data |
| BullMQ + Redis | Internal | Local docker-compose | DFN data |
| GitHub Issues (`apessolutions/dfn`) | External | Ready | — |
| Existing AgDR template (`templates/agdr.md`) | ApexYard | Ready | — |

### Technical constraints

- **Read-only audit**: production source files in `libs/user-subscription/src/**` MUST NOT be modified by this initiative. Only `libs/user-subscription/docs/**`, new `*.spec.ts` files, and new e2e test files are in-bounds. If the audit surfaces a bug, the fix is a separate ticket with its own PR.
- **Mermaid only** for diagrams — renders on GitHub without a build step, consistent with `templates/architecture/c4-container.md`.
- **Deterministic tests** — every time-based transition must be driven by the `time-warp` endpoint, never `setTimeout` / real wall-clock.
- **Idempotency assumptions**: BullMQ jobs retry by default; matrix MUST identify which transitions are safe to retry and which need an idempotency key.
- **Cross-store concerns** flagged but not solved: TypeORM (Postgres) holds subscription state; Mongoose (Mongo) holds period data; if the audit surfaces "what happens if Postgres commits but Mongo write fails?", that becomes a separate RFC.

---

## Launch Plan

### Rollout Strategy

- [x] **No production rollout** — the deliverable is documentation and tests; nothing user-facing ships.

### Phased delivery

| Phase | Deliverable | Exit criteria |
|-------|-------------|---------------|
| Phase 1 — Catalogue (~ 2 days) | List of every endpoint, cron, processor; first draft of state-machine.md | Reviewed by 1 other backend engineer |
| Phase 2 — Matrix (~ 3 days) | behaviour-matrix.md with every Must row populated, "Covering Test" filled in or marked MISSING | PR open against `development` |
| Phase 3 — Tests (~ 3 days) | E2E coverage to 80% of Must rows | `pnpm nx run web-api-e2e:test` and `pnpm nx run mobile-api-e2e:test` green on CI |
| Phase 4 — AgDRs (~ 1 day) | 3 retro-AgDRs landed in `docs/agdr/` | Linked from the audit doc |
| Phase 5 — Wrap (~ 0.5 day) | Linked from READMEs, follow-up issues triaged, initiative closes | DFN#81 closes; per-bug issues remain open |

Total: ~9 engineer-days.

---

## Open Questions

| Question | Owner | Status | Resolution |
|----------|-------|--------|------------|
| Are there support tickets describing real stuck-subscription / failed-renewal incidents that should drive the audit's edge-case list? | DFN support / ops | Open | If yes, pull last 3 months of `subscription` tickets and incorporate |
| Should the audit also cover the **transaction** lifecycle (cart → transaction → subscription) or stop at the subscription boundary? | Tech Lead | Open | Default = stop at subscription boundary; expand only if cross-cutting bugs found |
| Where do **MEAL** and **WORKOUT** plan-generation failures interact with period `GENERATING` state? | Tech Lead | Open | The audit must answer this — it's the trickiest part of the existing model |
| `update-completed-subscription-periods-job` excludes `COMPLETED` and `CANCELLED` — is there an unhandled state? Should `GENERATING` periods that have crossed their end-date be auto-completed or auto-failed? | Backend engineer | Open | Direct audit finding expected here |
| Does the team want this audit's docs in `libs/user-subscription/docs/` (lives with code) or in `projects/dfn/docs/` (lives in ops repo)? | DFN lead | Open | Recommendation: **lives with code** so it follows the codebase if it ever spins out. Mirror a pointer from `projects/dfn/README.md` |
| Should the freeze-caps (`MAX_FREEZE_DAYS=30`, `MAX_FREEZES_PER_PERIOD=2`) be configurable per package? | Head of Product | Open | Defer to a follow-up PRD if the audit surfaces demand |
| Is there a known SLO on renewal latency (e.g. "no user sees a period gap > 1 hour around renewal")? | Head of Product / SRE | Open | If yes, codify as a non-functional requirement; if no, flag as a missing SLO |

---

## Timeline

| Milestone | Target Date | Status |
|-----------|-------------|--------|
| PRD Approved | 2026-05-15 | Pending |
| Phase 1 — Catalogue + state-machine.md | 2026-05-19 | Not started |
| Phase 2 — behaviour-matrix.md complete | 2026-05-22 | Not started |
| Phase 3 — E2E coverage ≥ 80% of Must rows | 2026-05-27 | Not started |
| Phase 4 — 3 retro-AgDRs landed | 2026-05-28 | Not started |
| Phase 5 — Wrap, READMEs linked, initiative closes | 2026-05-29 | Not started |

(Dates assume one engineer at 60% allocation. Adjust at Tech Design phase.)

---

## Approvals

| Role | Name | Date | Status |
|------|------|------|--------|
| Product Manager | Abdelrahman Shahda (PM hat) | 2026-05-13 | Author |
| Head of Product | Abdelrahman Shahda | 2026-05-13 | Approved |
| Tech Lead | Abdelrahman Shahda (Tech Lead hat) | 2026-05-13 | Approved — handed off to Tech Design `td-subscription-cycle-audit.md` for effort estimation + scope confirm |
| Head of Design | n/a | n/a | Not applicable (no UI) |
| Head of Engineering | Abdelrahman Shahda | 2026-05-13 | Approved — read-only-on-src constraint + `qa/*` extension carve-out accepted |
