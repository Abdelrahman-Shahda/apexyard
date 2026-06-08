# PRD: Customer Groups + Restricted-Access Spaces

**Status**: Draft
**Author**: Abdelrahman Shahda (Product)
**Created**: 2026-05-31
**Last Updated**: 2026-05-31
**Backlog entry**: IDEA-004 — `projects/ideas-backlog.md`
**Target launch**: 2026-07-19 (≈ 7 weeks)

---

## Overview

### Problem Statement

Today every space on a Spark tenant is either **on** or **off** for the whole world — there is no way to restrict who can *see* or *book* it. Two real-world setups break under that model:

1. **Compound-internal courts.** A residential compound runs a padel court for its residents only. The compound is a Spark tenant, but residents and non-residents share the same Spark mobile app. There is no way to hide the court from non-residents or block their bookings — the operator's only options today are (a) keep the court off-platform entirely and lose the booking flow, or (b) leave it open and police bookings manually via the front desk. Both fail at scale.
2. **Academy-only slots.** A tenant runs a tennis academy. They want certain courts (or certain time-windows on a shared court — V2) to be bookable only by enrolled academy members, while other courts on the same tenant stay open to the public. There is no way today to express "this space is only for *these* users".

Underneath both is the same missing primitive: a **named, tenant-scoped set of users** that the tenant admin can curate, and a **space visibility/booking rule** that can point at one or more such sets.

The operational pain is acute on the curation side too. Compound and academy operators already have member lists — typically in Excel, with phone, first name, last name — but Spark has no way to ingest them. Adding members one-by-one through the existing user-creation flow is a non-starter at compound scale (hundreds to thousands of residents).

### Target User

**Primary**:

- **Tenant admins** running compounds, academies, or any tenant with a restricted-membership subset. They own group creation, Excel import, and per-space access rules.

**Secondary**:

- **End users** (residents, academy members) — visible side-effect: they see a curated set of spaces that match the real-world access they have, instead of being shown bookings they cannot complete.
- **Front-desk staff** — relieved of manual "are you a member?" gatekeeping at the booking moment.

### Goals

1. **Eliminate manual gatekeeping for membership-restricted spaces.** A compound's residents-only court can be hidden from non-residents end-to-end without front-desk intervention. Measured by counting front-desk reversal/refund events on restricted spaces post-launch (target: ≈ 0 for restricted-space bookings).
2. **5-minute self-serve from member list to live restriction.** A tenant admin can upload an Excel of members and have a restricted space go live in under 5 minutes, no engineering ticket. Measured by time-to-completion on the create-group → import → assign-space flow.
3. **Phone-based dedup is invisible and trustworthy.** Re-importing the same Excel produces zero duplicate users; existing platform users get attached to the tenant rather than re-created with a new account. Measured by zero duplicate-phone collisions in post-import audits and zero user-merge incidents in the first 90 days.
4. **Cover 100% of the compound use case and the academy use case in V1.** Both shapes use the same primitive (group + restricted space). Measured by onboarding a real compound tenant and a real academy tenant in the first 30 days post-launch.
5. **Restricted spaces never leak.** A non-member never sees a restricted space in any listing surface (mobile, website, deeplink, tenant page) and a direct booking attempt fails with a clear access-denied response, not a 500. Measured by zero leak-class bug reports in the first 90 days.

### Non-Goals (Out of Scope)

