# PRD: Super-Admin User Cluster Map

**Status**: Draft
**Author**: Abdelrahman Shahda (Product)
**Created**: 2026-05-10
**Last Updated**: 2026-05-10
**Backlog entry**: IDEA-002 — `projects/ideas-backlog.md`
**Target launch**: 2026-06-21 (≈ 6 weeks)

---

## Overview

### Problem Statement

Spark super-admins run cross-tenant marketing and comms campaigns (announcements, geo-targeted promos, new-venue launch outreach), but today there is no way to see *where* the user base actually is. Pulling a geo-segmented audience requires a one-off SQL request to engineering, which is slow, error-prone, and gates the marketing team on dev capacity. As Spark grows across cities, "everyone in a 5km radius of this venue" or "all users in Maadi" is becoming a weekly ask, and the current process does not scale.

We need a self-serve, map-first view that lets a super-admin visually see user density across all tenants, draw an arbitrary polygon on the map, see the users captured by that polygon, and export that list for use in marketing tooling.

### Target User

**Primary**: Spark super-admins on the marketing / growth side. They are platform-level (not tenant-scoped), trusted with cross-tenant PII, and currently rely on engineering to produce geo-segmented audiences.

**Secondary** (out of scope for V1): tenant admins who would want a tenant-scoped version of the same view. See Non-Goals.

### Goals

1. **Eliminate engineering-as-a-service for geo-segmented audiences.** A super-admin can produce a CSV of users in any drawn area without filing a ticket.
2. **Sub-5-minute self-serve from intent to export.** Open the map → draw → export request submitted, in under 5 minutes for a typical city-block area.
3. **Show density at every zoom level, accurately.** Cluster counts always sum to the true total of users on the map at the current viewport — no double-counting, no silent dropping.
4. **Cover ≥ 95% of "give me users in area X" requests for the first 90 days.** Tracked by counting how many such requests still flow through engineering after launch.
5. **Hand the marketing team an export pipeline they trust.** Reuse the existing booking-export pattern (Bull queue → `exceljs` → S3 → signed CDN link via email). Excel (.xlsx) output, completes within 10 minutes for up to 100k users in scope.

### Non-Goals (Out of Scope)

- **Tenant-admin scoping.** V1 is super-admin only. Tenant-scoped version is a candidate follow-up but is not in this PRD.
- **Saved / shared / named polygons.** V1 is session-only — close the tab, lose the polygon. Saved areas may follow.
- **Heatmap / choropleth alternative views.** V1 is point-cluster only.
- **Editing user data from the map.** Read-only. No bulk-tagging, no segmentation writes back to user records.
- **Push to CRM / segment tools.** V1 produces an Excel file; pushing that file into a marketing tool is the operator's job, not the system's.
- **Demographic / preference / engagement filters.** V1 lists users by location only; filtering by sport, last-booking, tenant, etc. is a follow-up.
- **Real-time live updates while the map is open.** Data is fresh on each query, not streamed.

### Success Metrics

#### Leading (first 4 weeks post-launch)

| Metric | Target | How Measured |
|---|---|---|
| Super-admins who use the map at least once | ≥ 80% of marketing super-admin accounts | Frontend analytics event on map load |
| Median time from page open → export request submitted | < 5 minutes | Frontend analytics, polygon-drawn → export-clicked timing |
| Cluster aggregate accuracy | 100% — sum of cluster counts = true filtered total | Automated reconciliation in QA + telemetry assert |
| Map first-paint with default viewport (country-level) | < 2 s p95 | Frontend RUM |
| Export job p95 completion (≤ 10k users) | < 60 s | Backend job telemetry |
| Export job p95 completion (≤ 100k users) | < 10 min | Backend job telemetry |

#### Lagging (months)

| Metric | Target | How Measured |
|---|---|---|
| Engineering tickets for ad-hoc geo audience extraction | ↓ 95% vs. pre-launch baseline (90-day window) | Issue label audit |
| Geo-targeted campaign volume (campaigns sent) | ↑ baseline established at +30 days, growth target reset at +60 days | Marketing tool reporting |
| Super-admin satisfaction with the audience workflow | ≥ 4 / 5 in post-feature survey | Internal NPS-style survey |

---

## User Stories

### US-1: See user density across the map

> As a super-admin, I want to open a map of all Spark users and see them clustered by density, so that I can immediately understand where the user base is concentrated without scrolling through lists.

**Acceptance Criteria**:

- [ ] When I open the user cluster map at default zoom (country level), I see clusters covering all users with at least one verifiable address.
- [ ] Each cluster displays the number of users it contains.
- [ ] The sum of all visible cluster counts equals the total number of users in the current viewport (no double-counting, no dropped users).
- [ ] Users without a geocodable address are excluded from the map and surfaced in a separate "N users without location" badge with a link to a list.

