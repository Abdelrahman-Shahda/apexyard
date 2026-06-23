---
id: AgDR-0006
timestamp: 2026-06-15T00:00:00Z
agent: tech-lead
model: claude-opus-4-7
session: techdesign-shared-space-multi-tenant-v2
trigger: user-prompt
status: executed
category: architecture
projects: [booking-system]
---

# Reschedule semantics + operational-vs-financial ownership decoupling

## Revision history

- **2026-06-15 v3** — Authz widening. Per CEO call (*"for any action on the booking we should be able to do it from siblings"* + *"for the transaction it would be linked to the tenant who completed the booking"*), refund **initiation** is now permitted from any sibling admin whose tenant is in the booking's `shared_court_group`. Refund **execution** still routes through the original selling tenant's PSP via the existing strict-equality filter on `transaction.tenantId` — the money flows match the transaction. The v2 "selling tenant only" carve-out for the refund button is dropped. The audit log on refund records both `refund_initiated_by_tenant_id` (the sibling admin who pressed the button) and `refund_executed_via_tenant_id` (the PSP context = `transaction.tenantId`) for traceability. Reschedule semantics + operational/financial decoupling are otherwise unchanged: `booking.recordId` may move between siblings; `transaction.tenantId` is immutable; cross-sibling reschedules emit `BookingRescheduleCrossSiblingDomainEvent`. The "commercial-price-edit gate" from v2 (which blocked partner-tenant admins from editing price) is also dropped under v3 D7 — any sibling admin can edit any operational/commercial field on the booking.
- 2026-06-15 v2 — Authored.

> In the context of the v2 sibling-spaces model where either tenant can reschedule a partner-sold booking, facing the AC that "both tenants can edit/cancel a shared-space booking" combined with the existing Spark reschedule semantics (which rewrites `booking.recordId` to the new slot's `spaceId` at `apps/spark-tenant-admin-api/src/app/modules/bookings/services/admin/bookings.service.ts:309`), I decided that reschedule MAY move the booking row to a different sibling space while the underlying transaction stays IMMUTABLY attached to the original selling tenant, to achieve a clean separation between operational ownership (booking row — both tenants edit) and financial ownership (transaction row — selling tenant only, even after reschedule), accepting that this introduces a silent attribution shift that must be made visible through an explicit audit-log event on every cross-sibling reschedule.

## Context

- Verified write path: `apps/spark-tenant-admin-api/src/app/modules/bookings/services/admin/bookings.service.ts:260-329` — `updateBookingWithSlots` takes the new slot's `spaceId` and passes it via the update DTO at line 309. Under v2 with cross-tenant operational mutate enabled (D5 widens `findOne` so A can reschedule a B-sold booking), the new `spaceId` may belong to **A's sibling** while the original booking was on B's sibling. The booking row effectively migrates between siblings.
- Verified financial path: `libs/booking/src/lib/application/strategies/booking/base-booking.strategy.ts:36` sets `tenantId = space.location!.tenantId` at booking creation; `libs/transaction/src/lib/infrastructure/persistence/entities/transaction.entity.ts:93-101` stores `transaction.tenantId` NOT NULL; transaction mutate paths (`transaction.repository.ts:225-239`, `transaction-query.utils.ts:27-38`) filter strictly on `transaction.tenantId`. **There is no path today that re-attributes a transaction post-creation.** v2 takes advantage of this: the strict-equality filter on the mutate path IS the financial gate.
- Adversarial review §4.5 flagged reschedule as "the sting in the tail" — even after widening `findOne` for read/cancel/mark-X, reschedule needs a deliberate decision about what moves and what doesn't.
- CEO decision (briefed in v2 rewrite scope): reschedule MAY move attribution. Matches existing Spark reschedule semantics; surprises operators less than "reschedule blocked across siblings". The decoupling is the deliberate design — operational ownership and financial ownership are separate concepts.

## Options Considered

| Option | Pros | Cons |
|---|---|---|
| **A. Reschedule moves `booking.recordId` to the new sibling; `transaction.tenantId` stays immutable on original seller; emit `BookingRescheduleCrossSiblingDomainEvent` on every cross-sibling reschedule for observability.** (v2 pick) | Matches existing Spark reschedule semantics (attribution moves with space). Cleanly separates operational ownership (booking — both tenants edit) from financial ownership (transaction — selling tenant only). Refund authority follows the money; the original seller is the only one who can refund the original transaction. Audit log makes the attribution shift visible to ops + audits — closes the "silently double-booked / silently migrated" concern from adversarial §4.5. | Operationally subtle: after reschedule the partner tenant's dashboard shows the booking under their court, but only the original seller's refund button is enabled. UX needs the `display_context` discriminator (D6) to surface this honestly. |
| B. Reschedule across siblings is blocked — A can only reschedule to A's sibling | Simpler mental model | Violates the AC "either tenant can edit/cancel" because reschedule is a kind of edit. Surprises ops. |
| C. Reschedule moves the booking AND moves the transaction (money follows the slot) | Operational + financial alignment | **Breaks reconciliation.** Money was already collected by the original seller's PSP merchant account. Moving the transaction record post-collection would force an inter-tenant cash transfer, which is exactly the "commission contracts" concept the v2 design explicitly defers to a future feature. |
| D. Reschedule across siblings is blocked unless an explicit "transfer" workflow is invoked (with both tenants consenting) | Defence-in-depth | Heavy. Out of scope for v1. Reasonable future enhancement. |

## Decision

Chosen: **A — reschedule moves operational attribution; financial attribution is immutable; explicit audit log on cross-sibling moves.**

### Semantics

| Action | What moves | What's immutable |
|---|---|---|
| Tenant A reschedules B-sold booking to a slot on A's sibling | `booking.recordId` (B's space → A's space). Through the derived chain, `booking.space → space.location → location.tenant_id` now resolves to A as the "selling tenant of the current sibling". The dashboard's `display_context.sold_by_tenant_id` recomputes from this chain. | `transaction.tenantId` stays = B. The transaction's `record_id` (pointing at booking) is unchanged. Refund button only lights up for B. |
| Tenant A reschedules B-sold booking to a slot on B's sibling | `booking.recordId` may change to a different B-sibling space (within B's slots), but `space.location.tenant_id` stays = B. No cross-sibling event. | Same. `transaction.tenantId` = B. |
| Tenant B reschedules own booking on B's sibling (same sibling) | Same as today — `recordId` may change between B's own spaces. No cross-sibling event. | Same. |

