# Technical Design: Customer Groups + Restricted-Access Spaces

**Status**: Draft
**Author**: Hisham (Tech Lead) — drafted on Abdelrahman Shahda's behalf
**Date**: 2026-05-31
**PRD**: `projects/booking-system/prd-customer-groups.md`
**Epic**: apessolutions/booking-system#707
**Backlog**: IDEA-004

---

## Overview

### Summary

Add a new `libs/customer-group` library that introduces tenant-scoped, admin-curated user groups. Extend `libs/space` with a per-space access mode and a many-to-many link to those groups. Build a Bull-backed Excel import pipeline that uses phone-based dedup (via existing `CreateUserAndAddToTenantCommand`) to populate groups. Listings filter by group membership at the query level; the booking and space-detail endpoints enforce the same predicate as a defence-in-depth guard.

### Goals

- Mirror the existing hexagonal lib shape (`libs/space` is the canonical reference).
- Reuse the existing `User` + `TenantUser` plumbing for member attachment — no duplicate user creation paths.
- Listing access filter is a single indexed left-join, not an in-memory pass.
- Server-side authorisation on both the listing surface and the action surface (booking, space-detail). UX hiding alone is not the security boundary.
- One Bull queue, one processor, idempotent at the row level, mirrors `user-map-export.processor.ts` shape.

### Non-Goals

- No new permission model (extend the existing `SpacePermission` + introduce one new permission set for customer groups; do not refactor RBAC).
- No change to the public listing API shape — the filter is internal.
- No change to the existing booking flow's response shape on the happy path.
- No retroactive migration of existing "informal" groupings (none exist).

---

## Domain Model

### New entities

```
CustomerGroup                                  (libs/customer-group/.../domain/customer-group.ts)
├── id: CustomerGroupId
├── tenantId: TenantId
├── name: string                               (1-60, unique per tenant case-insensitive)
├── description?: string                       (≤ 280)
├── createdAt, updatedAt, deletedAt
└── methods:
    ├── rename(name)
    ├── updateDescription(text?)
    └── softDelete()

CustomerGroupMember                            (libs/customer-group/.../domain/customer-group-member.ts)
├── customerGroupId: CustomerGroupId           (composite PK)
├── userId: UserId                              (composite PK)
└── addedAt: Date

# NOTE: "added by whom" and "added via UI vs import" are NOT stored on the row.
# Those facts are captured by the existing MongoDB audit-trail surface on
# the CustomerGroupMemberAdded event (actor + source channel already live there).
# Duplicating on the row would be storage spent on something already audited.

SpaceCustomerGroup                              (libs/space/.../domain/space-customer-group.ts)
├── spaceId: SpaceId                           (composite PK)
├── customerGroupId: CustomerGroupId           (composite PK)
└── createdAt: Date
```

### Extended entity (existing Space)

```
Space (extended)
├── ...existing columns...
└── accessMode: enum('public','restricted')    (default 'public')
```

Invariant on `Space`:

```
accessMode === 'restricted'  ⇒  exists at least one SpaceCustomerGroup row
                                with this spaceId
```

Enforced by an application-layer policy on save and a DB-level CHECK is **not** added (TypeORM ergonomics; we lean on the policy + a backfill job).

### Value objects

| VO | Fields | Purpose |
|---|---|---|
| `NormalisedPhone` | `e164: string`, `country: string` | Wraps `libphonenumber-js`. Throws `InvalidPhoneError` on unparseable input. Used at every entry point that ingests a phone (import processor + manual add). |
| `CustomerGroupName` | `value: string` | Validates length, normalises whitespace, exposes `equalsIgnoreCase()` for uniqueness check. |
| `ImportRowResult` | `row, outcome, message?` | One per row. `outcome` enum: `created_new`, `attached_existing`, `already_in_tenant`, `already_member`, `error`. |

### Domain events

| Event | Trigger | Data | Subscriber |
|---|---|---|---|
| `CustomerGroupCreated` | Group create command succeeds | `groupId, tenantId, name, actor, sourceChannel` | MongoDB audit-trail |
| `CustomerGroupMemberAdded` | Manual add OR import row | `groupId, userId, actor, sourceChannel` *(`'ui' \| 'import'`)* | MongoDB audit-trail |
| `CustomerGroupMemberRemoved` | Manual remove | `groupId, userId, actor, sourceChannel` | MongoDB audit-trail |
| `CustomerGroupSoftDeleted` | Soft delete command | `groupId, tenantId, actor` | MongoDB audit-trail + `SpaceAccessRevertSaga` (see § Sagas) |
| `SpaceAccessModeChanged` | Space access mode toggle | `spaceId, previousMode, newMode, actor` | MongoDB audit-trail |
| `CustomerGroupImportCompleted` | Bull processor end | `groupId, jobId, totals, s3ResultKey` | Email service (admin notification) |

**Actor + source channel live on the event, not the row.** Both fields ride on every membership-related event into the existing MongoDB audit-trail surface (the canonical Spark audit pattern per `CLAUDE.md` § Multi-Tenancy). Rationale: who-added and how-added are temporal facts about a transition, not durable facts about the relationship. Querying *"who added this user to this group?"* is a Mongo audit query, not a Postgres column read.

### Sagas / cross-aggregate flows

**`SpaceAccessRevertSaga`** — listens for `CustomerGroupSoftDeleted`. Within a single transaction:

1. Detach `SpaceCustomerGroup` rows referencing this group.
2. For every now-orphaned restricted space (zero remaining attached groups), set `space.accessMode = 'public'`.
3. Collect affected `spaceId`s.
4. Emit one `SpaceAccessAutoRevertedNotification` event per tenant batch → email handler.

Implemented in `libs/customer-group/.../application/sagas/space-access-revert.saga.ts`. Tested with a deterministic in-memory event bus.

---

## Architecture

### Lib structure (new `libs/customer-group`)

Mirrors `libs/space` exactly:

