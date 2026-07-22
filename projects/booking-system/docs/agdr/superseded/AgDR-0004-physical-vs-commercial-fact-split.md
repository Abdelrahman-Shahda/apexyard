---
id: AgDR-0004
timestamp: 2026-06-15T00:00:00Z
agent: tech-lead
model: claude-opus-4-7
session: techdesign-shared-space-multi-tenant-v2
trigger: user-prompt
status: superseded
category: architecture
projects: [booking-system]
superseded_by: techdesign-shared-space-multi-tenant.md#D2 (v3)
---

> **SUPERSEDED — 2026-06-15 (v3 design)**
>
> The CEO simplified the design after v2: *"each sibling can have his own availability rule that's fine — we should not read them from authority sibling, same as commercial facts"*. The physical-vs-commercial split is eliminated entirely. **All space-config fields are per-sibling.** The `shared_court_group` table is reduced to a relational anchor for cross-sibling conflict scope only — it carries no `physical_authority_space_id` and no read-through semantics.
>
> The conflict resolver (AgDR-0005) remains load-bearing and is more important now: with each sibling potentially running its own availability rules / granularity / slot grid, the cross-sibling booking conflict check is the only group-scope correctness guarantee.
>
> See the v3 technical design § D1 + D2 + `[[AgDR-0001-shared-space-data-model]]` (v3 revision history) for the live decision. This AgDR is preserved as an audit trail of the v2 attempt.
>
> # Physical vs commercial fact split on sibling spaces (SUPERSEDED)

> In the context of the v2 sibling-spaces model where two tenants each own a `space` row pointing at the same physical court, facing the need to let tenants diverge on price, mobile-on-off, photos, and cancellation policy WITHOUT letting them silently diverge on operating hours, slot duration, or capacity (which would break the conflict math), I decided to classify every field on `SpaceEntity` (and every booking-config concept touching it) as either **physical** (single-source on the `physical_authority_space_id` of the `shared_court_group`) or **commercial** (per-sibling, freely diverges) and to enforce the classification with a write-side validator in the space-update command handler, to achieve a single grid for slot/conflict math while letting each tenant run their own pricing and marketing, accepting that four fields on `SpaceEntity` are genuinely ambiguous and need a per-field call from Maha/Mariam before launch.

## Context

- The v2 sibling-spaces model (AgDR-0001 v2) gives each tenant its own first-class `space` row for the same physical court. Once there are two rows, the question "where does each field's value come from?" has to be answered explicitly — otherwise tenants can silently fork operating hours, granularity, etc., and the conflict math breaks (two slot grids = two booking timelines = no shared truth).
- The CEO's framing: physical facts about the court (where it is, when it's physically open, how long a slot can be, how many people can be on it) cannot diverge between siblings. Commercial facts about how each tenant SELLS the court (price, promo codes, cancellation policy, display name, photos, booking window) freely diverge and that divergence is the whole point of v2.
- Verified code basis — every field on `SpaceEntity` (file:line `libs/space/src/lib/infrastructure/persistence/entities/space.entity.ts:30-180`) is classified in the table below. Booking-config concepts that hang off space (notably `SpaceAvailabilityRule` at `space-availability-rule.entity.ts:30-37`) follow the same split.
- The adversarial review (`techdesign-sibling-spaces-adversarial-review.md` §3.11) flagged this as a structural break in the bare sibling-spaces proposal: if non-authority siblings can have their own availability rules row that's edited independently, the system silently runs two slot grids for one physical court. This AgDR closes that gap by making the split explicit and enforced.

## Options Considered

| Option | Pros | Cons |
|---|---|---|
| **A. Physical fields locked to `physical_authority_space_id`; commercial fields per-sibling. Enforced by write-side validator in the space-update command handler.** (v2 pick) | Single source of physical truth → slot grid + conflict math is consistent across siblings. Per-sibling commercial divergence is the v2 value prop. Validator is mechanical and grep-able. | Requires classifying every field on `SpaceEntity` and every related booking-config table; four fields are ambiguous and need product input. Adds one branch to the space-update flow. |
| B. All fields per-sibling, no enforcement (bare sibling-spaces) | Simplest. | **Catastrophic.** Adversarial §3.11 — two slot grids for one physical court. Conflict math has no shared truth. |
| C. All fields locked to physical authority; commercial divergence implemented via per-sibling override tables | Strongest physical-truth guarantee. | Reintroduces v1's "per-tenant override" plumbing complexity that v2 was supposed to remove. Defeats the value of sibling-spaces. |
| D. Read-only "shadow" non-authority sibling whose fields all forward through to the authority via a resolver | Conceptually clean. | Loses per-sibling commercial divergence (the v2 value prop) entirely — every field would resolve to the authority's value. |

## Decision

Chosen: **A — Physical fields locked, commercial per-sibling, enforced by write-side validator.**

### Classification table (every field on `SpaceEntity`)

