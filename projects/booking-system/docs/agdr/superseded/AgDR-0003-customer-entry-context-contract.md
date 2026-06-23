---
id: AgDR-0003
timestamp: 2026-06-15T00:00:00Z
agent: tech-lead
model: claude-opus-4-7
session: techdesign-shared-space-multi-tenant
trigger: user-prompt
status: superseded by AgDR-0001 (v2 sibling-space rewrite, 2026-06-15)
category: architecture
projects: [booking-system]
---

> **SUPERSEDED — 2026-06-15.** This AgDR decided on a multi-DTO contract bump (`entryLocationId?: number` added to all five cart-add DTOs across Mobile / Web / External-client) plus a `CartEntryLocationValidator` to attribute cart tenant under the v1 M:N `space_location` design. The v2 sibling-space model (`[[AgDR-0001-shared-space-data-model]]` v2) makes this contract **unnecessary**: each sibling is single-tenant, so the existing `cart.tenantId = spaces[0].location!.tenantId` derivation (at `libs/cart/src/lib/application/strategies/add-cart-item/add-slot-item.strategy.ts:52` and the four sibling strategies) is automatically correct without a client-supplied entry hint. The slot ID itself is space-keyed, and each space belongs to one tenant under v2 — so the cart tenant is derivable from the slot alone. No DTO bump. No multi-team coordination. No back-compat window. This AgDR is preserved as audit trail of the decision chain; the content below describes the v1 plan only.
>
> The cross-tenant cart-double-book concern that motivated part of this AgDR (carts in two different tenants holding the same physical slot via two different siblings) is still a real problem under v2 — but it's addressed by widening the cart conflict validator via the centralized resolver (`[[AgDR-0005-centralized-conflict-availability-resolver]]`), not by a DTO contract.
>
> Read AgDR-0001 (v2) for the active data model and AgDR-0005 for the cart-conflict fix that replaces this AgDR's V2-rollout step.

# Customer entry context contract — `entryLocationId` on cart-add DTOs (not `ContextProvider.getCurrentTenant()`) [SUPERSEDED]