### Refund attribution invariant (v3 update)

After a cross-sibling reschedule (A → A's sibling on a B-sold booking) or for any partner booking:
- `transaction.tenantId` = B (selling tenant).
- **Any sibling admin may initiate refund.** A's admin clicks "Refund" on the booking → the refund command handler accepts the request (booking is visible to A via the widened D5 filter).
- The refund command handler resolves the underlying transaction → `transaction.tenantId = B` → enqueues / executes the refund through B's PSP merchant context. The strict-equality filter on `transaction.tenantId` in the mutate path (`transaction.repository.ts:225-239`) is what ensures the PSP routing is correct.
- The audit log records `refund_initiated_by_tenant_id = A`, `refund_executed_via_tenant_id = B`.

The **action** (clicking refund) is widely permitted; the **financial execution** is constrained by the immutable `transaction.tenantId`. This satisfies the CEO's framing: any sibling can take any action; money flows match the transaction.

Direct PSP API calls (e.g. `POST /transactions/:id/refund` with the transaction id) still respect the strict-equality filter because the transaction read goes through `TransactionQueryBuilder` — A's admin cannot directly mutate B's transaction by id. Refund initiation must go through the booking-level refund command, which mediates the PSP routing.

### Refund UI transparency (CEO Q7 — resolved 2026-06-15)

When admin A initiates a refund on a partner booking (B-sold), the admin app **must explicitly surface the cross-tenant execution path** in the UI. Hiding the routing detail was rejected — operators should never be surprised about which merchant account a refund executes against.

Concrete UI requirements:
- **Pre-confirmation modal** on the Refund button for partner bookings: "*This booking was sold by [Tenant B's display name]. The refund will be issued through Tenant B's payment provider.*" Operator confirms before the request fires.
- **Post-action toast / status**: "*Refund initiated — pending execution by [Tenant B].*"
- **Booking detail view**: when `partner_booking_info` is non-null (AgDR-0007 substitution), show the routing chip "*Payment held by [Tenant B]*" next to the refund control so operators have context without clicking.

The audit log entry already records `refund_initiated_by_tenant_id` + `refund_executed_via_tenant_id` (see Audit-log event below). The UI surfacing is the operator-facing counterpart to that audit trail.

### Audit-log event (the observability requirement)

When `updateBookingWithSlots` detects that the new slot's `spaceId` belongs to a different `shared_court_group` sibling than the original, emit:

```typescript
class BookingRescheduleCrossSiblingDomainEvent {
  bookingId: number;
  originalSpaceId: number;
  newSpaceId: number;
  originalSellingTenantId: number;
  newSellingTenantId: number;
  transactionId: number;        // unchanged
  transactionTenantId: number;  // unchanged — should equal originalSellingTenantId
  rescheduleInitiatedByTenantId: number;
  rescheduleInitiatedByAdminId: number;
  occurredAt: Date;
}
```

Consumed by:
- `audit-trail` lib (compliance + forensic record).
- Datadog dashboard tag — alert if `originalSellingTenantId !== transactionTenantId` (sanity check that the immutability invariant holds).
- Future "shared court ops report" for super-admin.

### Justification

1. **Separation of operational and financial ownership** is a clean mental model that matches reality: the booking is "what's on the court right now"; the transaction is "who collected the money". These can legitimately diverge after reschedule.
2. **Refund follows the money.** The strict-equality filter on `transaction.tenantId` makes this mechanical — no new gate.
3. **Audit-log visibility** closes the "silent migration" concern. Every cross-sibling reschedule is explicit and traceable.
4. **Matches existing Spark reschedule semantics.** Minimal departure from the codebase's existing patterns.
5. **Leaves room for future "transfer" workflows.** Option D can be added later as an explicit feature without rearchitecting the core.

## Consequences

- `updateBookingWithSlots` detects cross-sibling moves (compare original `booking.recordId`'s `space.shared_court_group_id` with new `spaceId`'s) and emits the audit event.
- `transaction.tenantId` is **never** rewritten by any application code path. This is a load-bearing invariant; the integration test asserts it.
- D6's `display_context` block on the booking response recomputes correctly after reschedule because it derives from the live chain — partner badge updates from "A is partner" to "no badge" after A reschedules a B-sold booking onto A's sibling and operates it themselves. UX consequence: dashboards naturally reflect the new operational owner.
- Refund UI surfaces (in the dashboard) gate the refund button on `transaction.tenantId === current_tenant`, not on booking ownership. This is a UX-layer responsibility derived from the existing strict-equality filter.
- The "commission contracts" future feature (out of scope per v2) would extend this by adding a separate `commission` ledger; the transaction itself stays immutable in this AgDR's frame.
- Integration test required (tech design Step 25): "A reschedules B-sold booking across siblings → `booking.recordId` changes → `transaction.tenantId` unchanged → B can refund (200) → A cannot refund (404)".
- Integration test required: "A reschedules B-sold booking WITHIN B's siblings (no cross-sibling) → no audit event emitted".
- Audit-log consumer for the new event in the existing `audit-trail` lib.

## Artifacts

- Technical design: `projects/booking-system/techdesign-shared-space-multi-tenant.md` (v2) § D7 + Step 17 (audit log) + Step 25 (tests)
- Adversarial review: `projects/booking-system/techdesign-sibling-spaces-adversarial-review.md` §4.5 (the sting this AgDR closes)
- Partner AgDRs: `[[AgDR-0001-shared-space-data-model]]`, `[[AgDR-0004-physical-vs-commercial-fact-split]]`, `[[AgDR-0005-centralized-conflict-availability-resolver]]`
- Code evidence:
  - `apps/spark-tenant-admin-api/src/app/modules/bookings/services/admin/bookings.service.ts:260-329` (`updateBookingWithSlots`)
  - `apps/spark-tenant-admin-api/src/app/modules/bookings/services/admin/bookings.service.ts:309` (the line that rewrites `spaceId`)
  - `libs/booking/src/lib/application/strategies/booking/base-booking.strategy.ts:36` (selling tenant derivation)
  - `libs/transaction/src/lib/infrastructure/persistence/entities/transaction.entity.ts:93-101` (`transaction.tenantId` schema)
  - `libs/transaction/src/lib/infrastructure/persistence/repositories/transaction.repository.ts:225-239` (mutate-path strict-equality filter)
- Ticket: apessolutions/booking-system#752
