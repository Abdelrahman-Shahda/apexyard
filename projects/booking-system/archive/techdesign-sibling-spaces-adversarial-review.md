<!-- Source: ApexYard · projects/booking-system/techdesign-sibling-spaces-adversarial-review.md · MIT -->

# Adversarial Review — Sibling-Spaces Redesign for booking-system #752

**Reviewer**: Hisham (Tech Lead, sub-agent, independent review)
**Date**: 2026-06-15
**Subject**: The "two sibling space rows linked by `shared_court_group`" proposal that replaces the prior M:N `space_location` + `space_booking_entry` design.
**Mandate**: Find what's broken. Do not endorse for endorsement's sake. Disagree with in-thread Hisham if the code says otherwise.
**Evidence basis**: file:line citations against the live tree at `workspace/booking-system/`. All grep, no assumption.

---

## 1. Executive Verdict

**Verdict: NEEDS REVISION** (do not pivot wholesale, do not stick as written). The sibling-spaces *frame* is defensible. The proposal as stated has **one disqualifying load-bearing bug** (the conflict check), one **dashboard-flow correctness gap** (`bookings.service.findOne` returns NOT_FOUND for the cross-tenant case the AC explicitly requires), and at least **three quiet semantic regressions** (max-spaces quota, promo eligibility, statistics/exports). All are addressable; none are addressable by the "zero booking columns + zero new code paths" framing in the proposal.

### Top 3 things the design gets RIGHT

