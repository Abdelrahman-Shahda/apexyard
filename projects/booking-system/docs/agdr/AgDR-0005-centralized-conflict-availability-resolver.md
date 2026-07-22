---
id: AgDR-0005
timestamp: 2026-06-15T00:00:00Z
agent: tech-lead
model: claude-opus-4-7
session: techdesign-shared-space-multi-tenant-v2
trigger: user-prompt
status: executed
category: architecture
projects: [booking-system]
---

# Centralized `SharedCourtSpaceResolver` for conflict + availability

## Revision history

- **2026-06-15 v3** — Confirmed by v3 simplification pass. Possibly more important now: with each sibling owning its own availability rules and granularity (D2 in v3 tech design), the cross-sibling **conflict** check is the only group-scope correctness guarantee. The resolver's `resolveSiblingSpaceIds(spaceId): Promise<number[]>` is the load-bearing primitive that survives unchanged from v2. Note: under v3 each sibling reads its own `SpaceAvailabilityRule` rows (no read-through to an "authority"), so the secondary `resolvePhysicalAuthoritySpaceId` method from v2 is no longer needed — the interface reduces to the single `resolveSiblingSpaceIds` method. The `space-availability.validator.ts:16-37` call site reverts to reading the sibling's own rules (no resolver call); only conflict / cart-conflict / slot-listing paths go through the resolver. AgDR-0004 (the physical/commercial split) is SUPERSEDED in v3.
- 2026-06-15 v2 — Authored.

> In the context of the v2 sibling-spaces model where one physical court has two `space.id`s, facing the adversarial review's verified disqualifier that `BookingConflictValidator.recordId = spaceId` (and the parallel cart-conflict and slot-listing paths) silently miss cross-sibling bookings — meaning the bare sibling-spaces design double-books the court by construction — I decided to introduce a `SharedCourtSpaceResolver` primitive that, given any space id, returns the set of sibling space ids in the same `shared_court_group`, and to route EVERY conflict / availability / cart-conflict / slot-listing call site through it, to achieve a single physical-court key that all booking-related predicates honor, accepting that this is the design's #1 implementation risk and requires touching at least five scattered call sites that today each carry their own scoping logic.

## Context

- The v2 sibling-spaces model (`[[AgDR-0001-shared-space-data-model]]` v2) gives one physical court two `space.id`s. Every conflict / availability path that keys on `space.id` (which is essentially all of them today — verified file:line below) is now wrong by construction.
- The adversarial review (`techdesign-sibling-spaces-adversarial-review.md` §3.1, §3.3, §3.4) called this out as **the disqualifier** — the bare sibling-spaces proposal claimed "centralized availability resolver" as a primitive that doesn't exist. This AgDR is the resolver.
- Verified call sites (file:line):
  - `libs/booking/src/lib/application/validators/booking-conflict.validator.ts:16-24` — calls `bookingRepository.isConflicting({ recordId: data.spaceId, recordType: SPACE_ENTITY, ... })`. Hard equality on spaceId. Silently misses cross-sibling.
  - `libs/booking/src/lib/infrastructure/persistence/repositories/booking.repository.ts:199-217` — `isConflicting` implementation passes `recordIds: [spaceId]` to `BookingQueryBuilder`. Method signature needs to accept a list.
  - `libs/booking/src/lib/infrastructure/persistence/utils/booking-query.utils.ts:61-69` — `recordIds` filter is `booking.recordId IN (:...recordIds)`. **This filter has TWO semantics today** (per adversarial §7 step 4): "this exact sibling's bookings" (correct for `findAll` scoped by tenant) and "this physical court's bookings" (correct for conflict / availability). v2 makes these two semantics distinct; every caller needs a per-call decision.
  - `libs/cart/src/lib/validators/cart-conflict.validator.ts:22-58` — finds carts via `cartRepository.findMany({ tenantId: space.location?.tenantId })`. Tenant-scoped → cross-tenant cart double-book on the same physical court is invisible.
  - `libs/booking/src/lib/application/factories/space-schedule.factory.ts` — slot listing. Generates the slots a customer picks from. Must aggregate booking-suppression across siblings.
  - `libs/booking/src/lib/application/validators/space-availability.validator.ts:16-37` — reads `SpaceAvailabilityRule` for `spaceId`. Under v2 (AgDR-0004) the rules live on the physical-authority sibling only; the resolver redirects to the authority id.
- Pre-existing test coverage of conflict path: `libs/booking/**/*.spec.ts` — broad; AgDR-0005's biggest test surface.

