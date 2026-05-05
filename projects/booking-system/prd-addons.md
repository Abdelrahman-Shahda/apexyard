# Addons — PRD Companion (v1)

**Source of truth:** [Addons — Feature Specification (v1)](https://apessolutions.atlassian.net/wiki/spaces/SPARK/pages/1091371013/Addons+Feature+Specification+v1) (Confluence, last updated 2026-04-20).

**Backlog entry:** IDEA-001 — `projects/ideas-backlog.md`.

**Owner:** Shahda (Product) · **Status:** Draft pending engineering review · **Target launch:** 2026-04-27 (1 week).

This file is a deliberately short companion that fills the three sections the Confluence spec doesn't cover — **Goals**, **Success Metrics**, **Open Questions** — plus a calendar-anchored timeline. Everything else (problem statement, user stories, business rules, data model, worked examples, hook lifecycle, phased rollout, deferred scope, decision log) lives in Confluence. Don't duplicate — link and update there.

---

## Goals

1. **Ship ancillary revenue on Spark bookings.** Tenants can configure, price, and sell priced items tied to a booking without operating outside the platform.
2. **Unblock the 2 waiting tenants on video recording by 2026-04-27.** Both have a defined business need; both are the canary for the integration model.
3. **Prove the integration contract once.** One reference integration (video recording) exercises all five hook events end-to-end so future partners can be onboarded without redesigning the lifecycle.
4. **Unlock upsell for new tenants.** Sales can lead with "video recording + platform" as a bundle from 2026-04-28 onward.
5. **Keep the ledger auditable.** Line-item transactions per booking-addon so revenue, refunds, and future revenue-share reporting are queryable without migration.

## Success Metrics

### Leading (first 2 weeks post-launch)

- 2 waiting tenants live on video recording within 7 days of launch.
- `PRE_PURCHASE` hook success rate ≥ 99% per booking containing a video-recording addon.
- Async hook (`POST_CONFIRMATION`, `POST_CANCELLATION`, `POST_NO_SHOW`, `POST_ADDON_REMOVED`) failure rate < 1% per event type.
- Median time for a tenant admin to configure their first addon < 15 minutes from dashboard entry to first successful checkout test.
- Zero payment-split regressions in existing Spark bookings without addons.

### Lagging (weeks–months)

- N new tenants acquired where "video recording" is cited by sales in the deal notes. Target baseline established after 30 days.
- Retention on the 2 launch tenants at 90 days (proxy for "the integration actually worked in production").
- Ancillary revenue per booking with ≥1 addon attached, tracked monthly.
- Second integration partner onboarded with no code-level change to the hook registry contract.

## Timeline (calendar-anchored)

Confluence §8 describes 4 full-stack phases without dates. With the 2026-04-27 launch target, the realistic mapping is:

| Phase | Confluence §8 scope | Calendar | Ships for launch? |
|---|---|---|---|
| Phase 1 | Admin addon management (entities, CRUD, location config, drag-and-drop sort, tenant module flag) | 2026-04-20 → 2026-04-23 | ✅ Required |
| Phase 2 | User checkout + BookingAddon + transaction split on initial payment | 2026-04-21 → 2026-04-25 (overlaps Phase 1) | ✅ Required |
| Phase 3 | Hooks infra + video-recording reference integration, boot-time handler validation enforced | 2026-04-22 → 2026-04-26 (depends on partner API availability) | ✅ Required (scoped to video-recording hooks only) |
| Phase 4 | Admin add/remove on confirmed bookings, removal-refund auto-gen, cancellation refund split, audit log | 2026-04-28 onwards | ❌ **Slips past launch** — see Open Question OQ-01 |

**Launch-day scope = Phase 1 + Phase 2 + Phase 3 (video-recording only).**

Business rules deferred with Phase 4: BR-010 (admin adjustment on confirmed bookings), BR-021/022 (removal refund auto-gen), BR-037 (admin-initiated hook parity), BR-038 (audit log) in their admin-adjustment dimension. The customer-facing path and the video-recording integration ship on 2026-04-27; admin-side operational tooling follows.

## Open Questions

Collected from the Confluence spec's scattered TBDs and from gap-audit against this launch plan. Each needs an owner before we leave this sprint.

| ID | Question | Source | Owner | Needed by |
|---|---|---|---|---|
| OQ-01 | Phase 4 slip — do launch tenants have an operational workaround for removing a paid addon before Phase 4 ships? | Timeline above | Product + Ops | 2026-04-22 |
| OQ-02 | Video-recording revenue-share mechanics — where does the split ratio live (per-addon field? per-tenant agreement?), and who performs settlement to the provider? | Confluence BR-024..031 | Product + Finance | 2026-04-22 |
| OQ-03 | Hook payload schema for `PRE_PURCHASE` and `POST_CONFIRMATION` — partner is building against this now; must be frozen | Confluence §7 | Tech Lead + Partner | 2026-04-21 |
| OQ-04 | Video consent + retention + deletion — GDPR/privacy gate for recording customers in a public facility | Not in Confluence | Product + Security | 2026-04-23 |
| OQ-05 | Launch-day kill-switch path — is BR-002 (Addon INACTIVE) the agreed break-glass, and is it one click from the admin dashboard? | Confluence BR-002 | Tech Lead | 2026-04-24 |
| OQ-06 | Rounding tie-break rule — Confluence §6 defers "any deterministic rule — to be finalized in Phase 2". Proposal: largest subtotal first; ties broken by BookingAddon.createdAt ASC. | Confluence §6 | Tech Lead | 2026-04-22 |
| OQ-07 | Image upload pipeline for Addon.imageUrl — which bucket, which presigner? | Confluence Data Model | Backend Engineer | 2026-04-22 |
| OQ-08 | Currency — are any non-EGP tenants in scope for launch? | Confluence §6 examples | Product | 2026-04-21 |
| OQ-09 | Tax/VAT on addons — inclusive or exclusive of addon price, and is it parity with booking tax? | Not in Confluence | Product + Finance | 2026-04-23 |
| OQ-10 | Cancellation policy × addons — does a partial-refund cancellation policy apply to addons at the same %, or are addons always 100% refundable? | Confluence §6 worked example | Product | 2026-04-23 |
| OQ-11 | Staff-at-venue reconciliation — confirm this is deferred v1 and add to Confluence §9 | Not in Confluence §9 | Product | 2026-04-21 |
| OQ-12 | Minimum viable addon analytics for launch tenants — single "units sold per addon per month" count, or fully deferred? | Confluence §9 + BR-039 | Product | 2026-04-24 |

## Requirements — P0 / P1 / P2 mapping

The Confluence spec lists 40 business rules without priority. Mapping against the 2026-04-27 launch:

- **P0 (launch-blocking):** BR-001..009, BR-011..017, BR-024..036, BR-039, BR-040 (Phases 1–3 scope).
- **P1 (v1 commitment, ships Phase 4):** BR-010, BR-018..023, BR-037, BR-038.
- **P2 (explicitly deferred — Confluence §9):** analytics endpoints, courses/experiences/events/trips, hook retries & idempotency, auto-collection, credits, stock, quotas, localization, user self-service addon edit, price-change race handling, addon-level discounts.

## Related

- Confluence: [Addons — Feature Specification (v1)](https://apessolutions.atlassian.net/wiki/spaces/SPARK/pages/1091371013/Addons+Feature+Specification+v1)
- Backlog: `projects/ideas-backlog.md` (IDEA-001)
- Tracker epic: [apessolutions/booking-system#636](https://github.com/apessolutions/booking-system/issues/636)
  - Phase 1 — [#637](https://github.com/apessolutions/booking-system/issues/637)
  - Phase 2 — [#638](https://github.com/apessolutions/booking-system/issues/638)
  - Phase 3 — [#639](https://github.com/apessolutions/booking-system/issues/639)
  - Phase 4 — [#640](https://github.com/apessolutions/booking-system/issues/640)
  - OQ-03 (hook payload schema) — [#641](https://github.com/apessolutions/booking-system/issues/641)
  - OQ-04 (video consent / retention) — [#642](https://github.com/apessolutions/booking-system/issues/642)
