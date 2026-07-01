<!-- Based on ApexYard · templates/technical-design.md · github.com/me2resh/apexyard · MIT -->

# Technical Design: Notifications Routing & Preferences Engine

**Status**: In Review (rev 3 — conditional routing + Hakim security findings)
**Author**: Hisham (Tech Lead)
**Date**: 2026-06-28
**PRD**: TBD (feature-driven; this design doubles as the requirements capture pending a PRD)
**Repo**: apessolutions/booking-system (`libs/notification`)

> **Revision note (rev 2):** incorporates the Solution Architect (Tariq) review. Key changes: **Transport vs Audience** terminology split (was the overloaded "channel" — B1); **universal record** decoupled from in-app-as-transport (B2); **opt-out** preference default (B3); **always-on in-app floor** for mandatory events (B4); timing-rule **execution model** split out (M1, AgDR-0019); **NFR + caching** section (M2); full **precedence decision table** (M3); call-site count corrected to **~32** (M4); device-level `notificationsEnabled` relationship defined (M5).
>
> **Revision note (rev 3):** (a) **conditional routing** — static `(event,tenant)→transport set` replaced by ordered **routing rules with closed-catalog predicates** + per-event **strategy** (FIRST_MATCH / ALL_MATCH); this resolves the parked M6 cost-control open question (FIRST_MATCH = ordered fallback) and is ratified as **AgDR-0020**. (b) Hakim security review folded in: **H1** per-target output encoding (in-app stored-XSS / SMS control-char / WhatsApp param-only), **H2** IDOR binding on both `recipient_id`+`recipient_type` and on read+write, plus MEDIUM/LOW controls as ACs.

---

## Overview

### Summary

Replace the current "caller chooses channel + hardcodes copy" notification path with a **resolution engine**: domain handlers emit a *semantic notification intent* (`event + recipients + context + tenant`), and the engine resolves **who** is notified, **on which transports**, **with what rendered content**, respecting a strict three-actor ownership model. This unblocks per-recipient preferences, per-tenant event configuration, super-admin transport governance, templating/i18n, and new transports (WhatsApp via Twilio).

### Goals

- **Recipient preferences** — each admin toggles, per event, whether they personally receive it (**opt-out**: absent = on).
- **Tenant event control** — tenants define which events are active and their timing/business rules (e.g. "remind 2h before cancellation deadline").
- **Super-admin transport governance** — the platform controls (a) which transports a tenant may use (disable = permanent) and (b) which transport(s) each event routes through.
- **Templating + i18n** — content rendered from versioned templates keyed by `(event, transport, locale)`.
- **New transport: WhatsApp (Twilio)** — dispatch against a pre-approved Twilio content template SID; approval handled off-platform.
- **Testability + reliability** — provider port, isolated unit tests, retry + DLQ on dispatch. (Current lib has *zero* tests.)
- **Migrate safely** — strangler over the existing ~32 call sites; no big-bang flip.

### Non-Goals

- WhatsApp template *approval workflow* — done outside the platform; we only call Twilio with a known template SID.
- Recipient- or tenant-chosen transports — transport is platform-governed only.
- Tenant ability to re-enable a super-admin-disabled transport — disabling is irreversible.
- Real-time in-app transport (WebSocket/SSE) — out of scope for v1; the in-app feed remains the DB-backed universal record.
- Marketing/A-B-testing engine, event sourcing of notifications — future.

---

## Terminology (rev 2 — resolves the B1 collision)

Three distinct concepts the original draft overloaded as "channel":

| Term | Meaning | Values today | Owner |
|------|---------|--------------|-------|
| **Transport** | The delivery mechanism | PUSH, SMS, WHATSAPP | super-admin (routing + enablement) |
| **Audience / device-scope** | Which device registry a *push* lands on (Spark app vs tenant white-label app) | SPARK, TENANT (current `NotificationChannelEnum`) | resolved inside push delivery |
| **In-app feed** | The persisted notification row the mobile/admin apps list (`GET /v1/notifications`) | n/a — it's the **universal record**, not a transport | system (always written) |

