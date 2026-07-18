# App-Wide Validation Sync (FE ↔ BE ↔ Domain) — Technical Design

> **Status:** design, awaiting review (Tariq + CEO). **Branch base:** `development`.
> **Target repo:** apessolutions/moj_judiciary. **Prefix:** MOJ.
> **Trigger:** a long متهم (accused) name produced a **500 with no field error** instead of a 422.

## 1. Problem & root cause

The reported symptom: typing an over-long accused name returned **HTTP 500**, no validation message. Two
distinct defects combine to produce it, and the audit shows the pattern repeats beyond this one field.

**Defect A — DTO layer misses `@Size` where the domain enforces a limit.** The domain value object
`AccusedName` rejects `> 255` chars, but `CreateCaseRequest.AccusedInput.name` carries only `@NotBlank` — no
`@Size`. So over-long input skips bean-validation and reaches the domain constructor. Second confirmed
instance: `SaveDivisionPanelRequest.prosecutorName` (`@NotBlank` only; domain `ProsecutorName` enforces
min 2 / max 255). Four enum-as-`String` fields (court/division/prosecution `type`, station `mode`) similarly
lean on domain enum-parsing instead of a bean-validation constraint.

**Defect B — domain validation exceptions map to 4xx only within their owning controller.** Every
`Invalid*Exception` is mapped by a **controller-scoped** `@RestControllerAdvice(assignableTypes = XController.class)`.
When a **shared** value object is constructed from a *different* module's controller, no advice sees the
throw → it falls to `GlobalExceptionHandler`'s catch-all `Exception → 500`. The accused name is reachable from
the **court-session commit** path (a different module), where `courtsession` additionally throws raw
`IllegalArgumentException` for its own invariants — **nothing maps that at all**. That cross-module throw is
the 500.

The audit's structural finding: *the boundary (DTO bean-validation) is the only place that reliably yields a
localized field error; the domain VO must never be the first line of defense reached from HTTP, and even when
it is, its exception must map to 422 rather than 500.*

Full inventory: the two backend research reports (VO table, DTO string-field table, mismatch table,
unmapped-exception list) and the frontend audit (every zod schema + missing-`.max` list). Summarized below.

## 2. Goals

1. **No domain-limit violation ever returns a 500** — it returns a 422 with a localized field error.
2. **FE and BE enforce the same limits** — and can't silently drift.
3. **Single source of truth per limit** — one number, referenced everywhere, on each side.

## 3. Design — three layers

### Layer A — Boundary sync (BE DTOs) + single-source length constants

- **`FieldLimits` constants class** (`shared`): `public static final int ACCUSED_NAME = 255;` etc. — one per
  limited field. `@Size(max = ...)` requires a compile-time constant, and `public static final int` is one, so
  **both** the domain VO's `MAX_LENGTH` **and** the DTO's `@Size(max = FieldLimits.X)` reference the same
  constant. They can no longer drift. (Migrate existing VOs to reference `FieldLimits` incrementally; new/edited
  fields must.)
- **Add the missing constraints:**
  - `CreateCaseRequest.AccusedInput.name` → `@Size(max = FieldLimits.ACCUSED_NAME)` + new key
    `CASE_ACCUSED_NAME_SIZE`.
  - `SaveDivisionPanelRequest.prosecutorName` → `@Size(min = 2, max = FieldLimits.PROSECUTOR_NAME)` + new key
    `DIVISION_PANEL_PROSECUTOR_NAME_SIZE`.
  - Enum-string fields → adopt the **already-present-but-unused** `@EnumValue` constraint
    (`shared/web/validation/EnumValueValidator`) so an unknown enum yields a shaped field error like every other.
- **Message keys:** add the two new `*_SIZE` keys to `validation.properties` + `validation_ar.properties`
  (`MessageBundleCompletenessTest` fails the build otherwise — a built-in guard we lean on).
- **Full sweep:** the audit found the codebase is *mostly* synced; this layer closes the confirmed gaps and
  audits every remaining `*Request` string field against its VO in one pass.

### Layer B — Defense-in-depth: domain validation → 422 globally (kills the 500 class)

> **Re-specified per Tariq's design review (2026-07-17).** Layer A is the *actual* fix — once every `*Request`
> field mirrors its VO constraint, the domain VO is never the first responder reached from HTTP and the 500
> class is closed at the boundary. Layer B is pure defense-in-depth for cross-module VO construction, and is
> deliberately kept **minimal** to avoid a 34-class base-class reparenting and a 20-advice retrofit.