### US-2: Drill into a cluster by zooming

> As a super-admin, I want to click a cluster and zoom into it, so that I can see how density breaks down inside that area.

**Acceptance Criteria**:

- [ ] Clicking a cluster centers the map on it and zooms in by enough levels to break that cluster into its child clusters or individual user pins.
- [ ] At maximum zoom, individual users are shown as pins (not collapsed into a single cluster).
- [ ] Pin hover / click shows the user's name and email (no other PII at this stage).
- [ ] Zooming out re-clusters consistently — counts always reconcile to the same totals at every zoom level.

### US-3: Draw a polygon to select an area

> As a super-admin, I want to draw a freeform polygon on the map, so that I can capture an arbitrary geographic area that doesn't match any administrative boundary.

**Acceptance Criteria**:

- [ ] A "Draw polygon" tool is available in the map toolbar.
- [ ] I can place at least 3 vertices and close the polygon.
- [ ] As soon as the polygon closes, a side panel shows the count of users inside it and a sample list (first N).
- [ ] I can edit vertices, drag them, and the count updates live.
- [ ] I can delete the polygon and start a new one.
- [ ] Self-intersecting polygons are either auto-corrected or rejected with a clear message — no silent miscounts.

### US-4: List users inside the polygon

> As a super-admin, I want to see a paginated list of users inside my polygon, so that I can sanity-check who is included before exporting.

**Acceptance Criteria**:

- [ ] The side panel exposes a "View list" action that opens a paginated user table for users inside the active polygon.
- [ ] Columns: name, email, city/area, registered tenant(s), date joined.
- [ ] List is sortable by date joined and registered tenants.
- [ ] List handles up to 100k users without UI lockup (virtualised or server-paginated).

### US-5: Export polygon users as Excel

> As a super-admin, I want to export the users inside my polygon as an Excel file, so that I can use the list in our marketing/comms tools.

**Acceptance Criteria**:

- [ ] An "Export Excel" action is available on the side panel and on the list view (matching the existing **Bookings → Export Excel** UX in `apps/spark-super-admin-web/src/sections/bookings/bookings-list/menu-action.tsx`).
- [ ] Clicking export queues a Bull job (new `queue.user.export` queue, mirroring `queue.booking.export`) and shows a confirmation: "We'll email the download link to <my-email> when ready."
- [ ] The export email contains a signed CDN download link (via `s3Service.getTempLink()`), reusing the booking export's email-template pattern (`libs/mail/src/lib/mail-templates/booking/export-ready.hbs` adapted to a user variant).
- [ ] The output is an `.xlsx` file generated with `exceljs`, stored at `exports/users/{uuid}_{timestamp}.xlsx`, with human-readable column headers driven by a `user-export-headers.constants.ts` (mirroring `booking-export-headers.constants.ts`).
- [ ] Excel columns match the list columns plus a stable user ID.
- [ ] Empty polygons (0 users) refuse to export with an inline message rather than queueing an empty job.
- [ ] The job runs in batches (50-record fetches, 25-record transform batches with 50–100ms delays) — same throttling pattern as `booking-export.processor.ts` — to avoid DB strain.
- [ ] The job logs `adminId`, `adminEmail` (from `ContextProvider.getAuthAdmin()`), polygon coordinates, applied filters, and resulting row count, on start and completion. Same audit-via-logs approach as the booking export. (See FR-8 / OQ-05 for whether to upgrade to a dedicated audit table.)

### US-6: See cluster contents without zooming all the way

> As a super-admin, I want to click a cluster and inspect / export its contents without necessarily zooming to maximum, so that I can act on a cluster as a unit.

**Acceptance Criteria**:

