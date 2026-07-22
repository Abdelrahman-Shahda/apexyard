<!-- Source: ApexYard · projects/booking-system/techdesign-shared-space-multi-tenant.md · MIT -->

# Technical Design: Share a single physical court across multiple tenants (Sibling-Spaces Model — v3)

**Status**: Draft (v3 — supersedes v2)
**Author**: Hisham (Tech Lead)
**Date**: 2026-06-15
**Tracker**: apessolutions/booking-system#752
**AgDRs**:
- `[[AgDR-0001-shared-space-data-model]]` — sibling-space model (UPDATED for v3 — no authority concept)
- `[[AgDR-0004-physical-vs-commercial-fact-split]]` — **SUPERSEDED** (moved to `superseded/`); v3 makes all space config per-sibling
- `[[AgDR-0005-centralized-conflict-availability-resolver]]` — unchanged (conflict resolver still load-bearing)
- `[[AgDR-0006-reschedule-semantics-and-financial-decoupling]]` — UPDATED for v3 (widened refund authz)
- `[[AgDR-0007-dto-substitution-at-space-level]]` — **NEW** (embedded-space DTO substitution + partner badge)
- migration AgDR — TBD via `/migration` (workflow gate 3a) before any DDL edit

## Revision history

- **2026-06-15 v3** — Simplification pass. After v2, the CEO killed the physical/commercial split (*"each sibling can have his own availability rule that's fine"*) and rejected the v2 `display_context` field shape on the booking DTO (*"changing dto would break the admin app"*). v3 keeps the sibling-spaces frame and the conflict resolver, but: (a) every space config field is per-sibling — no authority concept anywhere; (b) the `shared_court_group` table is reduced to a relational anchor for **conflict scope only**, with no `physical_authority_space_id`; (c) cross-tenant visibility is rendered via **DTO substitution at the embedded space DTO level** instead of a new top-level field — the booking's `space` object is rewritten to the viewing tenant's sibling space, leaving every existing admin-app calendar / list / "bookings on space X" filter to keep working unchanged; (d) one tiny additive `partner_booking_info` flag at the booking level surfaces the "this was sold by a partner" badge; (e) authorization for any action on a shared booking is uniform across sibling admins — only refund **execution** stays constrained to the PSP that collected the money; (f) notifications fan out symmetrically to all admins of all siblings. AgDR-0004 is marked superseded and archived. AgDR-0001 is updated to drop the authority concept. AgDR-0006 is widened to permit refund initiation from any sibling admin. AgDR-0007 codifies the substitution mechanism.
- **2026-06-15 v2** — Sibling-spaces model with physical-vs-commercial fact split + `display_context` DTO field. SUPERSEDED by v3 — see git history at this file.
- **2026-06-15 v1** — M:N `space_location` join + `space_booking_entry` sidecar. SUPERSEDED by v2.

---

## Overview

### Summary

Two Spark tenants physically share one padbol court. Today they own separate `space` rows and the system double-books the court while showing the customer two duplicate bookings. v3 makes each tenant's view of the shared court a **first-class `space` row** in that tenant's own `location`, with the two siblings linked by a new `shared_court_group` row. **The group is a relational anchor for conflict scope and nothing else** — every space config field (operating hours, capacity, granularity, price, availability rules, mobile-on-off, photos) is per-sibling. One booking row per reservation (attached to whichever sibling sold it). Availability and conflict are computed **across the group**, not per sibling, via a centralized resolver. For cross-tenant visibility, the booking response transformer **substitutes the embedded space DTO** so a B-sold booking surfaced to A's admin appears under A's sibling space — the admin app needs zero changes to render it. A small additive `partner_booking_info` flag at the booking level powers a "Booked via partner — [Tenant X]" badge. Any sibling admin can take any action on the booking; refund execution still routes through the PSP that originally collected the money.

### Goals (from ticket ACs, post-v3 revision)

- One physical court, multiple tenant-owned `space` rows linked by `shared_court_group`.
- Both tenants can list, view, **cancel**, **reschedule**, **mark no-show**, **edit customer fields and notes**, **edit price**, **trigger refund** on any booking on the shared court.
- Availability and conflict are computed across siblings — no double-book by construction.
- Every space config field is **per-sibling** — siblings may freely diverge on availability rules, granularity, price, capacity, photos, etc. The `shared_court_group` correlates siblings for conflict purposes only.
- Each booking produces **exactly one transaction**, owned by the **selling tenant** (the sibling that sold the slot). Any sibling admin may initiate a refund; the refund **executes** through the PSP that owns the transaction (the original seller).
- Cross-tenant visibility is rendered via embedded-space DTO substitution — admin app sees partner bookings under its own sibling space with zero client changes.
- A discreet partner badge surfaces the original seller on substituted bookings.
- Notifications fan out symmetrically to all admins of all siblings on every booking event.
- Non-shared spaces continue to behave identically to today; no backfill.

### Non-Goals

- Revenue splitting between tenants (transaction stays whole; selling tenant owns it).
- Commission contracts between tenants — out of scope for v1; future feature.
- Per-tenant availability quotas / carve-outs on a shared court beyond what divergent per-sibling availability rules naturally allow.
- A new customer-facing UI surface.

### Scope changes — APPROVED by CEO 2026-06-15

These deltas from the original ticket #752 AC text are **approved**. Mariam (PM) handoff is documentary only — the CEO has authorised the scope expansion inline (chat record 2026-06-15, explicit "approved" referencing #752).

| Original AC | Revision (v3) | Why | Status |
|---|---|---|---|
| AC4: "availability + booking config single-source on the space" | **All space config is per-sibling. No single-source authority.** Siblings may diverge on availability rules, granularity, price, capacity, etc. | CEO simplification. The v2 attempt to split physical from commercial fields added classification ambiguity (4 fields were genuinely ambiguous) for marginal benefit. Conflict math correctness relies only on the conflict resolver (D4), not on field-level uniformity. | ✅ Approved 2026-06-15 |
| AC5: "exactly one transaction, owned by home tenant" | **Owned by the selling tenant.** Refund **initiation** allowed from any sibling admin; refund **execution** stays on the selling tenant's PSP. | The "home tenant" concept disappears under sibling-spaces — there is no single home. Selling-tenant attribution is structurally simpler; widened initiation reflects operator reality (any admin handling the customer can press the button). | ✅ Approved 2026-06-15 |
| Out-of-scope: "per-tenant pricing / config overrides" | **Pulled into scope** for every space field (price, granularity, capacity, channel flags, cancellation deadline, availability rules). | The point of v3. | ✅ Approved 2026-06-15 |
| Out-of-scope: revenue splitting | Still out of scope (commission contracts deferred to a future feature) | No change. | ✅ Confirmed 2026-06-15 |
| Out-of-scope: admin sharing API + quota enforcement + sibling-departure flow | Newly OUT of scope (CEO Q3/Q4) — DB-configured for v1; fresh shares only | Operational shape of sharing not yet load-bearing | ✅ Approved 2026-06-15 |