**Canonical status for a domain-limit/format violation = `422`** (matches `MethodArgumentNotValidException` and
Goal #1). The scoped `Invalid*` handlers currently return **400** with a *flat* message (no `errors` map) — so
removing them loses no field-keying, and standardizing on 422 removes the 400↔422 split for one error class.

1. **Marker interface, not a base class.** Introduce `DomainValidationError` (marker interface, `shared`). Every
   `Invalid*Exception` gains `implements DomainValidationError` — purely additive, keeps `RuntimeException` as
   superclass, no constructor-chain changes, ~35 one-line edits. (A base class would be an invasive reparent;
   Spring resolves `@ExceptionHandler` by interface fine.)
2. **One global handler.** `GlobalExceptionHandler` maps `@ExceptionHandler(DomainValidationError.class) → 422`
   with a localized generic message (bundle the message key in **both** locales). A cross-module VO throw is now
   a 422 regardless of which controller is in scope.
3. **Remove the scoped `Invalid*` handler methods** from the ~20 per-controller advices (keeping their
   `*NotFound` and other non-validation mappings). This **avoids the `@Order` registration-order tie** entirely
   (no overlap between scoped and global once the `Invalid*` methods are gone) and makes the global 422 the
   single source. *(Alternative if we'd rather keep them: add `@Order(Ordered.LOWEST_PRECEDENCE - 1)` to every
   scoped advice — the precedent Media/Transcript/CourtSession already follow — but removal is cleaner given
   they add no field-keying. Chosen: **removal.**)*
4. **`courtsession` `IllegalArgumentException` — convert ONLY the request-reachable, user-input invariants**;
   leave server-internal guards as-is (converting them would mask real server bugs as 422 — an anti-goal):
   - **Convert** (→ implement `DomainValidationError`, or a mapped subtype): `ProsecutorName` (blank/>255 — the
     direct analog of the reported bug), `SessionSpeaker` micSlot≥1, `AccusedRuling` (numberOfDays /
     nextRenewalDate / bail), `CourtSession` finalize/edit/reorder invariants, position>0 guard in
     `CourtSessionApplicationService`.
   - **Do NOT convert** (stay 500-class — programmer-error guards): all `*Id` null-guards and the
     aggregate-internal null-assembly guards (`CourtSessionAccused`, `CourtSessionAccusedLawyer`,
     `SessionSpeaker` assembly, `CourtSessionJudge`, `SessionActivityPeriod`). These fire only if server code
     passes null while assembling an already-validated snapshot.

Net: kills the reported 500, one canonical status (422), one mapping, no `@Order` tie, no base-class ripple.

### Layer C — FE shared limits + fill the missing `.max()` rules

- **`field-limits.ts` constants module** (FE) mirroring BE `FieldLimits` — one place, imported by every zod
  schema instead of hardcoding `.max(255)` inline. Kills the current pattern where the limit is duplicated in
  both `.max(N)` and the Arabic message string, inconsistently (100/150/200/255) across forms.
- **Add missing `.max()` rules** to the ⚠️ schemas the FE audit flagged: judicial-rank, prosecution-rank,
  prosecution names, lawyer fullName/barNumber, all renewal-flow person names (accused, lawyer, prosecutor),
  case number, session `chargeDescription`, panel names.
- **Drift guard:** a small FE unit test (and/or a checked-in table + CI check) asserts `field-limits.ts`
  matches the documented BE limits, so the two mirrors can't silently diverge. *(No OpenAPI/codegen exists and
  the target env is offline, so a generated client is out of scope for v1 — the mirror is manual but
  centralized + test-guarded. Revisit codegen later if the surface grows.)*
- **Server-error mapping already works** via `getServerError` (`utils/axios.ts`) → RHF `setError`; the new
  `*_SIZE` field errors flow through it. Note the modules with bespoke FE-name↔BE-name mappers
  (e.g. `applyDivisionServerErrors`) — new field keys must be added to those maps where names diverge.

## 4. The single-source-of-truth decision (→ AgDR-0077)

Choice of anti-drift mechanism: **(a)** shared `FieldLimits` constant per side + a drift test (recommended);
**(b)** expose limits via an API endpoint the FE fetches; **(c)** codegen from BE. Recommend **(a)** — simplest,
compile-time-safe on BE, offline-friendly, test-guarded on FE. File as **AgDR-0077** (next in the Moj sequence).

## 5. Ticket breakdown (proposed — initiative-sized)

Filed under **Epic #465**:

| Item | Ticket | Layer | Scope |
|---|---|---|---|
| V1 | **#469** | BE | `FieldLimits` + fix the 2 confirmed `@Size` gaps + 2 message keys + full `*Request` string-field sweep. AgDR-0077 filed here |
| V2 | **#470** | BE | `@EnumValue` adoption for the 4 enum-string fields |
| V3 | **#471** | BE | `DomainValidationError` **marker interface** + global 422 handler + remove scoped `Invalid*` handler methods + convert **request-reachable** courtsession IAEs only (Tariq B1/B2/B4/B5) — **closes the reported 500** |
| V4 | **#472** | FE | `field-limits.ts` + fill missing `.max()` across schemas + drift test. Blocked-by #469 |

Each = one PR off `development`, own Rex review. V3 is the one that closes the reported 500; V1 is the
boundary fix that prevents the domain from being reached in the first place. Security auditor auto-fires on any
diff touching validation/exception handling.

## 6. Decisions — settled

1. **Single-source strategy:** ✅ `FieldLimits` + drift test (→ AgDR-0077). *(§4)*
2. **Scope of the sweep:** ✅ full app-wide audit both sides (CEO). V1/V4 are the exhaustive passes.
3. **Layer B shape:** ✅ marker interface + global 422 + remove scoped `Invalid*` handlers + convert
   request-reachable courtsession IAEs only (Tariq design review, 2026-07-17). *(§3 Layer B)*
4. **Canonical status:** ✅ `422` for all domain-limit/format violations. *(§3 Layer B)*

**Tariq verdict:** Layers A + C **SOUND** (proceed); Layer B **re-specified** per B1/B2/B4/B5 above — now
build-ready.