> In the context of multi-tenant shared spaces needing per-cart entry-tenant attribution on the customer-facing booking path, facing the verified constraint that `UserAuthGuard` does NOT set `ContextProvider.setCurrentTenant` and the mobile API has no tenant-subdomain context (customer JWTs are cross-tenant by design), I decided to extend the cart-add request DTOs with an optional `entryLocationId: number` field (server-validated against the space's `home ∪ space_location` set), to achieve deterministic cart tenant derivation that survives the cross-tenant customer auth model, accepting a contract bump across Mobile + Web + External-client teams and a back-compat fallback window for old mobile binaries.

## Context

- The CEO flagged that the current cart-add code derives tenant from the entity (`spaces[0].location!.tenantId` at `libs/cart/src/lib/application/strategies/add-cart-item/add-slot-item.strategy.ts:52`, replicated at four sibling strategies). For shared spaces this routes every cart to the home tenant regardless of where the customer is shopping — defeating Decision 2's entry attribution at the source.
- A prior suggestion to swap with `ContextProvider.getCurrentTenant()!.id` would not work for customer flows. Verified:
  - `libs/authentication/src/lib/guards/user.guard.ts:34-90` populates `ContextProvider.setAuthUser(user)` at line 77 and never calls `setCurrentTenant`.
  - `setCurrentTenant` is called in exactly three places (`grep -rn setCurrentTenant`): `libs/tenants/src/lib/middleware/tenant.middleware.ts:23` (admin-impersonates-customer-mobile path only), `tenant.middleware.ts:49` (admin web — derived from Origin subdomain), and the API-key middlewares (`apps/spark-tenant-admin-api/src/app/modules/external-bookings/middlewares/api-key.middleware.ts:30`, `apps/spark-external-client-api/src/app/middlewares/api-key.middleware.ts:32`).
  - The mobile API has one host (no per-tenant subdomain); a normal customer request has NO tenant context.
- The cart-add request DTO currently carries `slotIds` only (`libs/contracts/src/lib/spark/mobile/v1/cart/mobile-add-to-cart.dto.ts:3-7`).
- Precedent: the cart-READ DTO already carries `locationId?: number` (`mobile-cart-query.dto.ts:8`) and `CartsService.findOne()` resolves tenant from `location.tenantId` (`apps/spark-mobile-api/src/app/modules/carts/carts.service.ts:89-103`). The pattern of "client tells the backend its entry location" exists on the read path; we propagate it to the write path.
- The remove-slot DTO also carries `locationId` (`mobile-remove-slot-from-cart.dto.ts:8`) — same precedent.

## Options Considered

| Option | Pros | Cons |
|---|---|---|
| **A. Add `entryLocationId?: number` to all five cart-add DTOs; server-validate against `home ∪ space_location` for each space; derive `cart.tenantId = entryLocation.tenantId` (fallback to today's home for absent value)** | Reuses an existing pattern in the same module (`SparkMobileCartQueryDto.locationId`). Server-side validation prevents client lying. Composes with Decision 2's sidecar (`entry_location_id` flows DTO → cart → checkout → `space_booking_entry`). Back-compat trivial: absent field = today's behaviour = home-tenant attribution = safe degraded mode for shared spaces. | Five DTOs touched (Mobile + Web + External-client contracts). Multi-team coordination cost. Mobile field rollout requires a force-upgrade decision (Q9). |
| B. `x-entry-tenant-id` / `x-entry-location-id` HTTP header | Lighter contract churn (no DTO field). | Easier to forget on the frontend (no compiler check); harder to discover in Swagger; same multi-team coordination; abandons the cleaner cart-read DTO precedent. Worse, not better. |
| C. Derive from auth principal (`ContextProvider.getCurrentTenant()`) | Trivial backend change. | **Verified non-viable**: customer auth is cross-tenant; `UserAuthGuard` doesn't set tenant; mobile API has no subdomain. The previous suggestion implicitly assumed a tenant-scoped customer model that doesn't exist in this codebase. |
| D. Per-tenant white-labeled mobile app builds, tenant baked into the binary, sent as a build-time header | If Spark already shipped per-tenant builds, the tenant would be on the client. | Verified false (one mobile API host, one customer-mobile binary, cross-tenant browsing in the customer flow). Per-tenant builds would be a multi-quarter rebrand and out of scope. |

## Decision

Chosen: **Option A — `entryLocationId?: number` on the cart-add DTOs.**

Contract shape (one example; pattern applies to all five add-cart DTOs and their web / external-client siblings):

```typescript
// libs/contracts/src/lib/spark/mobile/v1/cart/mobile-add-to-cart.dto.ts
export class SparkMobileAddToCartDto {
  @IsArray()
  @ArrayMinSize(1)
  slotIds!: [string];

  @IsOptional()
  @IsInt({ message: 'entryLocationId must be an integer' })
  @IsPositive({ message: 'entryLocationId must be positive' })
  entryLocationId?: number;
}
```

Application-layer derivation (replaces the home-tenant default at `add-slot-item.strategy.ts:52`):

```typescript
const entryLocation = isDefined(data.entryLocationId)
  ? await this.locationRepository.findOneOrFail({ filters: { id: data.entryLocationId } })
  : null;

if (isDefined(entryLocation)) {
  await new CartEntryLocationValidator(spaces, entryLocation, this.spaceLocationRepository).run();
}

const tenantId = entryLocation?.tenantId ?? spaces[0].location!.tenantId;
const cart = await this.cartRepository.findOrCreate({ tenantId, userId: data.userId });
```

`CartEntryLocationValidator` rejects an `entryLocationId` that isn't `space.locationId` (home) OR a `space_location.location_id` row for that space, for EVERY space in the cart-add batch.

Rollout: v1 ships the field as `optional` (back-compat fallback to today's home-tenant default — same shape as before for non-shared spaces, degraded-but-safe for shared spaces under old clients). v2 (post-mobile-rollout window) makes the field required after the force-upgrade gate decision (Q9).

Justification:

1. **Customer auth is cross-tenant in this codebase** — verified at `user.guard.ts:77` and the three `setCurrentTenant` call sites. There is no server-side tenant signal we can use for customer requests; the client is the only actor that knows.
2. **The pattern already exists** on the cart-read path (`SparkMobileCartQueryDto.locationId`) and on remove-slot. Propagating it to cart-add is the lowest-novelty answer for the codebase's idioms.
3. **Server-side validation prevents lying** by tying the entry location to the space's published share set.
4. **Composes with Decision 2** (`space_booking_entry` sidecar) — the entry location flows DTO → cart → checkout → sidecar row without a second resolution step.
5. **Back-compat** is a graceful degradation: old clients get home-tenant attribution (safe; just imprecise). Quantifiable and observable via mobile telemetry.

## Consequences

- Five cart-add DTOs gain an optional `entryLocationId?: number` field (mobile v1 + v2, web, external-client, admin-on-behalf-of-customer). Contracts module bumps across teams.
- New `CartEntryLocationValidator` enforces the validation invariant; reuses `SpaceLocationRepository` (introduced in AgDR-0001).
- `CartRepository.findMany` gains a `tenantIds: number[]` filter (used by the conflict validator rework — Decision 2a Step 15) alongside today's `tenantId` filter.
- Cart key implicitly becomes `(userId, entryTenantId)` — no schema change to `cart`; the `findOrCreate` lookup just resolves differently.
- Multi-cart edge case (customer holds carts on Tenant A AND Tenant B): two carts by construction. Tech-design Q7 confirms with product.
- Old mobile binaries continue to work in degraded mode: shared-space booking attributes to home tenant. Acceptable for the rollout window; force-upgrade gate is product call (tech-design Q9).
- Multi-team coordination required: Mobile (iOS + Android), Web (customer-facing), External-client, Backend. The contracts package change makes the bump compile-time visible on Web; mobile teams pick up the field via the contracts SDK update.
- Admin-on-behalf-of-customer flow continues to work: `tenant.middleware.ts:16-25` populates `ContextProvider.getCurrentTenant()` for the admin-impersonating-customer path, and the admin's frontend can default `entryLocationId` from the admin's current location selector.

## Artifacts

- Technical design: `projects/booking-system/techdesign-shared-space-multi-tenant.md` § Decision 2a
- Partner decisions: AgDR-0001 (`space_location` data model), AgDR-0002 (`space_booking_entry` sidecar)
- Code evidence:
  - `libs/cart/src/lib/application/strategies/add-cart-item/add-slot-item.strategy.ts:52` (the line being replaced)
  - `libs/cart/src/lib/application/strategies/add-cart-item/{add-experience-item,add-addon-item,add-trip-item,add-session-item}.strategy.ts` (four siblings)
  - `libs/cart/src/lib/validators/cart-conflict.validator.ts:29-31` (the conflict-scope sibling problem)
  - `libs/authentication/src/lib/guards/user.guard.ts:34-90` (customer auth does not set tenant)
  - `libs/tenants/src/lib/middleware/tenant.middleware.ts:16-50` (the three tenant-resolution paths)
  - `libs/contracts/src/lib/spark/mobile/v1/cart/mobile-add-to-cart.dto.ts:3-7` (current DTO shape)
  - `libs/contracts/src/lib/spark/mobile/v1/cart/mobile-cart-query.dto.ts:8` (the read-side precedent)
  - `apps/spark-mobile-api/src/app/modules/carts/carts.service.ts:89-103` (`findOne` shows the read-path tenant derivation pattern)
- Ticket: apessolutions/booking-system#752