The existing `NotificationChannelEnum {SPARK, TENANT}` is an **Audience** concept (today the processor loops it to pick tenant-scoped vs global devices, breaking on first non-empty). It is **orthogonal to Transport** and only affects PUSH device resolution + which Firebase credentials are used. SMS/WhatsApp address a phone number directly and ignore audience-scope. Retiring SPARK/TENANT-as-channel and re-homing it as Audience in the device repository is **AgDR-0018**.

---

## Ownership Model (the load-bearing decision)

Three actors, **non-overlapping** controls.

| Actor | Owns | Stored in |
|---|---|---|
| **Super admin (platform)** | Transport availability per tenant (disable = permanent); event→transport routing | `tenant_transport_enablement`, `event_transport_routing` |
| **Tenant** | Which events are active + their timing/business rules | `tenant_event_config` |
| **Recipient admin** | Per-event on/off for themselves (optional events only; opt-out default) | `notification_preference` |

> Ratified as AgDRs in the booking-system repo (`docs/agdr/`):
>
> - **AgDR-0014**: preference granularity = **per-event**, default = **opt-out (absent = on)**.
> - **AgDR-0015**: transport = platform routing `∩` tenant enablement; **never** a recipient/tenant choice.
> - **AgDR-0016**: super-admin transport disable is **irreversible**; mandatory events guaranteed an **always-on in-app floor**.
> - **AgDR-0017**: migration strategy = **strangler** behind a `notify()` facade.
> - **AgDR-0018**: retire SPARK/TENANT-as-channel → **Transport** + **Audience**; in-app = universal record, not a transport.
> - **AgDR-0019**: timing-rule storage + **execution model** (reactive sends vs scheduled reminders).

---

## Resolution Pipeline

```
domain handler (reactive)            scheduler (timing rules — AgDR-0019)
   │  notify({ event, recipients[], context, tenantId })   ← no title/body/transport
   ▼
[1] Tenant event active?   tenant_event_config(tenant, event).enabled?  (absent ⇒ enabled, migration default)  ──no──▶ drop
   ▼
[2] Recipient wants it?     mandatory(event) ? keep
                           : notification_preference(recipient, event).enabled?  (absent ⇒ ON, opt-out)  ──OFF──▶ drop recipient
   ▼
[3] Route transports        evaluate ordered routing RULES for (tenant override else global, event):
                              each rule = {transport, when: <predicate?>}; keep rules whose predicate holds
                              against (recipient, context); apply strategy:
                                FIRST_MATCH → first viable rule only (ordered fallback / cost control)
                                ALL_MATCH   → every matching rule
                              result ∩ event.allowedTransports                         (AgDR-0020)
   ▼
[4] Filter by enablement     ∩ tenant_transport_enablement(tenant)   (drop permanently-disabled transports)
   ▼
[5] Render per transport     template(event, transport, recipient.locale → tenant default → platform default)
                              + per-target output encoding (H1): IN_APP→HTML-escape, SMS→strip control chars,
                              WHATSAPP→Twilio template params only (no free interpolation)
   ▼
[6] Dispatch per transport   INotificationProvider[transport].send()  (1 job/transport, retry + DLQ)
                              PUSH: DeviceRepository resolves devices by Audience (TENANT→SPARK fallback) ∧ device.notificationsEnabled
   ▼
[7] RECORD (always)          persist DeliveredNotification{recipient, event, transport|FEED, status}  ← in-app feed + audit, NEVER gated
```

Key properties (rev 2):

- **Step [7] is universal and ungated** — every resolved recipient gets a record row (the in-app feed), independent of transport routing/enablement. This is the **always-on in-app floor** (B4) and fixes the feed regression (B2).
- **Mandatory (transactional) events** bypass step [2] (recipient preference) **and step [1]** (tenant event-config). A tenant cannot disable a mandatory event — otherwise it would be dropped *before* the floor, re-opening the silent-loss class B4 closes via a different door (Tariq NEW-1). Tenant event-config governs **optional** events only.
- If step [4] drops all routed transports, the universal record in [7] still lands — a mandatory event can never be fully silenced by an irreversible disable.
- **Opt-out default** (B3): a missing preference row means *enabled*. Flipping an event mandatory→optional is an explicit, audited per-event operation — never a blanket flip.
- **Two sources of "allowed transports"** with defined precedence (M3): `event.allowedTransports` is the catalog-level hard cap; `event_transport_routing` selects within it. Effective set = routing `∩` allowedTransports `∩` enablement.
- **Feed-record render source (Tariq NEW-2):** the universal record (step [7]) is content-bearing but FEED is not a routed transport, so it has no `(event, transport, locale)` row. The feed renders from a dedicated **`IN_APP` template target** — a render-only key in `notification_template` (transport column value `IN_APP`), distinct from a routed Transport (it never appears in routing/enablement). If the `IN_APP` template is absent, fall back to the primary routed transport's rendered content; if there is no routed transport either, render from `context` via the event's default in-app template. This is exercised by the M1 walking skeleton — settle it there.

