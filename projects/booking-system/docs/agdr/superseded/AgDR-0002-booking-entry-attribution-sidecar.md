---
id: AgDR-0002
timestamp: 2026-06-15T00:00:00Z
agent: tech-lead
model: claude-opus-4-7
session: techdesign-shared-space-multi-tenant
trigger: user-prompt
status: superseded by AgDR-0001 (v2 sibling-space rewrite, 2026-06-15)
category: architecture
projects: [booking-system]
---

> **SUPERSEDED — 2026-06-15.** This AgDR decided on a `space_booking_entry` sidecar table to attribute "which tenant did the customer enter through" under the v1 M:N `space_location` design. The v2 sibling-space model (see `[[AgDR-0001-shared-space-data-model]]` v2 + the rewritten tech design at `projects/booking-system/techdesign-shared-space-multi-tenant.md`) makes entry attribution **implicit via the existing `booking.space → space.location → location.tenant_id` chain** — each sibling is single-tenant, so the chain produces the selling tenant for free with no sidecar table required. The `space_booking_entry` table, the `BookingEntryLocationValidator`, the `SpaceBookingEntryEntity` / mapper / repository, and the read-path LEFT JOIN are all NOT being built. This AgDR is preserved as audit trail of the decision chain; the content below describes the v1 plan only.
>
> Read AgDR-0001 (v2) for the active data model and AgDR-0004 / 0005 / 0006 for the principles that replace the sidecar approach.

# Booking entry attribution — `space_booking_entry` sidecar table (no columns on the generic `booking` table) [SUPERSEDED]

> In the context of multi-tenant shared spaces needing per-booking "which tenant did the customer enter through" attribution, facing the constraint that `booking` is a generic polymorphic table (`recordId` + `recordType` discriminating between `SPACE_ENTITY` / `EVENT_SESSION_ENTITY` / `TRIP_ENTITY`) with no per-type detail tables, I decided to put entry attribution in a sidecar table `space_booking_entry(booking_id PK, entry_location_id NOT NULL)` joined on `booking.id`, to achieve clean attribution semantics without polluting the generic table with NULLs on every trip/class booking, accepting one extra LEFT JOIN on the hot booking-list read.

## Context

- `booking` is a single generic table with polymorphic FK (`booking.entity.ts:31-38`): `recordId: number` + `recordType: RecordTypeEnum` defaulting to `SPACE_ENTITY`. The polymorphic relation IS the type discrimination.
- There are NO per-type detail tables (`space_booking_details`, `trip_booking_details`). The team is not introducing sub-table inheritance as part of this ticket.
- Today's `sourceId` / `SourceEntity` (`booking.entity.ts:65-74`, `source.entity.ts:10-23`) represents the **channel** (mobile / website / external API) and is global across tenants — cannot encode entry-tenant.
- The existing `externalBookingData` JSON column (`booking.entity.ts:82-83`) is channel-scoped (`{ phoneNumber, name }` for external-API bookings) and inconsistently populated; not a clean reuse target.
- The codebase has no generic-metadata JSONB pattern on `booking` (only `booking_recurrence` uses `jsonb`, for structured recurrence rules).
- CEO ground truth 2026-06-15: nullable `entry_location_id` on `booking`, M:N `booking_tenant` with `is_source`, and sub-table inheritance are all rejected. Attribution must live where it's needed (space bookings on shared spaces) without leaking into the generic table.

## Options Considered

| Option | Pros | Cons |
|---|---|---|
| **A. Sidecar `space_booking_entry(booking_id PK FK, entry_location_id FK)`** | Zero impact on the generic `booking` table — no nullable noise on trip/class bookings. Row exists only when needed (space booking on shared space, non-home entry). PK on `booking_id` ⇒ semi-join cost on LEFT JOIN. Explicit FK to `location` keeps query semantics simple. Encapsulatable behind a domain accessor (`booking.entryLocation`). | One new table + one LEFT JOIN on the hot booking-list read. |
| B. Derive from existing data (`sourceId`, request context already on `booking`) | "No new schema." | Nothing on `booking` carries entry-tenant today. `sourceId` is channel-global; `externalBookingData` is channel-scoped JSON. No clean reuse exists. |
| C. JSONB / metadata column on `booking` | One column / overload of existing `externalBookingData`. | (i) No generic-metadata pattern exists; adding one to carry a single typed FK is over-engineering. (ii) JSONB FKs aren't enforced by the DB — lose `ON DELETE` semantics. (iii) Opaque queryability: `(metadata->>'entry_location_id')::int` is hard to index and conflicts with the project's strict-TypeScript / `EntityHelper`-driven entity discipline. (iv) Overloads `externalBookingData`'s existing semantic. |
| D. Nullable `entry_location_id` column on `booking` | One column; simple read path. | **Rejected by CEO**: pollutes the generic table with a space-booking-specific column that is forever NULL on every trip / class booking. Polymorphic table cleanliness is load-bearing. |
| E. Sub-table inheritance (`space_booking_details(booking_id PK, entry_location_id)`) | Type-specific data lives with type-specific table. | **Rejected**: no per-type detail tables exist today; the team is not adopting this pattern as part of this ticket. |
| F. `booking_tenant` M:N with `is_source` boolean | Models the multi-tenant relationship explicitly. | **Rejected by CEO**: redundant with `space_location` for visibility purposes (Decision 3 already gets the visibility right via the join table); adds row-write overhead on every trip/class booking for a concept that is space-booking-specific. |