- [ ] Clicking a cluster shows a hover/popover with: count, an "Inspect" action (opens the side panel with the cluster's users), and a "Zoom in" action.
- [ ] The "Inspect" path reuses US-4 and US-5 (list + export) with the cluster as the implicit selection.

### Edge Cases

| Scenario | Expected Behavior |
|---|---|
| User has no address / address fails geocoding | Excluded from the map; surfaced in a separate "N users without location" view. Never silently dropped. |
| User has multiple addresses (home + work) | Pin on primary address only. Documented in a tooltip on the map legend. |
| Polygon overlaps the antimeridian (rare in current geo footprint) | Reject with a clear message in V1. Documented as a known limitation. |
| Polygon contains > 100k users | Allow, but warn before queuing the export ("This polygon contains 142,318 users — export may take up to 15 minutes."). Reuse the booking-export batch throttling so DB load stays predictable. |
| Two super-admins draw overlapping polygons in parallel sessions | Independent — there is no shared state in V1. |
| User base grows past 1M total | Clustering must still render in < 2s p95 at country zoom. Performance budget assumed by Tech Design. |
| Address updated mid-export job | Snapshot at job-start time wins. CSV reflects the moment the job was queued, not the moment it ran. |
| Super-admin's session expires while the polygon is drawn | Polygon is lost (session-only — see Non-Goals). User is redirected to login; on return, map opens at default state. |

---

## Requirements

### Functional Requirements

| ID | Requirement | Priority | Notes |
|----|-------------|----------|-------|
| FR-1 | Cross-tenant cluster map of all geocodable Spark users, super-admin only | Must | Auth gate must be platform-role, not tenant-role |
| FR-2 | Cluster counts always reconcile to the true user total at the current viewport | Must | Aggregate accuracy is a launch blocker |
| FR-3 | Click-to-zoom on a cluster, recursing until individual user pins are visible | Must | |
| FR-4 | Polygon drawing tool with editable vertices, live count update | Must | |
| FR-5 | Side panel showing count + paginated list of users in a polygon or cluster | Must | List columns: name, email, city, tenant(s), date joined |
| FR-6 | Async **Excel (.xlsx)** export job, email-delivered signed CDN link. Implementation mirrors the existing booking export: Bull queue (`queue.user.export`) → `exceljs` → S3 (`exports/users/...`) → `s3Service.getTempLink()` → email template adapted from `export-ready.hbs`. | Must | Reuse, don't reinvent |
| FR-7 | "N users without location" badge + drill-in list | Must | Prevents silent data loss |
| FR-8 | Audit log of exports (who, when, polygon, row count) — at minimum via the structured logging pattern used by `booking-export.processor.ts`. Upgrade to a dedicated audit table is OQ-05. | Must | Compliance + abuse review |
| FR-9 | Cluster popover with Inspect + Zoom-in actions | Should | UX polish for US-6 |
| FR-10 | Sort + filter inside the side-panel list (by tenant, date joined) | Should | |
| FR-11 | Map data refresh on each query (no caching layer in V1) | Must | Per stakeholder ask. May revisit if perf budget breaches. |
| FR-12 | Saved / named polygons | Could | Future — explicitly Non-Goal for V1 |
| FR-13 | Tenant-admin tenant-scoped variant | Could | Future — explicitly Non-Goal for V1 |
| FR-14 | Engagement / demographic filters in the side panel | Could | Future — explicitly Non-Goal for V1 |

### Non-Functional Requirements

| Category | Requirement | Target |
|---|---|---|
| Performance | Map first-paint at country zoom | < 2 s p95 |
| Performance | Cluster recompute on pan/zoom | < 500 ms p95 |
| Performance | Polygon point-in-polygon query against full user base | < 1 s p95 for polygons under 200 vertices |
| Performance | Excel export job for ≤ 10k users | < 60 s p95 |
| Performance | Excel export job for ≤ 100k users | < 10 min p95 |
| Security | Authorization | Platform role only — must reject any tenant-scoped session, even with elevated tenant role |
| Security | PII handling | Map data and CSV both classify as user PII; access logged per FR-8 |
| Security | Export download links | Signed CDN URL via `s3Service.getTempLink()` (same primitive as booking export), single-recipient (no public sharing). Confirm/align expiry duration with the booking export's current setting. |
| Accessibility | Map controls (zoom, draw, edit) | Keyboard accessible; WCAG 2.1 AA where applicable |
| Accessibility | Side panel and list view | WCAG 2.1 AA |
| Compliance | Right-to-deletion | Deleted users disappear from the map and from in-flight exports queued before deletion |
| Observability | Aggregate accuracy assertion | Telemetry alert if sum-of-clusters ≠ filtered total |
| Observability | Export job lifecycle | Per-job span: queued → started → completed/failed, with row count and duration |

---

## Design

### User Flow

```
[Super-admin opens /admin/users/map]
    |
    v
[Map loads at country zoom, clusters rendered]
    |
    +--> [Pan / zoom] --> [Clusters recompute, counts reconcile]
    |
    +--> [Click cluster] --> [Popover: count, Inspect, Zoom in]
    |       |
    |       +--> [Inspect] --> [Side panel: list + export]
    |       |
    |       +--> [Zoom in] --> [Cluster expands into child clusters / pins]
    |
    +--> [Draw polygon tool]
            |
            v
        [Place vertices, close polygon]
            |
            v
        [Side panel: count + sample list]
            |
            +--> [Edit vertices] --> [Count updates live]
            |
            +--> [View full list] --> [Paginated table]
            |       |
            |       +--> [Export CSV] --> [Async job queued, email confirmation]
            |
            +--> [Delete polygon] --> [Back to map]
```

### Wireframes / Mockups

To be produced by UX + UI Design once this PRD is approved. See Open Questions OQ-04.

---

## Technical Notes

### Dependencies

| Dependency | Type | Status | Owner |
|---|---|---|---|
| Geocoding pipeline for user addresses | Internal | TBD — must verify coverage and freshness | Backend |
| Map provider (Mapbox / Google Maps / OSM) | External or internal choice | **Deferred to AgDR** — see OQ-01 | Tech Lead |
| Bull queue + `exceljs` + S3 + email pipeline used by the existing booking export | Internal | **Confirmed exists** (`libs/booking/src/lib/processors/booking-export.processor.ts`, `queue.booking.export`, `export-ready.hbs`). Reuse pattern verbatim with a `queue.user.export` queue and a user variant of the email template. | Backend |
| Super-admin role + auth | Internal | Exists | Platform |
| Frontend map + draw library (Mapbox GL Draw / Leaflet.draw / equivalent) | External | Tied to map provider decision | Tech Lead |

### Technical Constraints

- **Real-time / on-query data freshness.** No pre-aggregation cache for V1, per stakeholder direction. Backend must serve cluster aggregates on-demand at acceptable latency. If the perf budget can't be met without caching, raise it as an AgDR — do not silently introduce a cache.
- **Cross-tenant query path.** Super-admins query across all tenants; this is a different access pattern from the rest of the platform and may need indexing changes.
- **Map provider choice has cost + licensing implications.** Mapbox / Google Maps charge per map load and per-tile; OSM is free but operationally heavier. This is a Tech Lead AgDR, not a Product call.
- **Geocoding accuracy floor.** Whatever % of users are not currently geocodable must be measured and surfaced; if it is > 10% the marketing team's coverage target is in question.

---

## Launch Plan

### Rollout Strategy

- [x] **Internal-only feature flag.** Available to a single super-admin (the PM) for first-week dogfood, then to the full marketing super-admin group.
- [ ] All users at once (N/A — super-admin only feature)
- [ ] Phased rollout (N/A — small audience)
- [ ] Beta program first (covered by feature-flag dogfood above)

Day-zero playbook:

1. Feature-flag on for PM only on launch day.
2. Run 5 known-correct queries (e.g. "users in Maadi") and reconcile against the engineering-extracted CSVs from the previous month.
3. Open to 3 marketing super-admins on day 3 if reconciliation matches.
4. Open to all marketing super-admins on day 7 if no critical bugs.
5. Decommission the engineering-ticket-for-geo-audience workflow on day 14.

---

## Open Questions

| ID | Question | Owner | Status | Resolution |
|---|---|---|---|---|
| OQ-01 | Map provider — Mapbox / Google Maps / Leaflet+OSM? Cost, licensing, draw-tooling support, mobile parity. Becomes an AgDR. | Tech Lead | Open | |
| OQ-02 | What % of current users have geocodable addresses today? If < 90%, do we improve geocoding before launch or surface the gap? | Backend + Data | Open | |
| OQ-03 | Where does the multi-address "primary" rule live? Existing user model, or do we need a flag? | Backend | Open | |
| OQ-04 | UX/UI design timeline — wireframes by when? Component spec by when? | Head of Design | Open | |
| OQ-05 | Audit log retention policy for export records — 90 days? 1 year? Where does it live? | Security + Platform | Open | |
| OQ-06 | Antimeridian-crossing polygons — confirm V1 reject is acceptable for the current geo footprint. | Product | Open | |
| OQ-07 | Booking export currently handles 50-record fetch batches with 25-record transform sub-batches. Does that throughput meet the 100k / 10-min SLA for users, or do we need a tuned worker class for `queue.user.export`? | Backend | Open | |
| OQ-08 | Permission model — define `UserPermission.export` (or equivalent) mirroring `BookingPermission.export`. Which existing super-admin role gets it by default? | Platform + Security | Open | |

---

## Timeline

| Milestone | Target Date | Status |
|---|---|---|
| PRD Approved | 2026-05-17 | Draft |
| Tech Design + AgDR (map provider) | 2026-05-24 | Pending |
| UX wireframes + UI design | 2026-05-31 | Pending |
| Dev Complete (FR-1 to FR-8) | 2026-06-14 | Pending |
| QA Complete | 2026-06-19 | Pending |
| Internal dogfood (PM-only) | 2026-06-21 | Pending |
| Marketing super-admin rollout | 2026-06-28 | Pending |
| Engineering geo-ticket workflow decommissioned | 2026-07-05 | Pending |

---

## Approvals

| Role | Name | Date | Status |
|---|---|---|---|
| Product Manager | Abdelrahman Shahda | 2026-05-10 | Author |
| Head of Product | | | Pending |
| Tech Lead | | | Pending |
| Head of Design | | | Pending |
| Head of Security | | | Pending — PII access review |
