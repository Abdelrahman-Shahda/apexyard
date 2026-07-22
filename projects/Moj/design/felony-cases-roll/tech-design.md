# Felony Day Roll (جدول اليوم — جنايات أول درجة) — Technical Design

> **Status:** design, awaiting review (Tariq + CEO). **Branch base:** `development`.
> **Target repo:** apessolutions/moj_judiciary. **Epic:** #538. **Ticket:** #539 (F0).
> **Decisions:** AgDR-0093 (this cycle's seven calls), AgDR-0094 (migration — filed under #540).
> **Source of truth (ACs):** [Confluence — جدول اليوم (جنايات أول درجة)](https://apessolutions.atlassian.net/wiki/spaces/MOJ/pages/1191772164), stories JNA-DAY-A … I (J retired).
> **Screens:** `projects/Moj/design/felony-cases-roll/*.png`
> **Related:** AgDR-0088 (courtsession track split), AgDR-0025 (rollPosition vs position), AgDR-0049 / AgDR-0073 (access scoping), AgDR-0072 (felony API boundary), AgDR-0090 (proceeding-type scoping).

## 1. Problem

One screen — **جدول اليوم (جنايات)** — where a session secretary picks a **court**, a **division**, and **any day**, then:

1. sees and edits that day's **هيئة المحكمة** (panel),
2. builds the day's pool of **محامون منتدبون**,
3. views the day's **roll** of felony sessions, assigns each one a **رول الجلسة**, reorders the list, and opens a session to execute it.

Three things distinguish it from the shipped detention-renewal day roll:

| # | Delta | Why it matters |
|---|---|---|
| 1 | **The day is free**, not locked to today | Renewal derives "today" server-side and refuses a `date` param (AgDR-0012/0013). Felony sessions are booked weeks ahead and must be visible and preparable before their date. |
| 2 | **رول starts unassigned** and is secretary-managed | Renewal auto-fills `max+1` at commit. Felony booking must place a session on the roll **with no رول**; the secretary assigns it here, unique per day + division. |
| 3 | **محامون منتدبون day-pool** | A new day-scoped list, keyed by رقم النقابة lookup. Renewal has no equivalent — its lawyers are ad-hoc free text per accused. |

Everything else — the roll table, drag reorder, status buckets, search, court/division selection, panel composition — is behaviourally identical to renewal and is **reused, not rebuilt**.

### 1.1 Scope boundary

Sessions reach this roll **only** by booking in the قضايا الجنايات intake cycle (#321). This screen has **no إضافة جلسة and no remove control** — the only per-session action is to open and execute it. محامون are assigned to individual accused **per session in Cycle 2**, drawn from the pool built here; that assignment is out of scope for this cycle.

**Known gap (not a blocker).** `POST /felony-cases/{caseId}/sessions` — booking a *subsequent* session — is still a stub throwing `UnsupportedOperationException` (#387). Only first sessions from composite intake reach a roll today, so the roll stays sparse until #387 lands. This design does not depend on #387.

## 2. What already exists (the reuse surface)

This cycle is small because the `detentionrenewal` track split (AgDR-0088) already made the machinery track-agnostic. Verified against `development` @ `f931e22c`:

| Capability | Where it lives today | Reusable as-is? |
|---|---|---|
| Roll list for an **explicit date** | `ListCourtSessionsUseCase.listRoll(divisionId, date, status, text)` | ✅ Already exists. Its javadoc states it was added precisely so *"a future-dated felony booking is visible before its date arrives"*. |
| Per-status counts for an explicit date | `CountCourtSessionsByStatusUseCase.countRollByStatus(divisionId, date, status, text)` | ✅ Already exists, same rationale. |
| Panel for an explicit date | `GetEffectivePanelUseCase.getEffectivePanel(divisionId, date)` | ✅ Already date-aware; used by `FelonySessionBookingService`. |
| Drag reorder | `ReorderCourtSessionUseCase.moveTo(sessionId, newPosition)` + sibling re-spacing | ✅ |
| رول / display-order separation | `CourtSession.rollPosition` (frozen) vs `.position` (display sort key), AgDR-0025 | ✅ The separation is right; only the nullability is wrong. |
| Roll row wire shape | `CourtSessionSummary` — case, station, accused + charges, division, hearing reason, status, rollPosition | ✅ Covers every column on the screens. |
| Lawyer registry with رقم النقابة | `core/lawyer` — `Lawyer` aggregate, `BarNumber` VO, `lawyers` table with a filtered unique index on `bar_number` | ✅ No new registry needed. |
| Felony/renewal discriminator | `cases.proceeding_type` (`RENEWAL` \| `FELONY`), shipped | ✅ Cheaper than joining `case_felony_details`. |
| Access scoping | `AccessScope` / `AccessScopeGuard` — `courtRestriction()`, `divisionRestriction()`, `canAccessCourt`, `canAccessDivision`; fail-closed on empty | ✅ AgDR-0049 / 0073. |

**The only invasive change is nullability of `court_sessions.roll_position`** — today `INT NOT NULL`, with the `max+1` fallback baked into the aggregate. It is shared with live detention-renewal, which is why it is isolated into its own migration (#540) and its own PR (#541).

## 3. Decisions

The seven calls this design commits to. Full options + trade-offs in **AgDR-0093**; summarized here so the build tickets are unambiguous.

### D1 — Module and URL placement: `felonyintake`, under `/api/v1/felony/...`

**Decision:** the felony roll's application + web layer lands in the existing **`felonyintake`** module. Routes sit under `/api/v1/felony/divisions/{divisionId}/court-sessions` — a **division/day** resource, deliberately *not* under the existing `/felony-cases` **case** resource.

Rejected: a fourth module (`felonyday`). It would be a second domain-less track module over the same aggregate, for one screen, duplicating `felonyintake`'s exact dependency shape (`→ {judicialcase, courtsession, core}`) with no new boundary to protect. AgDR-0072 already chose "one un-scattered felony surface"; splitting felony REST across two modules now contradicts that with no gain.

The graph stays acyclic: `felonyintake → courtsession` already exists (the booking path). No new edge. `ModularityTests` is the check.

> **Naming note.** The module name `felonyintake` becomes slightly narrow once it hosts a day-roll. That is a rename question, not an architecture question — deliberately deferred rather than bundled into a delivery cycle.

### D2 — `rollPosition` becomes nullable; renewal's `max+1` moves to its call site

**Decision:** `CourtSession.rollPosition` becomes `Integer` (nullable) in the domain, the JPA entity, the persistence mapper, and `CourtSessionSummary`. The implicit `max(rollPosition)+1` fallback moves **out of the aggregate** into the **detention-renewal commit path**, where it belongs — it was always a renewal policy, not a session invariant.

Why this shape rather than a felony-only column or a sentinel value:

- A felony-only `felony_roll_position` column would fork the roll's ordering logic in two, and every read model would need to know which column to consult.
- A sentinel (`0` or `-1` meaning unassigned) makes "unassigned last" a magic-number sort and leaks the sentinel into every DTO and every FE comparison. `NULL` *is* the language's word for this.
- Nullable-with-policy-at-the-call-site keeps one aggregate, one ordering rule, and lets each track state its own booking policy — the exact separation AgDR-0088 established.

**Renewal behaviour must be byte-for-byte unchanged.** What pins that: the characterization tests for `commit()` / `edit()` added under #504, plus new coverage asserting a renewal commit with no explicit رول still lands `max+1`.

`position` (display order) stays `int NOT NULL` and is unchanged. A session with no رول still has a display position.

### D3 — رول uniqueness: DB index is the guarantee, service check is the message

**Decision:** enforce in **both** places, with distinct jobs.

- **Filtered unique index** `(division_id, session_date, roll_position) WHERE roll_position IS NOT NULL AND deleted_at IS NULL` — the actual guarantee. It holds under concurrency, which a service-layer read-then-write cannot.
- **Service-layer pre-check** — owns the *user-facing* error: a localized 422 naming the conflicting رول, consistent with the field-validation pattern used across the codebase.

The service check is not redundant with the index; it is what turns a constraint violation into a message a secretary can act on. The index is what makes the rule true. The persistence adapter must also translate a raced constraint violation into the same 422 rather than a 500 — two secretaries assigning the same رول simultaneously is a realistic scenario in a court's registry office, not a theoretical one.

Uniqueness is scoped to **(division, date)** — the same رول number legitimately recurs on other days and in other divisions.

### D4 — Reorder-by-رول is one server-side call for the whole day

**Decision:** `POST .../court-sessions/reorder-by-roll?date=` rewrites `position` for every session in that (division, date) from `rollPosition ASC`, **unassigned (NULL) last**, inside one transaction. Ties among unassigned rows keep their current relative order (stable sort on the existing `position, createdAt, id` tie-break).

Rejected: having the FE compute the new order and fire N `PUT .../{id}/position` calls. For a 40-session felony day that is 40 round-trips, non-atomic (a failure halfway leaves the roll in a state neither the user nor the server intended), and it re-implements a sort the database can express directly.

Drag-and-drop keeps its existing per-row endpoint — one drop is genuinely one intent, and the optimistic-update path already works.

Both mechanisms ship (CEO, 2026-07-22). They are not redundant: drag expresses "this case should go before that one" without committing to a رول number; the button expresses "make the display match the رول numbers I just entered."

### D5 — منتدب day-pool: own aggregate, keyed (division, date), no attendance method

**Decision:** a new aggregate with table `felony_day_appointed_lawyers`, keyed on **(division_id, session_date)**, carrying `lawyer_id` (**nullable**, FK to `lawyers`) and `lawyer_name` (**always populated**).

- A lawyer found by رقم النقابة is stored with both the `lawyer_id` reference **and** the resolved name. Storing the name is deliberate denormalization: the pool is a **record of who was appointed that day**, and it must not silently change if the registry entry is later edited or deactivated.
- A lawyer not in the registry is stored with `lawyer_id = NULL` and a typed name. This is a supported path, not a degraded one.

**No `attendance_method` column.** CEO decision (2026-07-22): these lawyers are always physically present in court. This is a conscious departure from Confluence JNA-DAY-D scenario 4, recorded here so QA reads it as a decision rather than a defect. Adding the column later is a nullable-column migration — cheap, and cheaper than shipping a required field nobody fills in truthfully.

**Terminology: منتدب / `appointed` everywhere** — table name, column names, DTO fields, message keys, UI copy. Never متطوع / `volunteer`. The Confluence pages still say متطوع; this design supersedes that wording per CEO. The two words mean different things in Egyptian court practice and the distinction is load-bearing.

### D6 — Roll queries filter on `proceedingType`

**Decision:** add a `proceedingType` dimension to `CourtSessionFilter`, implemented as a correlated `EXISTS` subquery over `cases` (mirroring `FelonyCaseListPersistenceAdapter`). The felony roll passes `FELONY`; the renewal roll passes `null` — preserving today's behaviour exactly.

Why bother, when a felony division and a renewal division are different divisions in practice? Because "in practice" is not an invariant. Nothing in the schema prevents a division from hosting both, division routing config is editable by administrators, and a renewal session surfacing on a felony roll would be a data-leak-shaped bug found in production rather than a compile error found here. The predicate costs one indexed subquery.

`cases.proceeding_type` already exists and AgDR-0090 already established it as a scoping dimension — this is applying a shipped pattern, not inventing one.

### D7 — FE: promote the track-agnostic components, keep columns local

**Decision** (CEO chose promotion over copying):

| Promote to shared | Keep track-local |
|---|---|
| `roll-table.tsx` (table shell, dnd context, skeleton/empty states) | `columns.tsx` — column *definitions* are injected as a prop |
| `sortable-roll-row.tsx`, `roll-reorder.ts` | `use-roll-row-actions.ts` — renewal has edit/delete, felony is execute-only |
| `roll-status-tabs.tsx` | add/edit session drawers — renewal-only by definition |
| `court-division-select.tsx`, `use-auto-select-sole-option.ts` | the date navigator — felony-only for now |
| `panel/*` (card, composer, seat/prosecutor/additional-judge fields) | page-level views and contexts |

The promotion PR (#545) is **strictly mechanical** — no behaviour change, and any generalization must be pure parameterisation with renewal passing exactly what it passes today. It lands before #546/#547 start.

The alternative — copying into a felony folder — buys full parallelism immediately at the cost of two roll tables that diverge from day one. With the renewal roll already in production use, a divergent second copy means every future roll fix has to be made and verified twice.

## 4. Backend design

### 4.1 `courtsession` changes (#541)

The aggregate custodian keeps owning the invariants. New/changed ports:

```java
// nullable now
private Integer rollPosition;

// new coarse port — assign, change, or clear
public interface AssignRollPositionUseCase {
    CourtSession assign(UUID sessionId, Integer rollPosition);   // null = clear
}

// new coarse port — whole-day re-sort
public interface ReorderRollByRollPositionUseCase {
    void reorderByRoll(UUID divisionId, LocalDate date);
}
```

`CourtSessionFilter` gains a fourth dimension:

```java
public record CourtSessionFilter(
        UUID divisionId, LocalDate sessionDate,
        CourtSessionStatus status, String text,
        ProceedingType proceedingType) { … }
```

Per AgDR-0088's union-parameter test: `proceedingType` is populated meaningfully by **both** tracks (`FELONY` for one, `null`-meaning-unrestricted for the other), so it is a genuine shared dimension, not one track's field parked on a shared record.

`CourtSessionRepository` is **not** published cross-module — `felonyintake` reaches the aggregate only through the task-shaped ports above, consistent with AgDR-0088.

### 4.2 Felony roll endpoints (#542)

All in `felonyintake/infrastructure/web/FelonyDayRollController`, base `/api/v1/felony/divisions/{divisionId}/court-sessions`:

| Method · Path | Perm | Purpose |
|---|---|---|
| `GET /?date=&status=&text=` | `COURT_SESSION_READ` | The day's roll + per-status counts. `date` **required**. Counts span every bucket regardless of `status`. |
| `GET /{sessionId}` | `COURT_SESSION_READ` | Full session payload. |
| `PUT /{sessionId}/roll-position` | `COURT_SESSION_UPDATE` | Assign / change / clear رول. 422 on duplicate. |
| `PUT /{sessionId}/position` | `COURT_SESSION_UPDATE` | Persist a drag-reorder. |
| `POST /reorder-by-roll?date=` | `COURT_SESSION_UPDATE` | Whole-day re-sort by رول (D4). |

Reuses `CourtSessionSummary` and the `courtsession` web mapper — no re-mapped inline DTOs (AgDR-0072 build rule).

**Access scoping.** Every route resolves `AccessScopeGuard.currentScope()` **inside the service**, never as a caller-supplied parameter, and is fail-closed: an empty restriction set denies rather than widens. This mirrors `FelonyCaseListApplicationService` exactly. The roll is a division resource, so the division check is the primary gate, with the court check applied through the division's court.

### 4.3 Felony panel endpoints (#543)

`GET`/`POST /api/v1/felony/division-panels?divisionId=&date=`, delegating to the already-date-aware `GetEffectivePanelUseCase`. Save propagates to that day's **not-yet-started** sessions only; started sessions stay frozen. Renewal's today-derived panel endpoints are untouched.

### 4.4 منتدب day-pool + نقابة lookup (#544)

```
GET    /api/v1/core/lawyers/lookup?barNumber=          isAuthenticated()
GET    /api/v1/felony/divisions/{divisionId}/appointed-lawyers?date=    COURT_SESSION_READ
POST   /api/v1/felony/divisions/{divisionId}/appointed-lawyers?date=    COURT_SESSION_UPDATE
DELETE /api/v1/felony/divisions/{divisionId}/appointed-lawyers/{id}     COURT_SESSION_UPDATE
```

The lookup is gated on `isAuthenticated()`, **not** `LAWYER_READ`: a session secretary needs to resolve a name to do their job but has no business browsing or editing the lawyer registry. It returns a single lawyer or a not-found result — never a 500, and never a list (it is not a search surface).

### 4.5 Files

- `courtsession/domain/` — `CourtSession` (nullable رول + assign behaviour), `CourtSessionFilter` (+ `proceedingType`)
- `courtsession/application/` — `AssignRollPositionUseCase`, `ReorderRollByRollPositionUseCase`
- `courtsession/infrastructure/persistence/` — entity nullability, mapper, `proceedingType` predicate, constraint-violation translation
- `detentionrenewal/application/` — `max+1` fallback relocated here
- `felonyintake/application/` + `.../infrastructure/web/` — roll service + controller + panel controller + appointed-lawyer slice
- `core/lawyer/` — lookup use case + endpoint
- `db/migration/courtsession/` + `db/migration/felonyintake/` — see #540

## 5. Frontend design

- **Route** `/today-roll-felony`; nav «جدول اليوم (جنايات)» gated on `COURT_SESSION_READ`.
- **Context** — a felony-day provider holding `court`, `division`, **`date`**, and `panelId` in URL search params (renewal's context deliberately has no `date`; this one does, so a prepared day is linkable and survives refresh).
- **Date navigator** — prev/next arrows plus a picker, rendering the day in Arabic long form («الأربعاء 22 يوليو 2026»). No component like this exists anywhere in the app today; it is genuinely new.
- **Roll table** — the promoted shell with felony columns: رول الجلسة · رقم القضية · قسم الشرطة · المتهمون · التهم · الدائرة · سبب النظر · حالة الجلسة · 👁 · drag handle.
- **رول cell** — inline-editable. Empty renders «بدون رول». A duplicate surfaces the server's message **without discarding the typed value**, so the secretary can correct rather than retype.
- **Reorder** — drag (per-row, optimistic, as renewal does) plus «إعادة الترتيب حسب الرول» (one call, then refetch).
- **منتدب card** — count in the header, empty state explaining the pool feeds per-session assignment, add dialog with رقم النقابة → name autofill and a manual-name fallback.
- **Execute-only** — no add/remove session controls. 👁 opens the session.

## 6. Testing strategy

Deliberately proportionate — this cycle reuses shipped machinery, so testing concentrates on the seams that are actually new:

| Area | Coverage |
|---|---|
| Nullable رول (**highest risk**) | Domain/application tests with in-memory fakes: null رول round-trips; clear sets null; duplicate rejected; unassigned sorts last. Plus the #504 characterization tests staying green. |
| Renewal regression | An explicit assertion that a renewal commit **with no رول supplied still lands `max+1`** — the single test that proves D2 didn't change renewal. |
| Uniqueness | Persistence IT: the filtered index rejects a duplicate; the same رول on a different day/division is accepted; a soft-deleted row does not block reuse. |
| `proceedingType` filter | Persistence IT: a renewal session in the same division never appears on a felony roll query. |
| Access scoping | Web-slice tests for the deny path — empty scope denies rather than widens. |
| FE promotion (#545) | The existing renewal FE tests, passing unchanged. That is the entire point of a mechanical refactor. |

## 7. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | Nullable `roll_position` touches the aggregate behind the **live** renewal roll | Own migration, own PR, `max+1` relocated rather than deleted, renewal-behaviour assertion required in #541's ACs |
| R2 | The uniqueness index fails to create if existing renewal data has duplicate (division, date, رول) | #540 runs a duplicate probe **first** and reports before the index migration is written |
| R3 | Concurrent رول assignment races past the service pre-check | The DB index is the real guarantee; the adapter translates the violation into the same 422 (D3) |
| R4 | FE promotion (#545) touches renewal files while PR #515 is open | Promotion is mechanical; conflict surface limited to `paths.ts`, `setup.tsx`, `config-nav-dashboard.tsx` — one touch each |
| R5 | Roll is near-empty until #387 (subsequent-session booking) lands | Accepted. Not a dependency; first-session bookings already populate it |

## 8. Open questions for review

1. **D1 module placement** — is `felonyintake` the right home for a division/day resource, or does the naming mismatch warrant the fourth module now rather than a rename later?
2. **D5 pool key** — (division, date) assumes a lawyer pool never spans divisions on the same day. Confluence says court + division + day; division implies court, so this should be equivalent. Confirm no court-level pooling is intended.
3. **D3 double enforcement** — confirm the index + service-check split is the right division of labour rather than service-only.

---

*Part of the Moj portfolio under ApexYard. Epic #538 · Design ticket #539.*