## Options Considered

| Option | Pros | Cons |
|---|---|---|
| **A. Single `SharedCourtSpaceResolver` primitive used by every conflict/availability path. Method `resolveSiblingSpaceIds(spaceId): Promise<number[]>` returns `[spaceId]` for non-shared, `[spaceId, ...sibling ids]` for shared.** (v2 pick) | Single source of truth for "what is the physical court key for this space?". Mechanical and grep-able — acceptance criterion is "zero direct uses of `space.id` in conflict / availability paths post-implementation". Composes cleanly with the existing `recordIds: number[]` filter shape (which already exists at `booking-query.utils.ts:61-69`). Easy to test in isolation. | One new primitive that every conflict path now depends on — failure mode is "we forgot to route a call site through it", which is silent and dangerous. AgDR enumeration + grep audit is the mitigation. |
| B. Push the logic into `BookingQueryBuilder.filterBooking` directly — every caller passes `spaceId`, the builder expands to sibling set internally | One filter does the right thing | Hides the expansion in a query-builder branch that other callers (cart, slot listing, statistics) don't go through — fragments the logic across two implementations. Worse: callers that genuinely want "this exact sibling's bookings" lose that option. |
| C. Per-domain widening — each lib (booking, cart, slot listing) implements its own sibling lookup | Local control | Three implementations to keep in sync. Same bug surface, tripled. |
| D. Denormalize `physical_court_key` onto `booking.record_id_group_key` (a separate identifier shared across siblings) | Conflict check is one column compare | New denorm column on the polymorphic `booking` table — same principle violation flagged in AgDR-0001 v2 (`booking.selling_tenant_id` was rejected for the same reason). Backfill needed; CASCADE risk on schema change. |

## Decision

Chosen: **A — single `SharedCourtSpaceResolver` primitive.**

### Interface

```typescript
// libs/space/src/lib/application/ports/shared-court-space-resolver.ts
export abstract class SharedCourtSpaceResolver {
  /**
   * Returns the set of space.id values that share a physical court with the given spaceId.
   *
   * - Non-shared space (space.shared_court_group_id IS NULL): returns [spaceId].
   * - Shared space: returns [spaceId, ...sibling space ids in the same shared_court_group]
   *   where siblings are NOT soft-deleted (deleted_at IS NULL).
   *
   * Used by all conflict + availability + cart-conflict + slot-listing paths.
   */
  abstract resolveSiblingSpaceIds(spaceId: number): Promise<number[]>;

  /**
   * Returns the physical-authority space id for the given spaceId.
   *
   * - Non-shared: returns spaceId itself.
   * - Shared: returns shared_court_group.physical_authority_space_id.
   *
   * Used by SpaceAvailabilityValidator to resolve availability rules through the authority.
   */
  abstract resolvePhysicalAuthoritySpaceId(spaceId: number): Promise<number>;
}
```

Implementation in `libs/space/src/lib/infrastructure/persistence/repositories/shared-court-space-resolver.relational.ts` uses a DataLoader (per CLAUDE.md "N+1 prevention") because the methods are called in hot loops (per-slot conflict check during cart-add).

### Acceptance criterion

A grep run as part of the design's exit gate:

```bash
# Should return zero matches outside the resolver implementation itself.
grep -rn 'isConflicting.*recordId.*spaceId\|recordIds.*\[spaceId\]\|findMany.*tenantId.*space\.location' \
  libs/booking libs/cart libs/space
```

Every conflict + availability + cart-conflict call site routes through the resolver.

### Call-site enumeration (file:line — these are the load-bearing changes)

