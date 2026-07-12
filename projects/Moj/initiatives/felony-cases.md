# Initiative — Felony Cases Cycle (قضايا الجنايات أول درجة)

> **Goal:** ship the جنايات أول درجة intake cycle — list / lookup / add-edit a felony case with accused, civil claimants, attachments, exhibits, and an optional first-session booking that feeds the جنايات day-roll.
> **Team:** 3–4 backend engineers on a work-queue (foundation-first; no per-dev assignment).
> **Spec (ACs):** Confluence [قضايا الجنايات](https://apessolutions.atlassian.net/wiki/spaces/MOJ/pages/1191804939) · **Screens:** `projects/Moj/design/felony-cases/`
> **Technical design:** [`../design/felony-cases/felony-cases-technical-design.md`](../design/felony-cases/felony-cases-technical-design.md)
> **Repo:** apessolutions/moj_judiciary · **Trunk:** `development`

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

## Next action

File the epic → L1 → L2 → L3 with real `blocked by #N` edges, on CEO go.

---

*Part of the Moj portfolio under ApexYard. Related: [[project-moj-m1-status]], [[project-moj-access-scoping]], [[project-moj-media-module]].*
