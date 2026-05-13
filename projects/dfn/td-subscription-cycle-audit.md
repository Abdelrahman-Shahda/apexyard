# Technical Design: DFN Subscription Cycle Audit

**Status**: Approved
**Author**: Abdelrahman Shahda (Tech Lead hat, drafted via Tech Design phase)
**Date**: 2026-05-13
**PRD**: [`projects/dfn/prd-subscription-cycle-audit.md`](prd-subscription-cycle-audit.md)
**Tracking issue**: [apessolutions/dfn#81](https://github.com/apessolutions/dfn/issues/81)
**Phase**: SDLC Phase 2 — Technical Design

---

## Overview

### Summary

The PRD scopes a read-only audit of the DFN user-subscription lifecycle whose deliverables are documentation (state machine + behaviour matrix + troubleshooting), regression tests, and three retro-AgDRs. **No production source under `libs/user-subscription/src/**` is modified.** This design pins down how the audit is executed: the catalogue method, the matrix schema, the test harness that exploits the existing QA endpoints, the issue-filing protocol for surfaced gaps, and the task / estimate breakdown.

This document hands off to Backend Engineer + Data Engineer for execution. There is no Frontend, Design, or SRE phase — this is a backend-only documentation + test initiative.

### Goals

- Operationalise the PRD's 5 goals into concrete tasks with code-anchored entry points.
- Set hard ground rules for the team — read-only on src, deterministic time-driven tests via `time-warp`, file-don't-fix discipline.
- Land an executable matrix where every "Must" row is a real Jest `describe` block, so a future regression names the matrix row in CI failure output.
- Decompose into ~12 implementation tickets the Backend Engineer can pick up sequentially.

### Non-Goals

- Designing or proposing a *new* state machine. We document the existing one.
- Building a custom test harness. We use Jest + the existing `*-e2e` Nx targets + the existing `qa/*` controller. Anything beyond that is YAGNI for this audit.
- Performance work on the cron / queue jobs. Not in scope unless correctness is affected.
- Cross-store (Postgres ↔ Mongo) consistency design. Flag if surfaced; do not solve.

---

## Domain Model

The audit covers an existing model. The design does not change it; it documents it. Anchor points the audit must produce diagrams + matrix rows for:

### Entities (existing, read from `libs/user-subscription/src/lib/domain/`)

```
UserSubscription
├── id: number
├── status: UserSubscriptionStatusEnum (ACTIVE | CANCELLED | REFUNDED)
├── user: User
├── package: Package
├── currency: Currency
├── startDate: Date
├── endDate: Date
└── 1:N → UserSubscriptionPeriod

UserSubscriptionPeriod
├── id: number
├── userSubscriptionId: number
├── status: SubscriptionPeriodStatusEnum (PENDING | ACTIVE | GENERATING | COMPLETED | CANCELLED)
├── periodNumber: integer
├── startDate: Date
├── endDate: Date
├── 1:1 → UserSubscriptionPeriodData
└── 1:N → UserSubscriptionPeriodFreeze (cap: MAX_FREEZES_PER_PERIOD = 2)

UserSubscriptionPeriodData
└── (per-period generated artefacts — meal plans, workout plans, etc.; see UserSubscriptionPeriodDataMuscleInjury)

UserSubscriptionPeriodFreeze
├── periodId: number
├── freezeStartDate: Date  (default: now)
└── freezeEndDate: Date    (default: now + MAX_FREEZE_DAYS = 30)

UserSubscriptionBenefit
└── (per-subscription benefit ledger — out of audit primary scope; cross-reference if surfaced)
```

### Value-shape unions already in code (the audit should anchor matrix outcomes to these)

The codebase has already introduced two typed outcome unions which the audit must use as canonical event-results:

```ts
// libs/user-subscription/src/lib/application/processors/renew-subscription.processor.ts
type RenewalOutcome =
  | { outcome: 'renewed'; newSubscriptionId: number }
  | { outcome: 'skipped'; reason:
      'subscription-not-active' | 'no-card-token' | 'not-in-renewal-window' | 'already-renewed' }
  | { outcome: 'failed'; reason: string; providerMessage?: string };

// libs/user-subscription/src/lib/application/jobs/handle-subscription-period-generation.job.ts
type PeriodGenerationOutcome =
  | { outcome: 'generated'; period: {...} }
  | { outcome: 'skipped'; reason:
      'subscription-not-active' | 'no-current-period' | 'frozen' |
      'not-in-window' | 'would-exceed-subscription-end' | 'already-exists' };
```

**Implication for the audit**: every renewal-event matrix row and every period-generation matrix row enumerates against the union members directly. This is a "the model already names its own edge cases" win — the matrix doesn't have to invent them.

### Domain events (implicit; no formal event bus is used)

| Event | Trigger site | Data |
|-------|--------------|------|
| Subscription expiring within 2 days | `HandleSubscriptionAutoRenewalJob.processJob` (cron, `EVERY_DAY_AT_MIDNIGHT`, `DAYS_BEFORE_EXPIRY=2`) | `subscriptionId` enqueued to `RENEWAL_QUEUE` |
| Period nearing refill | `HandleSubscriptionPeriodGenerationJob.processJob` (cron, midnight, `DAYS_TO_CHECK_AHEAD=4`) | Period IDs that may need a successor |
| Period reached `endDate` | `UpdateCompletedSubscriptionPeriodsJob.processJob` (cron, midnight) | Periods marked COMPLETED |
| Refill data accepted | `POST /v1/user-subscriptions/refill/data` | Per-user — touches `UserSubscriptionPeriodData` |
| Freeze toggled | `PUT /v1/user-subscriptions/periods/toggle-freeze` | Creates / updates `UserSubscriptionPeriodFreeze` |
| Cancellation | `DELETE /v1/user-subscriptions/cancel` (user) · `PUT /v1/user-subscriptions/:id/cancel` (admin) | Calls `CancelUserSubscriptionService.cancel`; uses Paymob refund |

---

## Architecture

### Audit component diagram (the test harness)

```
                ┌──────────────────────────────────────────────────────────┐
                │  apps/web-api-e2e  ·  apps/mobile-api-e2e (Jest + Nx)    │
                │                                                          │
                │  describe('M-NNN: <From-State> × <Event> → <To-State>')  │
                │     ├─ provision user (qa/users/:userId/provision)       │
                │     ├─ drive event (real endpoint or qa/* trigger)       │
                │     ├─ time-warp if needed (qa/:id/time-warp)            │
                │     ├─ assert next state via current/subscription, etc.  │
                │     └─ reset (qa/users/:userId/reset)                    │
                └──────────────────────────────────────────────────────────┘
                                          │
                                          ▼
                ┌──────────────────────────────────────────────────────────┐
                │  apps/web-api  ·  apps/mobile-api  ·  apps/org           │
                │  Real NestJS app under test (no behaviour change)        │
                └──────────────────────────────────────────────────────────┘
                                          │
                                          ▼
                ┌──────────────────────────────────────────────────────────┐
                │  Postgres (TypeORM)   Mongo (Mongoose)   Redis (BullMQ)  │
                │  Docker-compose locally + a per-test ephemeral schema    │
                │  (or per-test cleanup via the existing qa/reset)         │
                └──────────────────────────────────────────────────────────┘
```

The audit **does not introduce a new test framework**. It uses what's already there: Jest, Nx `*-e2e` apps, the QA controller (`time-warp`, `trigger-renewal`, `trigger-period-generation`, `reset`, `provision`).

### Data flow inside a single matrix-row test

```
[ Test setup ]
    └─ qa/users/:userId/provision    → puts a user into a known start state
            │
            ▼
[ Drive the event ]
    └─ Hit the real endpoint (user / admin)
        OR a cron trigger via:
          • POST /v1/qa/user-subscriptions/:id/trigger-renewal
          • POST /v1/qa/user-subscriptions/:id/trigger-period-generation
          • POST /v1/qa/user-subscriptions/:id/time-warp { offsetDays: N }
            │
            ▼
[ Wait for queue settlement (deterministic) ]
    └─ Drain RENEWAL_QUEUE + JOB_QUEUE — no real waits; use BullMQ test utilities
            │
            ▼
[ Assert ]
    └─ GET /v1/user-subscriptions/current/subscription   (status)
       GET /v1/user-subscriptions/current/period          (period status)
       Direct repo read for side-effect rows (transactions, freezes, periods)
            │
            ▼
[ Cleanup ]
    └─ qa/users/:userId/reset
```

**Critical design choice**: every time-based transition is driven via `time-warp`. No `setTimeout`, no `jest.useFakeTimers` against the cron — the cron uses `SchedulerRegistry` and the existing QA harness already accounts for that. This is the only way to keep e2e tests deterministic in CI.

---

## Behaviour Matrix — schema and storage

### File

`libs/user-subscription/docs/behaviour-matrix.md` (lives with the code per PRD Open-Question Q5 recommendation).

### Row format

```markdown
| ID | From State | Event | To State | Side Effects | Idempotent | Transactional | Covering Test | Notes |
```

### Conventions

- **ID** — `M-NNN`, three-digit, zero-padded, monotonically assigned in catalogue order. Once issued, never reused.
- **From / To State** — `UserSubscription:ACTIVE`, `Period:GENERATING`, etc. Use `*` for "any non-terminal".
- **Event** — one of:
  - `HTTP <METHOD> <path>` (user-driven)
  - `Cron <job-name>`
  - `Queue <queue>.<job>`
  - `QA <endpoint>` (admin-only diagnostic transitions)
- **Side Effects** — bullet list, prefixed `• ` inside the cell. Include row writes to `UserSubscriptionPeriod`, `UserSubscriptionPeriodFreeze`, `Transaction`, calls to `PaymentProvider`, audit-log writes.
- **Idempotent** — `Yes` / `No` / `Yes-with-key:<key>`. If `No`, the matrix MUST note the observed error (e.g. "second call throws ConflictException"). This is a known finding for `CancelUserSubscriptionService.cancel` — it throws `ConflictException` if `status !== ACTIVE`, so cancel is **not** idempotent at the public boundary.
- **Transactional** — `Yes (@Transactional)` / `Yes (manual)` / `No`. Map to the actual decorator presence.
- **Covering Test** — `apps/<app>-e2e/src/.../<file>.spec.ts::<describe-name>` OR `MISSING — issue #N` if no test exists yet. Every `MISSING` MUST file an issue before the matrix row is "done".

### Initial catalogue (the audit will produce the full version)

Anchors confirmed from the code scan:

| Source | Count | Notes |
|--------|-------|-------|
| `web-api` controller endpoints touching subscriptions | 7 | `cancel`, `current/subscription`, `current/period`, `periods/freezes`, `periods/toggle-freeze`, `refill/data`, plus list/get |
| `mobile-api` controller endpoints | ~6 | Mirrors web-api; subset of mutations |
| `org` admin endpoints | ~8 | Create, get, cancel, toggle-freeze, periods/data, etc. |
| `org/qa` QA harness endpoints | 5 | `time-warp`, `trigger-renewal`, `trigger-period-generation`, `reset`, `provision` |
| `@Cron` jobs | 4 | auto-renewal · period-generation · missed-refills · update-completed-periods |
| `@Process` handlers | ≥ 2 | `RENEWAL_QUEUE.process-subscription-renewal` + JOB_QUEUE handlers |

→ Expected matrix row count: **35–50**. Of those, ~25–30 are "Must" (covering the documented happy paths + concurrency / idempotency edges).

---

## API Design

No new API. The audit consumes existing APIs only. Endpoint catalogue (compiled from `apps/*/src/app/modules/user-subscriptions/controllers/v1/`):

| Method | Path | Surface | Purpose | Auth |
|--------|------|---------|---------|------|
| GET | `/v1/user-subscriptions/current/subscription` | web-api, mobile-api | Current ACTIVE subscription for the authenticated user | User |
| GET | `/v1/user-subscriptions/current/period` | web-api, mobile-api | Current ACTIVE period | User |
| GET | `/v1/user-subscriptions/periods/freezes` | web-api, mobile-api | List freezes on the current period | User |
| PUT | `/v1/user-subscriptions/periods/toggle-freeze` | web-api, mobile-api | Create or update an active freeze (cap-enforced) | User |
| DELETE | `/v1/user-subscriptions/cancel` | web-api, mobile-api | User-initiated cancel (refund flow) | User |
| POST | `/v1/user-subscriptions/refill/data` | web-api, mobile-api | Refill data for the current period (e.g. re-generate plan inputs) | User |
| GET | `/v1/user-subscriptions` | org | List subscriptions | Admin |
| GET | `/v1/user-subscriptions/:id` | org | Get one | Admin |
| POST | `/v1/user-subscriptions` | org | Manually create a subscription | Admin |
| PUT | `/v1/user-subscriptions/:id/cancel` | org | Admin-initiated cancel + refund | Admin |
| PUT | `/v1/user-subscriptions/:id/toggle-freeze` | org | Admin-initiated freeze | Admin |
| GET | `/v1/user-subscriptions/:id/periods/data` | org | Inspect period data | Admin |
| GET | `/v1/user-subscriptions/create-dummy-subscription` | org | Test-data generator | Admin |
| POST | `/v1/qa/user-subscriptions/:id/time-warp` | org/qa | Shift system clock for a subscription | Admin |
| POST | `/v1/qa/user-subscriptions/:id/trigger-renewal` | org/qa | Force-invoke `RenewSubscriptionProcessor.runForSubscription` | Admin |
| POST | `/v1/qa/user-subscriptions/:id/trigger-period-generation` | org/qa | Force-invoke period-generation for one subscription | Admin |
| POST | `/v1/qa/user-subscriptions/users/:userId/reset` | org/qa | Wipe a user's subscription state | Admin |
| POST | `/v1/qa/user-subscriptions/users/:userId/provision` | org/qa | Seed a user into a known state | Admin |

### Error responses to document (per matrix row)

The audit must catalogue the actual exceptions thrown at each transition site. Known starting points from code scan:

| Site | Exception | When |
|------|-----------|------|
| `CancelUserSubscriptionService.cancel` | `BadRequestException` | `refundAmount < 0` |
| `CancelUserSubscriptionService.cancel` | `NotFoundException` | subscription doesn't exist |
| `CancelUserSubscriptionService.cancel` | `ConflictException` | `status !== ACTIVE` (cancel is non-idempotent) |
| `CancelUserSubscriptionService.cancel` | `BadRequestException` | `refundAmount > 0` and subscription has already ended |
| `RenewSubscriptionProcessor.runForSubscription` | (no throw; returns `{outcome:'skipped'|'failed', reason: …}`) | All non-success paths |

---

## Data Model

No schema changes. The audit reads `UserSubscription`, `UserSubscriptionPeriod`, `UserSubscriptionPeriodFreeze`, `UserSubscriptionPeriodData`, `Transaction` rows for assertions. **No new migrations.**

### Access patterns the audit relies on (existing repos)

| Need | Repo / method |
|------|---------------|
| Subscription by ID with `findOneForUpdate` (row lock for the cancel test) | `UserSubscriptionRepository.findOneForUpdate` |
| Subscriptions expiring within N days | `UserSubscriptionRepository.find*` filtered by `endDate` + `status = ACTIVE` |
| Active period for a subscription | `UserSubscriptionPeriodRepository.find` filtered by `status = ACTIVE` |
| Active freezes for a period | `UserSubscriptionPeriodFreezeRepository.findOne` with `freezeEndDate >= now()` |
| Transactions for refund-side-effect assertions | `TransactionRepository.find` by `subscriptionId` + `reason` |

If the audit finds it needs a new query, the rule is: **don't add it.** Either (a) drive the assertion through an existing endpoint, or (b) raise a follow-up ticket and skip that matrix row.

---

## Implementation Plan

### Ticket breakdown

Each row below is a discrete GitHub issue on `apessolutions/dfn`. Branch convention: `feature/DFN-NN-<slug>`. PR-per-ticket. Sequencing is sequential except where noted.

| # | Ticket | Estimate | Dependencies | Owner role |
|---|--------|----------|--------------|------------|
| TD-1 | Catalogue every endpoint, cron, processor, and queue handler under `libs/user-subscription` → `libs/user-subscription/docs/catalogue.md` | 4h | — | Backend |
| TD-2 | Draft `libs/user-subscription/docs/state-machine.md` with one Mermaid `stateDiagram-v2` per enum + relationship explainer | 4h | TD-1 | Backend |
| TD-3 | Walk the cancel path end-to-end and confirm/correct the state diagram (concrete first transition; flushes out the methodology) | 3h | TD-2 | Backend |
| TD-4 | Skeleton `behaviour-matrix.md` — header row + one populated example per event type (HTTP / Cron / Queue / QA) | 3h | TD-2, TD-3 | Backend |
| TD-5 | Populate matrix rows for the **user-facing API** (`web-api` + `mobile-api`) | 8h | TD-4 | Backend |
| TD-6 | Populate matrix rows for the **admin API** (`org`) | 5h | TD-4 | Backend |
| TD-7 | Populate matrix rows for the **4 cron jobs** + **renewal queue** | 6h | TD-4 | Backend + Data |
| TD-8 | Cross-walk: every catalogue entry from TD-1 maps to ≥ 1 matrix row; gaps filed as `subscription-audit` issues with severity | 3h | TD-5, TD-6, TD-7 | Backend |
| TD-9 | Write e2e tests for "Must" matrix rows missing coverage; target ≥ 80% of Must rows | 16h | TD-8 | Backend |
| TD-10 | Write AgDR-0001: "Two-enum subscription model (subscription status vs period status)" — capture the *why* | 2h | TD-7 | Tech Lead |
| TD-11 | Write AgDR-0002: "Per-subscription BullMQ jobs vs single cron sweep for renewal" — capture the *why* | 2h | TD-7 | Tech Lead |
| TD-12 | Write AgDR-0003: "Freeze caps (`MAX_FREEZE_DAYS=30`, `MAX_FREEZES_PER_PERIOD=2`)" — verify the cap is actually enforced anywhere (freeze service alone does not enforce it!) and document the *why* | 2h | TD-7 | Tech Lead |
| TD-13 | `libs/user-subscription/docs/troubleshooting.md` with 3 walked-through real or representative support cases | 4h | TD-8 | Backend + Support |
| TD-14 | Link the new docs from `libs/user-subscription/README.md` and `projects/dfn/README.md`; close DFN#81; triage follow-up issues | 2h | All | Tech Lead |

**Total estimate**: 64h ≈ 8 engineer-days · matches the PRD's 9-day plan at 60% allocation (≈ 5.4 effective days/week → 14 calendar days, fits the 2026-05-29 target).

### Critical-path order

```
TD-1 → TD-2 → TD-3 → TD-4 → { TD-5, TD-6, TD-7 } in parallel → TD-8 → TD-9
                                                              ↘
                                                                { TD-10, TD-11, TD-12 } in parallel → TD-13 → TD-14
```

**One-ticket-at-a-time rule still applies per engineer** (per `.claude/rules/workflow-gates.md`) — the parallelism is across engineers, not across tickets one engineer owns concurrently.

### Testing patterns engineers must use

1. **One `describe` per matrix row.** Name format: `describe('M-NNN: <From-State> × <Event> → <To-State>', …)`. A failing test names the matrix row directly in CI output.
2. **Setup uses `qa/users/:userId/provision`**; never hand-craft fixtures. The audit assumes that `provision` is the canonical seed surface — if it's missing a needed start state, **extend it via a sub-ticket**, don't reach around it.
3. **Cleanup uses `qa/users/:userId/reset`**; one `afterEach`. Tests must be independent.
4. **Time-driven assertions use `time-warp`.** No `await sleep(…)`, no `jest.useFakeTimers()`. The QA endpoint is the only sanctioned time-shift mechanism.
5. **Queue assertions use BullMQ test utilities**, not real waits. Drain `RENEWAL_QUEUE` + `JOB_QUEUE` via `bullmq` test helpers before asserting.
6. **Payment-provider boundary mocked at `PaymobService`.** No real Paymob calls in e2e. Mock at the NestJS provider injection in `*-e2e` setup.
7. **Read-only on `libs/user-subscription/src/**`.** Reviewer rejects any PR in this initiative that mutates `src/`. Bugs found → file an issue with the matrix row ID in the title.

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Audit surfaces a P0 bug mid-flight (e.g. silent double-renewal under retry) that the team feels compelled to fix immediately | High | High | Pre-agreement: P0 bugs are filed as separate issues, opened with `severity: p0` and assigned to a fix-PR ticket. The audit ticket itself stays read-only. If a P0 needs hot-fixing, pause the audit ticket and resume after. |
| `qa/*` endpoints don't cover a state the audit needs to set up | Med | Med | Extend the `qa/*` controller via a sub-ticket; the QA harness IS sanctioned implementation work even though the rest of `libs/user-subscription/src/**` is not. Reviewer approves these sub-tickets on the merit of "without this, the matrix row is untestable". |
| `MAX_FREEZES_PER_PERIOD` not enforced anywhere — initial scan shows `UserSubscriptionFreezeService.createFreezePeriod` does not check the cap | High | Med | This is an expected finding, not a risk. The matrix will mark the freeze-toggle row as "**bug — cap not enforced**" and file a P1 issue. AgDR-0003 will document the intent vs the implementation gap. |
| BullMQ flakiness in CI (the renewal queue is the hottest one) | Med | Med | Tests drain queues deterministically via `bullmq` test helpers + use the on-demand `runForSubscription` path that the renewal processor already exposes for QA. Cron tests use `trigger-renewal`, not the real cron. |
| Paymob sandbox unavailable during tests | Med | Med | All payment-provider calls are mocked at the NestJS provider boundary. The audit doesn't claim Paymob behaviour is correct — only that the DFN side calls it with the right arguments at the right transitions. |
| Audit pulls in cross-store consistency (Postgres + Mongo) and the rabbit-hole eats the budget | Med | High | Hard scope rule per PRD: any cross-store finding is flagged + filed as a follow-up RFC. The audit does not solve it. |
| `time-warp` semantics drift between environments (works locally, breaks in CI) | Low | High | Add a smoke-test as TD-3's first action: provision a user, time-warp 30 days, assert the renewal cron picks them up. If smoke fails, fix the harness BEFORE doing any matrix rows. |
| The 64h estimate is wrong by 50%+ | Med | Low | Re-estimate after TD-4 (skeleton + first example). If the per-row matrix cost is > 30 min, scope down "Must" coverage from 80% to 60% with Head-of-Engineering sign-off. |

---

## Security Considerations

- [x] All audit-added e2e tests use the existing admin auth for `qa/*` and user auth for the user surface — no new auth code, no new tokens, no new bypass surfaces.
- [x] Paymob is mocked in e2e — no real charges, no real refund attempts, no test card numbers committed.
- [x] No PII added to test fixtures — `provision` seeds synthetic users. Reviewer rejects any test PR that hard-codes real names / emails / phone numbers.
- [x] No new secrets — tests inherit the existing `.env.deployment` shape (which itself is a known finding from the handover assessment, but is **not** an audit-scope fix).
- [ ] Activate Security Auditor role *if* the audit surfaces a finding in `libs/auth`, JWT lifetime around cancelled subscriptions, or any path where a CANCELLED subscription accidentally retains capabilities. Current expectation: not needed; activate only on finding.

---

## Testing Strategy

| Type | Coverage target | Notes |
|------|-----------------|-------|
| Unit | n/a — this initiative is e2e-driven | Existing unit tests stay green; we add to them only if a fix-ticket spawns out |
| Integration | n/a as a separate layer | Subsumed into e2e for this initiative — the matrix is inherently integration-level |
| E2E | ≥ 80% of "Must" matrix rows in `apps/web-api-e2e` and `apps/mobile-api-e2e` | Hard target; degrade to 60% only with Head-of-Engineering sign-off (Risk row above) |
| Determinism | 100% — zero `sleep`, zero wall-clock | Enforced by review |
| Repeatability | Tests pass 100 times in a row locally | `pnpm nx run web-api-e2e:test --testPathPattern=subscription --runInBand --testNamePattern='M-' --repeatEach 10` before PR |

---

## Open Questions

| Question | Owner | Status | Resolution path |
|----------|-------|--------|-----------------|
| Where does the docs set live — `libs/user-subscription/docs/` or `projects/dfn/`? | DFN lead | Open | **Tech Lead recommendation: `libs/user-subscription/docs/`** so it follows the code. Mirror a link from `projects/dfn/README.md`. Confirm at PRD-approval. |
| Should `qa/*` controller extensions count as "modifying src" under the read-only rule? | Tech Lead | **Resolved (this doc, Risk row)** | Yes-but: QA harness extensions are sanctioned sub-tickets. Reviewer's bar is "without this, the matrix row is untestable". |
| Is there a known SLO on renewal latency that should become a non-functional matrix row? | Head of Product / SRE | Open | If no SLO exists, flag as a missing SLO in TD-14's wrap-up and file as a follow-up. |
| Plan-generation failures in the AI engine — does the audit also catalogue them, or stop at the subscription boundary? | Tech Lead | Open | **Default: stop at boundary.** The matrix records `Period:GENERATING → ???` with reason `ai-engine-failure` and links to a follow-up issue for the AI Engine team to own. |
| What's the existing test-coverage baseline on `web-api-e2e` / `mobile-api-e2e`? | Backend Engineer | Open | TD-9's first action: run `pnpm nx run web-api-e2e:test --coverage` and commit the baseline number so the 80% target is measured against a real denominator. |

---

## Approvals

| Role | Name | Date | Status |
|------|------|------|--------|
| Tech Lead | Abdelrahman Shahda (Tech Lead hat) | 2026-05-13 | Author |
| Head of Engineering | Abdelrahman Shahda | 2026-05-13 | Approved — read-only constraint + `qa/*` extension carve-out accepted |
| Product Manager | Abdelrahman Shahda (PM hat) | 2026-05-13 | Approved — design serves the PRD |
| Backend Engineer | Abdelrahman Shahda | 2026-05-13 | Approved — estimate accepted; re-estimate trigger after TD-4 lands per Risk row |
| Security Auditor | n/a | n/a | Not activated; activate only if a finding surfaces in auth / crypto / payment paths |

---

## Handoff (per `roles/engineering/tech-lead.md`)

**Tech Lead → Backend Engineer + Data Engineer**:

- Deliverable: this Tech Design + the PRD + the linked tracking issue (#81)
- 14 tickets to create (TD-1 → TD-14); convention `feature/DFN-N-<slug>`, PR-per-ticket
- Read-only constraint on `libs/user-subscription/src/**` is enforced at review time
- One-ticket-at-a-time per engineer; matrix rows decomposed inside each ticket as `describe` blocks, not as separate PRs

**Tech Lead → QA Engineer**: (after the e2e suite lands)

- The matrix becomes the regression-test contract; QA runs `pnpm nx run web-api-e2e:test --testPathPattern='M-'` as part of release sign-off going forward
- File bugs against the matrix row ID — "M-014 fails" is enough context to dispatch