### Conditional Routing Rules (rev 3 — AgDR-0020)

Routing is **ordered rules**, not a flat transport set. Each rule names a transport and an optional **predicate**; a per-event **strategy** decides how matches combine.

```
event_transport_routing(BOOKING_CONFIRMED, tenant) = [
  { order: 1, transport: PUSH,     when: recipient.hasDevice },
  { order: 2, transport: SMS,      when: NOT recipient.hasDevice },     # fallback (no device)
  { order: 3, transport: WHATSAPP, when: context.source == 'DASHBOARD' } # conditional on event data
]
strategy: FIRST_MATCH | ALL_MATCH
```

- **`FIRST_MATCH`** — evaluate in `order`, deliver on the first rule whose predicate holds and whose transport survives enablement; stop. This is the **ordered-fallback / cost-control** answer to the former M6 open question (don't fan paid transports).
- **`ALL_MATCH`** — deliver on every matching rule (today's multi-send behaviour; the migration default).

**Predicates are a CLOSED catalog — not an expression language** (the load-bearing flexibility discipline). Supported v1 predicate inputs:

| Predicate input | Source | Notes |
|---|---|---|
| `recipient.hasDevice` / `recipient.hasPhone` | recipient profile | enables no-device → SMS fallback |
| `recipient.locale == X` | recipient profile | |
| `context.<key> == <value>` | `NotificationIntent.context` | `<key>` MUST be declared in the event's `contextSchema` (catalog) — predicates can't reference fields an event doesn't emit |
| `time.businessHours` | clock | future |

Super-admin composes rules from this menu (renders in a UI); no arbitrary code. This keeps routing **governable, cacheable** (the rules are; evaluation is per-send), **testable** (finite predicates), and **injection-safe**. A general expression engine is an explicit future decision, not the default (AgDR-0020 § Options).

**No-device fallback is pre-send** (predicate on `recipient.hasDevice`), which covers the stated case. *Delivery-failure* fallback (push token dead / app uninstalled, knowable only post-send via receipts) is harder and **deferred** — it needs delivery receipts + a requeue path.

### Precedence decision table (M3)

| Case | Outcome |
|------|---------|
| Tenant event config absent | Treat as enabled (migration-safe default) |
| Tenant event config disabled, **optional** event | Drop event for tenant |
| Tenant event config disabled, **mandatory** event | Ignored — mandatory events are not tenant-disable-able; event proceeds (NEW-1) |
| Event mandatory | Bypass step [1] (tenant config) AND step [2] (recipient preference); always record |
| Optional, preference row absent | Treat as ON (opt-out) |
| Optional, preference OFF | Drop recipient |
| No routing rule's predicate holds | No external transport; universal record still written |
| Routing ∩ allowedTransports = ∅ | No external transport; universal record still written |
| All routed transports disabled for tenant | No external transport; universal record still written (floor) |
| strategy=FIRST_MATCH, rule 1 viable | Deliver rule 1 only; skip remaining (ordered fallback / cost control) |
| strategy=FIRST_MATCH, rule 1 predicate false or transport disabled | Fall through to next rule in `order` |
| strategy=ALL_MATCH | Deliver on every matching + enabled transport |
| predicate references a `context.<key>` not in the event's contextSchema | Config-time validation error (rejected when the rule is saved) |
| Template missing in recipient locale | Fall back tenant-default → platform-default locale |
| Template missing in all locales | Skip that transport, status=RENDER_FAILED (logged); other transports proceed |
| Feed record render (FEED is not a transport) | Render from `IN_APP` template target → fall back to primary routed transport's render → fall back to event default in-app template from `context` (NEW-2) |
| PUSH, no enabled devices | status=SKIPPED (reason=no_device); record still written |
| Provider error | retry (n×) → DLQ → status=FAILED |

---

## Scheduling Model (M1 / AgDR-0019)

`tenant_event_config.timing_rules` ("remind 2h before cancellation deadline", "booking reminders") is a **scheduling** concern and must NOT live in the synchronous resolution pipeline. Two distinct paths:

- **Reactive sends** — a domain event fires → handler calls `notify()` immediately. (Most events.)
- **Scheduled reminders** — a time-relative rule. Executed by the **existing pattern**, not a new one: the Bull delayed-job / cron-scan mechanism already used by `OpenMatchReminderJob` (cron every 10 min, scan-window) and the birthday cron. A `NotificationSchedulerJob` evaluates active `timing_rules`, computes due sends, and calls the same `notify()` facade.

This reuses house machinery per the AgDR-0012 precedent ("match existing scheduling mechanism") rather than reinventing or fragmenting it.

---

## Domain Model

```
NotificationIntent (transient — the new input contract)
├── event: NotificationEvent
├── recipients: Recipient[]            (id + type + tenantId + locale + audiencePref)
├── context: Record<string, unknown>   (template variables: booking, resource, …)
└── tenantId: TenantId

NotificationEvent (catalog)
├── key: enum (BOOKING_COMPLETED, …)
├── category: enum                      (grouping for UI/admin only; NOT preference granularity)
├── mandatory: boolean                  (transactional → bypasses recipient preference + tenant config)
├── allowedTransports: Transport[]      (catalog-level hard cap on routing)
└── contextSchema: string[]             (declared context keys routing predicates may reference, e.g. ['source'])

DeliveredNotification (persisted — the existing `notification` table, ALTERED in place — see Data Model)
├── id, recipientId, recipientType, tenantId
├── event, transport (nullable: NULL = feed-only record)
├── status (PENDING|SENT|FAILED|SKIPPED|RENDER_FAILED)
├── renderedTitle, renderedBody, payload, locale
├── isRead (in-app feed), dispatchedAt, createdAt
```

### Domain Events (existing triggers — unchanged)

| Event | Trigger | NotificationEvent | Note |
|-------|---------|-------------------|------|
| BookingCompletedEvent | booking lifecycle | BOOKING_COMPLETED | confirm catalog mapping — today bookings may emit `AUTOMATED` (NIT1) |
| OpenMatchLiveEvent | match goes live | OPEN_MATCH_LIVE | |
| … (10 today) | … | … | |

---

## Architecture

```
┌─ apps (5 domains, ~32 call sites) ────────────────────────────┐
│  event handlers  ──▶  NotificationFacade.notify(intent)        │   ← strangler seam
│  scheduler job   ──▶  NotificationFacade.notify(intent)        │   (timing rules)
└───────────────────────────────────┬───────────────────────────┘
                                     ▼
┌─ libs/notification (engine) ──────────────────────────────────┐
│  ResolutionService  ─ reads ─▶ NotificationPreferenceRepository│
│        │                       TenantEventConfigRepository      │
│        │                       EventTransportRoutingRepository   │
│        │                       TenantTransportEnablementRepository│  ← config reads cached (M2)
│        ▼                                                       │
│  TemplateRenderer  ─ reads ─▶ NotificationTemplateRepository   │
│        ▼                                                       │
│  Dispatcher  ──enqueue──▶ Bull(queue.notification.<transport>) │  retry + DLQ
│        ▼                                                       │
│  ProviderRegistry: INotificationProvider                      │
│    ├─ PushProvider     (Firebase; DeviceRepository: Audience  │
│    │                    TENANT→SPARK fallback ∧ notifsEnabled) │
│    ├─ WhatsAppProvider (Twilio content template SID)          │
│    └─ SmsProvider      (Twilio)                               │
│  RecordWriter  ── ALWAYS ──▶ DeliveredNotification (feed+audit)│  ← ungated (B2/B4)
└───────────────────────────────────────────────────────────────┘
```

Ports are **abstract classes** named `<Thing>Repository` (house convention); only `INotificationProvider` is `I`-prefixed (it's a true interface) (N1). The current god-class `NotificationProcessor` splits into `ResolutionService` / `Dispatcher` / per-transport `Provider` / `DeviceRepository` / `RecordWriter`.

---

## Non-Functional Requirements & Caching (M2)

- **p95 resolution latency** (steps 1–5, excluding async dispatch) target **< 50ms** at booking-event volume; fan-out events (open-match reminders loop recipients) must batch reads.
- **Config reads are cacheable** — `event_transport_routing` (the rule *definitions*), `tenant_transport_enablement`, `tenant_event_config`, and `notification_template` are slow-changing → cache in Redis with **event-driven invalidation** on the corresponding super-admin/tenant write. This directly addresses M1's kill criterion ("if routing+preference can't be cached to acceptable p95"). Note: routing-rule **predicates evaluate per-send** against `(recipient, context)` — only the rule set is cached, not the routing *result*.
- **Preference reads batched** — for multi-recipient sends, fetch `notification_preference` for the whole recipient set in one query, not per-recipient.
- **Reliability** — per-transport Bull queue with bounded retries + dead-letter; failures recorded as `FAILED`, never silently dropped.

---

## Data Model

New + altered tables (all migrations via `/migration` — gate 3a):

| Table | Key columns | Owner | Change |
|-------|-------------|-------|--------|
| `notification_template` | event, transport, locale → title_tpl, body_tpl, payload_tpl, version | super admin | new |
| `event_transport_routing` | (tenant_id NULL=global), event, `order`, transport, `predicate`(json, closed-catalog), `strategy`(FIRST_MATCH\|ALL_MATCH) | super admin | new — ordered rules (AgDR-0020) |
| `tenant_transport_enablement` | tenant_id, transport, enabled, disabled_at (irreversible) | super admin | new |
| `tenant_event_config` | tenant_id, event, enabled, timing_rules(json) | tenant | new |
| `notification_preference` | recipient_id, recipient_type, event, enabled | recipient | new |
| `notification` | + transport (nullable), status, dispatched_at, rendered_* | system | **ALTER in place** (N2) |

> **N2 resolution:** `DeliveredNotification` is the existing `notification` table **altered in place** (add columns), NOT a rename — preserving the existing in-app feed rows and the indexes from migration 1771876579632.

### Key access patterns

- Routing: `event_transport_routing` by `(tenant_id OR global)` + event → index `(event, tenant_id)`.
- Preference: `(recipient_id, recipient_type, event)` → unique composite index.
- Render: `(event, transport, locale)` → unique composite index; locale fallback per decision table.

---

## Migration Strategy (strangler — AgDR-0017)

1. **Walking skeleton** — engine resolves ONE event (confirm `BOOKING_COMPLETED` catalog key, NIT1) on PUSH end-to-end through all 7 pipeline steps, incl. preference + routing reads + universal record. Old path untouched.
2. **Facade delegation** — `sendUserNotification`/`sendAdminNotification` reimplemented to build an intent and call `notify()`. **Behaviour-preservation is now explicit (B1):** the facade maps the legacy `channels:[TENANT,SPARK]` to the **Audience** fallback (not transport=push), preserves the device-resolution order, and treats all events mandatory + routes PUSH-only so un-migrated callers are byte-identical. The admin path has no `channels` field today — handled asymmetrically (NIT2). Characterization tests lock the SPARK/TENANT device fallback before any caller moves.
3. **Per-event-family migration** — booking → open-matches → tournament → campaign → user, each family one slice. `/fan-out` candidate. (~32 call sites total, M4.)
4. **Transport rollout** — WhatsApp, SMS providers behind the port.
5. **Config surfaces** (super-admin routing/enablement, tenant event config, recipient preferences) + UI.
6. **Delete legacy** — remove hardcoded-string handlers + duplicate service registration in `spark-tenant-admin-api` (confirmed real, module line ~20).

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| ~32 call sites + **zero tests** → regressions on migration | High | High | Strangler + characterization tests (incl. Audience fallback) before touching callers |
| Transport/Audience confusion recurs in code | Med | High | AgDR-0018 + explicit terminology section + naming review |
| Per-send read cost at fan-out volume | Med | Med | NFR target + config caching + batched preference reads (M2) |
| Multi-transport cost blow-up (SMS/WhatsApp) | Med | Med | Routing is explicit super-admin config; default = PUSH only; **cost-control fallback still open** (Open Questions) |
| Accidental irreversible disable | Low | Med | Always-on in-app floor guarantees mandatory delivery; confirmation on disable endpoint |
| Timing-rule scheduling fragments the cron landscape | Med | Med | Reuse existing Bull-delayed/cron-scan pattern (AgDR-0019) |

---

## Security Considerations (Hakim reviewed 2026-06-28 — H1/H2 HIGH folded in)

**HIGH (must land before the relevant slice builds):**

- [ ] **(AC) H1 — output encoding per target.** `context` is interpolated into rendered title/body, and the in-app feed replays `rendered_body` into web surfaces (stored-XSS). Encode per target at render (step [5]): **IN_APP → HTML-escape**, **SMS → strip control chars**, **WHATSAPP → Twilio template params only** (no free interpolation). Exercised by the M1 walking skeleton's render step.
- [ ] **(AC) H2 — IDOR binding complete.** Recipient preference endpoints bind **both** `recipient_id` AND `recipient_type` to the `ContextProvider` principal, on **read AND write** — never from body/param (the composite key means binding id alone is insufficient).

**Authz / governance:**

- [ ] **(AC)** Super-admin routing/enablement/template endpoints behind platform-admin authz only; template authoring is platform-only (SSTI guard — LOW).
- [ ] **(AC)** Tenant event config scoped by `tenantId` via the existing tenantId-filter pattern (not CASL).
- [ ] **(AC)** In-app feed (`GET /v1/notifications`) scoped to the principal (IDOR / enumeration — MEDIUM).
- [ ] **(AC)** Mandatory-event toggles read-only server-side (don't trust client).
- [ ] **(AC)** Capture `actor_id` on irreversible-disable + governance writes (repudiation — LOW).

**Secrets / PII / abuse:**

- [ ] Twilio credentials via `@./config` twilio module / secret store — **platform-global**, never plaintext per-tenant rows.
- [ ] **(AC)** No PII (phone numbers, message bodies) in logs — including provider error paths + the Bull DLQ.
- [ ] **PII at rest** in `rendered_body` / `payload` / DLQ → retention is a **GDPR/compliance** item (M5/follow-up), not just SRE housekeeping.
- [ ] **(AC)** Per-tenant **rate cap** on paid transports (SMS/WhatsApp) — cost-DoS guard.
- [ ] Forward-looking: validate Twilio webhook `X-Twilio-Signature` when delivery receipts are added.

---

## Testing Strategy

| Type | Coverage | Notes |
|------|----------|-------|
| Unit | ResolutionService precedence ≥90% | Every row of the decision table |
| Unit | Each provider | Twilio/Firebase mocked |
| Integration | Facade characterization | Lock current behaviour incl. SPARK/TENANT fallback BEFORE migration |
| Integration | Dispatch + retry/DLQ | Embedded Bull |
| E2E | One full path per transport | push + whatsapp critical |

---

## Open Questions

| Question | Owner | Status |
|----------|-------|--------|
| Cost-control: multi-transport send vs ordered fallback when an event routes to SMS+WhatsApp+push? | Tariq / CEO | **Resolved (rev 3)** — per-event `strategy`: FIRST_MATCH = ordered fallback (cost control), ALL_MATCH = multi-send (AgDR-0020) |
| Delivery-receipt-based fallback (push failed post-send → SMS) | Tech Lead | Deferred — needs Twilio/FCM receipts + requeue; rev-3 supports pre-send predicates only |
| In-app real-time transport (WS/SSE) now or deferred? | Tech Lead | Deferred (v1 = DB feed = universal record) |
| Retention/archival policy for `notification` table? | SRE | Follow-up ticket |
| Confirm `BOOKING_COMPLETED` catalog key vs current `AUTOMATED` (NIT1) | Backend | Open — resolve in M1 |

---

## Approvals

| Role | Name | Date | Status |
|------|------|------|--------|
| Tech Lead | Hisham | 2026-06-28 | Author (rev 3; conditional routing + Hakim H1/H2) |
| Solution Architect | Tariq | 2026-06-28 | APPROVED rev 2 (PR #761 gate); rev-3 re-review pending |
| Security (preferences = user data) | Hakim | 2026-06-28 | Reviewed rev 2 (PR #761) — H1/H2 folded into rev 3; re-confirm pending |