- **Time-window-scoped access.** "Court X is academy-only Mon-Fri 4-7pm, public the rest of the week." V2. V1 is whole-space access only.
- **Auto-membership rules.** "Anyone who buys subscription Y is auto-added to group Z." V2. V1 membership is curated (manual + Excel import).
- **Cross-tenant groups.** A group always belongs to exactly one tenant. A user in compound A's "Residents" group has no relationship to compound B's groups.
- **Self-service membership requests.** Users cannot apply to join a group from the app. V1 admission is admin-curated only.
- **Group-based pricing or addons.** Groups in V1 control access only, not price. A separate PRD can layer pricing rules on top of the group primitive later.
- **Group-based promo codes / discounts.** Same as above — V2.
- **Bulk membership migration between groups.** V1 ships add and remove; copy-from-group-to-group is V2.
- **CSV / Google Sheets import.** V1 is Excel (.xlsx) only — it matches the IDEA-002 export pipeline's format and the existing `get-users-import-template.query.ts` template.
- **SMS / email invite on auto-creation.** V1 silently creates the user record; the user discovers the access on their next app open or booking attempt. Invite messaging is a follow-up. *Confirmed by Product 2026-05-31.*
- **A super-admin cross-tenant view of groups.** V1 is tenant-admin-only. Super-admin observability ships separately if needed.

### Success Metrics

#### Leading (first 4 weeks post-launch)

| Metric | Target | How Measured |
|---|---|---|
| Tenant admins who create at least one group | ≥ 1 per onboarded compound/academy tenant | Backend event on `customer-group.created` |
| Excel imports that complete without manual cleanup | ≥ 95% | Import-job result event (success vs partial) |
| Median time from "open create-group" → "space restricted live" | < 5 minutes | Frontend funnel analytics |
| Restricted spaces with at least one member-group attached | 100% | DB invariant check (no restricted space with empty group set) |

#### Lagging (weeks 6-12)

| Metric | Target | How Measured |
|---|---|---|
| Compound front-desk reversal/refund events on restricted spaces | ≈ 0 | Tenant-admin support tickets + reversal audit |
| Duplicate user records produced by import dedup | 0 | DB audit on `phone_number` uniqueness |
| Leak-class bugs ("non-member saw restricted space") | 0 | Bug tracker label `leak/customer-group` |
| Tenants onboarded that needed customer groups | ≥ 1 compound + ≥ 1 academy in first 30 days | Sales / CS log |

---

## User Stories

### US-1: Tenant admin creates a customer group

> As a tenant admin, I want to create a named customer group on my tenant, so that I can collect a curated subset of my users for access control.

**Acceptance Criteria**:

- [ ] Group has a name (required, 1–60 chars), an optional description (≤ 280 chars), and a created-at timestamp.
- [ ] Group name is unique within a tenant (case-insensitive). Duplicate name → validation error before creation.
- [ ] Empty group is allowed on creation (members can be added later).
- [ ] Group is owned by the creating tenant. Hard-scoped — no cross-tenant visibility.
- [ ] Group is soft-deletable; soft-deleted groups detach from all spaces (see US-7).

---

### US-2: Tenant admin bulk-imports members from Excel

> As a tenant admin, I want to upload an Excel of phone + first name + last name, so that I can populate a group from a list I already maintain in Excel.

**Acceptance Criteria**:

- [ ] Admin downloads a template (.xlsx) with three required columns: `Mobile`, `First Name`, `Last Name`. Reuses the existing `get-users-import-template.query.ts` shape; reduces required columns to these three.
- [ ] Admin uploads a filled template against a target group.
- [ ] Phone is normalised to E.164 (strict) using the tenant-default country code before dedup. Rows whose phone cannot be normalised are skipped with a per-row `error: invalid phone format` outcome.
- [ ] **Per row**: if a user already exists in Spark with that phone, they are attached to the tenant (via `TenantUser` join) and added to the group. If no user exists, a new user record is created with phone + first + last (no password, no email), attached to the tenant, and added to the group.
- [ ] Import is processed asynchronously via a Bull job (mirrors the existing user-export processor pattern). Admin sees a status indicator and receives a result summary on completion.
- [ ] Result summary lists per-row outcome: `attached_existing` | `created_new` | `already_member` | `error` (with reason). Available as both UI summary and downloadable Excel report.
- [ ] Re-importing the same file is idempotent (no duplicates, no errors on already-member rows).
- [ ] Import is atomic at the row level (one bad row does not abort the whole job).
- [ ] Import respects a 10,000-row hard cap per upload in V1; larger files get rejected with a clear message.