```
libs/customer-group/src/lib/
├── customer-group.module.ts
├── domain/
│   ├── customer-group.ts
│   ├── customer-group-member.ts
│   ├── events/
│   │   ├── customer-group-created.event.ts
│   │   ├── customer-group-member-added.event.ts
│   │   └── customer-group-soft-deleted.event.ts
│   └── value-objects/
│       ├── normalised-phone.ts
│       └── customer-group-name.ts
├── application/
│   ├── commands/
│   │   ├── create-customer-group.command.ts
│   │   ├── rename-customer-group.command.ts
│   │   ├── soft-delete-customer-group.command.ts
│   │   ├── add-member-to-customer-group.command.ts
│   │   ├── remove-member-from-customer-group.command.ts
│   │   └── enqueue-customer-group-import.command.ts
│   ├── queries/
│   │   ├── list-customer-groups.query.ts
│   │   ├── get-customer-group-detail.query.ts
│   │   ├── list-customer-group-members.query.ts
│   │   ├── get-customer-group-import-template.query.ts
│   │   └── get-customer-group-import-result.query.ts
│   ├── ports/
│   │   ├── customer-group.repository.ts
│   │   └── customer-group-member.repository.ts
│   ├── sagas/
│   │   └── space-access-revert.saga.ts
│   └── policies/
│       └── customer-group-access.policy.ts
├── infrastructure/
│   ├── persistence/
│   │   ├── entities/
│   │   │   ├── customer-group.entity.ts
│   │   │   └── customer-group-member.entity.ts
│   │   ├── repositories/
│   │   │   ├── customer-group.repository.ts
│   │   │   └── customer-group-member.repository.ts
│   │   ├── mapper/
│   │   │   ├── customer-group.mapper.ts
│   │   │   └── customer-group-member.mapper.ts
│   │   └── migrations/
│   │       └── <timestamp>-CreateCustomerGroupTables.ts
│   └── persistence.module.ts
├── processors/
│   └── customer-group-import.processor.ts
└── constants/
    ├── customer-group-import-headers.constants.ts
    └── customer-group-import-queue.constants.ts
```

### Changes to `libs/space`

- New migration: `<timestamp>-AddSpaceAccessMode.ts` — adds `access_mode` enum column to `space`, default `'public'`, NOT NULL, backfilled to `'public'` for all existing rows.
- New migration: `<timestamp>-CreateSpaceCustomerGroupJoin.ts` — creates `space_customer_group(space_id, customer_group_id, created_at)` table with composite PK and an index on `customer_group_id` for the reverse lookup (used by the saga).
- New entity: `libs/space/.../infrastructure/persistence/entities/space-customer-group.entity.ts`.
- Existing `space.entity.ts` gains `accessMode` column + `oneToMany` to the join.
- Existing space-listing query handler gains the access filter (see § Access enforcement).
- Existing `space.policy.ts` (or equivalent) gains a `canUserSeeSpace(space, user)` predicate that mirrors the SQL filter for use at the controller layer.

### Component diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│  spark-tenant-admin-api  (controllers: customer-groups, spaces)     │
└────────────┬───────────────────────────────────────┬────────────────┘
             │ commands / queries                    │ commands
             ▼                                       ▼
┌──────────────────────────┐            ┌──────────────────────────┐
│ libs/customer-group       │            │ libs/space               │
│  ├ commands / queries     │  events    │  ├ Space + accessMode    │
│  ├ ImportProcessor (Bull) │ ◄───────── │  ├ SpaceCustomerGroup    │
│  └ SpaceAccessRevertSaga  │ ─────────► │  └ listing query w/      │
└────────┬─────────────────┘            │     access filter         │
         │ reuses                       └──────────────────────────┘
         ▼
┌──────────────────────────┐
│ libs/tenants              │ ◄── CreateUserAndAddToTenantCommand
│  ├ TenantUser join        │     (existing, reused for import)
└──────────────────────────┘
         │ reuses
         ▼
┌──────────────────────────┐
│ libs/user                 │
│  ├ User                   │
│  └ CreateUserCommand      │
└──────────────────────────┘

┌──────────────────────────┐
│ spark-mobile-api,         │ ← listing endpoints inject access filter
│ spark-website-api         │   via the extended space query handler
└──────────────────────────┘

┌──────────────────────────┐
│ booking endpoints         │ ← @UseGuards(SpaceAccessGuard) on create-booking
│ (spark-*-api)             │   + on space-detail endpoint
└──────────────────────────┘
```

### Data flow — Excel import

```
Admin uploads .xlsx
        │
        ▼
[Controller] POST /customer-groups/:id/import
   - multipart parse → buffer
   - persist buffer to S3 under uploads/customer-group-imports/<jobId>.xlsx
   - dispatch EnqueueCustomerGroupImportCommand
        │
        ▼
[Handler] enqueues Bull job onto CUSTOMER_GROUP_IMPORT_QUEUE
        │  jobData: { groupId, tenantId, adminId, s3Key, defaultCountryCode }
        ▼
[Bull Worker] customer-group-import.processor.ts
   1. download buffer from S3
   2. parse with xlsx → rows[]
   3. header strictness check → fail-fast if mismatch
   4. row count > 10_000 → fail-fast
   5. for each row (sequential within a job):
        - validate first/last present
        - NormalisedPhone.from(row.mobile, defaultCountryCode)
        - in-upload dedup set (skip if duplicate within file)
        - call CreateUserAndAddToTenantCommand (idempotent on phone)
        - call AddMemberToCustomerGroupCommand (idempotent on (group,user))
        - record ImportRowResult
   6. write result.xlsx → S3 under results/<jobId>.xlsx (signed URL, 7-day TTL)
   7. update customer_group_import_audit row (totals + s3ResultKey)
   8. emit CustomerGroupImportCompleted → email admin with download link
        │
        ▼
[Admin UI] polls GET /customer-groups/:id/imports/:jobId
   returns { status, totals, downloadUrl? }
```

### Data flow — non-member tries to view a restricted space

```
GET /spaces/:id (mobile-api)
   │
   ▼
[AuthGuard] resolves user → contextUser
   │
   ▼
[SpaceAccessGuard]            ◄── new guard (libs/customer-group/.../guards/)
   - load space.accessMode + attached customerGroupIds
   - if accessMode === 'public' → allow
   - else load contextUser's customer-group memberships for tenant
        - if intersection non-empty → allow
        - else → throw ForbiddenException('SPACE_NOT_AVAILABLE')
   │
   ▼
[Controller] returns space DTO

