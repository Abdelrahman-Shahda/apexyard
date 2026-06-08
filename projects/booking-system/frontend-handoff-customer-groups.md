# Customer Groups — Mobile + Customer-Web Frontend Handoff

> **Audience**: Spark mobile + customer-web client engineering teams.
> **Status**: Backend is fully shipped on `feature/#707-integration-customer-groups` and ready to be released to `development`. This doc tells you what the clients must do (and verify) before the Phase-1 pilot launches on **2026-07-19**.
> **Scope**: Coordination tickets `#731` (US-5 Frontend) and `#732` (US-6 Frontend) — *both have zero code in `spark-tenant-admin-web`* because the surfaces live in your repos.
> **Background**: PRD at `projects/booking-system/prd-customer-groups.md` · Tech design at `projects/booking-system/techdesign-customer-groups.md` · AgDR-0011 (layer-2 filter-in-find) and AgDR-0012 (handler-chain saga).

---

## Quick context

Spark tenants can now mark a space as **restricted**, attaching one or more customer groups. Restricted spaces are invisible — and unbookable — for non-members. Backend has shipped:

- Layer 1 — every listing query the clients call already injects `visibleToUserId` and returns only the visible subset (PR #721).
- Layer 1 facets — five dataloaders + two transformer counts that aggregate space-derived data also filter by visibility (PR #724).
- Layer 2 — every action endpoint that resolves a `spaceId` from user input re-runs the same predicate (PR #722, refactor in #723). On miss it raises HTTP **403** with body `{ "code": "SPACE_NOT_AVAILABLE" }`.
- Soft-delete + auto-revert — when a tenant admin deletes the last customer group attached to a restricted space, the space is automatically flipped back to public and the admin is emailed (PR #726).

The clients' job is to **render this correctly** end-to-end. Nothing here is optional for the pilot launch.

---

## Ticket #731 — US-5 Frontend (verification ticket)

> *"Every listing surface the end-user can see filters restricted spaces correctly."*

This is **verification, not implementation**. The backend already filters. Your job is to confirm the clients consume the filtered data correctly and don't undo the filter with stale state.

### Surfaces to verify on mobile + customer web

| Endpoint | What it returns | Verify |
|---|---|---|
| `GET /v1/locations/:id/spaces` | Spaces in a location | Response already excludes restricted spaces the caller can't see. Client just renders what arrives. **No client-side filter needed**; client must not re-filter (or it'll double-hide). |
| `GET /v1/locations/:id/slots` | Per-space slots + pricing | Slots are pre-filtered to the visible space set. Same — render as-is. |
| `GET /v1/locations` / `:id` | Location summary / detail | If the response carries an embedded `spaceCount`, `spaceTypes`, `availableSports`, `categoryIds`, or `classCount` — these are now computed against the **visible** subset (PR #724). Render them; they already exclude restricted-only data. |
| `GET /v1/tenants` / `:id` | Tenant summary / detail | Same — `hasExperiences` flag now reflects only visible experience-spaces. |
| `GET /v1/core/categories` | Category tree + per-category `spaceCount` | The tree itself is still global (covers events / trips too), but each category's `numberOfSpaces` reflects only the caller's visible spaces (per AgDR-0011 amendment). A category with count 0 should probably hide on the client. Confirm UI behaviour. |

### Verification checklist (per client team)

```
[ ] On a fresh logged-in session as a *non-member*, GET /v1/locations/<id-with-restricted-space>/spaces returns ONLY public spaces. The response does NOT include the restricted spaceId, even though the location has it.
[ ] Same call as a *member* of the attached customer group returns BOTH the public space AND the restricted one. No client-side magic needed.
[ ] No client cache (Redux / Zustand / RTK Query / SWR / Apollo) retains restricted space ids from a session where the user previously had access. Clear cache on auth-state change.
[ ] Embedded counts (spaceCount, classCount) match what the user can actually see. A non-member sees "1 space available" on a location with 1 public + 1 restricted court — NOT "2".
[ ] The /core/categories list either: (a) hides zero-count categories on the client, or (b) renders them dimmed so tapping them shows an honest empty result.
[ ] Deep-link landing on a restricted space (https://app/.../spaces/<id>) — see #732 below for the 403 contract; the client must NOT crash or show generic error.
```

### Out of scope for #731

- The tenant-admin app (`spark-tenant-admin-web`) — admins are intentionally **unfiltered**. They see every space regardless of access mode. If a tenant admin reports "I can see this restricted space but my user can't", that's *correct* behaviour, not a bug.
- The white-label / partner API (`spark-external-client-api`). Treated as a separate client; same predicate applies. Pen-test (Hakim) explicitly covers this surface — see AgDR-0008.

---

## Ticket #732 — US-6 Frontend (empty-state contract)

> *"When the server rejects a non-member's action on a restricted space, the client renders the right UX."*

This is the **single most user-visible piece** of the customer-groups rollout. Getting it wrong looks like a broken app.

### The wire contract

Every action endpoint listed below now raises HTTP **403** when the caller can't act on the resolved space:

```http
HTTP/1.1 403 Forbidden
Content-Type: application/json

{
  "statusCode": 403,
  "message": "Forbidden",
  "code": "SPACE_NOT_AVAILABLE"
}
```

The `code` field is the discriminator. **Match on `code === 'SPACE_NOT_AVAILABLE'`**, not on the status code alone — other 403s exist in the system and have different semantics.

### Endpoints that raise this error

| Method + path | When the 403 fires | Where the user is when it fires |
|---|---|---|
| `POST /v1/carts` (slot-add) | User adds a slot whose spaceId is restricted | On a space details page or shared link |
| `POST /v1/carts/sessions` | User adds an event session attached to a restricted space | On a session details page |
| `POST /v1/locations/slots/pricing` | Pricing request includes a restricted spaceId | Slot pricing recalculation |
| `POST /v1/carts/:id/checkout` | A cart line resolves to a restricted space the user can no longer access (rare — membership change between add + checkout) | Cart checkout |
| `GET /v1/experiences/:id` | User tries to view a restricted experience-space detail | Shared deeplink, search result, history |
| `GET /v1/experiences/:id/slots` | Same as above, via the slots tab | Experience detail |
| `POST /v1/experiences/:id/slots/pricing` | Pricing on a restricted experience | Experience booking flow |

### Client UX contract — what to render

#### ✅ DO: clean empty state

A dedicated "this isn't available to you" screen / inline panel that explains the situation honestly. The user isn't on a broken link; they just don't have access. The screen should:

- Use the same chrome as other empty states in the app (the empty-state component already exists in both clients).
- Say something like: **"This space isn't available for you to book. Membership is managed by the venue — reach out to the venue if you think this is wrong."**
- Offer a CTA back to the previous screen ("← Back to Padel Club" or similar).
- NOT mention "restricted" / "customer group" / "tenant" — those are internal concepts.

#### ❌ DON'T: generic error toast

```
✗ "Something went wrong. Try again." (toast)
```

The user CAN'T fix this by trying again. A toast wastes their time and erodes trust.

#### ❌ DON'T: 404 / not-found redirect

```
✗ "This page doesn't exist." (404 screen)
```

The space DOES exist — the user's friend just shared it. A 404 sends the user to support thinking the link is broken. It's a known shared-link path; the tech-design called out 403-not-404 specifically for this reason.

#### ❌ DON'T: silent retry loop

```
✗ Retry the 403 → fail → retry → fail (loop)
```

This is the most common bug we'll see if you're not careful. The 403 is intentional — no retry will succeed.

### Suggested rendering shape per surface

| Surface | UI element |
|---|---|
| Shared-link landing on `/experiences/:id` | Full-page empty state with "← Back" CTA. |
| `POST /v1/carts` (add-to-cart) | Inline panel under the slot picker; the slot itself shouldn't be tappable but if the client raced, the panel explains. |
| `POST /v1/locations/slots/pricing` | Empty state on the pricing pane; the slot stays selected so the user can deselect. |
| `POST /v1/experiences/:id/slots/pricing` | Inline panel above the price summary. |
| Cart checkout | A blocking modal listing the affected line items + "Remove from cart" action. This is the only path that's destructive — the user should be the one to remove. |

### Verification checklist (per client team)

```
[ ] Match on `code === 'SPACE_NOT_AVAILABLE'`, not just HTTP 403.
[ ] No generic error toast on this code.
[ ] No 404 redirect on this code.
[ ] No retry loop on this code.
[ ] Empty state copy reviewed by the product / brand voice owner before pilot.
[ ] Test by joining a customer group on staging, then leaving it, then trying to view the previously-accessible space — confirm the empty state, not an error.
[ ] Mobile-deeplink test: paste a restricted-space URL into iMessage / WhatsApp from a member, open it on a non-member device, confirm the empty state.
```

### Out of scope for #732

- "Request access" CTA on the empty state — V2 once we have a tenant-level access-request workflow.
- A separate empty state for soft-deleted groups vs. for never-attached users — the 403 doesn't distinguish them and shouldn't (the client doesn't know about groups).
- Telemetry on the 403 — instrument as part of the normal error pipeline; no special handling needed.

---

## Other things you might need

### Backend changelog (what was shipped on `feature/#707-integration-customer-groups`)

| PR | Summary |
|---|---|
| #716 | DB migrations (5) — customer_group, customer_group_member, space_customer_group, audit, space.access_mode column |
| #717 | Customer group CRUD (US-1 backend) |
| #718 | Space access mode + group restriction wiring (US-4 backend) |
| #719 | Manual member management (US-3 backend) |
| #720 | Excel bulk-import (US-2 backend) |
| #721 | Listing access filter (US-5 backend) |
| #722 | Layer-2 action-side enforcement (US-6 backend, part 1) |
| #723 | Helper deprecation cleanup (US-6 backend, part 2) |
| #724 | Facet visibility + dataloader audit (US-6 backend, part 3) |
| #725 | Frontend scaffold for spark-tenant-admin-web (routes, sidebar, API hooks, stubs) |
| #726 | Soft-delete saga + auto-revert + email (US-7 backend) |

### Reference docs

- **PRD**: `projects/booking-system/prd-customer-groups.md`
- **Tech design**: `projects/booking-system/techdesign-customer-groups.md`
- **Design specs (admin-side, but useful for visual language)**: `projects/booking-system/design-customer-groups.md`
- **Tech-design § "Client error contract"** has the canonical wire shape and the rationale for 403-not-404. Re-read it once before implementing.

### Open questions to raise back

If anything in this doc is ambiguous, ping back on the parent issue (`#707`) or the relevant frontend ticket (`#731` / `#732`). Specific topics worth a sync before pilot:

- Empty-state copy review with the brand-voice / product owner.
- Whether `/core/categories` zero-count categories should auto-hide on the client.
- The exact UI for the cart-checkout race (when a cart line resolves to a now-restricted space between add and checkout) — design-doc § Auto-revert banner is admin-side only.

### Pen-test sign-off (Hakim, external) is the hard launch gate

The Phase 1 pilot is gated on Hakim's pen-test. The clients should be wired up and verified before that — Hakim is going to test:

- A non-member crafting a direct API call to `/experiences/:restricted-id` — does the server reject with 403 + correct code, AND does the client render the empty state correctly when fed that response? (Both layers in scope.)
- A non-member crafting a shared-link payload that bypasses the normal flow — same.
- The `spark-external-client-api` white-label surface is the highest-leak-risk path; explicit pen-test scope.

If the clients don't honor this contract, the pen-test will fail and the pilot will slip.

---

*Generated from the customer-groups backend completion 2026-06-01. Backend authors: ApexYard backend agent. Mobile + customer-web teams own the surfaces in this doc.*