**Approval record**: CEO authorised inline on 2026-06-15 in the design conversation. Mariam (PM) is informed but not gating — the original ticket author (Abdelrahman) IS the CEO in this case, so the AC rewrite is self-authorised.

---

## Current-state code map (verified)

Every claim has a file:line citation against `workspace/booking-system/` as of 2026-06-15.

### Space + Location

- `libs/space/src/lib/infrastructure/persistence/entities/space.entity.ts:30-180` — `SpaceEntity`. `locationId` (line 97-98) is a single FK to `LocationEntity`. No grouping concept today.
- `libs/space/src/lib/infrastructure/persistence/entities/space.entity.ts:26-29` — partial unique index `idx_space_name_locationId` on `(name, locationId) WHERE deleted_at IS NULL`. Unaffected by v3.
- `libs/space/src/lib/infrastructure/persistence/entities/space-availability-rule.entity.ts:30-37` — `spaceId` single FK; each sibling owns its own rules under v3.
- `libs/space/src/lib/infrastructure/persistence/entities/space.entity.ts:145-159` — `parentSpaceId` / `parentSpace` / `childSpaces` — pre-existing hierarchical capacity inheritance (`space-capacity.utils.ts:13-115`). **Different semantics from sibling grouping** — see D1 below for why these cannot be reused.

### Booking — read path (the visibility seam)

- `libs/booking/src/lib/infrastructure/persistence/utils/booking-query.utils.ts:19-36` — polymorphic LEFT JOIN: `booking → space (recordType = SPACE_ENTITY) → location → tenant`.
- `libs/booking/src/lib/infrastructure/persistence/utils/booking-query.utils.ts:83-97` and `:99-118` — tenant filter (singular + plural). Widened in D5.
- `libs/booking/src/lib/infrastructure/persistence/utils/booking-query.utils.ts:61-69` — `recordIds` filter. Disqualifier root for conflict checks (see AgDR-0005).
- `libs/booking/src/lib/infrastructure/persistence/utils/join-booking-tenant.ts:14-47` — `COALESCE` tenant resolution — resolves to selling tenant under v3.

### Booking — conflict + availability (the disqualifier surface, AgDR-0005)

- `libs/booking/src/lib/application/validators/booking-conflict.validator.ts:7-31` — keys on `data.spaceId`. Missed cross-sibling. Fixed by resolver.
- `libs/booking/src/lib/application/validators/space-availability.validator.ts:16-37` — under v3, **each sibling reads its own availability rules** (no read-through). The resolver only widens the conflict-check set.
- `libs/booking/src/lib/application/factories/space-schedule.factory.ts` — slot listing must aggregate booking-suppression across siblings.
- `libs/cart/src/lib/validators/cart-conflict.validator.ts:22-58` — tenant-scoped cart conflict. Widened via resolver.

### Booking — write path (selling tenant derivation, no change)

- `libs/booking/src/lib/application/strategies/booking/base-booking.strategy.ts:36` — `tenantId = space.location!.tenantId`. Already produces selling tenant under sibling-spaces. No write change.
- `libs/booking/src/lib/application/visitors/tenant-getter.visitor.ts:9-15`, `tenant-checker.visitor.ts:9-15`, `booking-location-id-getter.visitor.ts:21-29` — all chain through `space.location` and resolve to selling sibling. Correct under v3.

### Dashboard mutate path (the cross-tenant gap)

- `apps/spark-tenant-admin-api/src/app/modules/bookings/services/admin/bookings.service.ts:332-343` — `findOne` filters by `ContextProvider.getCurrentTenant()!.id`. Widened by D5.
- `bookings.service.ts:241, 265, 353, 368, 378, 388, 398` — every admin mutate route funnels through `findOne(id)`. Widening `findOne` also widens every operational mutate including reschedule and refund initiation.
- `bookings.service.ts:260-329` — `updateBookingWithSlots` (reschedule). Under v3 reschedule may move the booking to a different sibling; the transaction stays immutable on the original seller (AgDR-0006).

### Booking response DTO shape (load-bearing for D6 — verified)

- `libs/contracts/src/lib/spark/tenant/v1/booking/admin-booking.dto.ts:19-100` — `SparkDashboardBookingDto` base class. `this.id = booking.id` at line 62. `name: string` field set from `space.name`. **No top-level `spaceId` field.**
- `libs/contracts/src/lib/spark/tenant/v1/booking/space/admin-space-booking.dto.ts:38-86` — `SparkDashboardSpaceBookingDto extends SparkDashboardBookingDto`. **The embedded space DTO is `space?: SparkBookingSpaceDto` at line 39.** Also carries `location?: SparkUserBookingLocationDto` at line 40. Constructor at line 68-75: `this.space = new SparkBookingSpaceDto(booking.space)` from `booking.space` directly.
- `libs/contracts/src/lib/spark/tenant/v1/booking/booking-space.dto.ts:6-19` — `SparkBookingSpaceDto` shape: `{id, name, spaceType, spaceTypeValue, pricingType}`. Lean — no permissions, no relations to other tenant context.
- `apps/spark-tenant-admin-api/src/app/modules/bookings/controllers/admin/booking.transformer.ts:208-220` — `BookingTransformer.transformBookings` constructs the DTO. **This is the substitution point** — we rewrite `(booking as SpaceBooking).space` and `space.location` to the viewing tenant's sibling before the constructor copies them.
- `apps/spark-tenant-admin-api/src/app/modules/bookings/controllers/admin/booking.transformer.ts:344-391` — `_mapLocationSpaceCalendar` / `_mapLocationCalendar` filter bookings by `b.recordId === space.id`. Under v3 the calendar substitution makes this filter naturally render partner bookings under the viewing tenant's sibling **without any calendar-side code change** — partner bookings retain canonical `recordId` for backend ops, but the rendered booking carries the viewing tenant's substituted `space`.