Mapped to HTTP: 403 SPACE_NOT_AVAILABLE
(NOT 404 — explicit signal it exists but is not for you; NOT 500 — safe behaviour)
```

---

## API Design

All endpoints are tenant-admin scoped (`@TenantAdminAuth([...])`) unless noted.

### Customer-group CRUD

| Method | Path | Purpose | Permission |
|---|---|---|---|
| POST | `/customer-groups` | Create group | `CustomerGroupPermission.add` |
| GET | `/customer-groups` | List groups (paginated, search by name) | `CustomerGroupPermission.list` |
| GET | `/customer-groups/:id` | Get group detail | `CustomerGroupPermission.list` |
| PATCH | `/customer-groups/:id` | Rename / update description | `CustomerGroupPermission.edit` |
| DELETE | `/customer-groups/:id` | Soft-delete | `CustomerGroupPermission.delete` |

### Membership

| Method | Path | Purpose | Permission |
|---|---|---|---|
| GET | `/customer-groups/:id/members` | List members (paginated, search by name/phone) | `CustomerGroupPermission.list` |
| POST | `/customer-groups/:id/members` | Add member by `userId` (admin search → add flow) | `CustomerGroupPermission.editMembers` |
| DELETE | `/customer-groups/:id/members/:userId` | Remove member | `CustomerGroupPermission.editMembers` |

### Import

| Method | Path | Purpose | Permission |
|---|---|---|---|
| GET | `/customer-groups/import-template` | Download sample .xlsx | `CustomerGroupPermission.import` |
| POST | `/customer-groups/:id/import` | Upload .xlsx and enqueue job. Returns `{ jobId }` | `CustomerGroupPermission.import` |
| GET | `/customer-groups/:id/imports/:jobId` | Poll job status + totals | `CustomerGroupPermission.import` |
| GET | `/customer-groups/:id/imports/:jobId/result.xlsx` | Signed-URL redirect to result Excel | `CustomerGroupPermission.import` |

### Space access (extends existing controller)

| Method | Path | Purpose | Permission |
|---|---|---|---|
| PATCH | `/spaces/:id/access` | `{ accessMode: 'public' | 'restricted', customerGroupIds: number[] }` | `SpacePermission.edit` |

### Request / response examples

**POST `/customer-groups`**

```json
// request
{ "name": "Compound A — Residents", "description": "Verified residents (2026)" }

// response 201
{
  "id": 42,
  "tenantId": 17,
  "name": "Compound A — Residents",
  "description": "Verified residents (2026)",
  "memberCount": 0,
  "createdAt": "2026-05-31T10:14:22Z"
}
```

**POST `/customer-groups/:id/import`**

```json
// request: multipart/form-data with file=<xlsx>
// response 202
{ "jobId": "imp_8c1f9", "status": "queued" }
```

**GET `/customer-groups/:id/imports/:jobId`**

```json
// response 200 (in progress)
{
  "jobId": "imp_8c1f9",
  "status": "processing",
  "rowsProcessed": 412,
  "rowsTotal": 1000,
  "totals": { "created_new": 0, "attached_existing": 0, "already_in_tenant": 0,
              "already_member": 0, "error": 0 }
}

// response 200 (completed)
{
  "jobId": "imp_8c1f9",
  "status": "completed",
  "rowsProcessed": 1000,
  "rowsTotal": 1000,
  "totals": { "created_new": 312, "attached_existing": 588, "already_in_tenant": 67,
              "already_member": 4, "error": 29 },
  "resultUrl": "/customer-groups/42/imports/imp_8c1f9/result.xlsx"
}
```

**PATCH `/spaces/:id/access`** (`Restricted` mode)

```json
// request
{ "accessMode": "restricted", "customerGroupIds": [42, 51] }

// response 200
{ "id": 88, "accessMode": "restricted", "customerGroups": [
    { "id": 42, "name": "Compound A — Residents" },
    { "id": 51, "name": "Compound A — Tennis Academy" }
]}
```

### Error responses

| Status | Code | When |
|---|---|---|
| 400 | `INVALID_INPUT` | Validation failed (e.g. name length, body shape) |
| 400 | `CUSTOMER_GROUP_NAME_TAKEN` | Duplicate name within tenant |
| 400 | `RESTRICTED_REQUIRES_GROUPS` | Save `Restricted` space with empty `customerGroupIds[]` |
| 400 | `IMPORT_FILE_INVALID` | Not a valid .xlsx |
| 400 | `IMPORT_HEADERS_INVALID` | Header mismatch |
| 400 | `IMPORT_TOO_LARGE` | > 10k rows |
| 409 | `IMPORT_IN_PROGRESS` | Tenant already has an in-flight import |
| 403 | `SPACE_NOT_AVAILABLE` | Non-member targets a restricted space (cart add, slots pricing, experience detail, booking) — see "Client error contract" below |
| 404 | `CUSTOMER_GROUP_NOT_FOUND` | Group doesn't exist or is in another tenant |
| 500 | `INTERNAL_ERROR` | Unexpected |

#### Client error contract — `SPACE_NOT_AVAILABLE`

```http
HTTP/1.1 403 Forbidden
Content-Type: application/json

