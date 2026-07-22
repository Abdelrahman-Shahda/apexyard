# Felony Day Roll (جدول اليوم — جنايات أول درجة) — Technical Design

> **Status:** revision 2 — folds in Tariq's design review of PR #548 (CHANGES REQUESTED on rev 1, findings B1–B9) and the CEO's endpoint-separation constraint. **Branch base:** `development`.
> **Target repo:** apessolutions/moj_judiciary. **Epic:** #538. **Ticket:** #539 (F0). **PR:** #548.
> **Decisions:** AgDR-0093 (ten decisions), AgDR-0094 (migration — authored under #540).
> **Source of truth (ACs):** [Confluence — جدول اليوم (جنايات أول درجة)](https://apessolutions.atlassian.net/wiki/spaces/MOJ/pages/1191772164), stories JNA-DAY-A … I (J retired).
> **Screens:** `projects/Moj/design/felony-cases-roll/*.png`
> **Related:** AgDR-0088 (track split), AgDR-0085 (`SessionCore`), AgDR-0083 (advisory lock), AgDR-0025 (رول vs position), AgDR-0049 / AgDR-0073 (access scoping), AgDR-0072 (felony API boundary), AgDR-0090 (proceeding-type denormalization).

## 1. Problem

One screen — **جدول اليوم (جنايات)** — where a session secretary picks a **court**, a **division**, and **any day**, then sees and edits that day's **هيئة المحكمة**, builds the day's pool of **محامون منتدبون**, and views the day's **roll** of felony sessions, assigning each a **رول الجلسة**, reordering the list, and opening a session to execute it.

Three deltas from the shipped detention-renewal day roll:

| # | Delta | Why it matters |
|---|---|---|
| 1 | **The day is free**, not locked to today | Renewal derives "today" server-side and refuses a `date` param (AgDR-0012/0013). Felony sessions are booked weeks ahead and must be preparable before their date. |
| 2 | **رول starts unassigned**, secretary-managed | Booking must place a session on the roll with no رول; the secretary assigns it here, unique per day + division. |
| 3 | **محامون منتدبون day-pool** | A new day-scoped list keyed by رقم النقابة lookup. Renewal has no equivalent. |

### 1.1 Scope boundary

Sessions reach this roll **only** by booking in the قضايا الجنايات intake cycle (#321). This screen has **no إضافة جلسة and no remove control** — the only per-session action is to open and execute it. محامون are assigned to individual accused **per session in Cycle 2**, drawn from the pool built here.

**Known gap (not a blocker).** `POST /felony-cases/{caseId}/sessions` — booking a *subsequent* session — is still a stub throwing `UnsupportedOperationException` (#387). Only first sessions from composite intake reach a roll today.

## 2. What already exists — verified against `development` @ `f931e22c`

| Capability | Where | Status |
|---|---|---|
| Roll list for an **explicit date** | `ListCourtSessionsUseCase.listRoll(divisionId, date, status, text)` | ✅ Exists. Javadoc names future-dated felony bookings as the reason it was added (#504). Asserts `assertCanAccessDivision`. |
| Per-status counts for an explicit date | `CountCourtSessionsByStatusUseCase.countRollByStatus(...)` | ✅ Exists, same rationale, same guard. |
| Panel for an explicit date | `GetEffectivePanelUseCase.getEffectivePanel(divisionId, date)` | ✅ Already date-aware. Ports, web DTOs, and permission constants are `@NamedInterface`-exposed. |
| Panel propagation to PENDING sessions | `DivisionPanelSavedEvent` → `DivisionPanelPropagationListener` | ✅ Free — §5.3 needs no new propagation logic. |
| Drag reorder | `ReorderCourtSessionUseCase.moveTo` + sibling re-spacing | ✅ |
| Max رول per (division, date) | `GetMaxRollPositionUseCase` | ✅ Already published — this is what renewal's relocated fallback calls. |
| Lawyer registry with رقم النقابة | `core/lawyer` — `Lawyer`, `BarNumber`, filtered unique index on `bar_number` | ✅ No new registry. |
| Track discriminator on cases | `cases.proceeding_type` (`NOT NULL`), `ProceedingType` in `shared.domain` | ✅ Zero new module edges to use it. |
| Access scoping | `AccessScope` / `AccessScopeGuard`, fail-closed on empty | ✅ AgDR-0049 / 0073. |
| Nullable-column migration runbook | `V20260720150759__nullable_session_prosecutor.sql` | ✅ Direct precedent for #540 — reuse it. |

### 2.1 What does NOT exist (corrections from review)

Revision 1 got these wrong. They are the real work:

- **`max+1` is in `SessionCore.create` (lines 102–112), not the aggregate** — the shared seam *both* tracks call.
- **Felony already receives `max+1`.** `FelonySessionBookingService:110` passes `rollPosition = null`, which triggers the fallback. This cycle changes shipped intake behaviour, deliberately.
- **`position` is seeded from رول** — `int position = rollPosition;`. With a null رول there is no source for display order. **No `maxPosition` port exists.** This is the one genuinely missing port.
- **`CourtSessionSummary.rollPosition` and renewal's `CourtSessionResponse.rollPosition` are primitive `int`**, passed straight through `CourtSessionWebMapper` (lines 134, 216). Both must become `Integer`.
- **A correlated `EXISTS` over `cases` from `courtsession` does not compile** — `CaseJpaEntity` is package-private, which is exactly why `FelonyCaseListPersistenceAdapter` lives in `judicialcase`.
- **`DivisionPanelWebMapper` is package-private** and not a named interface — #543 is blocked until it is exposed.

## 3. The separation rule (CEO, 2026-07-22)

**All felony endpoints live in `felonyintake`. Felony never reuses a detention-renewal endpoint, even where the underlying logic is identical** — so either track's behaviour can change later without touching the other. Full rationale in AgDR-0093 Decisions 1, 2, and 8.

| Layer | Separated? |
|---|---|
| Controllers / routes | **Yes** — felony controllers in `felonyintake` under `/api/v1/felony/...` |
| Response DTOs + web mappers | **Yes** — felony owns its roll row + day-roll envelope, mirroring how `detentionrenewal` owns `CourtSessionResponse` / `DayRollResponse` |
| Track workflow / application services | **Yes** |
| FE views, contexts, columns, row actions | **Yes** |
| Sub-DTOs owned by other slices (case, station, charges, division) | **No** — still sourced from their owning slice's mapper (CLAUDE.md) |
| `CourtSession` aggregate, its invariants, `CourtSessionRepository` | **NO — never.** Centralised in `courtsession` by AgDR-0088; `ModularityTests` pins it twice. Duplicating it would fork the invariants. |

The last row is the one a build agent could get wrong by over-applying the rule. It is stated in the AgDR's *Decision* section, not only in prose, so #542's implementer reads it.

## 4. Backend — `courtsession` changes (#541)

The aggregate custodian keeps owning the invariants.

```java
private Integer rollPosition;                    // was int; @Column(nullable=false) relaxed in the same PR

public interface AssignRollPositionUseCase {
    CourtSession assign(UUID sessionId, Integer rollPosition);   // null = clear
}

public interface ReorderRollByRollPositionUseCase {
    void reorderByRoll(UUID divisionId, LocalDate date);
}

public interface GetMaxPositionUseCase {                          // NEW — the missing port
    int maxPosition(UUID divisionId, LocalDate date);
}
```

**Relocating `max+1`.** Out of `SessionCore.create`, into `DetentionRenewalApplicationService.commit`, calling the already-published `GetMaxRollPositionUseCase`. `SessionCore` then passes through whatever it is given, including null.

**Seeding `position`.** `position = maxPosition(divisionId, date) + 1`, so a new session lands at the end of the day's list whether or not it has a رول.

**Pinning renewal.** `SessionCoreTest:134` asserts the current `max+1` behaviour and is deleted by this change. **Its assertion must be re-homed onto the renewal application-service test in the same PR** — otherwise nothing pins renewal.

**Track filtering.** `court_sessions` gains a denormalized `proceeding_type`, written at creation from `SessionCreationParams`, backfilled once from `cases.proceeding_type`. The felony roll read goes through a **track-specific, access-guarded port** applying the predicate internally.

> **Deliberately not a public `CourtSessionFilter` dimension.** `listRoll` / `countRollByStatus` assert `assertCanAccessDivision`; the scalar `list(filter)` / `countByStatus(filter)` overloads do **not**, and `CourtSessionFilter` is on the published allowlist. A public dimension would point a build agent at the unguarded overload and silently drop access scoping — a fail-closed violation of AgDR-0049/0073.

## 5. Backend — felony surface (`felonyintake`)

### 5.1 Roll endpoints (#542)

Base `/api/v1/felony/divisions/{divisionId}/court-sessions`:

| Method · Path | Perm | Purpose |
|---|---|---|
| `GET /?date=&status=&text=` | `COURT_SESSION_READ` | Day's roll + per-status counts. `date` required. Counts span every bucket regardless of `status`. |
| `GET /{sessionId}` | `COURT_SESSION_READ` | Full session payload. |
| `PUT /{sessionId}/roll-position` | `COURT_SESSION_UPDATE` | Assign / change / clear رول. 422 on duplicate. |
| `PUT /{sessionId}/position` | `COURT_SESSION_UPDATE` | Persist a drag-reorder. |
| `POST /reorder-by-roll?date=` | `COURT_SESSION_UPDATE` | Whole-day re-sort by رول, NULLs last, one transaction. |

Felony-owned row + envelope DTOs and web mapper (§3). Sub-DTOs from their owning slices' mappers.

**Access scoping.** Every route resolves `AccessScopeGuard.currentScope()` **inside the service**, never as a caller-supplied parameter, fail-closed on empty — mirroring `FelonyCaseListApplicationService`.

**رول uniqueness.** Advisory lock on (division, date) around assign, following the `CaseIdentityLock` / AgDR-0083 precedent; the filtered unique index is the backstop; the service pre-check owns the localized 422. Revision 1's "adapter translates the constraint violation" is rejected — AgDR-0083 already rejected it, and Hibernate raises at flush, after `save()` returns.

### 5.2 Panel endpoints (#543)

A **felony panel controller in `felonyintake`**, `GET`/`POST /api/v1/felony/division-panels?divisionId=&date=`, consuming `core.divisionpanel`'s already-exposed ports. Permissions: `DIVISION_PANEL_READ` / `DIVISION_PANEL_UPDATE`. The existing `/detention-renewal/division-panels` controller stays renewal's and is untouched.

**Enabling step:** `DivisionPanelWebMapper` is package-private and not a named interface. Exposing it is a prerequisite in this ticket — CLAUDE.md forbids constructing another slice's DTO inline. Exactly the "small enabling step" AgDR-0072 anticipated.

PENDING-only propagation comes free from `DivisionPanelSavedEvent` → `DivisionPanelPropagationListener`.

### 5.3 منتدب day-pool + نقابة lookup (#544)

```
GET    /api/v1/core/lawyers/lookup?barNumber=                        isAuthenticated()
GET    /api/v1/felony/divisions/{divisionId}/appointed-lawyers?date=  COURT_SESSION_READ
POST   /api/v1/felony/divisions/{divisionId}/appointed-lawyers?date=  COURT_SESSION_UPDATE
DELETE /api/v1/felony/divisions/{divisionId}/appointed-lawyers/{id}   COURT_SESSION_UPDATE
```

Aggregate owned by **`felonyintake`**. `lawyer_id` nullable, `lawyer_name` always populated. No attendance method. منتدب terminology throughout.

The lookup is `isAuthenticated()`, **not** `LAWYER_READ`: a secretary needs to resolve a name but has no business browsing or editing the registry. Returns one lawyer or a not-found result — never a 500, never a list.

## 6. Migration (#540)

Precedent to reuse verbatim: `V20260720150759__nullable_session_prosecutor.sql`.

1. `ALTER TABLE court_sessions ALTER COLUMN roll_position INT NULL` — and relax `@Column(nullable = false)` on the entity in the **same PR**, or Hibernate validation fails.
2. `ADD proceeding_type` + one-time backfill from `cases.proceeding_type`.
3. **Duplicate probe first**, covering **both** renewal and felony rows (felony rows carry auto-assigned numbers too), before creating:
   `uq_court_sessions_roll_per_division_day` on `(division_id, session_date, roll_position) WHERE roll_position IS NOT NULL AND deleted_at IS NULL`.
4. `CREATE TABLE felony_day_appointed_lawyers` — id, division_id, session_date, lawyer_id NULL, lawyer_name, created_at / updated_at / deleted_at.

**No backfill of existing رول values** (CEO, 2026-07-22): booked felony sessions keep their auto-assigned numbers; only new bookings start unassigned.

## 7. Frontend

- **Route** `/today-roll-felony`; nav «جدول اليوم (جنايات)» gated on `COURT_SESSION_READ`.
- **Context** — felony-day provider holding `court`, `division`, **`date`**, `panelId` in URL search params.
- **Date navigator** — prev/next plus a picker, Arabic long form. Genuinely new; nothing like it exists today.
- **Roll table** — promoted shell, felony columns: رول الجلسة · رقم القضية · قسم الشرطة · المتهمون · التهم · الدائرة · سبب النظر · حالة الجلسة · 👁 · drag handle.
- **رول cell** — inline-editable; empty renders «بدون رول»; a duplicate surfaces the server message **without discarding the typed value**.
- **Reorder** — drag (per-row, optimistic) plus «إعادة الترتيب حسب الرول» (one call, then refetch).
- **منتدب card** — count in header, empty state, add dialog with نقابة autofill and manual-name fallback.
- **Execute-only** — no add/remove session controls.

### 7.1 Promotion boundary (#545)

| Promoted | Stays track-local |
|---|---|
| `roll-table.tsx`, `sortable-roll-row.tsx`, `roll-reorder.ts`, `roll-status-tabs.tsx` | `columns.tsx` (injected as a prop) |
| `court-division-select.tsx`, `use-auto-select-sole-option.ts` | `use-roll-row-actions.ts` — renewal edits/deletes, felony executes |
| `panel/` — card, composer, seat / prosecutor / additional-judge fields | `roll-toolbar.tsx`, `roll-filters.ts`, `use-roll-data.ts`, the add/edit session drawers, `session-audit-drawer.tsx` |

Strictly mechanical. Verified by the existing renewal FE tests passing unchanged.

## 8. Testing strategy

| Area | Coverage |
|---|---|
| Nullable رول (**highest risk**) | Null round-trips; clear sets null; duplicate rejected; unassigned sorts last |
| Renewal preservation | The **re-homed** `SessionCoreTest:134` assertion on the renewal service — the single test proving renewal is unchanged |
| Felony booking change | New felony booking lands `rollPosition = null` and a sane `position` |
| `position` seeding | `maxPosition + 1` when رول is null; ordering stays deterministic |
| Uniqueness | Index rejects a duplicate; same رول on another day/division accepted; soft-deleted row does not block reuse; concurrent assign serialised by the advisory lock |
| Track filtering | A renewal session in the same division never appears on a felony roll |
| Access scoping | Deny path — empty scope denies rather than widens |
| FE promotion | Existing renewal FE tests passing unchanged |

## 9. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | Nullable رول touches the shared creation seam behind the **live** renewal roll | Own migration, own PR, `max+1` relocated not deleted, re-homed pinning test required in #541's ACs |
| R2 | Uniqueness index fails to create on duplicate existing data | #540 probes first, covering **both** tracks' rows |
| R3 | Concurrent رول assignment | Advisory lock (AgDR-0083 precedent); index as backstop |
| R4 | A build agent puts `proceedingType` on the public filter and reaches the unguarded overload | Track-specific guarded port instead; called out explicitly in §4 |
| R5 | FE promotion touches renewal files while PR #515 is open | Mechanical; conflict surface limited to `paths.ts`, `setup.tsx`, `config-nav-dashboard.tsx` |
| R6 | Existing felony sessions show auto-assigned رول alongside new unassigned ones | Accepted (CEO). A secretary can clear any رول inline |
| R7 | Roll near-empty until #387 lands | Accepted; not a dependency |

---

*Part of the Moj portfolio under ApexYard. Epic #538 · Design ticket #539 · PR #548.*