---

### US-3: Tenant admin manages group members manually

> As a tenant admin, I want to add and remove members from a group one-at-a-time through the admin UI, so that I can curate the group between bulk imports.

**Acceptance Criteria**:

- [ ] Admin can search the tenant's users (by name or phone) and add a result to a group.
- [ ] Admin can remove a member from a group. Removal does **not** remove the user from the tenant (the `TenantUser` join stays).
- [ ] Group member list is paginated and searchable; default sort is most-recently-added first.
- [ ] Member count is visible on the group list page without clicking in.

---

### US-4: Tenant admin restricts a space to one or more groups

> As a tenant admin, I want to mark a space as restricted to specific customer groups, so that only members of those groups can see and book it.

**Acceptance Criteria**:

- [ ] On the space edit screen, admin picks an access mode: `Public` (default, current behaviour) or `Restricted to groups`.
- [ ] In `Restricted` mode, admin picks one or more groups from the tenant's groups (multi-select).
- [ ] Access semantics are **OR**: a user qualifies if they are a member of *any* attached group.
- [ ] Admin cannot save a `Restricted` space with zero attached groups (validation error).
- [ ] Switching a space from `Public` to `Restricted` is allowed and takes effect immediately; existing bookings on the space are honored (not cancelled).
- [ ] Switching a space from `Restricted` to `Public` is allowed and re-exposes the space to all users immediately.

---

### US-5: Member sees and books a restricted space

> As an end user who is a member of an eligible group, I want a restricted space to appear in my listings exactly like a public space, so that I can book it normally.

**Acceptance Criteria**:

- [ ] Restricted space appears in mobile-app listings, website listings, the tenant page, search results, and deeplinks for eligible members.
- [ ] No "restricted" badge or visual distinction is shown — the experience is identical to a public space.
- [ ] Booking flow works end-to-end with no extra confirmation step or membership-check UI.

---

### US-6: Non-member cannot see or book a restricted space

> As an end user who is NOT a member of any eligible group, I want a restricted space to be completely invisible to me, so that I'm never shown options I can't act on.

**Acceptance Criteria**:

- [ ] Restricted space is absent from every listing surface (mobile-app listings, website listings, tenant page, search, deeplinks, sitemaps).
- [ ] If a non-member somehow lands on a restricted space's detail URL (e.g. shared link), they get a clear "not available" response — not a 404 (which would falsely imply the space does not exist) and not a 500.
- [ ] If a non-member crafts a direct booking API call against a restricted space, the booking API rejects with a clear access-denied response. Authorisation is checked server-side; client-side hiding is not the security boundary.
- [ ] Listing performance does not degrade meaningfully: the access filter adds at most one indexed join per listing query.

---

### US-7: Lifecycle — soft-delete and member removal

> As a tenant admin, I want to retire a group when it's no longer needed, so that I don't have stale groups cluttering my admin UI.

**Acceptance Criteria**:

- [ ] Admin can soft-delete a group. Soft-deleted groups disappear from the admin UI and from any space's group multi-select.
- [ ] Soft-deleting a group automatically detaches it from any space that referenced it. If that detachment leaves a `Restricted` space with zero groups, the space is automatically toggled back to `Public` and the tenant admin is emailed a notification listing the affected spaces. (Alternative considered: block deletion until detached. Rejected because compound use case wants "kill the group, ship the space back to public" as a one-step recovery flow.)
- [ ] Removing a member from a group has no effect on the user's other tenant relationships, other group memberships, or past bookings.

---

### Edge Cases