{ "statusCode": 403, "message": "Forbidden", "code": "SPACE_NOT_AVAILABLE" }
```

This error is **the discriminated signal** for end-user clients (mobile, customer web, white-label) that the resolved space is not accessible to the caller — either because they are a guest viewing a restricted space, or a logged-in user who is not a member of any group attached to the space. The semantic is **"not available to you"**, not **"system error"** and not **"resource missing"**.

**Client UX contract** (mobile + web teams MUST honour before launch):

- On `403 + code: SPACE_NOT_AVAILABLE` from any cart, pricing, or experience-detail call → render a clean **"this space isn't available to you"** empty state. Do NOT show a generic error toast.
- On shared-link / deep-link landing → same empty state. Do NOT redirect to a 404 page (would falsely suggest the space doesn't exist).
- The empty state may optionally surface a "request access" CTA per tenant configuration (V2; out of scope here).
- Treat any other 4xx code from these endpoints as a real error (toast / inline error).

**Server contract** (this PR honours):

- Raised via `throw new ForbiddenException({ code: 'SPACE_NOT_AVAILABLE' })`.
- Body shape verified by the contract test at `libs/space/.../utils/space-visibility-contract.spec.ts` (JS↔SQL parity) and the per-handler integration tests.
- Admin contexts never raise this code because admin code paths omit the `visibleToUserId` filter (sentinel `undefined`) and therefore receive every space from the find.

---

## Data Model

### `customer_group`

| Field | Type | Key | Purpose |
|---|---|---|---|
| `id` | int / serial | PK | |
| `tenant_id` | int | FK→`tenant.id`, NOT NULL | Tenant scoping; indexed |
| `name` | varchar(60) | | Display name |
| `description` | varchar(280) NULL | | Optional |
| `created_at`, `updated_at`, `deleted_at` | timestamp | | Standard `EntityHelper` columns |

**Indexes**:

- Unique: `(tenant_id, lower(name))` WHERE `deleted_at IS NULL` — enforces in-tenant case-insensitive uniqueness on active rows.
- Index: `(tenant_id)` — lists.

### `customer_group_member`

| Field | Type | Key | Purpose |
|---|---|---|---|
| `customer_group_id` | int | PK + FK→`customer_group.id` ON DELETE CASCADE | |
| `user_id` | int | PK + FK→`user.id` ON DELETE CASCADE | |
| `added_at` | timestamp NOT NULL | | |

**Intentionally no `added_by` or `added_via` columns.** Actor + source-channel are captured by the `CustomerGroupMemberAdded` event into the MongoDB audit-trail surface. Storing them on the row would be duplicating an already-audited fact and would invite drift between the row and the audit. Reverse query "who added user X to group Y?" is a Mongo audit query.

**Indexes**:

- PK is `(customer_group_id, user_id)` — primary lookup.
- Secondary: `(user_id)` — reverse lookup ("which groups is this user in for this tenant?"); critical hot path for the access guard and listing filter.

### `space_customer_group`

| Field | Type | Key |
|---|---|---|
| `space_id` | int | PK + FK→`space.id` ON DELETE CASCADE |
| `customer_group_id` | int | PK + FK→`customer_group.id` ON DELETE CASCADE |
| `created_at` | timestamp NOT NULL | |

**Indexes**:

- PK is `(space_id, customer_group_id)`.
- Secondary: `(customer_group_id)` — used by `SpaceAccessRevertSaga` to find affected spaces when a group is soft-deleted.

### `space` (column add)

| Field | Type | Key | Purpose |
|---|---|---|---|
| `access_mode` | enum('public','restricted') NOT NULL DEFAULT 'public' | — | Per PRD US-4 |

### `customer_group_import_audit`

| Field | Type | Key | Purpose |
|---|---|---|---|
| `id` | int / serial | PK | |
| `job_id` | varchar(40) UNIQUE | | External job id (`imp_<nanoid>`) |
| `tenant_id`, `customer_group_id`, `admin_id` | int | FK | |
| `s3_upload_key`, `s3_result_key` | varchar NULL | | S3 locations |
| `status` | enum('queued','processing','completed','failed') | NOT NULL | |
| `rows_total`, `rows_processed` | int | | |
| `totals_json` | jsonb | | Counts per outcome bucket |
| `error_message` | text NULL | | When `status='failed'` |
| `created_at`, `updated_at` | timestamp | | |

Mirrors the shape of the existing `user_export_audit` (referenced in research, pattern from `user-map-export.processor.ts`).

### Access patterns

| Access pattern | Query | Index used |
|---|---|---|
| List restricted spaces visible to user X on tenant T | `space LEFT JOIN space_customer_group sg ON …` + `IN (SELECT customer_group_id FROM customer_group_member WHERE user_id = X)` filtered by `s.access_mode='public' OR sg.customer_group_id IN (...)` | `space_customer_group(space_id)`, `customer_group_member(user_id)` |
| Reverse lookup on group soft-delete | `SELECT space_id FROM space_customer_group WHERE customer_group_id = G` | `space_customer_group(customer_group_id)` |
| Phone dedup at import | Existing `user(phone_number)` unique partial index | (existing) |
| Group uniqueness on create | `customer_group(tenant_id, lower(name))` partial unique | (new) |

---

## API surface impact (every endpoint that touches spaces — direct or derived)

This section enumerates **every** end-user-facing API surface that currently returns space data (or anything derived from space data) and specifies the exact access-filter treatment. Three user states drive the predicate; one filter helper drives the SQL; one rule covers facets.

### Three user states

| State | Authenticated? | Tenant relation | Access predicate |
|---|---|---|---|
| **Member** | yes | `TenantUser` exists AND member of ≥1 group attached to the space | sees public spaces + every restricted space whose attached group set intersects the user's group memberships |
| **In-tenant non-member** | yes | `TenantUser` exists, no relevant group membership | sees public spaces only |
| **Guest** | no | n/a | sees public spaces only |

### The filter SQL handles all three uniformly

`SpaceVisibilityFilter` is parameterised on a **nullable** `userId`:

```sql
WHERE space.deleted_at IS NULL
  AND space.status = true
  AND (
    space.access_mode = 'public'
    OR ( :userId IS NOT NULL
         AND space.id IN (
           SELECT sg.space_id
             FROM space_customer_group sg
             JOIN customer_group_member m ON m.customer_group_id = sg.customer_group_id
            WHERE m.user_id = :userId
         )
    )
  )