The verified fact pattern: **canonical `booking.id` survives**, **no top-level `spaceId` field conflicts with the substituted embedded space**, every mutation handler identifies the booking by `id` (e.g. `bookings.service.ts:332` `findOne(id)`).

### Transaction (financial-ownership seam)

- `libs/transaction/src/lib/infrastructure/persistence/entities/transaction.entity.ts:93-101` — `Transaction.tenantId` NOT NULL.
- `libs/transaction/src/lib/infrastructure/persistence/repositories/transaction.repository.ts:225-239` and `transaction-query.utils.ts:27-38` — strict-equality filter on `transaction.tenantId`. **Kept strict for refund execution** under v3 (AgDR-0006).

### Notification handlers (fanned out under D8)

- `libs/booking/.../events/handlers/admin/{created,canceled,completed,missed}-admin-notification.handler.ts:~73` (4 files) — `findAdminsByLocation(locationId, tenant)`. Symmetric fan-out under v3.
- `libs/tenants/.../events/handlers/tenant-user-booking-{created,updated}.handler.ts:42, 50, 58` (2 files) — same.

### Other load-bearing sites

| # | Site | v3 treatment |
|---|---|---|
| 1 | `cancellation-window-checker.visitor.ts:27-28` | Per-sibling commercial fact — selling sibling's policy applies. |
| 2 | `booking-max-user-booking.validator.ts:33, 42` | Per-sibling quotas on selling sibling. |
| 3 | `booking-window.validator.ts:31` | Per-sibling. |
| 4 | `booking-space-and-location-is-active.validator.ts:21-24` | Selling sibling. |
| 5 | `cart-conflict.validator.ts:22-58` | Widened via resolver (AgDR-0005). |
| 6 | Wallet pass generators (`booking-pass-object-generator.visitor.ts:64, 69`, `booking-primary-field-setter.visitor.ts:41, 46`) | Selling sibling — correct by construction. |
| 7 | Promo (`promo-campaign-usage.validator.ts:35`, `promo-code-usage.repository.ts:76-91`) | Per selling sibling. |
| 8 | Open matches (`open-match-query.utils.ts:19-24`) | Selling sibling. |
| 9 | External client (`external-client.service.ts:37-141`) | Per-sibling. |
| 10 | `max-spaces.policy.ts:20-40` | Quiet regression — dedupe sibling-group memberships. Q3 below. |
| 11 | Addon (`spaces-belong-to-location.validator.ts:26`) | Per-sibling. |
| 12 | Statistics (`libs/statistics/`) | Quiet regression. Q1 below. |

### Tests requiring attention

- `libs/booking/**/*.spec.ts` — conflict + availability + visitor tests touched by AgDR-0005.
- `libs/cart/**/*.spec.ts` — cart conflict.
- `apps/spark-tenant-admin-api-e2e/.../spaces` + `bookings` — tenant-isolation regression + positive shared-court tests.
- `libs/transaction/.../services/transaction-split.service.spec.ts` — refund path under widened authz (AgDR-0006).
- New: substitution transformer tests (D6).

---

## Decisions

### D1 — Sibling-space model with `shared_court_group` (conflict-scope anchor only)

Each tenant gets its own first-class `space` row in its own `location`. Two sibling rows are linked by a `shared_court_group` row. **The group is a relational anchor for conflict scope, nothing more** — it carries no authority designation, no shared config, no read-through behaviour.

**Why a separate `shared_court_group` table and NOT reuse of `parent_space_id`** (verified):

- `parent_space_id` carries existing semantics: **hierarchical capacity inheritance** (`libs/space/src/lib/utils/space-capacity.utils.ts:13-115`) where child spaces inherit `maxCapacity` / `maxBookingPerSlot` from their parent. Reusing it for sibling-grouping would either force capacity inheritance across siblings (contradicting D2 — *all config per-sibling*) or break the existing hierarchy for spaces that use both features.
- `parent_space_id` is also used as a "children of X" query filter (`space-query.utils.ts:114-116`); overloading it would corrupt court-count queries on parent spaces.
- A separate `shared_court_group` table preserves both semantics and gives commission-contract / group-admin features a stable anchor when they land later.

| Option | Pros | Cons |
|---|---|---|
| **A. Sibling spaces + `shared_court_group` (v3 pick)** | Selling-tenant attribution falls out for free via `booking.space → location → tenant`. Cart-tenant correct by construction. Wallet pass branding correct by construction. Clean separation between sibling grouping and parent-child hierarchy. | Two `space.id`s per physical court → conflict/availability/cart-conflict paths key on `space.id` → must widen via resolver (D4). Invasive in the query layer. |
| B. Reuse `parent_space_id` | No new table | Capacity-inheritance semantic conflict. Corrupts court-count queries. Contradicts D2. |
| C. M:N `space_location` (v1) | Conflict unchanged | Sidecar table for entry attribution. 5-DTO contract bump. Heavy. |
| D. Denormalised projection | Reads fast | Eventual consistency — UNACCEPTABLE per AC. |

**Chosen: A.** See `[[AgDR-0001-shared-space-data-model]]` (v3 update).

### D2 — All space config is per-sibling

Every field on `SpaceEntity` — `granularity`, `minSlots`, `maxSlots`, `capacityPerSlot`, `maxBookingPerSlot`, `basePrice`, `cancellationDeadline`, `enableBookingFromMobile`, etc. — is per-sibling. Each sibling owns its own `SpaceAvailabilityRule` rows.

| Option | Pros | Cons |
|---|---|---|
| **A. All config per-sibling (v3 pick — CEO call)** | Maximum operator flexibility — each tenant runs their own slot grid, prices, availability rules. No field-classification debate. Simpler validator surface (none). No "authority sibling" concept to maintain. | Two siblings may run different slot grids on the same physical court — operationally weird but explicitly accepted. Conflict resolver (D4) handles the booking-collision case across whatever grids each sibling exposes. |
| B. Physical/commercial split (v2, SUPERSEDED) | Single slot grid by construction | Four genuinely ambiguous fields. Validator complexity. Added "authority" concept that needed propagation everywhere. CEO-rejected. |