| Scenario | Expected Behavior |
|---|---|
| Excel row has a phone that's already in the tenant but not in the target group | Add to group; per-row result: `already_in_tenant` |
| Excel row has a phone of an existing global user but not in the tenant | Attach to tenant (insert `TenantUser`), then add to group; per-row result: `attached_existing` |
| Excel row has a phone in invalid format (e.g. letters, < 7 digits) | Skip the row; per-row result: `error: invalid phone format` |
| Excel row has missing first or last name | Skip the row; per-row result: `error: missing name field` |
| Two Excel rows have the same phone | Process the first; second gets `error: duplicate in upload` |
| User is in multiple groups attached to one restricted space | Access granted (OR semantics); no double-counting |
| User in compound A's "Residents" attempts to book in compound B | Compound B's group set does not include this user → access denied (groups are tenant-scoped) |
| Booking exists on a space at the moment it switches from `Public` to `Restricted` | Existing booking is honored; future bookings require membership |
| Member removed from group while a future booking exists | Existing booking is honored; cannot create new bookings on that space |
| Tenant admin tries to attach a group from a different tenant | API rejects; admin UI does not surface other tenants' groups |
| Bulk import file is corrupted / not a valid .xlsx | Job fails fast with a clear error before any rows are processed |

---

## Requirements

### Functional Requirements

| ID | Requirement | Priority | Notes |
|---|---|---|---|
| FR-1 | New `customer-group` library (`libs/customer-group`) with domain + application + infrastructure layers, mirroring the existing libs convention. | Must | Confirmed greenfield — no existing group/segment lib to extend. |
| FR-2 | `CustomerGroup` entity: `id`, `tenantId`, `name`, `description?`, `createdAt`, `updatedAt`, `deletedAt`. Unique `(tenantId, lower(name))` constraint. | Must | |
| FR-3 | `CustomerGroupMember` join entity: `customerGroupId`, `userId`, `addedAt`, `addedBy`. Composite PK `(customerGroupId, userId)`. | Must | |
| FR-4 | Bulk-import command handler: parse .xlsx → normalise phone → upsert user → ensure `TenantUser` → ensure `CustomerGroupMember`. | Must | Reuse the `xlsx` lib already in `user-map-export.processor.ts`. |
| FR-5 | Bull queue + processor for async import; result summary stored against the job and downloadable as .xlsx for ≥ 7 days. | Must | |
| FR-6 | `Space` entity extension: `accessMode: enum('public', 'restricted')` (default `public`), plus `SpaceCustomerGroup` join entity `(spaceId, customerGroupId)`. | Must | |
| FR-7 | Listing queries (mobile, website, tenant page, search) filtered by access check: `space.accessMode = 'public' OR user ∈ any attached group`. Filter applied at query level, not in-memory. | Must | Performance gate — see NFR-1. |
| FR-8 | Authorisation guard on the booking API: rejects with `403 access_denied` when a non-member targets a restricted space. | Must | Defence-in-depth; the listing filter is UX, the guard is security. |
| FR-9 | Admin UI: groups list, group create/edit, member list, Excel import button + template download. | Must | Lives under the existing tenant-admin UI. |
| FR-10 | Admin UI: space edit screen gains an "Access" section with the mode toggle and group multi-select. | Must | |
| FR-11 | Auto-detach groups from spaces on group soft-delete; auto-revert affected spaces to `public` if their group set goes empty; email tenant admin. | Must | See US-7 alternative-considered note. |
| FR-12 | Audit log on group membership changes (added by whom, when, via UI vs import). | Should | Reuses any existing tenant-admin audit pattern; spec the destination in Tech Design. |
| FR-13 | Per-row import result export (.xlsx download). | Should | Critical UX for large imports; can fall back to UI-only summary if cut. |
| FR-14 | Import rate limit: max 1 in-flight import per tenant at a time; queue subsequent submissions. | Should | Prevents foot-gun on enormous imports. |
| FR-15 | Search-by-name endpoint for adding individual members (US-3). | Must | Likely reuses the existing tenant-user search; confirm in Tech Design. |

**Priority Key**: Must (required for launch) | Should (important) | Could (nice to have)