```

When `:userId IS NULL` (guest), the OR-arm collapses to false and only public spaces survive. No special-case code path; one query covers all three states.

### Per-API impact

**Admin APIs do NOT apply the filter.** Tenant admins and super admins manage all spaces (restricted or not) — restriction is an end-user concept. The filter is wired only into the four user-facing apps below.

#### `spark-mobile-api` (logged-in users + guests via `@PassGuestUser()`)

| Endpoint | Today returns | Treatment | Notes |
|---|---|---|---|
| `GET /v1/locations/:id/spaces` | Spaces in location | **Apply `SpaceVisibilityFilter`** | Hot path; primary listing surface |
| `GET /v1/locations/:id/slots` | Per-space slots + pricing | **Pre-filter `spaceIds` through `SpaceVisibilityFilter` before slot generation** | Don't generate slots for spaces the caller can't see |
| `POST /v1/locations/slots/pricing` | Aggregate pricing for `spaceIds[]` | **Reject (`SPACE_NOT_AVAILABLE`) if any requested `spaceId` is invisible** | Prevents "price probing" of restricted spaces |
| `GET /v1/locations` / `:id` | Locations only (no embedded space list today) | **Verify and treat: if response computes embedded space counts, route them through the filter** | Inspect `LocationTransformer` for `spaceCount` / `availableSpaces` fields |
| `GET /v1/bookings` / `:id` | The user's own bookings (which include space data) | **No filter** | A user's own historical bookings reference spaces they had access to at booking time; do not retroactively hide them. Future booking on a space the user lost access to is OK to surface — display normally; cancel-vs-honor is governed by the existing booking lifecycle, not by this PRD (per PRD US-7 AC). |
| `GET /v1/tenants` / `:id` | Tenants only | **No filter on tenant fields** — but if `TenantTransformer` exposes any `spaceTypes` / `availableSports` derived from spaces, route those through the facet filter (below) |
| `GET /v1/core/categories` | Sport / event categories | **Facet filter** (see § Facet endpoints below) |

#### `spark-external-client-api` (white-label / third-party — same `@PassGuestUser()` pattern)

Mirror of mobile-api at every endpoint listed above. **Wire the same `SpaceVisibilityFilter` and the same facet treatment.** External-client is the highest-leak-risk surface because it's the most likely place for restricted spaces to slip into a partner's product without anyone noticing — explicitly include this app in pen-test scope (Hakim).

#### `spark-tenant-admin-api`

**No filter.** Tenant admins manage restricted spaces — they need to see and edit them. The `PATCH /v1/spaces/:id/access` endpoint added by this PRD lives here.

#### `spark-super-admin-api`

**No filter.** Super-admins see everything cross-tenant. Restricted-space behaviour is logged in the super-admin space-detail view ("This space is restricted to groups: A, B") for support purposes.

### Facet endpoints — the trap

The user-callout was precise: *"if we have space types array that the user can see this should be affected by types as well"*. Every endpoint that returns a **derived collection** from spaces (distinct space types, available categories, amenity buckets) **must apply the same filter at the derivation step** — otherwise a non-member sees "Tennis" listed as an available type, taps it, and gets an empty result, leaking the existence of restricted tennis courts.

| Endpoint | App | What it returns today | New treatment |
|---|---|---|---|
| `GET /v1/core/space-types` | tenant-admin | distinct space types across the tenant | No change for tenant-admin. Mirror endpoint NOT exposed on mobile/external-client today; if added later, derive from `space` joined through `SpaceVisibilityFilter`. |
| `GET /v1/core/categories` | mobile + external + admin | sport/event categories | **End-user surfaces**: derive the set from spaces visible to the caller, not from the global category catalog. Same join through `SpaceVisibilityFilter`. **Admin surfaces**: unchanged (return global catalog). |
| `GET /v1/core/amenities` | admin only today | global amenities | No change today. If a mobile/external surface is added later, apply the filter. |
| `GET /v1/core/tags` | admin only today | global tags | Same as amenities. |
| `GET /v1/locations` | mobile + external | locations | If `LocationTransformer.spaceTypes` / `availableSports` array is computed from underlying spaces, **drive the computation through `SpaceVisibilityFilter`** so the array reflects only what the caller can see. |
| `GET /v1/locations/:id` | mobile + external | location detail | Same as above for embedded facet arrays. |
| `GET /v1/tenants/:id` | mobile + external | tenant detail | Same as above. |

#### Facet rule (the one principle)

> **Any derived collection that is a function of the space set must be derived from the *visible* space set, not the full space set.**

This is the trap operator and reviewer should bake into the code-review checklist: *"is this response a function of spaces? if yes, did you go through `SpaceVisibilityFilter`?"*

Implementation pattern — every facet query computes against the visible-spaces subquery:

```sql
-- "categories available to this caller in this tenant"
SELECT DISTINCT c.*
  FROM category c
  JOIN space_category sc ON sc.category_id = c.id
  JOIN space s ON s.id = sc.space_id
 WHERE s.tenant_id = :tenantId
   AND (
     s.access_mode = 'public'
     OR ( :userId IS NOT NULL
          AND s.id IN (
            SELECT sg.space_id FROM space_customer_group sg
              JOIN customer_group_member m ON m.customer_group_id = sg.customer_group_id
             WHERE m.user_id = :userId
          )
     )
   )
```

Centralised as a `SpaceVisibilityFacetHelper` that wraps the SELECT-DISTINCT-over-visible-spaces pattern so feature facets (`getAvailableCategoriesForCaller`, `getAvailableSpaceTypesForCaller`, etc.) only differ by the joined facet table.

### Booking entry points — action-side enforcement (filter-in-find)

> **Revision (AgDR-0011, US-6 build phase)**: the earlier draft of this section described a `SpaceAccessGuard` (`CanActivate`) on `POST /v1/bookings`. Audit during US-6 found there is no `POST /v1/bookings` endpoint and no `GET /v1/spaces/:id` on mobile-api or external-client-api — bookings are cart-mediated and the user payload is `slotIds: string[]` decoded server-side. Layer 2 is therefore enforced by **populating `visibleToUserId` on the existing `spaceRepository.findOne` / `findMany` call** inside each handler that resolves user input into spaceIds. The find returns `null` / a shorter result when the caller can't see the space; the handler raises 403 `SPACE_NOT_AVAILABLE`. The semantic ("every action that resolves a spaceId from user input re-runs the visibility predicate") is preserved, and admin code paths bypass naturally by omitting the filter (sentinel `undefined`).

Surfaces that populate `visibleToUserId` on their existing find:

- `AddCartItemFacade.addToCart` (libs/cart) slot path — `findMany({ids, visibleToUserId})` + length check; the visible set is reused for type-dispatch, so what was two queries becomes one.
- `ExperiencesService.findById` (mobile-api) — covers `GET /v1/experiences/:id` and `GET /v1/experiences/:id/slots` (the slots endpoint calls `findById` internally).
- `ExperiencesService.findSlotsPricing` (mobile-api) — covers `POST /v1/experiences/:id/slots/pricing`.
- `POST /v1/locations/slots/pricing` (mobile + external) — currently uses the `assertSpacesVisibleToUser` helper from #712; PR-2 of US-6 inlines it into the same filter-in-find shape.

Cart `checkout` does NOT need a re-check — every line was already filter-validated at add-time. Group-membership-loss-between-add-and-checkout is governed by US-7's lifecycle, not by Layer 2.

`AddSessionCartItemStrategy` (event-session adds) does NOT apply Layer 2 in PR-1 of US-6 — sessions on space-bound events are revisited in a follow-up.

### Aggregate read pattern (counts, "available now", featured)

| Pattern | Today | Treatment |
|---|---|---|
| Space counts in tenant detail | If returned, computed from `space` table | Compute through `SpaceVisibilityFilter` |
| "X spaces available" badges on listings | Counted on the unfiltered set | Compute through `SpaceVisibilityFilter` |
| Featured / trending / "popular" | Curated server-side | Filter the curated list through `SpaceVisibilityFilter` before returning |
| Search autocomplete with space names | If exposed to end-user surfaces | Filter through `SpaceVisibilityFilter` |

If any of these surfaces is added in a future feature, the same rule applies — and the Layer-2 guard on the action surface catches any leak even if the listing/facet filter is forgotten.

### Test surface

Per-app E2E coverage required before launch:

- **mobile-api**: member sees / non-member doesn't / guest doesn't — for listings, slots, pricing, categories facet, location detail.
- **external-client-api**: identical matrix as mobile-api, plus partner-context edge cases (the white-label calling environment).
- **tenant-admin-api**: admin always sees (regression test).
- **super-admin-api**: super-admin always sees (regression test).
- **Action surface (booking)**: member books OK, non-member 403, guest 403, in-tenant non-member 403.
- **Facet surface (categories)**: a tenant with one public tennis court + one restricted tennis court → public-caller sees "Tennis" only because of the public court (caller still gets it); a tenant with zero public tennis courts + one restricted tennis court → non-member does NOT see "Tennis" in categories.

### Implementation deltas to the plan

Update the implementation plan with these additional tasks:

| # | Task | Estimate | Dependencies |
|---|---|---|---|
| 10a | `SpaceVisibilityFilter` accepts nullable `userId` (guest case) | included in #10 | 9 |
| 10b | `SpaceVisibilityFacetHelper` — SELECT-DISTINCT-over-visible-spaces wrapper | 4h | 10 |
| 10c | Refactor `/v1/core/categories` mobile + external handlers to use the facet helper | 3h | 10b |
| 10d | Audit `LocationTransformer` + `TenantTransformer` for embedded `spaceTypes` / `spaceCount` / `availableSports` arrays; route any found through the visible-space derivation | 4h | 10b |
| 10e | Wire `SpaceVisibilityFilter` into mobile-api: `locations/:id/spaces`, `locations/:id/slots`, `locations/slots/pricing` | 3h | 10 |
| 10f | Wire `SpaceVisibilityFilter` into external-client-api: same three endpoints | 3h | 10 |
| 11a | `SpaceAccessGuard` on booking endpoints (mobile + external) — extension of #11 | included in #11 | 11 |
| 22a | E2E matrix per app (mobile + external) — three user states × five surface types | 8h | 10e, 10f, 11a |

---

## Access enforcement (defence-in-depth)

This is the load-bearing security design. **Three layers, all required**.

### Layer 1 — listing-query filter (UX)

Every listing query that returns spaces to an end user (mobile, website, tenant page, search, deeplink resolution) acquires this predicate, injected centrally via a shared `SpaceVisibilityFilter` query helper in `libs/space`:

```sql
WHERE space.deleted_at IS NULL
  AND space.status = true
  AND (
    space.access_mode = 'public'
    OR space.id IN (
      SELECT sg.space_id
      FROM space_customer_group sg
      JOIN customer_group_member m ON m.customer_group_id = sg.customer_group_id
      WHERE m.user_id = :userId
    )
  )