**Chosen: A.** No validator. No authority concept. The conflict resolver (D4) is the only group-scope concern. AgDR-0004 marked superseded.

**Subtle consequence**: if Sibling A has hours 09:00–17:00 with 60-min slots and Sibling B has hours 12:00–22:00 with 30-min slots, both siblings expose their own slot grids; bookings from either grid go through the same cross-sibling conflict check (D4), so a 13:00 booking on A's 60-min grid blocks B's 13:00 + 13:30 slots. This is explicitly intended behaviour — flagged in Q2 for product confirmation but treated as the v3 default.

### D3 — Booking attribution + selling tenant derivation (no denorm)

Booking attribution is derived through the existing `booking.space → space.location → location.tenant_id` chain. Under v3 this produces the **selling tenant**. No new column on `booking`.

| Option | Pros | Cons |
|---|---|---|
| **A. Derive via 3-hop join (v3 pick)** | Zero schema churn. Write path already correct. | Mutate-authz does the 3-hop join. Acceptable today. |
| B. Denorm `booking.selling_tenant_id` | One column compare | New nullable column on polymorphic table — violates the "no type-specific columns on the generic table" principle. Rejected for the same reason as v1/v2. |

**Chosen: A.** If the join becomes a perf hot-path (Step 23 benchmark), add a covering index before reaching for denorm. Flagged as a known risk (R11).

### D4 — Centralized conflict + availability resolver (`SharedCourtSpaceResolver`)

The biggest concrete piece of work. Conflict + cart-conflict + slot-listing paths today key on `space.id` and silently miss cross-sibling bookings. v3 introduces a `SharedCourtSpaceResolver` with one method:

```typescript
abstract resolveSiblingSpaceIds(spaceId: number): Promise<number[]>;
```

For a non-shared space, returns `[spaceId]`. For a shared space, returns `[spaceId, ...sibling space ids]` (excluding soft-deleted).

**Difference from v2**: the resolver no longer needs `resolvePhysicalAuthoritySpaceId` because availability rules are per-sibling under D2. The interface is reduced to a single method.

Call sites that route through the resolver:

| # | File:line | Today | Post-resolver |
|---|---|---|---|
| 1 | `booking-conflict.validator.ts:16-24` | `isConflicting({ recordId: spaceId })` | `isConflicting({ recordIds: await resolver.resolveSiblingSpaceIds(spaceId) })` |
| 2 | `booking.repository.ts:199-217` | `recordId: number` | `recordIds: number[]` (signature change) |
| 3 | `cart-conflict.validator.ts:22-58` | tenant-scoped | `spaceIds: number[]` from resolver; new `CartRepository.findMany` filter |
| 4 | `space-schedule.factory.ts` | Per-sibling slot list | Booking-suppression aggregated across siblings |
| 5 | `space-availability.validator.ts:16-37` | Per-sibling rules | **Unchanged** under v3 — each sibling reads its own rules |

See `[[AgDR-0005-centralized-conflict-availability-resolver]]`.

### D5 — Cross-tenant visibility via widened booking query

Booking-query filter widened with an EXISTS disjunct keyed on `shared_court_group_id`:

```sql
event.tenant_id = :tenant
OR location.tenant_id = :tenant
OR EXISTS (
  SELECT 1
  FROM space s_sold
  JOIN space s_sibling ON s_sibling.shared_court_group_id = s_sold.shared_court_group_id
  JOIN location l_sibling ON l_sibling.id = s_sibling.location_id
  WHERE s_sold.id = booking.record_id
    AND booking.record_type = 'space'
    AND s_sold.shared_court_group_id IS NOT NULL
    AND l_sibling.tenant_id = :tenant
)
OR trip.tenant_id = :tenant
```

Applied to `booking-query.utils.ts:83-118` (both `tenantId` and `tenantIds` variants).

Every admin mutate route in `bookings.service.ts` funnels through `findOne` which runs through `BookingQueryBuilder.filterBooking`, so **widening the read filter automatically widens cancel / mark-X / edit-notes / edit-price / refund-initiate / reschedule**. Uniform authz (D7).

**Indexes**: `space(shared_court_group_id) WHERE shared_court_group_id IS NOT NULL` (partial). EXISTS rather than JOIN to avoid row multiplication.

### D6 — DTO substitution at the embedded space DTO level

**Replaces v2's `display_context` field.**