| Field | space.entity.ts lines | Class | Notes |
|---|---|---|---|
| `name` | 31-32 | Commercial | Each tenant labels their court differently. |
| `enableBookingFromMobile` | 34-35 | Commercial | Each tenant controls their own mobile surface. |
| `enableBookingFromWebsite` | 37-38 | Commercial | Same. |
| `description` | 40-41 | Commercial | Marketing copy. |
| `spaceType` | 43-44 | Physical | The physical court type. Cannot diverge. |
| `spaceTypeValue` | 47-48 | Physical | Court dimensions, surface — physical fact. |
| `minCapacity` | 50-51 | Physical | Court physical occupancy floor. |
| `maxCapacity` | 53-54 | Physical | Court physical occupancy ceiling. |
| `granularity` | 56-57 | Physical | **Critical**: slot duration. Two siblings on two grids = conflict math breaks. |
| `minSlots` | 59-60 | **AMBIGUOUS** (tilt commercial) | "Customer must book ≥ N slots." Physical use-of-court rule, or per-tenant policy? Default: commercial. |
| `maxSlots` | 62-63 | **AMBIGUOUS** (tilt commercial) | Same. |
| `cancellationDeadline` | 65-66 | Commercial | Per-tenant cancellation policy. |
| `basePrice` | 68-69 | Commercial | **The point of v2.** |
| `categories` (ManyToMany) | 71-76 | Commercial | Tenant taxonomy. |
| `availabilityRules` (OneToMany) | 78-87 | Physical | The court's open hours. Non-authority sibling has NO rule rows; reads through to the authority via the resolver (AgDR-0005). |
| `tags` | 89-95 | Commercial | Tenant tagging. |
| `locationId` / `location` | 97-106 | Structural | The owning location of THIS sibling. Never crosses. |
| `media` (photos) | 108-112 | Commercial | Each tenant's branding. |
| `status` (active flag) | 114-115 | Commercial | A tenant may deactivate their listing while the physical court stays open via the partner. |
| `externalId` | 117-118 | Commercial | Per-tenant integration ID. |
| `pricingType` (per-granularity vs per-slot) | 120-125 | Commercial | Pricing model. |
| `order` (display order) | 127-128 | Commercial | UI sort. |
| `minMinutesBeforeBooking` | 130-134 | Commercial | Booking window. |
| `capacityPerSlot` | 136-137 | **AMBIGUOUS** (tilt physical) | Physical seats per slot, or tenant policy? Default: physical (pairs with other capacity fields). |
| `capacityUnit` | 139-140 | Physical | Pairs with capacity fields. |
| `maxBookingPerSlot` | 142-143 | **AMBIGUOUS** (tilt physical) | Court can host N parallel bookings, or tenant policy? Default: physical. |
| `parentSpaceId` / `parentSpace` / `childSpaces` | 145-159 | Structural | Padel hierarchy. **Cannot cross siblings in v1** — open question Q5 in the tech design. |
| `accessMode` | 163-168 | Commercial | Per-tenant access policy. |
| `customerGroups` (M:N) | 174-179 | Commercial | Each tenant's customer groups. |

### Write-side validator (lives in the space-update command handler)

Pseudocode:

```typescript
if (space.shared_court_group_id != null) {
  const group = await sharedCourtGroupRepo.findById(space.shared_court_group_id);
  const isAuthority = group.physical_authority_space_id === space.id;
  const touchesPhysical = PHYSICAL_FIELDS.some(f => f in updateDto);
  if (touchesPhysical && !isAuthority) {
    throw new ForbiddenException(
      `Cannot edit physical fields on a non-authority sibling. ` +
      `Physical authority is space ${group.physical_authority_space_id}.`,
    );
  }
}
```

`PHYSICAL_FIELDS` is the deduplicated set from the classification table above (with ambiguous-but-tilt-physical included).

### Commercial-field edit gate on booking-side (separate but related)

D7 of the tech design adds a parallel gate: when an admin updates a BOOKING's commercial fields (`basePrice`, etc.) and `is_partner_booking = true`, reject. This is conceptually the booking-side analog of the space-side physical-field gate. Mechanically separate handler, same principle.

### Justification

1. **Conflict math integrity.** Granularity, capacity, operating hours cannot diverge without breaking the resolver's premise that all siblings share one physical schedule.
2. **Mechanical enforcement.** Validator is one branch in one handler — auditable, grep-able. No CASL needed.
3. **Honest ambiguity.** Four fields are genuinely ambiguous; flagging them as open questions is better than silently picking a side that surprises operators later.
4. **`SpaceAvailabilityRule` resolution.** The non-authority sibling has no rule rows. Application code that reads rules routes through the resolver (AgDR-0005), which returns the authority sibling's id. No data is duplicated; no divergence is possible.

## Consequences

- Write-side validator in `apps/spark-tenant-admin-api/src/app/modules/spaces/services/admin/spaces.service.ts` (or the equivalent command handler) — rejects physical-field edits on non-authority siblings with a clear error.
- `SpaceAvailabilityRule` rows belong only to the physical-authority sibling. The application layer NEVER reads rules from a non-authority sibling. Verified by an integration test (Step 25 in the tech design) that creates a non-authority sibling and asserts its rule-read returns the authority's rules.
- Four ambiguous fields (`minSlots`, `maxSlots`, `capacityPerSlot`, `maxBookingPerSlot`) tracked as open question Q3 in the tech design; default tilt documented; needs Maha + Mariam call before launch.
- The classification table is itself a deliverable: it lives in this AgDR and is the single source of truth for "is this field physical or commercial". Future fields on `SpaceEntity` need a classification call; the AgDR is revised in place.
- AC4 from the original ticket is split: "physical config single-source on authority; commercial config per-sibling". This is one of the scope changes flagged in the tech design's "Scope changes requiring product approval" section.
- Touches the AC that says "config single-source on the space" — that phrasing dies cleanly; the split replaces it.

## Artifacts

- Technical design: `projects/booking-system/techdesign-shared-space-multi-tenant.md` (v2) § D2
- Partner AgDRs: `[[AgDR-0001-shared-space-data-model]]` (v2), `[[AgDR-0005-centralized-conflict-availability-resolver]]`, `[[AgDR-0006-reschedule-semantics-and-financial-decoupling]]`
- Code evidence:
  - `libs/space/src/lib/infrastructure/persistence/entities/space.entity.ts:30-180` (every field classified)
  - `libs/space/src/lib/infrastructure/persistence/entities/space-availability-rule.entity.ts:30-37` (single `spaceId` FK → authority owns)
- Ticket: apessolutions/booking-system#752
