# Initiative — Felony Cases Cycle (قضايا الجنايات أول درجة)

> **Goal:** ship the جنايات أول درجة intake cycle — list / lookup / add-edit a felony case with accused, civil claimants, attachments, exhibits, and an optional first-session booking that feeds the جنايات day-roll.
> **Team:** 3–4 backend engineers on a work-queue (foundation-first; no per-dev assignment).
> **Spec (ACs):** Confluence [قضايا الجنايات](https://apessolutions.atlassian.net/wiki/spaces/MOJ/pages/1191804939) · **Screens:** `projects/Moj/design/felony-cases/`
> **Technical design:** [`../design/felony-cases/felony-cases-technical-design.md`](../design/felony-cases/felony-cases-technical-design.md)
> **Repo:** apessolutions/moj_judiciary · **Integration branch:** `feature/GH-321-felony-cases` (off `development`)
>
> **Branch model (2026-07-12):** renewal ships to production this week from clean `development`; felony is isolated on the **`feature/GH-321-felony-cases`** integration branch. ALL felony PRs (L1 #331, L2 #323–329, L3) target that branch, NOT `development`. Periodically merge `development` → the epic branch to avoid drift (low cost — felony is mostly new files). One final PR `feature/GH-321-felony-cases` → `development` when felony is ready for prod.

## Delivery model: foundation-first, then work-queue (rev 3)

Ship a shared foundation (schema + per-sub-aggregate persistence infra) **first**; then the API stories fan out to **3–4 backends** who pull the next unblocked story. Front-loading the shared files (schema, `Case` extensions, mappers, controller scaffolding) once removes the same-module contention and the `J` bottleneck the vertical-slice split carried. The residual coupling is just **C, J, L** (they compose sub-resources).

| Layer | Work | Parallelism |
|---|---|---|
| **L1 — DB design** | one additive migration + AgDR for the whole felony sub-data schema | serial (1 dev), **blocks L2/L3** |
| **L2 — Persistence infra** | per sub-data: aggregate + JPA + repo + mapper + shared request/DTO; + K selector, D resolver, `felonyintake` scaffold | parallel among sub-data |
| **L3 — APIs (work-queue)** | use-case + controller per story (A…O) | 3–4 backends, pull next unblocked |

## Dependency DAG (foundation-first)

```
L1  ┌─────────────── DB design (one migration + AgDR) ───────────────┐  (blocks all)
    ▼
L2  Claimant-infra · Exhibit-infra · Attachment-infra · [Accused exists]   (parallel)
    K-selector(on AccessScope) · D-resolver · felonyintake-scaffold
    ▼
L3  A · B · E · F · G · H · I · M · N   ← free-running once infra lands
        └─ C ←K,D    J ←C+sub-use-cases    L ←J    M/N/O ←I/L    felonyintake-wire ←J,I
```

## Enabler + foundation status

Every classic "enabler" reuses shipped work (see table below); the only true foundation is **L1 (schema)** + **L2 (infra + K/D/felonyintake)**.

## Enabler status

| Enabler | Blocks | Status |
|---|---|---|
| User → محكمة استئناف assignment | K | **✅ reuse** — admin court-assignment already accepts appeal courts (AgDR-0049); no new table |
| Court → محكمة استئناف mapping | A, B, C, N | **✅ reuse** — shipped `Court.subCourtIds` (appeal→primary); no new column |
| دائرة routing rules (DIV-E/F/G) | D, I | **✅ SHIPPED** — AgDR-0061 / GH-316 / PR #317 |
| قسم شرطة / نيابة / تهمة / sub-type lookups | B, C, E | **✅ exist** (core reference aggregates) |
| Day-roll session placement | I, M, N | **✅ exists** (M1 courtsession write path) — reuse, don't fork |
| File storage | G | **✅ exists** (`media` module) |

**All enablers now reuse shipped work — no separate enabler tickets to file.** (rev 2, post-review)

## ✅ Resolved — accused-minimum is track-dependent (CEO, 2026-07-12)

**0 accused allowed for felony (FELONY_FIRST); ≥1 still required for renewal (تجديد).** `Case.register` is parameterized by نوع القضية — not globally relaxed — so the shipped renewal path keeps its guard. Firm AgDR to file during Build.

## Ticket manifest (NOT yet created — CEO previews the batch first)

> Design IDs from Confluence; GitHub numbers assigned on creation. Label by **sub-module + layer** (no per-dev), so any of the 3–4 backends pulls the next unblocked story.

**Epic:** `[Epic] Felony Cases Cycle`

**L1 — foundation (blocks all):**

- `[Migration] Felony cycle schema` — case-ext + `case_claimant` + `case_exhibit` + `case_attachment` + session cols (one AgDR)

**L2 — infra (blocked-by L1; parallel):**

- `[Task] Claimant persistence infra` · `[Task] Exhibit persistence infra` · `[Task] Attachment-link persistence infra`
- `[Task] Accused — track-dependent min (extend)` · `[Feature] K active-court selector` · `[Feature] D division resolver` · `[Task] felonyintake scaffold + AgDR-INTAKE-TX`

**L3 — APIs (work-queue; blocked-by relevant L2):**

- Free-running: A, B, E, F, G, H, I, M, N
- Convergence: C ←K,D · J ←C+sub-use-cases · L ←J · O ←L · felonyintake-wire ←J,I

**AgDRs during Build:** AgDR-INTAKE-TX (first) · active-court selector (extends AgDR-0049) · Claimant/Exhibit sub-aggregates + schema · attachment linkage · division-resolver placement · track-dependent accused min.

## L1 build — felony-only, in one PR (2026-07-12)

Review (Rex + Tariq) found the case identity model contradicted the felony scoping stories (`cases` has no court dimension). **AgDR-0064** captured the decisions; after the product owner clarified **court/division/appeal are FELONY-ONLY**, the whole thing collapsed into a single low-risk PR:

- **PR [#331](https://github.com/apessolutions/moj_judiciary/pull/331)** — all felony sub-data in extension tables: `case_felony_details` (holds felony-only `court_id`/`division_id`/`appeal_court_id` + crime description), `case_accused_felony_details`, the 3 child tables (`case_civil_claimants`/`case_exhibits`/`case_attachments`), and the inline session-snapshot fields. Touches **no shipped data**. Migration `V20260712094733`; AgDRs 0063 (migration) + 0064 (data-modeling). **Rex ✅ + Tariq ✅ at `33043bd`. HELD for CEO GitHub review + merge nod.**
- **Track A CANCELLED** — the shared-`cases` migration (court/division for all types, uniqueness, backfill) is dropped: **[#333](https://github.com/apessolutions/moj_judiciary/issues/333) closed, AgDR-0065 removed.** No renewal impact.

**Service convention (PO, 2026-07-13):** each felony sub-aggregate (CivilClaimant, Exhibit, Attachment, …) has its OWN `Case<X>ApplicationService` implementing its sync use case — not piled into `CaseApplicationService` (the L3 APIs add add/edit/delete per sub-aggregate). Constraint: `sync<X>(Case, List)` signature preserved (no self load/save) so J composes all children in one transaction; children stay inside the Case aggregate. Accused sync stays in `CaseApplicationService` (shipped). Established in PR #363; #325+ follow it.

**Key model facts (AgDR-0064, felony-only):**

- Court/division/appeal live on `case_felony_details` (felony-only), NOT shared `cases`.
- **Felony-vs-renewal discriminator = presence of a `case_felony_details` row** (felony list = inner join; renewal = anti-join). `case_type` (جناية/جنحة) = crime class, orthogonal.
- **Felony "unique per appeal court" = app-layer check in story B** (stations aren't 1:1 with appeal courts; cross-table DB index impossible). Open story-B item: shared `uq_cases_identity` may over-constrain cross-appeal-court felony duplicates.
- **Build note (Tariq):** insert the `case_felony_details` row in the case's own aggregate transaction; guard story-B uniqueness against TOCTOU.
- Cosmetic fast-follow: AgDR-0064 H1 title + Artifacts annotation still say "on cases".

Cosmetic fast-follow: AgDR-0063 intro prose still describes the pre-re-cut shape (non-blocking).

## Filed (spine — 2026-07-12)

| # | Ticket | Layer |
|---|---|---|
| [#321](https://github.com/apessolutions/moj_judiciary/issues/321) | Epic — Felony Cases Cycle | epic |
| [#322](https://github.com/apessolutions/moj_judiciary/issues/322) | Migration: felony sub-data schema (AgDR-0063) | L1 |
| [#323](https://github.com/apessolutions/moj_judiciary/issues/323) | Claimant persistence infra | L2 |
| [#324](https://github.com/apessolutions/moj_judiciary/issues/324) | Exhibit persistence infra | L2 |
| [#325](https://github.com/apessolutions/moj_judiciary/issues/325) | Attachment-link persistence infra | L2 |
| [#326](https://github.com/apessolutions/moj_judiciary/issues/326) | Accused minimum, track-dependent | L2 |
| [#327](https://github.com/apessolutions/moj_judiciary/issues/327) | JNA-CASE-K active-court selector | L2 |
| [#328](https://github.com/apessolutions/moj_judiciary/issues/328) | JNA-CASE-D division resolver | L2 |
| [#329](https://github.com/apessolutions/moj_judiciary/issues/329) | felonyintake scaffold + AgDR-INTAKE-TX | L2 |

**Blocked-by:** all L2 (#323–#329) reference L1 #322 in their bodies. Migration AgDR-0063 authored at `workspace/Moj/docs/agdr/`.

## Next action

**L3 (13 API stories)** to be filed once L1 #322 lands and the schema/DTO names are locked — so their ACs reference the real table/field names. Then the work-queue opens for 3–4 backends.

---

*Part of the Moj portfolio under ApexYard. Related: [[project-moj-m1-status]], [[project-moj-access-scoping]], [[project-moj-media-module]].*