## Decision

Chosen: **Option A — `space_booking_entry` sidecar table.**

```sql
CREATE TABLE space_booking_entry (
  booking_id        INTEGER PRIMARY KEY,
  entry_location_id INTEGER NOT NULL,
  created_at        TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT FK_SBE_BOOKING  FOREIGN KEY (booking_id)        REFERENCES booking(id)  ON DELETE CASCADE,
  CONSTRAINT FK_SBE_LOCATION FOREIGN KEY (entry_location_id) REFERENCES location(id) ON DELETE CASCADE
);
CREATE INDEX IDX_space_booking_entry_location ON space_booking_entry(entry_location_id);
```

Justification:

1. **Polymorphic-table cleanliness.** The generic `booking` table stays free of type-specific columns; trip/class bookings remain byte-identical to today.
2. **Pay-for-what-you-use cardinality.** A row exists ONLY for space bookings on shared spaces with a non-home entry. Same-tenant entries (home location) do not get a row — sidecar absence = "entry equals home", resolved via `COALESCE(sbe.entry_location.tenant_id, space.location.tenant_id)`.
3. **Read cost is bounded.** PK-on-FK LEFT JOIN on the hot booking-list path. The optimiser short-circuits when `recordType != SPACE_ENTITY`. No row multiplication (1:1 max with `booking.id`).
4. **Write-path simplicity.** Single conditional INSERT in the booking-creation strategy after the booking INSERT, in the same `@Transactional` boundary. No write change for non-shared spaces (zero rows written).
5. **Encapsulatable.** Application code reads `booking.entryLocation` via a domain accessor that delegates to the sidecar (falling back to `space.location` when absent). No application code touches `space_booking_entry` directly.

## Consequences

- New table `space_booking_entry(booking_id, entry_location_id, created_at)`; PK `(booking_id)`; FKs both `ON DELETE CASCADE`; index on `entry_location_id`.
- `booking.entity.ts` is **unchanged** — no `ALTER TABLE booking`.
- New entity `SpaceBookingEntryEntity`, mapper `SpaceBookingEntryMapper`, port + repository following the standard layered pattern in CLAUDE.md.
- `BookingEntity` gets a read-only `@OneToOne(() => SpaceBookingEntryEntity)` named `spaceEntry` (`persistence: false`, eager: false) — joined on demand by `BookingQueryBuilder`.
- `BookingMapper.toDomain` hydrates `Booking.entryLocation` from `spaceEntry.entryLocation`; fallback to `space.location` when sidecar absent.
- New `BookingEntryLocationValidator` enforces application invariants: entry must be in `space_location` for the booking's space; home entry skips the insert.
- Read-path query builders (wallet pass, customer-facing booking detail) read `booking.spaceEntry?.entryLocation ?? space.location` for entry attribution.
- Cost: one LEFT JOIN added to `BookingQueryBuilder` constructor. No change to existing `tenantId` filter shape — Decision 3's visibility predicate keys off `space_location`, not `space_booking_entry`.
- Open question: cross-tenant cancellation refund path (tech-design Q4) — does the customer's money come back from tenant A's PSP merchant account when tenant B's admin initiates the cancellation? Partner to AgDR-0001's same open question.

## Artifacts

- Technical design: `projects/booking-system/techdesign-shared-space-multi-tenant.md` § Decision 2
- Partner data-model decision: `projects/booking-system/docs/agdr/AgDR-0001-shared-space-data-model.md`
- Ticket: apessolutions/booking-system#752
- Pattern reference for sidecar table shape: `libs/space/src/lib/infrastructure/persistence/migrations/1779000400000-CreateSpaceCustomerGroupTable.ts` (composite-PK, FK + index, no soft-delete, no `id`)
- Migration AgDR: TBD — to be created via `/migration` before any DDL edit (workflow gate 3a)