| # | Site | Today | Post-resolver |
|---|---|---|---|
| 1 | `libs/booking/src/lib/application/validators/booking-conflict.validator.ts:16-24` | `isConflicting({ recordId: data.spaceId, ... })` | `isConflicting({ recordIds: await resolver.resolveSiblingSpaceIds(data.spaceId), ... })` |
| 2 | `libs/booking/src/lib/infrastructure/persistence/repositories/booking.repository.ts:199-217` (`isConflicting` impl) | Accepts `recordId: number` | Accepts `recordIds: number[]` (passes through to `BookingQueryBuilder.filterBooking({ recordIds })`) |
| 3 | `libs/cart/src/lib/validators/cart-conflict.validator.ts:22-58` | `cartRepository.findMany({ tenantId: space.location?.tenantId })`; item-side filter `cartItem.additional.spaceId === this.spaceId` | Resolver returns sibling space ids; extend `CartRepository.findMany` with `spaceIds: number[]` (driving filter on the cart-item side); the item-side filter checks `cartItem.additional.spaceId IN siblingSet` |
| 4 | `libs/booking/src/lib/application/factories/space-schedule.factory.ts` | Generates slots per `space.id` | Booking-suppression aggregates across `resolver.resolveSiblingSpaceIds(spaceId)` |
| 5 | `libs/booking/src/lib/application/validators/space-availability.validator.ts:16-37` | Reads `SpaceAvailabilityRule` for `spaceId` | Resolves availability rules via `resolver.resolvePhysicalAuthoritySpaceId(spaceId)` (AgDR-0004) |
| 6 | `libs/booking/src/lib/infrastructure/persistence/utils/booking-query.utils.ts:61-69` | `recordIds` filter (existing shape works; just gets called with the expanded list) | **Unchanged.** This filter is correct under v2 too — what changes is who calls it with which set of ids. |

Statistics queries (`libs/statistics/`) **also** key on booking-list — open question Q1 in the tech design decides whether stats route through the resolver (cross-sibling view) or stay per-sibling (physical-authority sibling halved). Either choice is a follow-up wire-up; the resolver primitive supports both.

### Justification

1. **Single source of truth.** The resolver is THE answer to "what is the physical court key for this space?". Every place that needs that answer asks the resolver. No re-derivation.
2. **Composability with the existing `recordIds: number[]` filter shape.** `BookingQueryBuilder.filterBooking` already accepts a list at `booking-query.utils.ts:61-69`. The resolver just produces the right list. Minimal schema/builder churn.
3. **Mechanically auditable.** The grep acceptance criterion is concrete. The PR can show zero direct uses of `space.id` in conflict paths.
4. **Performance-aware.** DataLoader-batched to avoid N+1 in hot loops.

## Consequences

- New port + relational impl: `SharedCourtSpaceResolver` in `libs/space/src/lib/application/ports/` and `libs/space/src/lib/infrastructure/persistence/repositories/`.
- `BookingRepository.isConflicting` signature changes: `recordId: number` → `recordIds: number[]`. All callers updated in lockstep (Step 8 in the tech design).
- `CartRepository.findMany` gains a `spaceIds?: number[]` filter (or the cart-conflict validator switches to a different repo method shape).
- `BookingConflictValidator`, `CartConflictValidator`, `space-schedule.factory.ts`, `SpaceAvailabilityValidator` all gain a constructor injection on `SharedCourtSpaceResolver`.
- This AgDR is the design's **#1 risk** (risk R1 in tech design). Failure mode: a missed call site that still keys on `space.id` is a silent double-book. Mitigation: the grep acceptance criterion above + an integration test "two tenants book the same physical slot at the same time; second is rejected".
- The `recordIds` filter at `booking-query.utils.ts:61-69` carries TWO semantics today ("this sibling only" vs "this physical court"). v2 makes them distinct. The PR walks every caller of `recordIds` and tags the intent. Documented in the tech design § R1.
- DataLoader pattern means the resolver should be request-scoped (NestJS scope: REQUEST or DataLoader registered per-request). Otherwise cache poisoning across requests is a risk.
- Open question: statistics path (Q1) — does it use the resolver or stay per-sibling? Either is fine; the primitive supports both. Resolved by Mariam + CEO.

## Artifacts

- Technical design: `projects/booking-system/techdesign-shared-space-multi-tenant.md` (v2) § D4 + Steps 6–11
- Adversarial review: `projects/booking-system/techdesign-sibling-spaces-adversarial-review.md` §3.1, §3.3, §3.4 (the breaks this AgDR closes)
- Partner AgDRs: `[[AgDR-0001-shared-space-data-model]]`, `[[AgDR-0004-physical-vs-commercial-fact-split]]`
- Code evidence:
  - `libs/booking/src/lib/application/validators/booking-conflict.validator.ts:16-24`
  - `libs/booking/src/lib/infrastructure/persistence/repositories/booking.repository.ts:199-217`
  - `libs/booking/src/lib/infrastructure/persistence/utils/booking-query.utils.ts:61-69`
  - `libs/cart/src/lib/validators/cart-conflict.validator.ts:22-58`
  - `libs/booking/src/lib/application/validators/space-availability.validator.ts:16-37`
  - `libs/booking/src/lib/application/factories/space-schedule.factory.ts`
- Ticket: apessolutions/booking-system#752