When the widened query (D5) returns a B-sold booking to A's admin, the response transformer substitutes the embedded `space` object inside the booking with **A's sibling space** (instead of B's canonical sibling). A `location?` field on the same DTO is substituted to A's location for the same reason. The canonical `booking.id` is unchanged; the canonical `recordId` (which the substitution does NOT alter) keeps mutation routing honest.

#### The substitution mechanism (verified site)

Substitution lives in `BookingTransformer.transformBookings` at `apps/spark-tenant-admin-api/src/app/modules/bookings/controllers/admin/booking.transformer.ts:208-220`:

```typescript
// Pseudocode for the substitution shim before the constructor call:
const viewingTenantId = ContextProvider.getCurrentTenant()!.id;
const canonicalSpace = (booking as SpaceBooking).space;
const canonicalSellingTenantId = canonicalSpace.location!.tenantId;
let renderedSpace = canonicalSpace;
let partnerBookingInfo: PartnerBookingInfo | null = null;

if (canonicalSpace.sharedCourtGroupId != null && canonicalSellingTenantId !== viewingTenantId) {
  // Cross-tenant view — fetch viewing tenant's sibling in the same group via DataLoader.
  const siblingSpace = await this.sharedCourtSiblingForTenantLoader.load({
    sharedCourtGroupId: canonicalSpace.sharedCourtGroupId,
    viewingTenantId,
  });
  if (siblingSpace != null) {
    renderedSpace = siblingSpace; // substitute embedded space
    partnerBookingInfo = {
      sold_by_tenant_id: canonicalSellingTenantId,
      sold_by_tenant_name: canonicalSpace.location!.tenant!.name,
      sold_by_location_name: canonicalSpace.location!.name,
    };
  }
}

// SparkBookingSpaceDto is constructed from renderedSpace inside the existing DTO constructor
// (admin-space-booking.dto.ts:68-75). booking.id and booking.recordId stay canonical.
```

The substitution is implemented by passing a derived "rendered space" object into the existing constructor at `admin-space-booking.dto.ts:68-75` — either via a small interface change on the transformer's call path (preferred) or by patching `booking.space` before construction (acceptable; the booking is a transient read-model at this point). See AgDR-0007 for the exact wiring.

**Calendar path** (`booking.transformer.ts:344-391`) — `_mapLocationCalendar` filters bookings by `b.recordId === space.id`. Under v3 partner bookings retain canonical `recordId` (e.g. B's space.id), so they will **not** match A's sibling space row in the current calendar filter. To get partner bookings to render under A's calendar slot for A's sibling space, the calendar filter at line 380-383 expands to `b.recordId === space.id || resolver.resolveSiblingSpaceIds(space.id).includes(b.recordId)`. Combined with the substitution, the calendar then renders these bookings naturally under A's sibling row with the substituted embedded `space` and the partner badge. Step 12 covers this.

#### `partner_booking_info` field (the only additive DTO field)

Added at the booking level (not inside the space object), nullable, additive:

```typescript
// admin-space-booking.dto.ts — addition to SparkDashboardSpaceBookingDto
partner_booking_info: {
  sold_by_tenant_id: number;
  sold_by_tenant_name: string;
  sold_by_location_name: string;
} | null;
```

Defensible because:
- Nullable, so existing clients ignore it without breakage.
- Load-bearing for operator UX (operator needs to know they're handling a partner's booking).
- Sits at the booking level, not nested inside the space object — keeps the lean `SparkBookingSpaceDto` shape (`booking-space.dto.ts:6-19`) untouched.
- This is the **one** additive DTO change in v3.

#### Why this beats the v2 `display_context` approach

| Axis | v2 `display_context` | v3 substitution |
|---|---|---|
| Admin app changes | New field to handle in UI logic | Zero — booking renders under existing space-list / calendar / filter code |
| Backward compatibility | Additive but client must learn new shape | Substituted space is the same `SparkBookingSpaceDto` shape; only `partner_booking_info` is new |
| Mutation routing | Canonical `space_id` separate from displayed | Canonical `booking.id` carries mutation; `recordId` stays canonical for backend; no conflict |
| Calendar rendering | New rendering branch needed | Existing `recordId === space.id` filter just needs to widen via resolver |

See `[[AgDR-0007-dto-substitution-at-space-level]]`.

### D7 — Uniform mutate authz; refund execution still PSP-constrained

If the widened query (D5) returns the booking to the viewer, the viewer's admin can take any action: cancel, reschedule, edit customer, edit notes, **edit price**, **mark no-show / attended**, **initiate refund**.

**Refund detail**: the refund initiation endpoint accepts the request from any sibling admin; the **execution** still routes through the PSP that collected the money. Mechanically:

- `POST /bookings/:id/refund` from A's admin on a B-sold booking → accepted (booking is visible to A via D5).
- The refund command handler resolves the transaction via `booking.transaction` → `transaction.tenantId = B` → enqueues / executes the refund through B's PSP merchant context.
- The audit log records: `refund_initiated_by_tenant_id = A`, `refund_executed_via_tenant_id = B`.

This satisfies the CEO's framing: **any sibling can take any action; the money flows match the transaction.**

The previous v2 commercial-price-edit gate is **dropped** — under v3 any sibling admin can edit the price (commercial flexibility was the whole point). Any sibling admin can also edit notes, customer fields, addons. The "selling tenant only" carve-out applies to **refund execution** only — and that's enforced by the transaction-side PSP routing, not a new authz layer.

### D8 — Symmetric notification fan-out

All admins of all siblings get notified on every booking event. No tiering, no "quieter" notification.

Updated handlers:

- `libs/booking/.../events/handlers/admin/created-admin-notification.handler.ts` — fan out across all siblings in the group
- `.../canceled-admin-notification.handler.ts`
- `.../completed-admin-notification.handler.ts`
- `.../missed-admin-notification.handler.ts`
- `libs/tenants/.../events/handlers/tenant-user-booking-created.handler.ts`
- `.../tenant-user-booking-updated.handler.ts`

Implementation: each handler resolves the sibling space ids via the resolver, then calls `findAdminsByLocation` for each sibling's location and unions the recipient set.

### D9 — Admin sharing surface — deferred; v1 is DB-configured only

**v1 decision (CEO, Q3)**: no admin / super-admin sharing endpoints in this release. Sharing is set up by inserting `shared_court_group` rows and updating `space.shared_court_group_id` **directly in the database** via a runbook script. Rationale: low frequency, narrow blast radius (only super-admins do it), and engineering effort is better spent on the resolver + DTO substitution where the load-bearing risk lives.

**Constraints the manual ops must still respect** (encoded in the runbook, not in code):
- `space.deletedAt IS NULL` for every sibling being added
- `space.shared_court_group_id IS NULL` before assignment (no double-grouping)
- Sibling tenants distinct — same tenant cannot have two siblings in one group (no within-tenant cannibalisation)
- Share creation precedes any customer-facing exposure (no "going live" mid-booking)

**Operating assumption from Q4**: a tenant only joins a share when they're opening a *fresh* sibling space at the partner's location. There are no historical bookings on a freshly created sibling, so the sharing operation is a clean DB write with no backfill / replay concern.

**Future ticket**: when the second or third partnership comes online, file a follow-up to promote this into a super-admin API. Until then, runbook ops are sufficient and the code stays smaller.

---

## Architecture

### Component diagram (text C4)

```
[ tenant-admin-api ] -- read --> BookingQueryBuilder         (visibility widened, D5)
                  '-- mutate --> BookingQueryBuilder          (same widened filter authorizes mutates — D7)
                  '-- mutate --> Refund command handler       (initiation widened; PSP execution via transaction.tenantId — D7)
                  '-- read --> BookingTransformer             (substitutes embedded space + adds partner_booking_info — D6)
                  '-- read --> Statistics                     (Q1)
[ tenant-admin-api ] -- mutate --> TransactionQueryBuilder    (strict — refund PSP routing)
[ super-admin-api ] -- mutate --> SharedCourtGroupController  (NEW — D9)

[ booking-write ] -- uses --> SharedCourtSpaceResolver         (NEW — D4 / AgDR-0005)
                                 |
                                 v
                  shared_court_group  <----+
                                           |
                       space.shared_court_group_id (FK)
                                 ^
                                 |
                              booking.recordId (no schema change)
```

### Data flow — customer books via tenant B's app on a shared court

1. Customer in tenant B's mobile app sees space S_B in B's space list.
2. Customer adds slot → cart conflict (D4 via resolver) checks across `[S_A, S_B]`. Cross-tenant double-add caught.
3. Checkout → booking conflict (D4) checks across siblings. Cross-sibling double-book caught.
4. Booking row written with `recordId = S_B.id`. `booking.space → S_B → location_b → tenant_b` → selling tenant = B.
5. Transaction created with `tenantId = B`.
6. Notifications fan out (D8): every admin of A and every admin of B receives the booking-created notification.
7. A's dashboard runs widened query (D5): the booking surfaces. Transformer (D6) substitutes `space` with S_A and sets `partner_booking_info.sold_by_tenant_id = B`. Calendar renders the booking under S_A; partner badge shows "Booked via partner — Tenant B".
8. A's admin clicks "Cancel" → widened `findOne` returns the booking → cancel command executes. A's admin clicks "Refund" → command accepted; routed through B's PSP via `transaction.tenantId = B`.

---

## Data Model

### New table `shared_court_group`

| Column | Type | Constraint | Purpose |
|---|---|---|---|
| `id` | INT | PK, auto | Group id |
| `name` | VARCHAR(120) | NULL | Optional admin label (e.g. "Padbol Downtown shared court") |
| `created_at` | TIMESTAMPTZ | DEFAULT now() | Audit |
| `updated_at` | TIMESTAMPTZ | DEFAULT now() | Spark `EntityHelper` convention |
| `deleted_at` | TIMESTAMPTZ | NULL | Soft delete |

**No `physical_authority_space_id` column.** The group is a relational anchor for conflict scope only.

Application-layer invariants:
- Cannot soft-delete a group while it has active siblings — must remove siblings first via D9.
- A space can belong to at most one active group at a time (`space.shared_court_group_id` is a single FK).

Indexes: PK on `id`.

### Modification to `space`

| Column | Type | Constraint | Purpose |
|---|---|---|---|
| `shared_court_group_id` | INT | NULL, FK → `shared_court_group(id)` ON DELETE RESTRICT | NULL for non-shared spaces; set when sibling-joined |

Indexes: `IDX_space_shared_court_group_id` partial `WHERE shared_court_group_id IS NOT NULL`.

Existing `idx_space_name_locationId` unchanged.

### Modifications to `booking` and `cart`

**None.** Selling tenant derived through `booking.space → location → tenant`. Cart tenant derived from `spaces[0].location.tenantId` (each sibling is single-tenant).

### Composite index proposal (perf hedge)

Once the conflict check is rewritten via the resolver:

```sql
SELECT 1 FROM booking
WHERE record_type = 'space' AND record_id IN (<sibling ids>)
  AND NOT (end_time <= :start OR start_time >= :end)
LIMIT 1
```

Existing `booking(record_type, record_id)` index should cover this. Benchmark in Step 23 confirms.

### Migration plan

Three migrations, additive, zero downtime.

| # | Migration | DDL | Rollback |
|---|---|---|---|
| 1 | `<ts>-CreateSharedCourtGroupTable.ts` | `CREATE TABLE shared_court_group(id, name, created_at, updated_at, deleted_at)` | `DROP TABLE shared_court_group` |
| 2 | `<ts>-AddSharedCourtGroupIdToSpace.ts` | `ALTER TABLE space ADD COLUMN shared_court_group_id INT NULL REFERENCES shared_court_group(id) ON DELETE RESTRICT; CREATE INDEX IDX_space_shared_court_group_id ON space(shared_court_group_id) WHERE shared_court_group_id IS NOT NULL` | Drop column + drop index |
| 3 | (if benchmark requires) Composite index on `booking` covering conflict path | `CREATE INDEX ... ON booking(record_type, record_id, start_time, end_time) WHERE deleted_at IS NULL` | Drop index |

No backfill. Existing spaces have `shared_court_group_id = NULL`; resolver returns `[spaceId]`; non-shared behaviour is byte-identical.

Migration AgDR (workflow gate 3a) — TBD via `/migration` BEFORE editing any migration file.

### Backward compatibility

- Non-shared spaces: zero behaviour change.
- API contracts: only addition is `partner_booking_info: ... | null` on `SparkDashboardSpaceBookingDto`. Nullable → backwards compatible.
- Mobile / web customer clients: zero change.

---

## Implementation Plan

Using `Step N` notation per `.claude/rules/ticket-vocabulary.md` — these are **plan items**, not tracker tickets.

| # | Step | Layer | Notes |
|---|---|---|---|
| Step 1 | Run `/migration` to create the migration AgDR + labelled migration ticket | docs + tracker | Workflow gate 3a. Required before any DDL edit. |
| Step 2 | Migration: `CreateSharedCourtGroupTable` | infra | `id, name, created_at, updated_at, deleted_at` |
| Step 3 | Migration: `AddSharedCourtGroupIdToSpace` | infra | Nullable FK + partial index |
| Step 4 | New entity `SharedCourtGroupEntity` + mapper + port `SharedCourtGroupRepository` + relational impl | persistence | Standard layered pattern |
| Step 5 | Extend `SpaceEntity` with `shared_court_group_id` + `sharedCourtGroup` relation (eager: false) | persistence | Read-only relation on `space` |
| Step 6 | Implement `SharedCourtSpaceResolver` (single method `resolveSiblingSpaceIds`) | application/utils in `libs/space` | DataLoader-batched (request-scoped) per CLAUDE.md N+1 prevention |
| Step 7 | Refactor `BookingConflictValidator` to call resolver | application/validators | Disqualifier #1 fix |
| Step 8 | Refactor `BookingRepository.isConflicting` signature to `recordIds: number[]` | infra/persistence | Method-signature change; all callers in lockstep |
| Step 9 | Refactor `CartConflictValidator` + extend `CartRepository.findMany` with `spaceIds: number[]` | application/validators + persistence | Disqualifier #2 fix |
| Step 10 | Refactor `space-schedule.factory.ts` to aggregate booking-suppression across siblings via resolver | application/factories | Avoids "slot looks free then conflict rejects" |
| Step 11 | Extend `BookingQueryBuilder.filterBooking` `tenantId` + `tenantIds` filters with EXISTS clause (D5) | infra/persistence | Snapshot-test the SQL |
| Step 12 | Extend `SpaceQueryBuilder.filterSpace` so a sibling appears in the viewing tenant's space list AND extend `_mapLocationCalendar` filter at `booking.transformer.ts:380-383` to expand `recordId` via resolver | infra/persistence + transformer | Powers calendar rendering of partner bookings under viewing tenant's sibling row |
| Step 13 | Implement embedded-space DTO substitution + `partner_booking_info` enrichment in `BookingTransformer.transformBookings` (`booking.transformer.ts:208-220`) | apps/transformer | Per AgDR-0007. Introduce `SharedCourtSiblingForTenantLoader` (DataLoader). Add nullable `partner_booking_info` field on `SparkDashboardSpaceBookingDto` |
| Step 14 | Refund command handler — accept initiation from any sibling admin; route execution through `transaction.tenantId` PSP context; emit audit log with `refund_initiated_by_tenant_id` + `refund_executed_via_tenant_id` | application/commands | Per AgDR-0006 (v3 update) |
| Step 15 | Reschedule audit log — when `updateBookingWithSlots` moves the booking across siblings, emit `BookingRescheduleCrossSiblingDomainEvent` | application/events | AgDR-0006 |
| Step 16 | Symmetric admin notification fan-out — 4 admin handlers + 2 tenant-user handlers resolve sibling space ids and union recipients across all sibling locations | application/events | D8 |
| Step 17 | ~~`MaxSpacesPolicy` update~~ — **dropped from v1** per Q3 (no admin API for sharing → no quota enforcement needed) | — | — |
| Step 18 | **Build a dedicated "Shared Court Bookings" view** (admin surface) — per Q1: main per-tenant stats stay unchanged; this is a NEW aggregation surface showing partner-shared bookings for each tenant | libs/statistics + apps/spark-tenant-admin-api | New view; replaces v2 stats-widening plan |
| Step 19 | Wallet pass — verify correct by construction (selling sibling); add regression test | tests | Win versus v1 |
| Step 20 | ~~Super-admin sharing endpoints~~ — **dropped from v1** per Q3/D9 (DB-configured for v1; runbook script only) | — | — |
| Step 21 | ~~Sibling-departure / soft-delete handling~~ — **dropped from v1** per Q4 (fresh shares only; no historical state to migrate). Keep the FK on `space.shared_court_group_id` with `ON DELETE RESTRICT` so accidental group deletion fails loudly | infra/persistence | Q4 resolved |
| Step 22 | Tests: unit (resolver, conflict validators, transformer substitution + partner badge, refund routing including UI cross-tenant disclosure), integration (cross-sibling conflict, cross-sibling reschedule preserves transaction, partner-booking dashboard rendering via substitution, refund from any sibling executes via correct PSP, symmetric notification fan-out, tenant-isolation regression on non-shared, "Shared Court Bookings" view returns correct cross-tenant aggregation), E2E (full booking lifecycle on both tenants) | tests | See Testing Strategy |
| Step 23 | Perf benchmark — tenant booking list under load with 10 / 100 / 1000 shared courts; conflict check hot path; decide on Migration 3 | tests | R11 |

**Total v1 steps: 20** (Steps 17, 20, 21 dropped per CEO Q3/Q4 resolutions). The dropped scope ships as a v1.1 follow-up once the operational shape of sharing is real.

---

## Risks & Mitigations

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | **Resolver misses a call site** — silent cross-sibling double-book | High | **Critical** | Step 6–10 enumerate sites; AgDR-0005 carries the full list; acceptance criterion is grep with zero direct `recordId.*space` outside resolver; integration test "two tenants book same physical slot — second rejected" |
| R2 | **DTO substitution wires the wrong tenant's sibling** — A sees B-sold booking under wrong space | Low | High | Step 13 unit tests; the DataLoader keys on `(sharedCourtGroupId, viewingTenantId)`; assertion in integration test that `space.id` in the substituted DTO belongs to the viewing tenant's location |
| R3 | **Substitution breaks calendar `recordId` filter** | Med | Med | Step 12 widens the calendar filter via resolver. Tested at integration level |
| R4 | **Refund initiation widening exposes refund to malicious sibling admin who fraudulently cancels customer bookings** | Low | High | Action is auditable (audit log Step 14 records `refund_initiated_by_tenant_id`); CEO accepted the trade — operator trust is sibling-level by definition |
| R5 | **Reschedule cross-sibling silently shifts attribution** | Med | High | AgDR-0006: `transaction.tenantId` immutable; Step 15 audit log; integration test asserts transaction unchanged after cross-sibling reschedule |
| R6 | **Notification fan-out spam** — symmetric fan-out causes notification overload | Med | Low | CEO call: explicit. Future: per-group notification config (D9 extension) |
| R7 | **Divergent per-sibling availability rules confuse customers** — A's app shows 13:00 free, B's app shows 13:00 booked by A | Med | Med | Per D2 + Q2 — explicit product decision. Conflict resolver catches collisions at booking time |
| R8 | **`max-spaces` quota counts shared court twice** | Med | Med | Step 17 dedupe per Q3 |
| R9 | **Sibling departure leaves historical bookings orphaned** | Low | Med | D9 soft-delete preserves `shared_court_group_id`; Step 21 verification |
| R10 | **`parent_space_id` interaction unspecified** | Low | Med | Open question Q5; v3 default: siblings cannot also participate in parent-child hierarchy |
| R11 | **3-hop join perf** | Low → Med (growth) | Med | Composite index hedge; Step 23 benchmark; revisit denorm only on failure |
| R12 | **Old DTO consumers** crash on `partner_booking_info` field | Low | Low | Nullable additive — existing clients ignore |

---

## Security Considerations

- [x] Authn — existing JWT chain unchanged.
- [x] Authz — D5 widens read filter (which authorizes all operational mutates including refund initiation per D7); D7 keeps refund **execution** PSP-routed via transaction strict-equality. No CASL.
- [x] No PII added.
- [x] Audit trail — `shared_court_group` lifecycle events + cross-sibling reschedule event + refund-initiator/executor audit fields flow to `audit-trail` lib.
- [x] No new secrets, no new external integrations.
- [x] Multi-tenant data leak vectors: booking visibility (D5), conflict (D4 / AgDR-0005), cart conflict (D4), notification (D8), statistics (Step 18).
- [x] Substitution does NOT expose private B-tenant fields — `SparkBookingSpaceDto` shape (`booking-space.dto.ts:6-19`) is `{id, name, spaceType, spaceTypeValue, pricingType}` and the substituted object is A's own sibling space, so A only ever sees their own fields. `partner_booking_info` exposes selling tenant + location name only (no addresses, no contact info).

---

## Testing Strategy

| Type | Coverage | Notes |
|---|---|---|
| Unit | `SharedCourtSpaceResolver` (non-shared, shared, soft-deleted exclusion) | New test class |
| Unit | `BookingConflictValidator` post-resolver — cross-sibling conflict detected, non-shared unchanged | Regression-critical |
| Unit | `CartConflictValidator` post-resolver — cross-tenant cart conflict detected | Regression-critical |
| Unit | `BookingQueryBuilder.filterBooking` with EXISTS clause | Snapshot SQL |
| Unit | `BookingTransformer` substitution — same-tenant booking unchanged; cross-tenant substitutes space + sets `partner_booking_info`; non-shared booking unchanged | UX correctness — D6 |
| Unit | Refund command handler — initiation from any sibling accepted; execution routes via `transaction.tenantId` PSP | D7 + AgDR-0006 |
| Integration | Cross-sibling booking conflict (A at 7pm; B at 7pm rejected) | Disqualifier #1 |
| Integration | Cross-tenant cart conflict (two carts → second rejected) | Disqualifier #2 |
| Integration | Cross-tenant dashboard read — A's admin GET /bookings/:id (B-sold) returns booking with substituted `space.id = A_sibling.id` and `partner_booking_info.sold_by_tenant_id = B` | D6 |
| Integration | Calendar render — partner booking appears under A's sibling space row on calendar | D6 + Step 12 |
| Integration | Cross-tenant operational mutate — A cancels / marks-no-show / edits-notes / edits-price on B-sold booking | D7 |
| Integration | Cross-tenant refund — A initiates refund on B-sold booking → 200; audit log shows `executed_via = B`; B's PSP charged | AgDR-0006 (v3) |
| Integration | Cross-sibling reschedule — A reschedules B-sold booking to A's sibling: `booking.recordId` changes; `transaction.tenantId` unchanged | AgDR-0006 |
| Integration | Symmetric notification fan-out — booking-created emits notifications to admins of both A and B | D8 |
| Integration | Non-shared isolation regression — A's non-shared booking NOT visible to B | Catches `1=1` regressions |
| E2E | Customer books via B's mobile → wallet pass shows B's branding; A's admin can cancel, refund executes through B | Customer + admin loop |
| Perf | Booking-list endpoint under 10 / 100 / 1000 shared courts | R11 |

Coverage target: > 80% on touched domain logic.

---

## Open Questions

CEO-resolved the v3 question set on 2026-06-15. Outstanding items below.

### Resolved (CEO, 2026-06-15)

| # | Resolution |
|---|---|
| **Q1** — Statistics shape | **Separate dedicated "Shared Court Bookings" view.** Main per-tenant stats stay unchanged (each tenant's own non-shared bookings only). A new admin surface aggregates the partner-bookings view distinctly. Step 18 reframed accordingly: no widening of the existing stats query; build a new view. |
| **Q2** — Per-sibling availability rules | **Confirmed intentional.** Each sibling defines its own availability. The "A's app says 13:00 free, B's app says 13:00 booked-by-A" experience is the explicit trade. |
| **Q3** — `max-spaces` quota | **Not in scope for v1.** Sharing is rare and DB-configured (see D9). Quota enforcement for siblings is deferred until there's an admin API. Step 17 dropped from v1 scope. |
| **Q4** — Sibling-departure | **Out of scope for v1.** Operating assumption: a tenant only joins a share when opening a *fresh* sibling space at the partner's location. No historical bookings exist on a freshly created sibling. Share dissolution will be handled when (and if) the case actually arises. |
| **Q7** — Refund cross-tenant routing transparency | **Surface in UI.** When admin A triggers a refund on a B-sold booking, the UI explicitly shows "refund will execute via Tenant B" so the operator understands the cross-tenant routing. Encoded in AgDR-0006 + D7. |

### Outstanding

| # | Question | Owner | Why it matters |
|---|---|---|---|
| Q5 | Can a sibling space also participate in the `parentSpace` / `childSpace` hierarchy (padel-court capacity inheritance)? | Mariam | v3 default: no. Revisit if product needs it. Lower priority — no current ask. |
| Q6 | Notification fan-out volume — symmetric fan-out may cause admin notification spam at multi-tenant scale. Acceptable for v1, or add per-group throttle/digest? | Mariam + Khalid | v3 default: symmetric fan-out without throttle. Future enhancement track. |
| Q8 | If the 3-hop join (D3) shows up as hot-path perf regression in Step 23, do we add a `booking.selling_tenant_id` denorm column? | CEO + Tech Lead | v3 default: no denorm; add covering index. Revisit only on benchmark failure. |

---

## Approvals

| Role | Name | Date | Status |
|---|---|---|---|
| Tech Lead | Hisham | 2026-06-15 | Author (v3) |
| Head of Engineering | Khalid | — | Pending (architecture review — multi-tenant boundary change) |
| Security Auditor | Hakim | — | Pending (touches tenant isolation, conflict resolver, refund routing) |
| Product Manager | Mariam | — | Documentary — CEO self-authorised (ticket author = CEO) |
| **CEO** | **Abdelrahman** | **2026-06-15** | **✅ Approved — scope changes table + Q1/Q3/Q4/Q7 resolved** |
