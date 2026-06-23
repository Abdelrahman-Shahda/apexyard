---
id: AgDR-0001
timestamp: 2026-06-15T00:00:00Z
agent: tech-lead
model: claude-opus-4-7
session: techdesign-shared-space-multi-tenant-v2
trigger: user-prompt
status: executed
category: architecture
projects: [booking-system]
---

# Shared-court data model — sibling spaces linked by `shared_court_group`

> In the context of two Spark tenants physically sharing one padbol court, facing the v1 M:N design's developer-experience cost (sidecar table + 5-DTO contract bump) and the v2 attempt's classification-overhead from a physical/commercial fact split, I decided to give each tenant its own first-class `space` row in its own `location` and link the siblings via a new `shared_court_group` row that acts as a **relational anchor for conflict scope only** (no `physical_authority_space_id`, no read-through, no per-field classification), to achieve selling-tenant attribution that falls out of the existing `booking.space → space.location → location.tenant_id` chain for free with every space-config field per-sibling, accepting that all conflict / availability / cart-conflict paths that key on `space.id` are wrong by construction and must be widened via a centralized resolver (see AgDR-0005).

## Revision history

- **2026-06-15 v3** — Simplification. CEO killed the v2 physical/commercial split (*"each sibling can have his own availability rule that's fine"*). Removed `physical_authority_space_id` from `shared_court_group`. Removed all "authority sibling" semantics — there is no read-through for availability rules; each sibling reads its own. The `shared_court_group` table is reduced to `{ id, name, created_at, updated_at, deleted_at }` — a relational anchor that groups siblings for cross-sibling conflict scope and nothing else. AgDR-0004 (physical/commercial split) marked SUPERSEDED. Verified that reusing `parent_space_id` was ruled out by code-confirmed semantic conflict: `parent_space_id` already drives hierarchical capacity inheritance (`libs/space/src/lib/utils/space-capacity.utils.ts:13-115`) and powers "children of X" filter queries (`space-query.utils.ts:114-116`); reusing it for sibling-grouping would either contradict the per-sibling config principle or corrupt court-count queries on parent spaces. Separate `shared_court_group` table preserves both semantics and gives future commission-contract / group-admin features a stable anchor.
- **2026-06-15 v2** — Rewritten to the sibling-spaces model. Replaced the v1 M:N `space_location` decision wholesale. Introduced `physical_authority_space_id` on `shared_court_group` + physical/commercial fact classification. SUPERSEDED by v3 simplification.
- 2026-06-15 v1 (SUPERSEDED) — M:N `space_location` join with `space.location_id` kept as home FK. See git history.

## Context

- The v1 M:N design (`space_location` + `space.location_id` as home + `space_booking_entry` sidecar) was correct on the safety-critical axes (conflict + availability worked unchanged because there was still ONE `space.id` per physical court) but expensive on developer experience: a sidecar table plus a 5-DTO contract bump (mobile + web + external-client + admin + admin-on-behalf) plus a `CartEntryLocationValidator` plus entry-location plumbing through wallet-pass visitors and notification handlers.
- An adversarial review (`techdesign-sibling-spaces-adversarial-review.md`) pressure-tested the sibling-spaces alternative. Verdict: sibling-spaces gives cleaner selling-tenant attribution + cart-tenant derivation + wallet pass branding **for free**, but reintroduces the cross-sibling double-book risk that the M:N existed to prevent (because two siblings = two `space.id`s). The review enumerated three structural breaks (conflict validator, cart conflict, reschedule) and three quiet semantic regressions (max-spaces, promo eligibility, statistics) that the sibling-spaces design has to address.
- The CEO accepted the trade-off: more invasive surgery in the query layer (a centralized conflict/availability resolver — AgDR-0005) in exchange for a cleaner conceptual model and the elimination of v1's sidecar + 5-DTO bump.
- Verified code basis for the rewrite:
  - `libs/space/src/lib/infrastructure/persistence/entities/space.entity.ts:30-180` — every field on `SpaceEntity` (classified physical vs commercial in AgDR-0004).
  - `libs/booking/src/lib/application/strategies/booking/base-booking.strategy.ts:36` — write path already pulls `tenantId = space.location!.tenantId`. Under sibling-spaces this **automatically** produces the selling tenant.
  - `libs/cart/src/lib/application/strategies/add-cart-item/add-slot-item.strategy.ts:52` — cart tenant derivation `spaces[0].location!.tenantId`. Under sibling-spaces this is also automatically correct.
  - `libs/booking/src/lib/application/validators/booking-conflict.validator.ts:16-24` — keys on `data.spaceId`. **This is the disqualifier** under sibling-spaces and is addressed by AgDR-0005.
  - `libs/space/src/lib/infrastructure/persistence/entities/space-availability-rule.entity.ts:30-37` — `SpaceAvailabilityRule.spaceId` is a single FK; the physical-authority sibling owns the rule rows under v2.

