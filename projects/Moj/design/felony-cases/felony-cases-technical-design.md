# Felony Cases Cycle — Technical Design (cross-dev contracts + phasing)

> **Status:** Draft — rev 3 (delivery model reshaped to **foundation-first + work-queue** per CEO 2026-07-12; architecture from rev 2 unchanged — Tariq's findings still hold)
> **Author:** Tech Lead (Hisham) · **Reviewer:** Solution Architect (Tariq)
> **Source of truth (ACs):** Confluence — [قضايا الجنايات](https://apessolutions.atlassian.net/wiki/spaces/MOJ/pages/1191804939) (Ziad Kamal, 2026-07-09). Architecture/parallelization layer only; does not restate ACs.
> **Screens:** `projects/Moj/design/felony-cases/*.png`
> **Scope:** stories **K, A, B, C, D, E, F, G, H, I, J, L, M, N, O**.

## 0. Design-review response log (rev 1 → rev 2)

| Finding | Resolution in rev 2 |
|---|---|
| **B1** Port 3 (`BookFirstSession` inside J's tx) creates `judicialcase → courtsession` cycle → `ModularityTests` fails | **Fixed §4/§4a.** Booking is optional and leaves the case-save transaction. A new **acyclic composition service** (`felonyintake`) depends *downward* on both `judicialcase` and `courtsession` and owns the "save case, then optionally book" coordination. J (in `judicialcase`) persists the case only. Shipped direction `courtsession → judicialcase` is preserved. |
| **B2** K rebuilds shipped `AccessScope` (AgDR-0049) | **Fixed §5.** K **reuses** `AccessScopeGuard` / `AccessScope.courtRestriction()` / `Specs.restrictTo`. The only new piece is the request-scoped **active-appeal-court selector**. `court.appeal_court_id` and `user_appeal_courts` **dropped** — reuse shipped `Court.subCourtIds` + admin court-assignment. |
| **B3** No AgDR on the tx-boundary / module-direction decision | **Fixed §10** — AgDR-INTAKE-TX added as first AgDR to file, before P0 port freeze. |
| **B4** New schema duplicates shipped relationships | **Dropped** (see B2). No new tables for scope. Claimant/Exhibit tables still needed (§10), migration AgDR noted. |
| **A1** §8 "optional accused" contradicts shipped `Case.register` (≥1 accused) | **RESOLVED (CEO, 2026-07-12):** accused-minimum is **track-dependent** — **0 for FELONY_FIRST, ≥1 for renewal (تجديد)**. `Case.register` is parameterized by نوع القضية, NOT globally relaxed (protects the shipped renewal path). Now a firm AgDR (§10.6), no longer conditional. |
| **A2** `CaseWebMapper` / `CaseApplicationService` are shared seams | **Fixed §6** — named as coordinated seams, not clean splits. |
| **A3/A4/A5** cross-module tx smell / NFRs absent / ports 4-5 are intra-module | **Fixed** §4a (event option documented), §11 (NFR paragraph), §4 (ports 4/5 reclassified as in-module use-cases). |

---

## 1. Purpose

Freeze the module boundaries, aggregates, and **cross-developer contracts** so two backend engineers build this cycle in parallel with couplings decided at design time. The team chose a **vertical-slice split**; the contracts below are therefore load-bearing.

## 2. Where this lands (mostly extension, not greenfield)

Modules (each `@ApplicationModule`, cross-module via `@NamedInterface`): `judicialcase`, `courtsession`, `core`, `iam`, `media`, `shared`, `transcript`. **Shipped dependency direction that constrains this design: `courtsession → judicialcase` (courtsession orchestrates case creation during session commit — M1). `judicialcase → courtsession` is currently zero and must stay zero.**

### 2.1 Existing-vs-new map

| Story | Verdict | Anchor |
|---|---|---|
| A List | Extend | `ListCasesUseCase` + scope restriction |
| B Lookup/Upsert | Extend | `FindCaseIdsByNumberLikeUseCase`, `CaseExistsUseCase` + scope + 4-key |
| C Core Data | Extend | `Case` + `CreateCaseCommand` + الوصف + scoped المحكمة + الدائرة from D |
| D Division Suggestion | **Build resolver on shipped data** | AgDR-0061 routing tables exist; algorithm new |
| E Accused | Extend | `Accused`, `SyncCaseAccusedUseCase` exist |
| F Claimants | **New sub-aggregate** | mirror `Accused` |
| G Attachments | Wire | `media` module + 6-category Link |
| H Exhibits | **New (small)** | رقم+سنة+وصف VOs |
| I Book Session | Extend (heavy) | courtsession day-roll write path + calendar |
| J Save/Create | Extend | case-persist only (booking moved out — B1) |
| K Scope | **Small — selector only** | reuse AccessScope (AgDR-0049) |
| L Details | Compose (read) | `GetCaseUseCase` + session timeline |
| M Reschedule | Extend | courtsession, non-started guard |
| N Change Court&Division | Extend (heavy) | case + courtsession, warning-gated |
| O Soft-delete | Extend | `SoftDeleteCaseUseCase` + no-session-started guard |

## 3. Delivery model — foundation-first, then work-queue (rev 3)

Instead of two vertical-slice devs, the cycle ships in **three layers**. A shared foundation (schema + per-sub-aggregate persistence infra) lands first; then the API stories fan out to **3–4 backends on a work-queue** — no per-dev assignment, each pulls the next unblocked story. This deliberately trades a short serial foundation for a maximally-parallel API phase, and it *pre-resolves* the same-module contention (§6) and the `J` bottleneck by establishing the shared files (schema, `Case` extensions, mappers, controller scaffolding) **once**, up front.

- **Layer 1 — DB design (serial, blocks all):** one additive migration + AgDR for the whole felony sub-data schema.
- **Layer 2 — persistence infra per sub-data (parallel):** aggregate + JPA + repo + mapper + shared request/DTO for Claimant, Exhibit, Attachment-link (Accused exists); plus the cross-cutting foundations K selector, D resolver, `felonyintake` scaffold.
- **Layer 3 — APIs (fully parallel work-queue):** each story = use-case + controller on shared infra. The only residual integration edges are **C, J, L** (they compose sub-resources — "last to converge"); everything else is free-running.

## 4. Contracts (freeze BEFORE P1)

| # | Contract | Kind | Published by | Consumed by |
|---|---|---|---|---|
| 1 | `AccessScopeGuard` + active-appeal-court selector | **reuse (AgDR-0049)** + thin new selector | shared/iam (exists) · selector by **Dev A** | A, B, C (Dev A) · I, M, N (Dev B) |
| 2 | `SuggestDivisionUseCase` | cross-module port (`core`) | **Dev B** (D) | C (Dev A) · I (Dev B) |
| 3 | `SaveCaseUseCase` (persist only, returns `CaseId`) | in-module (judicialcase) | **Dev A** (J) | `felonyintake` orchestrator (Dev B) |
| 4 | `BookFirstSessionUseCase` | cross-module port (`courtsession`) | **Dev B** (I) | `felonyintake` orchestrator (Dev B) |
| 5 | `SyncClaimantsUseCase` / `SyncExhibitsUseCase` | **in-module** use-cases (judicialcase) | **Dev B** (F/H) | J (Dev A) |
| 6 | `LinkAttachmentsUseCase` | cross-module port (`media`) | **Dev B** (G) | J (Dev A) |
| — | `SyncCaseAccusedUseCase` | exists | E (Dev B extends) | J (Dev A) |

Ports 5 are **intra-`judicialcase`** (Claimant/Exhibit live there) — plain use-case interfaces, not named-interface cross-module ports (A5). Ports 2/4/6 are genuine cross-module and directionally safe (`judicialcase→core`, `felonyintake→courtsession/media` — all downward).

### 4a. The `felonyintake` composition service (resolves B1)

```
        felonyintake  (NEW slice — Dev B; depends DOWNWARD only)
        /        \
 judicialcase   courtsession        ← existing edge courtsession→judicialcase preserved
   (Dev A: J     (Dev B: I book)
    persist)
```

- **`CreateFelonyCaseUseCase.handle(cmd)`**: (1) `SaveCaseUseCase` persists the case (judicialcase, Dev A) — its own tx incl. accused/claimants/exhibits/attachment links; (2) *if* a first session was requested, `BookFirstSessionUseCase` books it (courtsession, Dev B). Booking is **optional** and **not** in the case-persist transaction (a case must persist with zero sessions — §8).
- Coupling trade-off (A3): case-save and booking are **two aggregates → two transactions**, coordinated by the orchestrator. If a booking fails after a case saved, the case stands and the UI surfaces a "book session" retry from the details view (L) — acceptable because booking is optional and rول-less. Documented in **AgDR-INTAKE-TX**.
- No cycle: `felonyintake → {judicialcase, courtsession}` only. `ModularityTests` stays green.

## 5. Scope model (K) — reuse, don't rebuild (resolves B2)

Shipped in `shared/security` + `iam/access` (AgDR-0049): `AccessScope` (courts+divisions, `superAdmin`, fail-closed), `AccessScopeGuard` (`assertCanAccessCourt`, `currentScope`), `AdminAccessScopeResolver` (**already expands assigned appeal courts → sub-courts**, request-memoized), `Specs.restrictTo` (fail-closed `IN`, empty ⇒ deny-all). `Court.subCourtIds` already models appeal→primary.

**K = the request-scoped active-appeal-court selector only.** When the operator's `AccessScope` spans >1 appeal court, a per-request selector narrows to one; A/B/C read paths and I/M/N writes then apply `AccessScope.courtRestriction()` intersected with the selected appeal court's `subCourtIds`. "Not-found not forbidden," fail-closed empty-scope, single→auto are all inherited from the shipped stack — **no new scope port, no `court.appeal_court_id`, no `user_appeal_courts`.**

## 6. Same-module contention — pre-resolved by Layer 1/2 (rev 3)

> Under foundation-first, the shared `judicialcase` files below are established **once** in Layers 1–2 before the Layer-3 fan-out. The table now documents *who lays each shared file down in the foundation*, not a live per-dev collision surface. The two coordinated seams (`CaseApplicationService`, `CaseWebMapper`) are settled during Layer 2, so Layer-3 API stories only *add* use-cases/controllers.


| Path | Owner | Note |
|---|---|---|
| `judicialcase/domain/Case*`, `CaseFilter`, `CaseRepository` | **Dev A** | |
| `judicialcase/domain/{Claimant,Exhibit}*`, `Attachment*` | **Dev B** | new files |
| `judicialcase/domain/Accused*` | **Dev B** | extend |
| `CaseApplicationService` (hosts `SyncCaseAccused` today) | **coordinated seam** | Dev B's `SyncClaimants/SyncExhibits` land here or in sibling services — agree split in P0 (A2) |
| `CaseWebMapper` (injects sibling web mappers per cross-slice rule) | **coordinated seam** | L (Dev A) embeds claimant/exhibit/attachment/session summaries from Dev B's mappers (A2) |
| `judicialcase/infrastructure/web/CaseController` | **Dev A**; sub-resources get own sub-route controllers | |
| `courtsession/**`, `felonyintake/**` | **Dev B** | |
| `core/division` suggestion resolver | **Dev B** | |
| active-appeal-court selector | **Dev A** | thin, on AccessScope |

Rule: **new files over shared edits**; Dev A pre-lands `Case` extension points + agrees the two coordinated seams in P0.

## 7. Phasing (three layers)

| Layer | Work | Parallelism | Gate |
|---|---|---|---|
| **L1 — DB design** | one additive migration + migration AgDR: `case` ext (الوصف العام) · `case_claimant` · `case_exhibit` · `case_attachment`(→media) · session-booking cols | serial (1 dev) — **blocks L2/L3** | schema applied on staging; round-trip test green |
| **L2 — Persistence infra** | per sub-data: aggregate + JPA + repo + mapper + shared request/DTO (Claimant · Exhibit · Attachment-link; Accused = extend for track-min) · **+ K selector · D resolver · `felonyintake` scaffold + AgDR-INTAKE-TX** | parallel among sub-data | each infra round-trips; contracts frozen; module graph acyclic |
| **L3 — APIs (work-queue)** | use-case + controller per story: A · B · C · E · F · G · H · I · J · L · M · N · O | **3–4 backends, pull next unblocked** | per-story ACs; cycle demo-able |

**Residual L3 edges (only these):** `C` (form) ← K,D · `J` (save) ← C + sub-resource use-cases · `L` (details) ← J · `M/N/O` ← I/L · `felonyintake` wire ← J,I. Every other API story is free-running once L2 lands. The former `J`/orchestrator bottleneck is now a thin convergence step, not a build-order spine.

## 8. Invariants (one OPEN Product item)

- **✅ Accused-minimum is track-dependent (CEO, 2026-07-12):** **0 for FELONY_FIRST**, **≥1 for renewal (تجديد)**. `Case.register` reads the minimum from نوع القضية rather than a blanket relax — the shipped renewal path keeps its ≥1 guard. Dev A threads the rule through the case-type in P0 (shared-file edit to `Case.java` + AgDR §10.6). C/E/J treat accused as optional for felony.
- **Non-started only:** M/N/O act only when every session's حالة = لم تبدأ. `courtsession` exposes `hasStartedSession(caseId)`; both tracks call it.
- **4-key identity** (رقم الدعوى + سنة القيد + نوع القضية + قسم الشرطة), read-only on match (reuse M1 4-tuple).
- **No hard delete.** **رول assigned on the roll, not at booking/reschedule.** **Claimants optional.**

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| case↔session integration cycle | resolved via `felonyintake` (§4a); booking out of case tx |
| K rebuilds scope | reuse AccessScope (§5) |
| same-module merge collisions | §6 seams + new-files rule + P0 pre-land |
| optional-accused conflict | **escalated to Product (§8)** — blocks C/E/J |
| two-tx case+book partial failure | booking optional + retry from L; AgDR-INTAKE-TX |
| division-suggestion precedence | "sub-type wins" fixed in AgDR-0061; resolver table-test |

## 10. AgDRs to file during Build

1. **AgDR-INTAKE-TX (first, before P0 freeze)** — transaction ownership + module direction: `felonyintake` composition, booking out of case-save tx, two-tx trade-off (B1/B3).
2. **Active-appeal-court selector** — framed as *extending AgDR-0049*, not a new scope mechanism (B2).
3. **Claimant / Exhibit as `Case` sub-aggregates** + their migration (mirror Accused; migration AgDR since new tables — B4 residue).
4. **Attachment linkage** via `media` (link vs copy; 6-category taxonomy).
5. **Division-suggestion resolver placement** (`core.division` app service) — extends AgDR-0061.
6. **Track-dependent accused minimum** — `Case.register` reads the minimum from نوع القضية (0 for FELONY_FIRST, ≥1 for renewal). Firm decision (CEO 2026-07-12); semantic change to shared `Case.java`, land in P0.

## 11. NFRs (A4)

Scope adds **one `IN` predicate per read** via the shipped, request-memoized `AccessScope` — no new query round-trips, no N+1 (list uses existing pagination; L composition reuses batched `GetCasesByIdsUseCase`-style fetches per the N+1 handbook). Division suggestion is a bounded in-memory match over ≤4 weeks / N station-rules / M sub-types per division (EAGER `@BatchSize(50)` already shipped). No new hot-path regression expected; confirm with the existing list/details perf tests.

---

*Planning artifact under ApexYard — rev 2 addresses the `/design-review` (Tariq) findings; one item (§8) is an open Product decision.*
