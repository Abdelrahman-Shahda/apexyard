---
id: AgDR-0007
timestamp: 2026-06-15T00:00:00Z
agent: tech-lead
model: claude-opus-4-7
session: techdesign-shared-space-multi-tenant-v3
trigger: user-prompt
status: executed
category: architecture
projects: [booking-system]
---

# Cross-tenant booking visibility via embedded space DTO substitution

> In the context of the v3 sibling-spaces model where tenant A's admin needs to view, mutate, and refund partner-sold bookings on a shared court, facing the CEO constraint *"changing dto would break the admin app — for space dto itself instead of sending tenant B's space replace it with tenant A space"*, I decided to render cross-tenant visibility by **substituting the embedded `space` DTO** inside the booking response with the viewing tenant's own sibling space (instead of the canonical selling sibling's space) and to add one nullable additive `partner_booking_info` field at the booking level for the partner badge, to achieve zero admin-app changes (existing calendar / list / "bookings on space X" filters keep working unchanged) while preserving the canonical `booking.id` and `recordId` so mutation routing stays honest, accepting that the calendar-side `recordId === space.id` filter at `booking.transformer.ts:380-383` needs a small widening via the conflict resolver so substituted bookings render under the viewing tenant's sibling row.

## Context

### Verified DTO shape (the load-bearing facts)

- `libs/contracts/src/lib/spark/tenant/v1/booking/admin-booking.dto.ts:19-100` — `SparkDashboardBookingDto` (base). `this.id = booking.id` (line 62). Carries `name: string` (set from `space.name` by transformer). **No top-level `spaceId` field.** No `tenantId` field.
- `libs/contracts/src/lib/spark/tenant/v1/booking/space/admin-space-booking.dto.ts:38-86` — `SparkDashboardSpaceBookingDto extends SparkDashboardBookingDto`. **The embedded space DTO is `space?: SparkBookingSpaceDto` at line 39.** Also `location?: SparkUserBookingLocationDto` at line 40. Constructor at lines 68-75:
  ```typescript
  if (isDefined(booking.space)) {
    this.space = new SparkBookingSpaceDto(booking.space);
    if (isDefined(booking.space.location))
      this.location = new SparkUserBookingLocationDto(
        booking.space.location,
        instanceToPlain(booking.space.location.image)['path'],
      );
  }
  ```
  The DTO copies fields off `booking.space` at construction time — so the substitution point is "what `booking.space` is set to" *before* the constructor runs.
- `libs/contracts/src/lib/spark/tenant/v1/booking/booking-space.dto.ts:6-19` — `SparkBookingSpaceDto`:
  ```typescript
  class SparkBookingSpaceDto {
    id!: number;
    name!: string;
    spaceType!: SpaceTypeEnum;
    spaceTypeValue!: SpaceType;
    pricingType!: SpacePricingEnum;
  }
  ```
  Lean shape — no permissions, no relations to tenant context. Substitution is safe: A's sibling space has the same shape as B's; only the `id`, `name`, and per-sibling config differ.
- `apps/spark-tenant-admin-api/src/app/modules/bookings/controllers/admin/booking.transformer.ts:208-220` — `BookingTransformer.transformBookings` is where `SparkDashboardSpaceBookingDto` is constructed. **This is the substitution point.**

### Verified mutation routing

- `apps/spark-tenant-admin-api/src/app/modules/bookings/services/admin/bookings.service.ts:332-343` and every mutate route (`241, 265, 353, 368, 378, 388, 398`) — all identify the booking by `id` and run `findOne(id)`. `findOne` runs through `BookingQueryBuilder.filterBooking` which under D5 widens to include partner siblings. **No mutation path reads `space.id` from the request body to identify the booking** — the canonical `booking.id` is the routing key. Substituting the embedded `space` DTO in the response does not affect mutation routing.
- The booking's `recordId` (which points at the canonical selling sibling's `space.id`) is NOT changed by substitution. Backend logic that needs the canonical space (conflict check, transaction routing, audit) reads `booking.recordId` from the domain entity, not from the substituted DTO.

### Calendar path