## Options Considered

| Option | Pros | Cons |
|---|---|---|
| **A. Sibling spaces + `shared_court_group` (v3 pick — conflict-scope anchor only)** | Selling-tenant attribution falls out of `booking.space → space.location → location.tenant_id` chain for free — **no sidecar table, no DTO contract bump, no per-field classification**. Cart-tenant derivation correct by construction. Wallet pass branding correct by construction. Each sibling owns its own config (price, availability, granularity) — maximum operator flexibility. Operator mental model "each tenant has their own court row" is cleanest. | Two `space.id`s per physical court → every conflict / cart-conflict path that keys on `space.id` is now structurally wrong and must be routed through a centralized resolver (AgDR-0005). This is invasive — the design's #1 risk. Per-sibling availability divergence may surprise customers (A's app shows 13:00 free, B's app shows 13:00 booked by A) — explicitly accepted by CEO. |
| B. Reuse `parent_space_id` for sibling grouping | No new table | Verified semantic conflict: `parent_space_id` already drives capacity inheritance (`space-capacity.utils.ts:13-115`) and powers "children of X" queries (`space-query.utils.ts:114-116`). Reusing it would either force capacity inheritance between siblings (contradicting v3's all-per-sibling principle) or break the existing parent-child hierarchy. Corrupts court-count integrity. |
| C. M:N `space_location` join (v1 — SUPERSEDED) | Conflict unchanged | Sidecar table + 5-DTO contract bump. Heavy. |
| D. Sibling spaces + physical/commercial fact split (v2 — SUPERSEDED) | Single slot grid by construction | Four genuinely-ambiguous fields. New "authority sibling" concept to maintain. CEO rejected. |
| E. Per-tenant denormalised projection fed by events | Reads fast | Eventual consistency — UNACCEPTABLE per AC. |

## Decision

Chosen: **A — sibling spaces + `shared_court_group` (conflict-scope anchor only).**

```sql
CREATE TABLE shared_court_group (
  id           SERIAL PRIMARY KEY,
  name         VARCHAR(120) NULL,           -- optional admin label
  created_at   TIMESTAMPTZ DEFAULT now(),
  updated_at   TIMESTAMPTZ DEFAULT now(),
  deleted_at   TIMESTAMPTZ NULL
);

ALTER TABLE space
  ADD COLUMN shared_court_group_id INT NULL
    REFERENCES shared_court_group(id) ON DELETE RESTRICT;

CREATE INDEX IDX_space_shared_court_group_id
  ON space(shared_court_group_id)
  WHERE shared_court_group_id IS NOT NULL;   -- partial: sparse population
```

**No `physical_authority_space_id` column.** The group is a relational anchor for conflict scope, nothing more.

Application-layer invariants:
- A space can belong to at most one active group at a time (`space.shared_court_group_id` single FK).
- Cannot soft-delete a group while it has active siblings — must remove siblings via D9's super-admin endpoint first.

Justification:

1. **Selling-tenant attribution is free.** `base-booking.strategy.ts:36` already does `tenantId = space.location!.tenantId`. Under sibling-spaces each sibling is single-tenant, so the chain produces selling tenant with **zero write-path change**. No sidecar table. No new column. This eliminates the v1 design's `space_booking_entry` table + `BookingEntryLocationValidator` + 5-DTO contract bump in one stroke.
2. **Cart-tenant attribution is free.** `add-slot-item.strategy.ts:52` does `spaces[0].location!.tenantId`. Same logic — each sibling is single-tenant so this is automatically correct.
3. **Wallet pass branding is free.** The wallet pass visitors stamp the pass with `space.location` → the selling sibling's location → the selling tenant's branding. Win versus v1, which had to plumb entry-location through the wallet visitors.
4. **Operator mental model is cleaner.** Each tenant has their own row to edit; UI surfaces are "your space" not "the shared space with overrides". Aligns with how Spark already treats locations.
5. **Pattern reuse.** `shared_court_group` follows the same shape as other domain-grouping tables (composite parent + per-row reference back to the group via FK on `space`).

Trade-off accepted: AgDR-0005 (centralized conflict/availability resolver) is the load-bearing implementation work that makes this safe. Every conflict / availability / cart-conflict / max-spaces / statistics path that today keys on `space.id` must be widened to key on `shared_court_group_id` via the resolver. The CEO accepted this trade explicitly — the v2 model accepts more surgery in the query layer to remove the sidecar table + DTO plumbing from v1.

## Consequences

- New table `shared_court_group(id, name, created_at, updated_at, deleted_at)`.
- New nullable FK column `space.shared_court_group_id` + partial index.
- `booking` table is **unchanged** — no new columns, no sidecar table. Selling tenant derived through the 3-hop chain. The "no nullable columns on the polymorphic table" principle preserved.
- `cart` table is **unchanged**.
- All conflict + cart-conflict + slot-listing paths route through the new `SharedCourtSpaceResolver` — see `[[AgDR-0005-centralized-conflict-availability-resolver]]`. This is the design's #1 risk; AgDR-0005 carries the enumerated call sites.
- **Every space-config field is per-sibling** — no authority concept anywhere; no read-through; each sibling owns its own `SpaceAvailabilityRule` rows. AgDR-0004 (the v2 physical/commercial split) is SUPERSEDED.
- Cross-tenant visibility renders via embedded-space DTO substitution at the transformer layer (`booking.transformer.ts:208-220`) — admin app sees partner bookings under its own sibling space row with zero client-side changes. One additive `partner_booking_info` field powers the partner badge. See `[[AgDR-0007-dto-substitution-at-space-level]]`.
- Uniform mutate authz on any sibling — cancel, reschedule, edit price, refund initiation. Refund **execution** still routes via the original selling tenant's PSP (`transaction.tenantId` strict-equality preserved). See `[[AgDR-0006-reschedule-semantics-and-financial-decoupling]]` (v3 update).
- Symmetric notification fan-out across all sibling admins on every booking event — no tiering.
- **Sharing is DB-configured for v1** (CEO Q3 — 2026-06-15). No super-admin endpoints in this release; runbook script writes `shared_court_group` rows + sets `space.shared_court_group_id` directly. Promoted to an admin API when partnership volume justifies the surface.
- **No quota enforcement for siblings in v1** (CEO Q3). Sharing is rare and operator-configured; `MaxSpacesPolicy` is left untouched.
- **Statistics: separate dedicated view** (CEO Q1) — existing per-tenant stats stay unchanged; a new "Shared Court Bookings" surface aggregates partner-shared bookings. No widening of the existing stats query.
- **Sibling-departure is out of scope for v1** (CEO Q4). Operating assumption: tenants only join a share when opening a fresh sibling at a partner's location (no historical booking state to migrate). FK on `space.shared_court_group_id` declared `ON DELETE RESTRICT` so accidental group deletion fails loudly.
- Backwards-compatible: non-shared spaces have `shared_court_group_id = NULL`; resolver returns `[spaceId]`; zero behavior change.

## Artifacts

- Technical design: `projects/booking-system/techdesign-shared-space-multi-tenant.md` (v3)
- Adversarial review (preserved as forensic record of v1→v2 transition): `projects/booking-system/archive/techdesign-sibling-spaces-adversarial-review.md`
- Partner AgDRs: `[[AgDR-0005-centralized-conflict-availability-resolver]]`, `[[AgDR-0006-reschedule-semantics-and-financial-decoupling]]` (v3 update), `[[AgDR-0007-dto-substitution-at-space-level]]`
- Superseded AgDRs (preserved in `superseded/`): `[[AgDR-0002-booking-entry-attribution-sidecar]]`, `[[AgDR-0003-customer-entry-context-contract]]`, `[[AgDR-0004-physical-vs-commercial-fact-split]]`
- Ticket: apessolutions/booking-system#752
- Pattern reference: `libs/space/src/lib/infrastructure/persistence/migrations/1779000400000-CreateSpaceCustomerGroupTable.ts`
- Migration AgDR: TBD via `/migration` before any DDL edit (workflow gate 3a)
