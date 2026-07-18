# Renewal Cases List (قضايا التجديد) — Technical Design

> **Status:** design, awaiting review (Tariq + CEO). **Branch base:** `development`.
> **Target repo:** apessolutions/moj_judiciary. **Prefix:** MOJ.
> **Related:** felony api-plan §0 (discriminator), AgDR-0049 (access-scoping), AgDR-0070-source (lean list read model).

## 1. Problem

A single page — **قضايا التجديد** — lists judicial cases with a lean row projection and two
filters, gated by a view-cases permission. Design: `projects/Moj/design/detention-renewal-list/`.

**Row columns (per screenshot):**

| Column (ar) | Meaning | Source |
|---|---|---|
| # | row index | client-side |
| رقم القضية | case number `N/YYYY`, **clickable** | `cases.number` + `cases.year` |
| قسم الشرطة | police station | `cases.police_station_id` → name |
| عدد الجلسات | session count | **courtsession** (cross-module) |
| آخر تاريخ جلسة | last session date | **courtsession** (cross-module) |
| عدد المتهمين | accused count | `case_accused` |
| المتهمون | accused names (bulleted) | `case_accused.name` |

**Filters:** case number (LIKE) + police station (قسم الشرطة, exact). *(Confirmed with CEO 2026-07-17 —
the screenshot's second filter is police-department, not accused-name.)*

## 2. The felony/renewal discriminator — DEFERRED to the felony branch

The felony design (api-plan §0, AgDR-0064-draft) defines the discriminator: a case is **felony iff it
has a `case_felony_details` row**; **renewal = the anti-join**. But on `development` **`case_felony_details`
does not exist** (no table, no entity, no `felonyintake` module — confirmed by code scan) and no felony
rows exist. **Therefore every case on `development` is a renewal case.**

**Decision:** ship the renewal list on `development` **with no discriminator predicate** (all cases =
renewal — correct while felony intake is not live), behind a single, explicit, isolated seam:

- The driving query goes through one method whose contract is "renewal cases only." On `development` its
  WHERE clause has no felony predicate. When the felony branch lands `case_felony_details`, that one method
  gains `AND NOT EXISTS (SELECT 1 FROM case_felony_details f WHERE f.case_id = c.id)` — **one predicate, one
  place, no rework** elsewhere.
- A code comment + this doc mark the seam so the felony branch cannot miss it. The felony branch's own
  "felony list = inner-join" story is the mirror image and will be added there.

This honours the CEO instruction (2026-07-17): *"on development we won't have case felony details, delay
this change for the felony branch."*

## 3. Backend design

> **Assembly approach — RECONSIDERED 2026-07-17 (CEO + Tech Lead), during PR #474 review.**
> §3.2 below originally specified a bespoke lean read model (a `ListRenewalCasesService` read-service +
> read-port + interface projection + a separate accused-names query). Two premises changed on review:
> **(1)** each row must carry each accused's **charges** (not just names), so loading the `Case` aggregate —
> which already holds accused + chargeIds — is a *requirement*, not over-fetch (only `charge_description`,
> a `NVARCHAR(MAX)` blob, is surplus, and it's loaded-and-ignored per CEO); **(2)** the felony/renewal seam
> lives cleanly as a `renewalOnly` dimension on the judicialcase `CaseFilter` — it does **not** touch
> `/core/cases` (which has no live list endpoint). **Decision: reuse `ListCasesUseCase.list` (full aggregate)
> and assemble the row in `DetentionRenewalWebMapper` via three batched reads** (charges → `GetChargesByIdsUseCase`,
> police → `GetPoliceStationsByIdsUseCase`, sessions → `CaseSessionStatsPort`). The read-service / read-port /
> projection are removed. The §3.3 inversion port is unchanged and still used (from the web mapper). The seam
> moves to `CasePersistenceAdapter.findPage` under `renewalOnly=true`, still pinned by an anchor test.
> §3.2's lean-projection detail is retained below as history.

### 3.1 Endpoint

`GET /api/v1/detention-renewals` — a **new `DetentionRenewalController`** in `judicialcase` (NOT on the generic
`CaseController`, which stays `/core/cases` for the shared `/search` + create-case ops). A domain-named,
renewal-cycle resource — **symmetric with the felony side's `/api/v1/felony-cases`**. *(CEO, 2026-07-17: the
generic `/core/cases` was the wrong home for a cycle-specific list.)* Module placement stays `judicialcase`
(the case's home module) for symmetry — felony's list lives in its cycle module `felonyintake`, not in
`courtsession`; the renewal analog is judicialcase, keeping case-read ownership there and using the §3.3
inversion port for the session columns.

```
@RestController @ApiV1 @RequestMapping("/detention-renewals")
class DetentionRenewalController {
  @GetMapping
  @PreAuthorize("@perms.has('" + CasePermission.Authority.CASE_READ + "')")
  ApiResponse<PaginatedData<RenewalCaseRow>> list(
          @ModelAttribute RenewalCaseListFilter filter, Pageable pageable) { … }
}
```

- `CASE_READ` already exists — no new permission.
- Filter binds `number` + `policeStationId` (both optional). Sort is server-controlled
  (`PageQueries.from(pageable, DEFAULT_SORT)`), default e.g. `number` asc — same pipeline as `iam/admin`.
- Output wrapped with `PaginatedData.fromList(...)` (1-based wire pages, `limit` param) per `backend/CLAUDE.md` §5.

### 3.2 Lean read model (CQRS-lite — mirrors AgDR-0070 story-A, NOT `findPage`)

The existing `ListCasesUseCase.list` returns the **full aggregate** per row (`CasePersistenceMapper.toDomain`
loads all accused) — the over-load the felony design flags. The list must **not** reuse it. Instead, three
**batched** reads per page (no N+1):

1. **Driving query** — `RenewalCaseRowProjection`: `id, number, year, policeStationId(+name)`, filtered
   (number LIKE, policeStationId =), the deferred renewal seam (§2), paginated + sorted. Returns the page's
   `caseIds`.
2. **Accused batch** — `accusedNamesByCaseIds(page.caseIds)` → `Map<CaseId, List<String>>` (names ordered by
   `position`). Gives both المتهمون (names) and عدد المتهمين (`.size()`). Reused verbatim from the felony
   read-model plan (accused model is track-agnostic).
   `SELECT case_id, name FROM case_accused WHERE case_id IN (:ids) ORDER BY position`.
3. **Session-stats batch** — `sessionStatsByCaseIds(page.caseIds)` → `Map<CaseId, SessionStats(long count,
   LocalDate lastSessionDate)>`. Gives عدد الجلسات + آخر تاريخ جلسة. **Cross-module — see §3.3.**
   **Status semantics — DECIDED (CEO, 2026-07-17): ALL scheduled sessions.** Count and `MAX(session_date)`
   include **every** live session regardless of status (`PENDING` + `AWAITING_VERDICT` + `FINISHED`) — so
   "آخر تاريخ جلسة" reflects the full calendar and **may be a future date**. No status predicate on the
   group-by (only `@SQLRestriction` soft-delete). Pin this in the port contract + persistence IT (assert a
   future `PENDING` session IS counted and CAN be the max date). FE renders the (possibly future) date plainly.

The controller/read-service assembles `RenewalCaseRow` from the three maps. All three keyed on the same page
of `caseIds`, so exactly 3 queries per page regardless of page size.

### 3.3 Cross-module session data — dependency-inversion port (the key constraint)

`courtsession → judicialcase` **already exists** in the module graph. A direct `judicialcase → courtsession`
call for the session columns would create a **cycle** that `ModularityTests` rejects. Resolution mirrors the
shipped `AccessScope` pattern (AgDR-0049) and the `iam/access` → `shared/security/AccessScopeResolver` inversion:

- Define the **port interface in `judicialcase`** (or `shared`): `CaseSessionStatsPort` with
  `Map<CaseId, SessionStats> statsFor(Collection<CaseId> ids)`.
- **`courtsession` implements it** (it already depends on `judicialcase`), backed by one group-by:

  ```
  SELECT s.caseId, COUNT(s), MAX(s.sessionDate)
  FROM CourtSessionJpaEntity s WHERE s.caseId IN :ids GROUP BY s.caseId
  ```

  `@SQLRestriction` keeps it live-only automatically. Cases with zero sessions are absent from the map →
  read-service defaults to `count 0, lastSessionDate null`.
- `judicialcase` depends only on its own interface. **No new edge; graph stays acyclic.**

### 3.4 Access-scoping — DECIDED: permission-only (CEO, 2026-07-17)

Felony scopes its list on `case_felony_details.court_id/division_id`. **Renewal cases have no intrinsic
court/division key** — the `cases` table has none, and a case only touches a division *through its sessions*
(and may have zero, or several across different divisions over time).

**DECIDED (v1): gate on `CASE_READ` permission only; do NOT court/division-scope the renewal list.**

- No case-level scope key exists; the shipped case `findPage` already applies no scope.
- The *sensitive* operations (viewing/editing a session + its transcript) are **already division-scoped** at
  the courtsession/transcript layer (AgDR-0049 M3). The list exposes only case identity + aggregate counts,
  not session content.
- Session-division scoping would make **zero-session cases invisible** to non-super-admins (fail-closed) and
  surface multi-division cases to any one scoped division — semantically muddy.

**Alternative (only if product wants day-roll parity):** scope to "renewal cases with ≥1 session in a
division ∈ `scope.divisionIds`." Reintroduces the cross-module dependency + the "no-sessions ⇒ invisible"
edge. **This is a conscious product call — flag for Tariq + CEO sign-off, do not assume.**

### 3.5 Files (backend)

- `judicialcase/application/`: `CaseSessionStatsPort` (interface), `SessionStats`, `RenewalCaseListFilter`,
  `ListRenewalCasesUseCase` + impl in a read-service (lean projection assembly).
- `judicialcase/infrastructure/persistence/`: projection query (anti-join seam), `accusedNamesByCaseIds`.
- `judicialcase/infrastructure/web/`: new `DetentionRenewalController` (`/detention-renewals`), `RenewalCaseRow`
  DTO, mapper.
- `courtsession/infrastructure/persistence/` + `.../application/`: `CaseSessionStatsPort` impl + group-by query,
  exposed via existing `courtsession → judicialcase` edge.
- Tests: persistence IT (anti-join seam returns all on dev; batch queries correct), `ModularityTests` stays
  green, web slice test for the endpoint + permission gate.

## 4. Frontend design

Mirror the shipped list-page pattern (`sections/core/judges/view/judge-list-view.tsx` — the **filtered**
variant: TanStack-Table-v8-through-MUI, `useSetState` filters, debounced search, `TablePagination`).

- **Page:** `pages/dashboard/detention-renewal/renewal-cases-list.tsx` (thin Helmet + view).
- **View + toolbar + columns:** `sections/detention-renewal/renewal-list/`. Columns per §1; رقم القضية
  rendered as a `RouterLink` (target = case details route — **see open question**).
- **Data:** endpoint in `utils/axios.ts` `endpoints` (new — none exists yet); service in
  `api/actions/`; `useQuery` hook in `api/hooks/` with `queryKeys`; hand-written types
  `api/types/renewal-case.ts` (`RenewalCaseRow` + `RenewalCaseListParams`). Pagination 1-based, `limit` param.
- **Routing (3 edits):** `routes/paths.ts` (add `detentionRenewal.cases`), `routes/sections/*.tsx`
  (`lazy()` + `<PermissionGuard permission={PERMISSIONS.CASE_READ}>`), `layouts/config-nav-dashboard.tsx`
  (nav item gated on `PERMISSIONS.CASE_READ`).
- **Filters:** case number (debounced text) + police station (Autocomplete of stations — reuse existing
  police-station options source).

**رقم القضية link target — DECIDED: plain text, no link (CEO, 2026-07-17).** The screenshot styles the case
number as a link, but for this MVP it navigates nowhere — render the number as styled (gold) but non-navigating
text. A link target can be wired later when the case-details page ships.

## 5. Ticket breakdown (proposed)

Filed under **Epic #464**:

| Item | Ticket | Layer | Notes |
|---|---|---|---|
| T1 | **#466** | BE | `CaseSessionStatsPort` inversion port + courtsession group-by impl (all-status per R1) + ModularityTests green. **AgDR-0078: port placement in consumer (`judicialcase`) vs `shared` — Tariq R3** |
| T2 | **#467** | BE | Renewal lean read model + `GET /detention-renewals` (`DetentionRenewalController`) + `CASE_READ` gate + the deferred anti-join seam + **anchor test for the seam (Tariq R2)**. Blocked-by #466 |
| T3 | **#468** | FE | Renewal list page + routing + nav + permission gate + 2 filters; رقم القضية = styled non-navigating text; `null` last-date → empty cell. Blocked-by #467 |

Each = one PR off `development`, own Rex review.

## 7. Review outcome (Tariq, 2026-07-17) — SOUND-WITH-REFINEMENTS

Verified correct: the inversion port keeps `ModularityTests` green (simpler than the `AccessScope`
precedent — the port lives in the consumer `judicialcase` because the `courtsession → judicialcase` edge
already flows that way); `@SQLRestriction` auto-filters soft-deleted sessions; the deferral seam is a sound
YAGNI; the 3-query lean read model is the right CQRS-lite shape.

Refinements folded in: **R1** session-status semantics (§3.2 — the one pending decision, see §6); **R2**
anchor test for the felony seam (T2); **R3** AgDR-0078 for the consumer-local port placement (T1); **R4**
below.

**R4 — Security flag (advisory).** Permission-only scoping means **any `CASE_READ` holder sees case number +
accused names (PII) for every case, including cases whose sessions belong to a division outside their scope**.
Session *content* stays division-scoped (correct). CEO owns this call (made knowingly); flagged for the
Security Auditor to acknowledge, not a blocker.

## 6. Decisions

**Settled (CEO, 2026-07-17):**

1. **Access-scoping:** ✅ permission-only (`CASE_READ`). *(§3.4)*
2. **رقم القضية link target:** ✅ plain text, no link for MVP. *(§4)*
3. **Discriminator deferral:** ✅ all cases = renewal on `development`; anti-join seam added on the felony
   branch. *(§2)*

4. **Session-count / last-date semantics:** ✅ **all scheduled** sessions (incl. future `PENDING`); last date
   may be a future date. No status predicate on the group-by. *(§3.2)*

All decisions settled — both designs build-ready.