- `apps/spark-tenant-admin-api/src/app/modules/bookings/controllers/admin/booking.transformer.ts:344-391` — `_mapLocationCalendar` filters bookings into space buckets by `b.recordId === space.id` (line 380-383). Under v3 partner bookings retain canonical `recordId` (B's space.id), so without a fix they would NOT match A's sibling space row and would render in the wrong bucket (or not at all). The fix: expand the filter to `b.recordId === space.id || resolverSiblingIds.includes(b.recordId)` so partner bookings on shared courts naturally render under A's sibling row. Combined with the substitution this gives A's calendar a coherent view where the shared court shows A's bookings + B's bookings together under A's sibling row, with the partner badge distinguishing them.

## Options Considered

| Option | Pros | Cons |
|---|---|---|
| **A. Substitute embedded `space` DTO; add nullable `partner_booking_info` at booking level (v3 pick)** | Zero admin-app changes — existing space-list / calendar / filter / details UI just works. Canonical `booking.id` preserved for mutations. Lean `SparkBookingSpaceDto` shape (5 fields) means substitution is safe and visually correct (substituted name = A's label for the court). One additive nullable field (backward-compat). Minimal transformer-layer change. | The substitution requires a DataLoader call per booking row (resolve viewing tenant's sibling in the same group). Cost: one extra batched query per page. Calendar-side `recordId === space.id` filter needs a small widening. |
| B. v2's `display_context` field on the booking DTO | Mechanically explicit | Changes admin-app DTO shape — the CEO rejected this exact approach. UI has to learn a new field and decide rendering branches. |
| C. Don't substitute; show B-sold bookings under B's space row (which A can't see unless we also show B's spaces) | Truthful | Adds clutter to A's dashboard with B's tenant-foreign space rows. Worse UX than substitution. |
| D. Substitute at the API gateway / middleware layer | Centralized | Too generic — the substitution rule is domain-aware (depends on shared_court_group). Better in the transformer. |

**Chosen: A.**

## Decision

Chosen: **A — embedded space DTO substitution + `partner_booking_info`.**

### Mechanism

Substitution lives in `BookingTransformer.transformBookings` at `apps/spark-tenant-admin-api/src/app/modules/bookings/controllers/admin/booking.transformer.ts:208-220`, just before the `SparkDashboardSpaceBookingDto` constructor is called.

```typescript
// inside transformBookings, per-booking branch for SpaceBooking
const viewingTenantId = ContextProvider.getCurrentTenant()!.id;
const canonicalSpace = (booking as SpaceBooking).space;
const canonicalSellingTenantId = canonicalSpace.location!.tenantId;

let renderedSpace = canonicalSpace;
let partnerBookingInfo: PartnerBookingInfo | null = null;

if (
  canonicalSpace.sharedCourtGroupId != null &&
  canonicalSellingTenantId !== viewingTenantId
) {
  const siblingSpace = await this.sharedCourtSiblingForTenantLoader.load({
    sharedCourtGroupId: canonicalSpace.sharedCourtGroupId,
    viewingTenantId,
  });
  if (siblingSpace != null) {
    renderedSpace = siblingSpace;   // SUBSTITUTION
    partnerBookingInfo = {
      sold_by_tenant_id: canonicalSellingTenantId,
      sold_by_tenant_name: canonicalSpace.location!.tenant!.name,
      sold_by_location_name: canonicalSpace.location!.name,
    };
  }
}

// Pass renderedSpace into the constructor instead of booking.space.
// Two implementation paths:
//   (a) Cleaner: add an optional `renderedSpace?` parameter to SparkDashboardSpaceBookingDto.
//   (b) Pragmatic: mutate booking.space = renderedSpace before constructing
//       (acceptable; booking is a transient read-model at this point).
```

The new DataLoader `SharedCourtSiblingForTenantLoader` lives in `libs/space/src/lib/infrastructure/loaders/` and batches lookups keyed by `(sharedCourtGroupId, viewingTenantId)` → `Space | null`. Request-scoped per CLAUDE.md N+1 prevention.

### `partner_booking_info` field

Added at the booking level on `SparkDashboardSpaceBookingDto` (`admin-space-booking.dto.ts`):

```typescript
export class SparkDashboardSpaceBookingDto extends SparkDashboardBookingDto {
  space?: SparkBookingSpaceDto;
  location?: SparkUserBookingLocationDto;
  tickets: SparkAdminBookingTicketDto[];
  paymentScreenshot: NullableType<SparkMediaDto>;
  partner_booking_info: PartnerBookingInfo | null;   // <-- v3 addition

  constructor(/* ... */) {
    super(/* ... */);
    // ... existing assignments
    this.partner_booking_info = null;   // default; set by transformer via setter
  }
}

interface PartnerBookingInfo {
  sold_by_tenant_id: number;
  sold_by_tenant_name: string;
  sold_by_location_name: string;
}
```

### Calendar filter widening

`booking.transformer.ts:380-383` — `_mapLocationCalendar` bucket filter expands:

```typescript
// before
bookings: data.bookings.filter(
  (b) =>
    b.recordId === space.id &&
    b.recordType === RecordTypeEnum.SPACE_ENTITY,
),

// after
const siblingIds = await this.resolver.resolveSiblingSpaceIds(space.id);
bookings: data.bookings.filter(
  (b) =>
    siblingIds.includes(b.recordId) &&
    b.recordType === RecordTypeEnum.SPACE_ENTITY,
),
```

This is one of the calendar-side surfaces the substitution requires. After this widening + the substitution, A's calendar shows the shared court as one row (A's sibling) carrying both A-sold and B-sold bookings, with the partner badge surfacing B-sold ones.