1. **The physical/commercial split is a clean conceptual axis.** Naming a single `physical_authority_space_id` for "who owns operating hours, granularity, capacity" gets the rest of the project out of the M:N's "shared single space with per-tenant overrides" mess. The codebase's space-availability rules already key off a single `spaceId` (`libs/space/src/lib/infrastructure/persistence/entities/space-availability-rule.entity.ts:30-37`) — so concentrating physical truth on one row matches the entity grain that already exists.
2. **Keeping `booking.space → space.location → location.tenant_id` intact for selling-tenant attribution.** This is correct: the existing write path at `libs/booking/src/lib/application/strategies/booking/base-booking.strategy.ts:36` already pulls `tenantId = space.location!.tenantId`. Sibling-spaces gives the selling tenant identity to that chain *for free*, with no new `entry_location_id` sidecar. That alone removes the `space_booking_entry` table + 5 cart-DTO changes + the `CartEntryLocationValidator` from the prior design.
3. **Cart double-book is closed by construction** *for the cart-stage check at `libs/cart/src/lib/validators/cart-conflict.validator.ts:29-31`*. Two siblings = two tenants = two distinct `tenantId` filters — same cart-key shape works without modification. (Caveat: this only closes the *intra-tenant* cart case; see §3 break #1 for the *cross-tenant* hole that remains.)

### Top 3 things that BREAK or are seriously underspecified

1. **`BookingConflictValidator` is broken under sibling-spaces** — silent double-book by design. See §3.1 below. **This is the disqualifier.**
2. **Dashboard update flow fails Scenario Y** — `findOne` filters by `tenantId: ContextProvider.getCurrentTenant()!.id` (`apps/spark-tenant-admin-api/src/app/modules/bookings/services/admin/bookings.service.ts:337`). Tenant A cannot read/update/cancel a B-sold booking. This contradicts the stated AC. See §4.
3. **Reschedule (slot move) is structurally broken** for sibling spaces — `updateBookingWithSlots` reattaches to a different `spaceId` (`bookings.service.ts:271,281-288,309`). If Tenant A reschedules a B-sold booking, the new slot belongs to *A's sibling space* (different `spaceId`), and `isConflicting` won't see the *other sibling's* bookings. See §4.5 — double-book risk on reschedule.

### One-line recommendation

**NEEDS REVISION** — the sibling-spaces frame is keepable, but the design must add:

- A **physical-court key** (the `shared_court_group_id`) that all conflict / availability / cart-conflict checks key on (NOT `spaceId`).
- A **tenant-scope widener** for the dashboard update flow that mirrors what the M:N design proposed for read (`booking-query.utils.ts:83-118`), explicitly applied to the mutate path (`bookings.service.findOne`).
- Schema columns the proposal claims are unnecessary (see §5).

Without these three the design does not meet the ACs.

---

## 2. Pre-flight verification of the proposal's load-bearing claims

| Claim in proposal | Verdict | Evidence |
|---|---|---|
| "`booking.space → space.location → location.tenant_id` resolves selling tenant correctly" | TRUE for the write path | `libs/booking/src/lib/application/strategies/booking/base-booking.strategy.ts:36`; `libs/booking/src/lib/application/visitors/tenant-getter.visitor.ts:9-15` |
| "`cart.spaces[0].location!.tenantId` resolves correctly because each sibling is single-tenant" | TRUE for the cart-tenant *attribution* path; FALSE for *conflict-scope* | Attribution: confirmed at `libs/cart/src/lib/application/strategies/add-cart-item/add-slot-item.strategy.ts:52`. Conflict-scope: see §3.4. |
| "Booking — NO new columns" | FALSE in practice — at minimum needs an `entry_location_id` or `selling_tenant_id` denorm if we want refund/cancel/edit-price authz to gate at the mutate layer without a 3-table join on every write. See §5. | See §5. |
| "Centralized availability resolver" exists | FALSE — there is no central resolver | §3.3 |

---

## 3. Part A — Adversarial findings

### 3.1 BREAK — `BookingConflictValidator` does not detect cross-sibling conflicts (CRITICAL)

**Citations:**
- `libs/booking/src/lib/application/validators/booking-conflict.validator.ts:16-24` — calls `bookingRepository.isConflicting({ recordId: this.data.spaceId, recordType: SPACE_ENTITY, startTime, endTime, excludeId })`.
- `libs/booking/src/lib/infrastructure/persistence/repositories/booking.repository.ts:199-217` — `isConflicting` builds `BookingQueryBuilder.filterBooking({ recordIds: [spaceId], conflictStartTime, conflictEndTime, ... })`.
- `libs/booking/src/lib/infrastructure/persistence/utils/booking-query.utils.ts:61-69` — `recordIds` filter is `booking.recordId IN (:...recordIds)`. Hard equality on the booking's stamped `spaceId`.

**Failure mode under sibling-spaces:**

Sibling A and sibling B are two *separate* rows in `space` with two *different* `id` values. A booking sold by tenant A stamps `booking.recordId = A.spaceId`. A booking sold by tenant B at the same physical time stamps `booking.recordId = B.spaceId`. When tenant B's booking-creation runs through `BookingConflictValidator` with `data.spaceId = B.spaceId`, the `IN (B.spaceId)` filter does *not* find tenant A's existing booking on the same physical slot. **Two bookings on the same physical court at the same time, neither validator complains.**

This is the same root failure (one physical court → two `space.id`s) the M:N design existed to prevent. The sibling-spaces design re-introduces it unless the conflict check is rewritten to key off `shared_court_group_id` instead of `recordId`.

**Cost of fix:** must replace the `recordIds` filter in `isConflicting` (and the validator) with a query of shape "`recordId IN (SELECT id FROM space WHERE id = :spaceId OR shared_court_group_id = (SELECT shared_court_group_id FROM space WHERE id = :spaceId AND shared_court_group_id IS NOT NULL))`". Add `shared_court_group_id` to a composite filter on `BookingQueryBuilder`. This is a non-trivial refactor of `booking-query.utils.ts:61-69` AND `isConflicting` AND every other caller of `recordIds`-filter that means "this physical court" (which today is everywhere). The proposal's "zero new code paths" claim is wrong.

### 3.2 BREAK — Reschedule (`updateBookingWithSlots`) compounds the conflict bug

**Citation:** `apps/spark-tenant-admin-api/src/app/modules/bookings/services/admin/bookings.service.ts:260-329`.

Reschedule flow:
1. Line 265: `findOne(id)` — already broken (§4) for cross-tenant.
2. Line 271: `firstSlotSpaceId = slots[0].spaceId` — taken from the slot ID generated client-side. Client picked the spaceId from *whichever tenant's* listing they were looking at — sibling A or sibling B.
3. Line 281-288: `FindOneSpaceQuery({ id: firstSlotSpaceId, tenantId: ContextProvider.getCurrentTenant()!.id! })` — tenancy check that the slot's spaceId belongs to current tenant.
4. Line 307-313: `update(id, { spaceId: updateSlot.spaceId, ... })` — and crucially, line 309 passes `spaceId: updateSlot.spaceId` as the NEW spaceId. If A is rescheduling a booking that was originally on A's sibling, it stays on A. If A is rescheduling a booking on *B's* sibling and the client picked A's-side slot IDs, the booking record gets rewritten to A's sibling space — **a cross-tenant migration of the booking row, silently, with no audit, and with the conflict check still only looking at A's sibling's bookings.**

**Net:** reschedule can either (a) refuse the action because of the §4 NOT_FOUND, or (b) silently move the booking to the wrong sibling and double-book. Neither is acceptable.

### 3.3 BREAK — There is NO centralized availability resolver. The proposal hand-waves a primitive that doesn't exist.

**Verified call sites that ask "is this slot free?":**
- `libs/booking/src/lib/application/validators/space-availability.validator.ts:16-37` — only checks `SpaceUtils.checkTimeSlotAvailability(space, ...)` against availability rules. **Does not consult existing bookings.**
- `libs/booking/src/lib/application/validators/booking-conflict.validator.ts:16-24` — the actual booking-existence check.
- `libs/cart/src/lib/validators/cart-conflict.validator.ts:22-58` — *only* checks cart-stage conflicts, scoped by tenant (so cart double-book between two carts on the same physical court but two siblings → undetected; same root cause as §3.1).
- `libs/booking/src/lib/application/factories/space-schedule.factory.ts` — generates slot listings.

There are at minimum **three separate availability-shaped predicates** (slot listing, booking conflict, cart conflict), each living in a different lib, each with its own scoping logic, none with a shared "physical court key". The proposal's load-bearing claim ("availability is computed *over the group* via a centralized resolver") describes a primitive that does not exist in the codebase and would need to be created from scratch as a precondition for sibling-spaces correctness. That work is invisible in the proposal's scope estimate.

### 3.4 BREAK — Cart-conflict tenant scoping is too narrow for cross-tenant

**Citation:** `libs/cart/src/lib/validators/cart-conflict.validator.ts:29-31` — `cartRepository.findMany({ tenantId: space.location?.tenantId })`.

Sibling-spaces helpfully makes the *cart-tenant attribution* fall out for free (cart attaches to whichever sibling's tenant the customer was browsing). But that's the *attribution* win — it doesn't help conflict-scope. A cart in tenant A holding a slot on A's sibling at 7pm, vs. a cart in tenant B holding a slot on B's sibling at 7pm (same physical court) → neither sees the other. Same physical-court-key problem as §3.1.

**Fix:** same shape as §3.1 — widen the cart conflict query by `shared_court_group_id` instead of `tenantId`.

### 3.5 SEMANTIC REGRESSION — `max-spaces` quota double-counts shared courts

**Citation:** `libs/space/src/lib/application/policies/max-spaces.policy.ts:20-40` (read up to line 40). The policy counts spaces per location via `spaceRepository.count(...)`.

Under sibling-spaces, two siblings = two `space` rows. The tenant's "spaces per location" quota now counts the shared court twice across two tenants (once per sibling), AND counts it as one of *each* tenant's quota individually. So if Tenant A's package allows 5 spaces and they have 4 physical courts + 1 shared sibling, they're at 5/5, but their physical inventory is only 4. Confusing operationally; revenue impact if a tenant runs out of quota because of a shared court they don't physically own.

The M:N design at §A "`max-spaces` quota Q1" flagged this and recommended home-only counting. **Sibling-spaces makes this question unavoidable**, not optional, because *every* sibling counts as a real `space` row in queries that don't know about `shared_court_group_id`.

### 3.6 SEMANTIC REGRESSION — promo eligibility now hangs on selling-tenant, with no opt-out

**Citation:** `libs/promotion/src/lib/application/validators/promo-campaign-usage.validator.ts:35` — `!promoCampaign.allowedTenantIds.includes(this.location.tenantId)`.

Under sibling-spaces, `location.tenantId` is the *selling* tenant. If tenant A runs a promo only on their physical courts, and a customer books the shared court through tenant B's app, the booking's location is B's location → promo allowed-list miss → customer gets a confusing refusal. Conversely if B runs a promo for "their" customers, A-sold bookings (same physical court) bypass it. **There is no escape hatch unless the promo system gets a notion of `shared_court_group_id` ownership too.**

This is not the M:N design's "entry-tenant vs home-tenant" problem (which had an answer: entry-tenant). It's a new degree of freedom the proposal hand-waves over.

### 3.7 SEMANTIC REGRESSION — statistics / revenue dashboards now show only sold bookings, not court-utilization

**Citation:** `libs/statistics/` aggregates by `tenantId`-filtered booking queries (the `BookingQueryBuilder` is the universal filter, see `libs/booking/src/lib/infrastructure/persistence/utils/booking-query.utils.ts:83-118`).

Under sibling-spaces, Tenant A's "court utilization" dashboard sees only A-sold bookings on the shared court — half the picture. The physical-authority owner is structurally blinded to what's happening on *their own physical court* outside their sale channel. Spark today (single-tenant model) gives the operator the full picture of their physical inventory; sibling-spaces silently halves that picture.

**Open question for Mariam/CEO:** is "shared court utilization view" out-of-scope (acceptable per proposal § AC) or is it a launch blocker for the home tenant? If launch-blocker, sibling-spaces needs a "physical court view" dashboard query layer that aggregates across siblings — work item not in the proposal.

### 3.8 BREAK — admin notification fan-out has the same root miss

**Citation:** `libs/booking/src/lib/application/events/handlers/admin/booking-created-admin-notification.handler.ts:73` (and three siblings: `-canceled-`, `-completed-`, `-missed-`). All call `adminRepository.findAdminsByLocation(locationId, tenant)`.

`locationId` is the location of the *selling* sibling. A booking sold by B notifies B's admins. A's admins (whose physical court is being used) get nothing.

The M:N design called this out explicitly (`techdesign-shared-space-multi-tenant.md` line 86). The sibling-spaces design's "Cross-tenant booking visibility" widens the *read* filter but says nothing about the *event/notification* path. That's a regression vs. the M:N design's plan, not an improvement.

### 3.9 BREAK — soft-delete cascade on a sibling silently drops historical bookings' UX context

**Citations:**
- `space.entity.ts:100-106` — `LocationEntity` ref is `onDelete: 'CASCADE'`.
- `space.entity.ts:148-156` — `parentSpace` ref is `onDelete: 'CASCADE'`.
- `EntityHelper` provides `deletedAt` soft-delete (CLAUDE.md "Soft delete").
- `BookingQueryBuilder` includes `withDeleted()` in its base query (`booking-query.utils.ts:18`).

If Tenant B's sibling is soft-deleted (B leaves the sharing arrangement), historical B-sold bookings still exist with `booking.recordId = (deleted sibling's id)`. The booking's `space.location.tenant_id` chain still resolves (soft-delete keeps the row); BUT:
- Tenant A querying "bookings on this physical court" via `shared_court_group_id` may or may not find them depending on how the JOIN handles `deleted_at` on the sibling.
- Revenue / refund reconciliation: where does a future refund land? The sibling tenant's PSP merchant account may already be closed.

The proposal doesn't address sibling departure. The M:N design had the same problem but the scope of impact is smaller (no full sibling row to delete; only the join-table row).

### 3.10 BREAK — `parent_space_id` interaction not specified

**Citations:**
- `space.entity.ts:146-159` — `parentSpaceId` is the existing padel-court parent/child relation.
- `libs/space/src/lib/infrastructure/persistence/repositories/space.repository.ts:219-220` — known special-case logic for parent/child traversal that the prior design called out as "already a source of double-counting in padel queries".
- `libs/space/src/lib/infrastructure/persistence/utils/space-query.utils.ts:114-135` — `parentSpaceId` filter is independent of any `shared_court_group_id` concept.

Open question: can a sibling space also be a parent or child space? If yes, do BOTH siblings of one parent share into the same group? Or does only the parent share, with the children invisible to the sharing tenant? The proposal is silent. This is an explicit "what could possibly go wrong" mine — padel court counts are already buggy according to the M:N design's diagnosis (lines 88-93 of `techdesign-shared-space-multi-tenant.md`), and sibling-spaces compounds this without acknowledgement.

### 3.11 BREAK — `SpaceAvailabilityRule` ambiguity

**Citation:** `space-availability-rule.entity.ts:30-37` — `spaceId` is a single FK.

Proposal says "physical facts (operating hours, slot duration) live on the physical-authority sibling." OK — then non-authority siblings have... no availability rules? Or copied rules? Or rules that read through to the authority? The proposal doesn't say.

Worst case: the non-authority sibling has its OWN availability rules row, and an admin on the non-authority tenant edits them, and the system silently uses them for that tenant's slot generation but NOT the authority tenant's. → Two different slot grids for one physical court.

Best case: rules read through to the authority sibling — but that's net-new code (a query-level resolver) the proposal doesn't quantify.

### 3.12 WORTH FLAGGING — wallet pass (`google-wallet`, `apple-wallet`)

**Citations:**
- `libs/google-wallet/src/lib/application/visitors/booking-pass-object-generator.visitor.ts:64,69`
- `libs/apple-wallet/src/lib/application/visitors/booking-primary-field-setter.visitor.ts:41,46`

Sibling-spaces makes this trivially correct: the pass is stamped with the selling tenant's branding because the booking's `space.location` is the selling sibling's location. No fix needed. This is one of the genuine wins vs. M:N (which had to plumb an `entryLocation` through). Credit where due.

---

## 4. Part B — Dashboard booking-update flow, scenario by scenario

**Methodology:** trace `bookings.service.ts` actions, identifying which use `findOne` and which dispatch the command directly. Determine which scenarios fail.

### 4.1 The `findOne` is the gate

All admin booking actions go through `findOne(id)` first (e.g. `update:241`, `complete:353`, `markAsMissed:368`, `markAsContacted:378`, `cancel:388`, `confirmCompleted:398`).

```ts
// bookings.service.ts:332-343
async findOne(id: number) {
  return this.queryBus.execute(new FindOneBookingQuery({
    filters: {
      id,
      tenantId: ContextProvider.getCurrentTenant()!.id!,
      locationIds: LocationUtils.getAdminLocationIds(),
    },
  }));
}
```

This flows through `BookingQueryBuilder.filterBooking` (`booking-query.utils.ts:83-97`), where `tenantId: A` becomes `location.tenantId = A`. The booking's space points at sibling B; sibling B's location.tenant_id = B. **`findOne` returns null. Every downstream action throws or returns nothing.**

### 4.2 Scenario X — Tenant B's admin updates a B-sold booking

**Verdict: ✅ Works as-is.** B's `tenantId` matches B-sibling's `location.tenantId`. `findOne` returns the booking; `UpdateBookingCommand` runs.

### 4.3 Scenario Y — Tenant A's admin updates a B-sold booking

**Verdict: ❌ FAILS.** `findOne(id)` filters by `tenantId: A`. The booking's space is B's sibling, whose `location.tenantId = B`. Filter mismatch → null → caller sees NOT_FOUND / undefined-deref crash (depending on call site).

**This is the failure mode the AC explicitly requires us to prevent.**

**Minimum fix:** widen `BookingQueryBuilder.filterBooking`'s `tenantId` clause with an EXISTS predicate keyed on `shared_court_group_id`:

```sql
location.tenant_id = :tenantId
OR EXISTS (
  SELECT 1 FROM space s_authoring
  WHERE s_authoring.id = booking.record_id
    AND booking.record_type = 'space'
    AND s_authoring.shared_court_group_id IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM space s_my_sibling
      WHERE s_my_sibling.shared_court_group_id = s_authoring.shared_court_group_id
        AND s_my_sibling.location_id IN (
          SELECT id FROM location WHERE tenant_id = :tenantId
        )
    )
)
```

This is the *same shape* as the M:N design's Decision 3, just keyed on `shared_court_group_id` instead of `space_location`. The semantic is preserved: "I can see this booking if my tenant has a sibling in the same group." **This widening covers both Y and Z by symmetry.**

### 4.4 Scenario Z — Tenant B's admin updates an A-sold booking

**Verdict: ❌ FAILS, same root as Y.** Same fix applies.

### 4.5 Reschedule — the sting in the tail

Even after fixing `findOne` (so A can SEE B-sold bookings), reschedule (`updateBookingWithSlots`) is **structurally broken** for cross-sibling bookings, see §3.2. The function rewrites `booking.recordId = updateSlot.spaceId`, which is A's sibling's spaceId. The booking effectively migrates from B's books to A's books — revenue, refund authority, and selling-tenant attribution all silently flip — AND the new spaceId's conflict check ignores B's bookings on the same physical court.

**Minimum acceptable fix:** reschedule must either (a) be gated to selling-tenant only (A cannot reschedule B's booking — but the AC says A can), or (b) keep the booking's `recordId` pointing at the original (B's) sibling even when an A-admin reschedules, and force the conflict check to widen by `shared_court_group_id`. (b) is correct; (a) violates the AC.

Implementation cost of (b): `updateBookingWithSlots:309` must NOT pass `spaceId: updateSlot.spaceId` for shared-court bookings — it must pass the original `booking.recordId`. AND the slot listing the customer/admin is choosing from must aggregate across siblings (which depends on the centralized availability resolver in §3.3 that doesn't exist yet).

### 4.6 Per-operation status table

| Op | Endpoint method | After tenantId widening alone | After widening + reschedule fix | After widening + reschedule fix + price-authz |
|---|---|---|---|---|
| Cancel | `cancel(id)` (line 387) | ✅ A can cancel B-sold; refund TBD (Q4) | ✅ | ✅ |
| Reschedule | `updateBookingWithSlots(id)` (line 260) | ❌ silently double-books / migrates tenant | ✅ if (b) implemented | ✅ |
| Update (notes / customer fields) | `update(id)` (line 240) | ⚠️ partial — `SparkUpdateBookingDto` may carry price; needs §5 column | ⚠️ | ✅ |
| Refund | upstream of `cancel`; needs verification on `transaction.repository` (selling-tenant strict-equality) | ✅ refund stays gated by `transaction.tenantId` (sibling-spaces makes this == selling tenant, so the strict-equality filter naturally rejects A's refund attempt on B-sold transactions) | ✅ | ✅ |
| Mark no-show | `markAsMissed(id)` (line 367) | ✅ | ✅ | ✅ |
| Mark contacted | `markAsContacted(id)` (line 376) | ✅ | ✅ | ✅ |
| Complete | `complete(id, ...)` (line 346) | ⚠️ takes payments — must verify which tenant's PSP gets debited | ⚠️ | ⚠️ — needs explicit gate to selling tenant only |
| Edit price | inside `update(id, ...)` | ❌ A can change B's commercial fact via dashboard, no gate | ❌ | ✅ if §5 column added & gated |

**Critical "sting":** after the `findOne` widening, A's admin gains write authority over B's price, B's notes, B's customer fields — which the proposal says are *commercial* facts owned only by selling tenant. Without an additional authz gate on the mutate command (separate from the read filter), the design ships a privilege escalation: any sibling tenant can edit any other sibling's commercial booking data.

---

## 5. Schema additions actually required (push-back on the "zero new columns" claim)

The proposal claims `booking` and `cart` need NO new columns. I disagree on at least one:

### 5.1 `booking.selling_tenant_id` (denormalized) — RECOMMENDED, not strictly required

Today the selling tenant is derivable via `booking → space → location → tenant`. Three joins. Every mutate-authz check ("can this admin edit this commercial fact?") must do that 3-hop join.

**Push-back:** denormalizing `selling_tenant_id` directly on `booking`:
- Saves the join on every mutate-authz check (read still uses the join via `BookingQueryBuilder`).
- Acts as a tripwire if the booking row ever migrates between siblings (a la §4.5) — a strict-equality check `booking.selling_tenant_id == new space.location.tenant_id` catches the silent-migrate bug.
- Costs one int column on `booking`. Same noise the proposal rejected for `entry_location_id`, but with stronger justification: this column is needed on *every* shared-court booking, not just non-home entries.

**Verdict:** not a hard blocker; the 3-hop join works. But the proposal underestimates how often this resolution will happen now that mutate-authz is split from read-authz.

### 5.2 `space.shared_court_group_id` index + nullable FK — REQUIRED

The proposal mentions it but doesn't quantify the indexing strategy. Every conflict check, availability resolver, cart-conflict, statistics-aggregation will key off this column. It needs `idx_space_shared_court_group_id` from day one (not after the first slow query).

### 5.3 Composite index `(record_type, shared_court_group_id)` on `booking` (via `space` join) — NEEDED FOR PERFORMANCE

Once the conflict check is rewritten to look across the group, the hot conflict query becomes `WHERE record_type = SPACE AND record_id IN (SELECT id FROM space WHERE shared_court_group_id = X)`. PG will execute this as a hash semi-join. At >1M bookings (Spark's growth target?) this needs index support.

### 5.4 NO new column on `cart` — confirmed

The proposal is correct here. Cart tenant attribution falls out from `spaces[0].location.tenantId` because each sibling is single-tenant. ✅

### 5.5 `shared_court_group.physical_authority_space_id` constraint — REQUIRED

The proposal mentions this but doesn't constrain `physical_authority_space_id`:
- Must be NOT NULL (group with no authority is meaningless).
- Must reference a `space` row whose `shared_court_group_id = group.id` (self-referential consistency).
- Must reference a `space` row whose `deleted_at IS NULL` (cannot point at a soft-deleted sibling — bricks the group).

DB-level CHECK constraint OR application-level invariant. Proposal says neither.

---

## 6. Open questions that need product/CEO answers BEFORE we can finalize

| # | Question | Owner | Why it matters |
|---|---|---|---|
| Q1 | Does the home tenant need a "physical court utilization view" that aggregates across siblings? If yes, in-scope or follow-up? | Mariam + CEO | §3.7. If launch-blocker, sibling-spaces grows another query-layer. |
| Q2 | Can a tenant edit *commercial* facts on the other sibling's booking (price, cancellation policy applied at refund)? Per proposal: no. Per code today (after widening `findOne`): yes by default. Where do we put the mutate-authz gate? | CEO | §4.6. Privilege-escalation surface. |
| Q3 | Is `SpaceAvailabilityRule` per-sibling or per-group? If per-group, who owns adding a new rule (authority only? authority + commercial-by-vote?)? | Maha + Mariam | §3.11. |
| Q4 | Sibling-departure procedure: when B leaves the sharing, what happens to (a) historical B-sold bookings, (b) the `shared_court_group` row, (c) the orphaned non-authority sibling row? | CEO + Finance | §3.9. |
| Q5 | Can a sibling space also be a `parentSpace` / `childSpace` for the padel-court hierarchy? | Mariam | §3.10. |
| Q6 | Promo-eligibility — proposal makes promos selling-tenant-scoped by construction. Is that the desired behavior, or do we need "shared-court promos" that work across sibling sellers? | Mariam | §3.6. |
| Q7 | `max-spaces` quota — count siblings against both tenants (default fallout), only the authority, or neither? | Mariam | §3.5. |
| Q8 | Notification fan-out — does the authority tenant get notified when their court is sold by the non-authority? Per proposal: silent. Per common sense: yes. | Mariam + Khalid | §3.8. |
| Q9 | (Carried over from M:N design Q4) Refund-issuance path when non-selling tenant initiates a cancel — does sibling-spaces remove this question entirely (since the proposal says only selling can refund) or just re-shape it? | CEO + Finance | If A cannot cancel B-sold without B's PSP, the AC "either tenant can cancel" needs surgical interpretation. |

---

## 7. Migration risk assessment

Order-of-operations for rolling sibling-spaces out without breaking existing tenants:

| # | Step | Risk | Mitigation |
|---|---|---|---|
| 1 | Migration AgDR + labelled migration ticket (workflow gate 3a) | Low | `/migration` skill, per `.claude/rules/workflow-gates.md`. |
| 2 | Add `space.shared_court_group_id` nullable column + index | Low (additive) | Zero-downtime; nullable. |
| 3 | Add `shared_court_group` table | Low (additive) | Zero-downtime. |
| 4 | Rewrite `BookingQueryBuilder` `recordIds` filter to widen via `shared_court_group_id` IFF the booking's space is grouped | **HIGH** | This filter is used by ~30+ callers (every booking list / detail / stats / report). Snapshot-test SQL output. Any caller that means "this exact sibling's bookings" vs. "this physical court's bookings" must be enumerated and tagged. The M:N design's grep at lines 78-93 of `techdesign-shared-space-multi-tenant.md` is a good starting point; the sibling-spaces semantic flip changes which interpretation is correct for each caller — re-walk the list. |
| 5 | Rewrite `BookingRepository.isConflicting` to widen by group | **HIGH** | Cited as §3.1. Most load-bearing change. |
| 6 | Rewrite `CartConflictValidator` to widen by group | High | §3.4. |
| 7 | Rewrite `updateBookingWithSlots` to keep `recordId` stable across sibling-reschedule | **HIGH** | §4.5. Single most subtle correctness bug. Add an integration test that asserts cross-tenant reschedule does not migrate `booking.recordId`. |
| 8 | Notification handler fan-out (4 handlers) | Med | §3.8. |
| 9 | Statistics/exports — decide on Q1, then either ship physical-court view or document gap | Med | Visible to customers (operators). |
| 10 | First production share — create one `shared_court_group` and two sibling rows for one real court | Low if 4-8 done correctly; catastrophic if not (double-bookings live) | Soak on staging with synthetic bookings before flipping prod. |
| 11 | Post-launch: monitor for `recordId` migrations on shared-court bookings (telemetry) | Low | Datadog query on update of `booking.record_id` where `recordType = SPACE`. |

**Most insidious risk:** step 4 is the biggest "find every caller" exercise. The `recordIds` filter today carries TWO semantics: (a) "this exact sibling's bookings" (correct for `findAll` scoped by current sibling tenant) and (b) "this physical court's bookings" (correct for conflict / availability / utilization). Sibling-spaces makes these semantically different; the existing call sites cannot be widened blanket-style without a per-caller decision.

---

## 8. Comparison to the prior M:N design — when in-thread Hisham and I converge

| Concern | M:N design's answer | Sibling-spaces' answer | Adversarial verdict |
|---|---|---|---|
| Double-booking via conflict check | Single `space.id` → conflict check works unchanged | Two `space.id`s → conflict check structurally broken (§3.1) | **M:N wins on this single axis decisively.** Sibling-spaces requires invasive surgery to recover what M:N gets for free. |
| Selling-tenant attribution / revenue | Needs sidecar table + entry-location plumbing across 5 cart DTOs + new validators | Falls out of `space → location → tenant` chain | **Sibling-spaces wins decisively.** Simpler attribution. |
| Cross-tenant visibility (the AC) | EXISTS clause on `BookingQueryBuilder` over `space_location` | EXISTS clause on `BookingQueryBuilder` over `shared_court_group_id` | **Tie.** Same shape, different join key. |
| Reschedule across siblings | Doesn't apply — one space, both tenants edit same row | Structurally broken (§4.5); requires keeping `booking.recordId` stable | **M:N wins.** |
| Notification fan-out | Plan exists (4 handlers enumerated) | Not addressed in proposal | **M:N wins by virtue of explicit treatment.** |
| Wallet pass branding | Required entry-location plumbing | Falls out naturally | **Sibling-spaces wins decisively.** |
| Statistics / utilization views | Single physical row → operator sees everything | Two siblings → operator's view is halved (§3.7) | **M:N wins.** |
| Promo eligibility | Entry-tenant decision needed (resolved: entry-tenant) | Locked to selling-tenant with no escape (§3.6) | **M:N has more flexibility; sibling-spaces is simpler-but-rigid.** |
| `parent_space_id` interaction | Same problem either way | Same problem either way | **Tie.** |
| Migration risk | Mostly additive — sidecar table + reverse relation | High — semantic flip of `recordIds` filter callers (§7 step 4) | **M:N wins on migration safety.** |

**Score:** M:N wins on safety-critical axes (conflict, reschedule, notifications, stats); sibling-spaces wins on developer-experience axes (attribution, wallet pass, no DTO plumbing).

**This is the trade I think the CEO is implicitly making** — accepting more surgery in the query layer in exchange for a cleaner conceptual model. That's a defensible call IF the surgery is done right. The proposal under-states the surgery.

---

## 9. Recommendation

**NEEDS REVISION.** Specifically, before this design can be approved:

1. **Acknowledge `shared_court_group_id` as the physical-court key** and refactor `BookingConflictValidator`, `BookingRepository.isConflicting`, `CartConflictValidator`, and the availability-resolver question into the design (§3.1, 3.3, 3.4). These are the load-bearing changes; "zero new code paths" is not true.
2. **Specify the `bookings.service.findOne` widening** (or equivalent) so Scenario Y/Z works (§4.3, 4.4).
3. **Specify reschedule semantics for cross-sibling bookings** — booking row MUST stay attached to its original sibling on reschedule (§4.5). Add an integration test.
4. **Decide on Q2** — where the mutate-authz gate lives for commercial facts (price, notes). Without this, sibling-spaces silently gives every sibling write-authority over every other sibling's commercial fields.
5. **Answer Q1, Q3, Q5, Q7, Q8** with product owners before estimating.
6. **Add `space.shared_court_group_id` index + the composite indexes in §5.2-5.3** to the schema section.
7. **Add a section on `SpaceAvailabilityRule` ownership** (Q3 / §3.11) — per-sibling or per-group, with implementation cost.
8. Either add `booking.selling_tenant_id` denorm column (§5.1) OR document the 3-hop join cost explicitly so the team understands the tradeoff.

After these revisions, sibling-spaces is a reasonable design with a cleaner conceptual model than M:N. As written, it has at least three correctness bugs and at least three semantic regressions that the proposal doesn't acknowledge.

---

## 10. What I would NOT change in the proposal

To be balanced — the things in-thread Hisham endorsed that I agree are correct:

- **Physical-authority sibling pattern** for operating hours / capacity. Aligns with the entity grain (`SpaceAvailabilityRuleEntity.spaceId` is already singular).
- **Selling-tenant = sibling.tenant** for attribution + revenue. This is the one place sibling-spaces is cleaner.
- **Commission as out-of-scope** for v1. Right call.
- **No `cart` schema changes.** Correct.
- **AC4 / AC5 scope expansion (config split, transaction owner = selling tenant).** Correct in direction; needs the gate specification (§3 break, Q2).

---

## Appendix — file:line index of every claim

| Claim | Citation |
|---|---|
| `BookingConflictValidator` keys on `recordId` (spaceId) | `libs/booking/src/lib/application/validators/booking-conflict.validator.ts:16-24` |
| `isConflicting` repository filter is `recordIds IN` | `libs/booking/src/lib/infrastructure/persistence/repositories/booking.repository.ts:199-217` |
| `recordIds` filter is hard equality on `booking.recordId` | `libs/booking/src/lib/infrastructure/persistence/utils/booking-query.utils.ts:61-69` |
| `SpaceAvailabilityValidator` does NOT consult bookings (only availability rules) | `libs/booking/src/lib/application/validators/space-availability.validator.ts:16-37` |
| `CartConflictValidator` scopes by `space.location?.tenantId` | `libs/cart/src/lib/validators/cart-conflict.validator.ts:29-31` |
| `bookings.service.findOne` gates by current tenant | `apps/spark-tenant-admin-api/src/app/modules/bookings/services/admin/bookings.service.ts:332-343` |
| `updateBookingWithSlots` rewrites `recordId` | `apps/spark-tenant-admin-api/src/app/modules/bookings/services/admin/bookings.service.ts:260-329` |
| All mutate operations route through `findOne` | `apps/spark-tenant-admin-api/src/app/modules/bookings/services/admin/bookings.service.ts:241, 265, 353, 368, 378, 388, 398` |
| `BookingQueryBuilder.filterBooking` tenantId disjunct | `libs/booking/src/lib/infrastructure/persistence/utils/booking-query.utils.ts:83-118` |
| `SpaceEntity` complete field list (physical vs commercial classification source) | `libs/space/src/lib/infrastructure/persistence/entities/space.entity.ts:30-180` |
| `BookingEntity` complete field list (no new columns proposal source) | `libs/booking/src/lib/infrastructure/persistence/entities/booking.entity.ts:21-150` |
| `SpaceAvailabilityRule` keyed on `spaceId` singularly | `libs/space/src/lib/infrastructure/persistence/entities/space-availability-rule.entity.ts:30-37` |
| `MaxSpacesPolicy` counts via `spaceRepository.count` per location | `libs/space/src/lib/application/policies/max-spaces.policy.ts:20-40` |
| Promo eligibility keys on `location.tenantId` | `libs/promotion/src/lib/application/validators/promo-campaign-usage.validator.ts:35` |
| Admin notification routing via `findAdminsByLocation` | `libs/booking/src/lib/application/events/handlers/admin/booking-created-admin-notification.handler.ts:73` (and 3 siblings) |
| Wallet pass visitors use `space.location` | `libs/google-wallet/src/lib/application/visitors/booking-pass-object-generator.visitor.ts:64,69`; `libs/apple-wallet/src/lib/application/visitors/booking-primary-field-setter.visitor.ts:41,46` |
| `parent_space_id` chain still present, independent of sharing | `libs/space/src/lib/infrastructure/persistence/entities/space.entity.ts:146-159`; `libs/space/src/lib/infrastructure/persistence/repositories/space.repository.ts:219-220` |
| `base-booking.strategy` uses `space.location.tenantId` as tenant | `libs/booking/src/lib/application/strategies/booking/base-booking.strategy.ts:36` |

— Hisham (sub-agent, adversarial review)