### Non-Functional Requirements

| Category | Requirement | Target |
|---|---|---|
| Performance — listing | Restricted-space filter adds at most one indexed join per query. P95 listing query time post-launch within 10% of pre-launch baseline. | P95 < 250 ms on tenant-page listing |
| Performance — import | 1,000-row import completes in < 60 seconds; 10,000-row in < 10 minutes. | Bull job duration |
| Security — access boundary | Server-side authorisation on booking + space-detail endpoints. Listing hiding is UX, not security. Validated by adversarial test cases. | Pen-test sign-off pre-launch |
| Security — multi-tenancy | All group + member + space-access queries are tenant-scoped at the persistence layer (not just at the API layer). | Reviewed in Tech Design |
| Reliability — import dedup | Re-importing the same Excel produces zero new rows. | Idempotency test |
| Reliability — soft-delete safety | Soft-delete of a group never leaves a restricted space in a "zero groups attached" state. | DB invariant test |
| Privacy | Phone, first name, last name imported under existing PII handling — no new collection categories. | Compliance audit |

---

## Design

### User Flow — Tenant admin: create group + import + restrict space

```
[Tenant admin opens "Customer Groups" (new sidebar entry)]
    |
    v
[Click "New Group" -> name + description -> Save]
    |
    v
[Group detail page -> "Import Members" -> Download template]
    |
    v
[Admin fills template offline -> Upload .xlsx]
    |
    v
[Async job runs (Bull) -> progress indicator]
    |
    +---> [Success: summary + downloadable result.xlsx]
    |
    +---> [Partial: per-row outcomes -> admin retries / fixes]
    |
    v
[Navigate to Space edit -> Access section -> "Restricted to groups"]
    |
    v
[Multi-select the new group -> Save]
    |
    v
[Restricted space now hidden from non-members; visible + bookable to members]
```

### User Flow — End user: discovery of restricted space

```
[Member opens mobile app -> Tenant page]
    |
    v
[Listing query runs with access filter -> restricted space included]
    |
    v
[Member taps space -> standard booking flow]

[Non-member opens mobile app -> Tenant page]
    |
    v
[Listing query runs with access filter -> restricted space excluded]
    |
    v
[Space simply not present; non-member is never shown it]
```

### Wireframes / Mockups

To be produced by UI/UX Designer (Nour + Iman) after PRD approval. Required screens:

- Customer Groups list (tenant-admin sidebar)
- Group create / edit modal
- Group detail (members tab, import tab, settings tab)
- Excel import upload + result summary
- Space edit — new Access section with mode toggle + group multi-select

---

## Technical Notes

### Dependencies

| Dependency | Type | Status | Owner |
|---|---|---|---|
| `libs/tenants` (existing `TenantUser` join) | Internal | Ready | Backend |
| `libs/user` (existing user entity, phone uniqueness, import template) | Internal | Ready | Backend |
| `libs/space` (existing entity to extend with `accessMode` + join) | Internal | Ready | Backend |
| Bull queue + worker (used by existing user-map-export processor) | Internal | Ready | Backend |
| `xlsx` npm lib (already in deps) | External | Ready | Backend |
| Tenant-admin UI shell (sidebar, route registration) | Internal | Ready | Frontend |

### Technical Constraints

- **Phone normalisation has no existing helper.** A new utility is needed: E.164 normalisation with a tenant-default country code; reject (per-row error) if the input cannot resolve. Confirmed scope; Tech Design captures the implementation choice (e.g. `libphonenumber-js`) in an AgDR.
- **No existing "audience / segment" abstraction.** Build new; do not retrofit the tournament-division-group shape (different domain).
- **`TenantUser.status: boolean`** today does not differentiate "active" vs "passive" — import attaches with `status: true`. Tech Design must confirm this matches current invariants.
- **Listing performance budget is tight.** The access filter must be query-level (single indexed join), not application-level. Confirm with a load-test on a tenant with 10k+ users and 50+ spaces.
- **Authorisation must be enforced on the booking endpoint AND the space-detail endpoint.** The listing filter is not a security boundary.