```

This is the **single source of truth** at the query layer. Every existing listing query handler is refactored to use the helper — no copy-paste of the predicate.

### Layer 2 — filter-in-find (defence-in-depth)

> Revised in AgDR-0011 (US-6 audit): originally specified as a NestJS guard, briefly implemented as a separate handler-level assertion, then collapsed to **filter-in-find** — pass `visibleToUserId` on the existing `spaceRepository.findOne` / `findMany` call inside each handler. One mechanism for Layer 1 + Layer 2; no extra query; admin bypass is the natural sentinel-`undefined` behaviour.

Every end-user handler that resolves a `spaceId` from user input populates `visibleToUserId` on its existing find — see § "Booking entry points" above for the canonical list. When the filtered find returns `null` (or a result shorter than the requested batch) the handler raises `ForbiddenException({ code: 'SPACE_NOT_AVAILABLE' })`, mapped to HTTP **403** with body `{ code: 'SPACE_NOT_AVAILABLE' }`.

Admin code paths in `spark-tenant-admin-api` and `spark-super-admin-api` **omit** the filter — the sentinel `undefined` means "no filter, return everything". Admins see every space, regardless of access mode.

Rationale: **403, not 404.** Returning 404 would falsely imply the space doesn't exist, complicating tenant-admin debugging ("the user says they get 404 but I can see the space exists"). 403 with a distinct code lets the mobile client either silently retry (e.g. if membership changed) or surface a clean "this space isn't available to you" empty state if a user lands on a shared link.

### Layer 3 — persistence-layer scoping (safety net)

All `customer_group*` queries are tenant-scoped at the repository layer (not just at the API layer). The repository constructor receives `ContextProvider.getTenant()` and stamps `tenantId` on every read. This prevents a controller bug from accidentally exposing one tenant's groups via a different tenant's endpoint.

### Why all three

| Bug class | Layer that catches it |
|---|---|
| Listing accidentally exposes restricted space to non-member | Layer 1 |
| User crafts direct API call with `spaceId` from a shared link | Layer 2 |
| Tenant-admin endpoint queries the wrong tenant (controller bug) | Layer 3 |
| Listing helper not used in a future new listing endpoint | Layer 2 backstop |

### Performance budget

NFR target: listing query P95 < 250 ms; access filter adds ≤ 1 indexed join.

The subquery in Layer 1 is a small `IN (SELECT …)`. Postgres planner will turn this into a semi-join driven by `customer_group_member(user_id)`. For a user with up to ~50 group memberships across tenants (a generous upper bound), the inner result set is tiny and the outer space scan is unaffected. Load test against a tenant with 10k+ users, 50+ spaces, and 10+ active groups before sign-off.

If the subquery shows up hot in profiling, fallback plan: rewrite as an explicit `LEFT JOIN` on `space_customer_group` + `customer_group_member` filtered by `user_id`, which the planner sometimes prefers — but only after measurement.

---

## Phone normalisation (AgDR)

See `docs/agdr/AgDR-0007-phone-normalisation.md` (in `workspace/booking-system/docs/agdr/`, created alongside this design).

Summary: use `libphonenumber-js/min` (already lean; ~150KB), wrap in `NormalisedPhone` VO, require a tenant-default country code (new field on `tenant.default_country_code`; backfill `'EG'` for all existing tenants — Spark is Egypt-primary). Reject unparseable rows at import with a per-row `error: invalid phone format`.

Open question for product: do we want to fail the import row when the phone is valid for a different country than the tenant default, or accept any valid E.164? **Lean: accept any valid E.164** (lets a compound tenant ingest foreign residents).

---

## Access enforcement (AgDR)

See `docs/agdr/AgDR-0008-restricted-space-access-enforcement.md` — captures the three-layer defence-in-depth rationale + the 403-vs-404 choice.

## Bull import job shape (AgDR)

See `docs/agdr/AgDR-0009-customer-group-import-job-shape.md`.

Summary: one queue (`CUSTOMER_GROUP_IMPORT_QUEUE`), one processor, single concurrency per tenant (Bull job lock keyed on `tenantId`). Job payload references an S3 buffer rather than embedding the file (Bull-queue payload size + Redis memory). Result Excel written to S3 with a 7-day TTL signed URL. Audit row in Postgres for status polling — Bull's own job state is not the API.

Idempotency: re-importing the same file is safe because (a) `CreateUserAndAddToTenantCommand` is `createOrIgnore` on `(tenantId, userId)`, and (b) the new `AddMemberToCustomerGroupCommand` is `createOrIgnore` on `(customerGroupId, userId)`. The processor only logs the outcome per row; it never inserts duplicates.

In-upload dedup: a `Set<string>` keyed on normalised E.164 within the job catches the same phone appearing twice in one file — the first wins, the second gets `error: duplicate in upload`.

Failure handling: a single row's failure does not abort the job (per-row try/catch around `CreateUserAndAddToTenantCommand`). A file-level failure (e.g. parser exception) marks the audit row `failed` with the error message.

---

## Implementation Plan

Each line below maps to a sub-issue to be filed after this design is approved (under epic apessolutions/booking-system#707).

| # | Task | Estimate | Dependencies |
|---|---|---|---|
| 1 | Migration: add `tenant.default_country_code` + backfill 'EG' | 2h | — |
| 2 | New lib scaffold: `libs/customer-group` (module, layered folders, persistence module) | 3h | — |
| 3 | Migrations: `CreateCustomerGroupTables` + `CreateCustomerGroupImportAudit` | 3h | 2 |
| 4 | Domain: entities + VOs + events; mappers; repositories | 6h | 3 |
| 5 | Commands: create / rename / soft-delete (group) + add/remove member | 6h | 4 |
| 6 | Queries: list groups / get detail / list members / search-by-name | 4h | 4 |
| 7 | `NormalisedPhone` VO + AgDR-0001 implementation (`libphonenumber-js`) | 3h | — |
| 8 | Migration: `AddSpaceAccessMode` + `CreateSpaceCustomerGroupJoin` | 3h | — |
| 9 | Extend `Space` entity + domain + mapper + `SpaceCustomerGroup` join entity | 4h | 8 |
| 10 | `SpaceVisibilityFilter` helper + refactor ALL existing listing queries to use it | 8h | 9 |
| 11 | `SpaceAccessGuard` + wire onto space-detail and booking endpoints (all apps) | 6h | 9 |
| 12 | PATCH `/spaces/:id/access` endpoint + validation | 3h | 9 |
| 13 | `customer-group-import.processor.ts` (Bull) + audit table writes + per-row outcomes | 8h | 5, 7 |
| 14 | POST/GET import endpoints + S3 upload helper + signed-URL result | 6h | 13 |
| 15 | `GetCustomerGroupImportTemplate` query (3-col sample xlsx) | 2h | — |
| 16 | `SpaceAccessRevertSaga` + email notification on auto-revert | 5h | 5, 11 |
| 17 | New `CustomerGroupPermission` enum + wire into `TenantAdminAuth` decorators | 2h | — |
| 18 | Frontend: customer-groups list / detail / member CRUD / import flow | 16h | 5, 6, 13–15 |
| 19 | Frontend: space edit Access section (mode toggle + group multi-select) | 6h | 12 |
| 20 | Unit tests (domain + commands + saga) — coverage > 80% on `libs/customer-group` | 10h | 4–6, 16 |
| 21 | Integration tests for the import processor (xlsx fixtures: happy, partial, malformed) | 6h | 13 |
| 22 | End-to-end test: create group → import → restrict space → non-member 403 → member 200 | 6h | all above |
| 23 | Load test: 10k-user tenant, 50+ spaces, restricted query path P95 | 4h | 10 |
| 24 | Pen-test sign-off on access boundary (Hakim) | external | all above |

**Total backend + frontend: ≈ 122h**, ~3 engineer-weeks at one backend + one frontend overlap.

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Listing-query refactor regresses public-space P95 | Med | High | All listing queries flow through the helper; load test before sign-off; revert path is a single helper change |
| New listing endpoint added later forgets the access filter | High | High (leak) | `SpaceAccessGuard` (Layer 2) catches it at the action surface even if Layer 1 forgot. Lint rule (eslint custom rule) flagged as a follow-up — out of scope for V1 |
| Phone normalisation rejects locally-formatted Egyptian numbers some tenants use | Med | Med | E.164 strict + tenant-default country code handles "01XXXXXXXXX" correctly via `libphonenumber-js`. Manual QA on real tenant Excel files before rollout |
| Bull processor death mid-job leaves the audit row in `processing` forever | Low | Med | Heartbeat: processor updates `rows_processed` every 100 rows. Audit row in `processing` with no heartbeat > 30 minutes → reaper marks `failed` |
| Saga auto-revert nukes a restricted-space's access without admin awareness | Med | Med | Email notification on every auto-revert; affected spaces listed in the email. Considered (rejected) alternative: block group delete |
| Large imports lock a tenant's other admins out of the feature | Low | Low | Per-tenant concurrency = 1 + `IMPORT_IN_PROGRESS` 409; admin sees clear "wait for current import to finish" message |
| Country-code mismatch (foreign phone in a default-EG tenant) | Med | Low | Accept any valid E.164 (per AgDR-0001 lean); per-row error only on truly unparseable input |
| TypeORM `softDelete` cascade behaviour on `space_customer_group` differs from what the saga expects | Med | High | Explicit hard-`DELETE` in saga rather than relying on cascading soft-delete; integration test covers it |

---

## Security Considerations

- [x] Authentication required on all customer-group endpoints (`@TenantAdminAuth(...)`)
- [x] Authorisation: tenant-scoped at repository (Layer 3), enforced again at controller (Layer 2)
- [x] Input validation: VOs (`NormalisedPhone`, `CustomerGroupName`) at every entry point
- [x] **Restricted-space access**: defence-in-depth (Layer 1 query filter + Layer 2 guard)
- [x] Excel parsing runs in the worker, not the API. Malicious .xlsx (zip-bomb, formula injection) is contained to the Bull worker; output result.xlsx escapes formula prefixes (`=`, `+`, `-`, `@` → prefix with `'`)
- [x] PII: phone/name/last-name are existing collection categories. No new PII collected.
- [x] S3 upload paths: per-tenant prefix, server-side encryption, 7-day result-file TTL via lifecycle policy
- [x] Pen-test sign-off (Hakim) required pre-launch — Layer 1 bypass + direct-API attack on Layer 2 are the headline cases