### Security invariant (load-bearing)

The substituted `space` is **always the viewing tenant's own sibling space** — never another tenant's space. `SparkBookingSpaceDto`'s lean field set (`id, name, spaceType, spaceTypeValue, pricingType`) carries no cross-tenant data. Verified at the DTO level: substitution cannot leak B's per-sibling config to A because A only sees A's own sibling fields.

The `partner_booking_info` field exposes only `sold_by_tenant_id`, `sold_by_tenant_name`, and `sold_by_location_name` — no addresses, no contact info, no transaction data. Intentional minimum-information for the badge UX.

### Justification

1. **Zero admin-app changes.** The substitution preserves the existing DTO shape; existing UI code paths (calendar, list, filter, details modal) keep working. The only thing the UI *gains* is the optional partner badge.
2. **Canonical mutation routing preserved.** `booking.id` is the routing key for every mutate handler (verified at every `findOne(id)` call site in `bookings.service.ts`). The substituted `space.id` is purely display.
3. **CEO-aligned.** Direct response to *"changing dto would break the admin app"*.
4. **Minimal additive surface.** One nullable optional field. Backward-compat by definition.

## Consequences

- `SparkDashboardSpaceBookingDto` gains a nullable `partner_booking_info` field (the only v3 DTO addition).
- `BookingTransformer.transformBookings` (`apps/spark-tenant-admin-api/src/app/modules/bookings/controllers/admin/booking.transformer.ts:208-220`) gains the substitution branch + DataLoader injection.
- New DataLoader `SharedCourtSiblingForTenantLoader` in `libs/space/src/lib/infrastructure/loaders/` — request-scoped, batches by `(sharedCourtGroupId, viewingTenantId)`.
- Calendar bucket filter at `booking.transformer.ts:380-383` widens via the resolver from AgDR-0005.
- Mutation routing is unchanged. Every admin mutate already identifies the booking by `id`; the canonical `recordId` survives substitution.
- The web bookings controller (`apps/spark-tenant-admin-api/src/app/modules/bookings/controllers/web/web-booking.transformer.ts`) and any external-client transformer that constructs the same DTO need the same substitution applied — Step 13 in the tech design covers the admin path; verify the web path during implementation and apply if it serves cross-tenant.
- Integration test required (tech design Step 22): A's admin GET /bookings/:id on a B-sold booking returns `{id: <canonical bookingId>, space: {id: <A_sibling.id>}, partner_booking_info: {sold_by_tenant_id: B}}`. Followed by POST cancel → 200, POST refund → 200 with audit log showing PSP=B.

## Artifacts

- Technical design: `projects/booking-system/techdesign-shared-space-multi-tenant.md` (v3) § D6 + Step 12 + Step 13
- Partner AgDRs: `[[AgDR-0001-shared-space-data-model]]` (v3), `[[AgDR-0005-centralized-conflict-availability-resolver]]`, `[[AgDR-0006-reschedule-semantics-and-financial-decoupling]]` (v3)
- Code evidence (verified):
  - `libs/contracts/src/lib/spark/tenant/v1/booking/admin-booking.dto.ts:19-100` (base DTO, no top-level spaceId)
  - `libs/contracts/src/lib/spark/tenant/v1/booking/space/admin-space-booking.dto.ts:38-86` (embedded `space?: SparkBookingSpaceDto`)
  - `libs/contracts/src/lib/spark/tenant/v1/booking/booking-space.dto.ts:6-19` (lean substitutable shape)
  - `apps/spark-tenant-admin-api/src/app/modules/bookings/controllers/admin/booking.transformer.ts:208-220` (substitution site)
  - `apps/spark-tenant-admin-api/src/app/modules/bookings/controllers/admin/booking.transformer.ts:344-391` (calendar bucket filter to widen)
  - `apps/spark-tenant-admin-api/src/app/modules/bookings/services/admin/bookings.service.ts:241, 265, 332-343, 353, 368, 378, 388, 398` (mutation routing by `findOne(id)`)
- Ticket: apessolutions/booking-system#752