---

## Launch Plan

### Rollout Strategy

- [x] Phased rollout (recommended)

Phase 1 (Week 1 post-merge): enabled for two pilot tenants only — one compound, one academy. Feature flag gated.
Phase 2 (Week 2): enabled for all P0 tenants. Monitor for leak-class bugs.
Phase 3 (Week 3+): full rollout, feature flag retired.

---

## Open Questions

| Question | Owner | Status | Resolution |
|---|---|---|---|
| Phone normalisation strategy | Product | **Closed** | Normalise to E.164 strict using tenant-default country code; reject unparseable rows with a per-row error in the import result |
| Excel column header strictness | Product | **Closed** | Strict header match (`Mobile`, `First Name`, `Last Name`). The Customer Groups screen exposes a "Download sample Excel" button so tenants always have the canonical template |
| SMS invite on auto-creation | Product | **Closed** | No SMS invite in V1. Auto-created users discover access silently on next app touch |
| Group-soft-delete behaviour when attached space's group set goes empty | Product | **Closed** | Auto-revert to `public` + email tenant admin (US-7 AC) |
| Caps on groups per tenant / members per group / groups per space | Product | **Closed** | **No domain caps in V1.** Groups per tenant, members per group, and groups per space are all unbounded. The only size guard is the **import-job-level** 10k-row cap per upload (NFR — protects the Bull worker, not a domain limit). Larger lists ship as multiple imports against the same group |
| Should the audit log of group membership changes be visible to the tenant admin, or backend-only? | Product | Open | Lean: backend-only V1, surface later |

---

## Timeline

| Milestone | Target Date | Status |
|---|---|---|
| PRD Approved | 2026-06-03 | Pending |
| Design Complete (wireframes for groups + import + space access) | 2026-06-10 | Pending |
| Tech Design + AgDRs (phone normalisation, access enforcement, import job shape) | 2026-06-14 | Pending |
| Dev Complete | 2026-07-10 | Pending |
| QA Complete (incl. pen-test on access boundary) | 2026-07-17 | Pending |
| Phase 1 launch (2 pilot tenants, feature-flagged) | 2026-07-19 | Pending |
| Full rollout | 2026-08-02 | Pending |

---

## Approvals

| Role | Name | Date | Status |
|---|---|---|---|
| Product Manager | Mariam | 2026-05-31 | Author |
| Head of Product | Omar | | Pending |
| Tech Lead | Hisham | | Pending |
| Head of Design | Maha | | Pending |

---

## Glossary

| Term | Definition |
|---|---|
| Tenant | A Spark customer org (compound, club, academy, federation) operating its own spaces. |
| Space | A bookable unit (court, hall, room) owned by a tenant. Today public-by-default; this PRD adds a restricted mode. |
| Customer Group | New primitive: a named, tenant-scoped set of users curated by the tenant admin. Used as the access predicate for restricted spaces. |
| Member | A user attached to a tenant via `TenantUser` AND included in a specific customer group. Membership in the tenant alone does not grant access to a restricted space. |
| Public space | Current default. Visible and bookable to anyone who can see the tenant. |
| Restricted space | New mode. Visible and bookable only to users who are members of at least one attached customer group. |
| Compound use case | Residential development running a court for residents only. The tenant is the compound; residents are a single customer group; the court is restricted to that group. |
| Academy use case | Tenant running an academy program with member-only courts/slots. The tenant has its general public spaces plus academy-restricted spaces; academy members are a customer group; restricted spaces point at it. |
| Phone-based dedup | Import logic that uses normalised phone as the canonical user identity. Existing users get attached; only truly new phones create new user records. |
| OR semantics (group access) | A user qualifies for a restricted space if they belong to ANY of the space's attached groups, not all. |