---

## Testing Strategy

| Type | Coverage | Notes |
|---|---|---|
| Unit | `libs/customer-group` 90%+ | All domain logic, VOs, saga, command handlers |
| Unit | `NormalisedPhone` 100% | E.164 normalisation behaviour matrix (EG local, EG E.164, foreign E.164, invalid) |
| Integration | Import processor | Fixtures: happy 100-row, header-mismatch, duplicate-in-file, mixed valid/invalid phone, > 10k rows |
| Integration | `SpaceAccessRevertSaga` | Two attached groups → delete one (no revert); delete last → revert + email |
| E2E | Critical path | Create group → import 10 rows → restrict space → non-member GET returns 403 → POST booking returns 403 → member sees + books |
| Load | Listing P95 | 10k-user tenant, 50 spaces, 10 groups, simulated active user with 3 memberships; assert P95 < 250ms |
| Adversarial | Layer 1 bypass | New listing endpoint added in a test, confirms Layer 2 still rejects |
| Adversarial | Cross-tenant | User in tenant A's group attempts booking on tenant B's restricted space |

---

## Open Questions

| Question | Owner | Status |
|---|---|---|
| Tenant-default country code: is there an existing `defaultCountry` on `tenant`, or do we add `default_country_code`? Confirm during scaffold. | Backend (#1 in plan) | Open |
| Should the audit `customer_group_import_audit.totals_json` schema be versioned for forward-compat? | Tech Lead | Open — lean yes (add `schema_version: 1`) |
| Country-code mismatch policy (foreign phone in default-EG tenant): accept any valid E.164 vs. reject? | Product | Open — lean accept |
| Confirm `space` has direct `tenantId` (the listing query in research used `space.tenantId`, but the column surface listed `locationId` only). If `tenantId` is derived through `location`, the access filter needs a join. | Backend (during #9) | Open |
| Should `CustomerGroupPermission` ship as a separate enum or extend `SpacePermission`? | Tech Lead | Open — lean separate |
| Email template for auto-revert notification — reuse existing tenant-admin alert template? | Frontend / Product | Open |
| `IMPORT_IN_PROGRESS` 409 — should an admin be able to cancel an in-flight job? | Product | Open — lean no, V2 |

---

## Approvals

| Role | Name | Date | Status |
|---|---|---|---|
| Tech Lead | Hisham | 2026-05-31 | Author |
| Head of Engineering | Khalid | | Pending (architecture sign-off — new lib + access-control pattern) |
| Security Auditor | Hakim | | Pending (access enforcement design) |
| Product Manager | Mariam | | Pending (open product questions above) |

---

## Spark-specific conventions applied

This design conforms to `workspace/booking-system/CLAUDE.md`:

- **App-side feature module** at `apps/spark-tenant-admin-api/src/app/customer-groups/` follows the controller → service → transformer split. No `commandBus.execute` from the controller; the service owns CQRS dispatch.
- **DTOs** live in `libs/contracts/.../customer-groups/`, end with `V1DTO` (e.g. `SparkCustomerGroupV1DTO`, `SparkCustomerGroupMemberV1DTO`, `SparkCustomerGroupImportStatusV1DTO`), are constructed via `new SparkCustomerGroupV1DTO(domainEntity)` — never object literals.
- **Transformer ownership**: `customer-groups/transformer/customer-group.transformer.ts` is the only place that constructs the customer-group DTOs. The space-access response uses the existing `space.transformer.ts` extended with one method.
- **Response shape**: list endpoints → `ResponseGenerator.generatePaginationFormat` with shared `PageOptionsDto`; single resource → `generateResourceFormat`. Swagger decorators paired accordingly.
- **Entity naming**: `CustomerGroupEntity`, `CustomerGroupMemberEntity`, `SpaceCustomerGroupEntity`, `CustomerGroupImportAuditEntity`. All extend `EntityHelper` from `@./common` → `id`, `createdAt`, `updatedAt`, `deletedAt` come for free.
- **Mapper**: `CustomerGroupMapper.toDomain()` (instance, async) + `CustomerGroupMapper.toPersistence()` (static).
- **Ports**: abstract classes at `application/ports/customer-group.repository.ts`; impl at `infrastructure/persistence/repositories/customer-group.repository.ts` as `CustomerGroupRelationalRepository`.
- **Function naming**: repository reads are `findOne`, `findManyWithPagination`, `findUsersByGroup`; derived/aggregate reads are `getCustomerGroupImportStatus`, `getMemberCount`; mutations are `createCustomerGroup`, `addMemberToCustomerGroup`, `softDeleteCustomerGroup`, `queueCustomerGroupImport`. No `do*` / `handle*` / noun-only.
- **`@Transactional()`** on every command handler that writes.
- **Path alias**: `@./customer-group` added to `tsconfig.base.json`; lib exports the public surface via `libs/customer-group/src/index.ts`.
- **Audit trail for membership changes** writes to the existing **MongoDB audit-trail** surface (matches Spark precedent), not Postgres. The import job's per-job audit stays in Postgres (`customer_group_import_audit`) because it powers a polled API; Mongo would be wrong for that hot path.
- **Migrations** generated via `npm run migration:generate -- --name <Name>` and live in the lib's `infrastructure/persistence/migrations/` folder; imports registered in `libs/database/src/lib/sources/data-source.ts`.
- **Frontend** uses the standard `DashboardContent` + `CustomBreadcrumbs` chrome; primary actions ("Import members", "New group") in the breadcrumbs `action` slot.

## Glossary

| Term | Definition |
|---|---|
| Hexagonal lib | A Spark library split into domain / application / infrastructure layers, mirrored from `libs/space`. Domain has no external dependencies; infrastructure adapts to TypeORM, Bull, etc. |
| `NormalisedPhone` VO | A value object that wraps `libphonenumber-js`. Holds the E.164 form + country, throws `InvalidPhoneError` on unparseable input. Single source of truth for phone normalisation. |
| Defence-in-depth (access) | Three independent layers (query filter, controller guard, repository scoping) that each enforce the access predicate, so a bug in one doesn't leak data. |
| `SpaceVisibilityFilter` | A reusable query helper that injects the public-or-member predicate into any space-listing QueryBuilder. Replaces ad-hoc `WHERE` clauses in existing listing handlers. |
| `SpaceAccessGuard` | A NestJS guard that re-runs the same predicate at the controller layer on space-detail and booking endpoints. The action-side enforcement of access. |
| `SpaceAccessRevertSaga` | A domain event handler that reacts to `CustomerGroupSoftDeleted` by detaching the group from all spaces and reverting any orphaned-restricted spaces back to public. |
| `createOrIgnore` | An existing repository pattern in Spark (e.g. `TenantUserRepository.createOrIgnore`) that inserts a row if it doesn't exist, otherwise no-ops. The backbone of import idempotency. |
| Import job | One Bull job per uploaded .xlsx. Owns one audit row in `customer_group_import_audit`, processes rows sequentially, emits one result Excel at completion. |
| Per-row outcome | One of `created_new`, `attached_existing`, `already_in_tenant`, `already_member`, `error`. Tracked individually so the admin can see and remediate partial imports. |
