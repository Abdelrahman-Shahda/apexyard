# Felony Cases — L3 API Plan

> **Status:** design, build-ready after the two foundation items in §2 land.
> **Decisions:** [AgDR-0072](../../../../workspace/Moj/docs/agdr/AgDR-0072-felony-api-module-boundary.md) (API module boundary), [AgDR-0073](../../../../workspace/Moj/docs/agdr/AgDR-0073-judicialcase-felony-access-scoping.md) (access-scoping). Epic #321.
> **Reviewed by:** Tariq (Solution Architect), Hisham (Tech Lead) — both recommended splitting the web layer across modules; CEO chose a single un-scattered felony surface (AgDR-0072).

## 0. The discriminator (felony vs renewal)

Both cycles share the `cases` table. A case is **felony** iff it has a `case_felony_details` row (PK = `case_id`), which carries the felony-only `court_id` / `division_id` / `appeal_court_id` + crime description; **renewal** has no such row (AgDR-0064). The check is `felonyDetailsRepository.existsById(caseId)` — already used by the accused-minimum guard. `case_type` (جناية/جنحة) is the **crime class**, orthogonal to the cycle — not a discriminator. Felony list = inner-join on `case_felony_details`; renewal list = anti-join.

## 1. Module & routing (AgDR-0072)

**All felony REST lives in one place — the `felonyintake` module — under `/api/v1/felony-cases`.** Renewal keeps `/api/v1/core/cases` in `judicialcase`, untouched. Felony controllers **reuse** `judicialcase`'s shared use-cases + `CaseWebMapper` + sub-resource web mappers/DTOs (exposed cross-module via `@NamedInterface`) — never re-mapped inline. Graph stays acyclic: `felonyintake → {judicialcase, courtsession}`, no back-edge.

Small enabling step before the L3 controllers: `@NamedInterface`-expose the sub-resource application ports (`Add/Edit/Delete/List<X>UseCase`) and the web mappers `felonyintake` consumes.

## 2. Foundation items — MUST land before the L3 fan-out

Both are Layer-2 and block the sub-resource CRUD. Do not open the work-queue until these are green.

| # | Item | Why it blocks | Gates |
|---|------|---------------|-------|
| **F1** | **Felony-details persistence** — `FelonyDetails` entity/mapper + `Case`→court read (the L1 `case_felony_details` migration already landed; the *code* does not exist) | It's the discriminator **and** the scope key `court_id` | C, D, L, and F2 |
| **F2** | **`AssertCanAccessCase` write-guard + scoped felony list** (AgDR-0073) — service-layer, keyed on `case_felony_details.court_id`/`division_id`, fail-closed | Without it every `/felony-cases/{caseId}/…` write is an **IDOR** | E, F, G, H |

## 3. Endpoint catalog (all under `/api/v1/felony-cases`, in `felonyintake`)

| Story | Method · Path | Perm | Purpose |
|---|---|---|---|
| **A** #385 | `GET /felony-cases` | READ | Felony list — lean projection (number/year/station, accused names + charges, court/division, next session); **scoped** (F2) + filtered (court, division, appeal court, status, search) |
| **B** #386 | `POST /felony-cases/search` | READ | Lookup by identity → found / not-found (reuses the shared `SearchCaseUseCase` as a thin felony-scoped delegate) |
| **C** #388 | *(fields in J / N)* | — | Case core data (بيانات القضية): number, year, station, type, court, division, appeal court, crime description — persisted via F1 |
| **D** #328 | `GET /felony-cases/divisions/suggest?courtId=…` | READ | Division auto-suggestion (DIV-E/F/G routing) |
| **E** #381 | `POST·PUT·DELETE /felony-cases/{id}/accused[/{aid}]` | UPDATE | Accused CRUD — **separate felony DTO** (carries the extended `case_accused_felony_details` identity fields); track-min enforced in the use-case; **blocked-by F2** |
| **F** #382 | `POST·PUT·DELETE /felony-cases/{id}/civil-claimants[/{cid}]` | UPDATE | Civil claimants CRUD; **blocked-by F2** |
| **G** #383 | `POST·DELETE /felony-cases/{id}/attachments[/{aid}]` | UPDATE | Attachments — link a `media` object; **blocked-by F2** |
| **H** #384 | `POST·PUT·DELETE /felony-cases/{id}/exhibits[/{eid}]` | UPDATE | Exhibits (الأحراز) CRUD; **blocked-by F2** |
| **I** #387 | `POST /felony-cases/{id}/sessions` | UPDATE | Book first session — **reuses the M1 courtsession write path**; feeds the جنايات day-roll (composite, `courtsession`-touching) |
| **J** #389 | `POST /felony-cases` | CREATE | **Composite intake** — case + accused + claimants + exhibits + attachments + optional first session in **one `@Transactional`**; returns a **thin** response (`caseId` + `bookedSessionId?`), FE re-fetches details |
| **K** #327 | `GET /courts/options?type=APPEAL&sessionEligible=…` | READ | Active appeal-court selector — **already shipped** (the #413 court-options refactor) |
| **L** #390 | `GET /felony-cases/{id}` | READ | Details (تفاصيل القضية) — case + all sub-resources (each loaded by `CaseId`); needs F1 |
| **M** #391 | `PUT /felony-cases/{id}/sessions/{sid}` | UPDATE | Reschedule a non-started session (`courtsession`-touching) |
| **N** #392 | `PUT /felony-cases/{id}/court-division` | UPDATE | Change court & division — updates `case_felony_details`; re-checks the "unique per appeal court" rule |
| **O** #393 | `DELETE /felony-cases/{id}` | DELETE | Soft-delete case → cascades to sub-resources + sessions |

## 4. Build rules (freeze before the fan-out)

1. **DTOs:** reuse the track-agnostic sub-resource DTOs (claimant/exhibit/attachment — already `@NamedInterface("dto")`). **Exceptions:** accused (felony carries extended identity fields → a **separate** felony accused request/response) and create (`CreateFelonyCaseRequest`, **not** an overloaded shared `CreateCaseRequest`).
2. **Composite double-write trap:** `CaseJpaEntity` keeps a LAZY `@OneToMany(cascade=ALL)` purely for the soft-delete cascade. In the composite create, write children **only** via their own repositories — **never** populate the Case entity's child collection, or Hibernate double-flushes (duplicate rows). Pin with a persistence IT asserting child row-counts after a composite create, plus one asserting case soft-delete still cascades.
3. **Invariant placement:** the track-dependent accused minimum (≥1 renewal / 0 felony) stays enforced **once, in the shared use-case** — never re-encoded in a felony controller.
4. **Permissions (MVP):** all sub-resource writes gate on `CASE_UPDATE`, reads on `CASE_READ`. No per-sub-resource permissions (conscious decision, not drift).
5. **Controllers:** one controller per sub-resource (its own `@RestControllerAdvice`), all in `felonyintake/infrastructure/web/`; a sub-route ownership map keeps the composite controller and the sub-resource controllers from colliding on the shared `/felony-cases` base.

## 5. Two-developer split (unchanged by the routing decision)

| Dev A — spine & composites | Dev B — sub-resources, reads, infra |
|---|---|
| **F1** felony-details persistence · **F2** scope guard · #329 felonyintake scaffold · J (#389) · E (#381) · L (#390) · O (#393) | F (#382) · G (#383) · H (#384) · A (#385) · B (#386) · I (#387) · D (#328) → C (#388) |

Convergence points: C ← F1 + K/D; J ← #329 + F1 + sub-use-cases; E/F/G/H ← **F2**; M/N ← I/L.

---

*Part of the Moj portfolio under ApexYard. Related: felony-cases-technical-design.md, subresource-aggregate-promotion.md.*
