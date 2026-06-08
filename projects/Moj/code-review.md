# Code Review — Moj (MOJ Judiciary Portal backend)

**Reviewer:** Rex (Code Reviewer Agent) · **Type:** code-quality calibration review (whole-codebase, no single PR)
**Branch:** `development` · **Stack:** Java 25 · Spring Boot 3.5.14 · Spring Modulith 1.4.11 · jMolecules DDD (`2023.3.2`) + ArchUnit · SQL Server + Flyway · Lombok
**Scope:** Canonical slices read in full (`iam/admin`, `iam/role`, `iam/auth`, `shared/`); `core` slices spot-checked for drift (`charge`, `court`, `division`, `judge`, `lawyer`, `participanttype`, `policestation`, `prosecution`, `governorate`, `judicialrank`). 667 main / 61 test Java files.

---

## Executive summary

**Overall code health: Excellent (A‑).** This is one of the cleanest hexagonal/DDD codebases I've reviewed. It lives up to its own `CLAUDE.md` to a degree that is genuinely rare:

- **Architecture boundaries verify mechanically and hold in practice.** `shared/` imports neither `iam/` nor `core/` (grep-clean). `iam/` never imports `core/`. The domain layer carries no Spring/JPA imports anywhere — the *only* framework import in any `domain/` package is the intentional `@NamedInterface` Modulith marker on `iam/role`'s `PermissionCatalog`/`PermissionSection`, which is the one documented cross-slice contract. All three architectural gate tests are present and wired: `ModularityTests` (Docker-free `ApplicationModules.verify()`), `PermissionCatalogIntegrityTest`, `MessageBundleCompletenessTest`.
- **Visibility discipline is near-perfect.** Every `Controller`, `ApplicationService`, `PersistenceAdapter`, JPA entity/repo/mapper is package-private; only ports + cross-package domain types are public. (Two web mappers — `AdminWebMapper`, `AuthWebMapper` — are `public` where `JudgeWebMapper`/`DivisionWebMapper` are package-private; see nit below.)
- **The N+1 trap the doc warns about is closed by construction.** Every cross-aggregate web mapper (`AdminWebMapper`, `JudgeWebMapper`, `DivisionWebMapper`, `CourtWebMapper`, `PoliceStationWebMapper`) exposes `toResponse` + `toResponses(List)` with the batched-lookup internalized so `toResponse` delegates to `toResponses`; `@BatchSize(50)` is on the `@ElementCollection` side-tables. I could not find a single per-row fetch inside a stream.
- **Localization, audit, permissions, soft-delete, pagination** all follow the documented patterns slice-for-slice. Commands self-validate; value objects self-validate in compact constructors; the `register()`/`rehydrate()` two-factory split is universal; `FieldValidationException` (not slice-local exception+handler) is used for every cross-aggregate field error.
- **Test coverage is better than the 61/667 ratio suggests** — that ratio is misleading because each test exercises a whole slice. Every slice has domain (where it has logic) + application (in-memory fake) + persistence (Testcontainers) tests, exactly per the doc's testing-gate split.

**How well it lives up to its CLAUDE.md:** ~95%. The findings below are concentrated, not systemic — chiefly the **`division` slice** (the most complex aggregate, where discipline measurably slipped) and a couple of **`lawyer`** drifts. No BLOCKING correctness or security defects were found; the single BLOCKING-tier item is a missing test for the codebase's richest untested domain invariant.

**Excellent, worth calling out explicitly:**
- `iam/admin` is a textbook reference slice — `AdminWebMapper`'s Javadoc literally explains *why* the component (not static) mapper shape exists (N+1 containment). New engineers can learn the pattern from the code alone.
- `Judge`/`Division` correctly reuse the `Admin → RoleId` by-id cross-aggregate reference pattern and validate FK existence **and activeness** through use-case ports (`CourtExistsUseCase.existsActiveById`) — never reaching into sibling domains.
- `GlobalExceptionHandler` mirrors `ExceptionTranslationFilter`'s anonymous-vs-authenticated 401/403 semantics correctly, and gates stack-trace exposure behind `errorProperties.isIncludeStack()` (off in prod) — no info-disclosure leak.
- `DivisionFormation` and `Panel` value objects model a genuinely intricate domain (single vs 3-judge panel, reserve judges, child-court specialists) with self-validating invariants kept *in the domain*.

---

## BLOCKING

### B1 — `Division` aggregate has zero domain tests despite owning the codebase's richest invariant
**Location:** missing `src/test/.../core/division/domain/DivisionTest.java` (cf. `DivisionFormation.java:21-32`, `Panel.java`)
**Issue:** `DivisionFormation`'s compact constructor enforces the "additional judges must not overlap the panel" invariant and throws `InvalidFormationException`; `Panel` distinguishes single vs 3-judge shapes; `DivisionType.fromValue` parses/validates wire input. None of this pure, framework-free domain logic has a unit test. Per `CLAUDE.md` § "Testing gates", domain logic is exactly what in-memory, no-Spring tests must cover, and this is the highest-value uncovered invariant in the repo. `DivisionApplicationServiceTest` exists but exercises the service path, not the VO invariants directly.
**Fix:** Add `DivisionTest` + `DivisionFormationTest` (and ideally `PanelTest`) using plain JUnit — assert: overlap throws `InvalidFormationException`; single-judge panel exposes its judge as president; `DivisionType.fromValue` trims/upper-cases and rejects null/blank/unknown. This is the one gate failure that could let a real regression through silently. (Sibling smaller gaps — `LawyerTest`, `ParticipantTypeTest`, `LawyerSubscriptionTest` — are lower-value because those aggregates are near-anemic; fold them into the same testing pass.)

---

## suggestion:

### S1 — `assert cfg != null;` used for control flow in `DivisionApplicationService`
**Location:** `core/division/application/DivisionApplicationService.java:86`
**Issue:** Java assertions are **disabled at runtime by default** (require `-ea`). The code is *currently* safe — `cfg` is only null when `courtType == null`, in which case `errors.throwIfAny()` on line 84 has already thrown — but encoding that reasoning as an `assert` makes it (a) a no-op in production and (b) fragile against future edits to the guard. It reads as a tool-silencing hack for a nullability warning.
**Fix:** Restructure so `cfg` is unconditionally assigned, or guard explicitly: build and return the `Division` inside the `if (courtType != null)` block (the `throwIfAny()` guarantees we never reach past it with a null `cfg`), eliminating the `assert` entirely.

### S2 — `isEligible(...)` is semantically inverted (returns true for *ineligible* judges)
**Location:** `core/division/application/DivisionApplicationService.java:257-271`
**Issue:** `isEligible` returns `true` when the judge is null / inactive / wrong-court, and callers read `if (isEligible(judge, courtId)) { errors.field(...); }` — i.e. "if eligible, record an error." The method actually computes *ineligibility*. The logic is correct but the name lies; a future maintainer will misread it.
**Fix:** Rename to `isIneligible(...)` (keep the body), so call sites read `if (isIneligible(...)) errors.field(...)`. Pure readability, zero behaviour change.

### S3 — `LawyerApplicationService.existsById` loads the whole aggregate instead of an existence check
**Location:** `core/lawyer/application/LawyerApplicationService.java:99-104`
**Issue:** Uses `lawyerRepository.findById(new LawyerId(id)).isPresent()`. Every *other* slice's `existsById` use case calls the repository's cheap existence method: `court`, `division`, `governorate`, `judicialrank`, `participanttype` all do `repo.existsById(new XId(id))` (a `SELECT 1`/`COUNT`). The lawyer version hydrates the full row + side state to throw it away. Clear convention drift and a (small) needless cost on a hot reference-validation path.
**Fix:** Add `boolean existsById(LawyerId id)` to `LawyerRepository` + adapter and call it, matching the five sibling slices. Also normalize the null guard to the sibling shape `id != null && lawyerRepository.existsById(...)`.

### S4 — `Lawyer` contact fields (`nationalId`, `phone`, `email`) are raw `String`, not value objects
**Location:** `core/lawyer/domain/Lawyer.java:37-42, 99-103`
**Issue:** `CLAUDE.md` (and `code-standards.md`) prescribe value objects for domain concepts; `nationalId` in particular is a real domain concept with a dedicated `shared/web/validation/NationalId` validator. Currently the format invariant lives *only* at the DTO/Bean-Validation edge — the domain accepts any string (e.g. `rehydrate` or any future non-web caller bypasses validation). `email`/`phone` are weaker cases but the same shape. Contrast with `BarNumber`/`LawyerFullName`, which *are* VOs.
**Fix:** Promote at least `NationalId` to a domain value object (record implementing `ValueObject`, self-validating compact constructor throwing `InvalidNationalIdException`), so the invariant holds regardless of entry path. `Phone`/`Email` VOs are optional but would complete the pattern. (Acknowledged trade-off: these are nullable/optional fields, so weigh ceremony vs. value — but `nationalId` is worth it.)

### S5 — `CLAUDE.md` says "Java 21"; the project is on Java 25
**Location:** `backend/CLAUDE.md:3` ("Spring Boot 3.5, Java 21, SQL Server") vs `pom.xml` `<java.version>25</java.version>`
**Issue:** The canonical conventions doc is now stale on the language version after the Java 25 bump. Since `CLAUDE.md` is the source of truth new engineers read first, the drift undermines its authority.
**Fix:** Update the header to "Java 25". While there, consider a one-line note on which post-21 features are sanctioned (the codebase currently uses almost no Java 21+ features — sealed types / record patterns / pattern-switch appear in only ~6 files; `DivisionType`/`Panel`/`CourtType` dispatch is a natural fit for sealed + exhaustive switch if the team wants to adopt them).

---

## nit:

### N1 — Mixed tabs/spaces in the `division` slice
**Location:** `core/division/application/DivisionApplicationService.java:86-87` (space-indented amid tabs); `core/division/domain/DivisionType.java:19-20` (`MISDEMEANOR`, `MISDEMEANOR_APPEAL` 2-space indented; the other two constants tab-indented)
**Issue:** The whole repo is tab-indented except these few division lines. Reads as hand-edits that escaped formatter discipline. The division slice is the *only* place this occurs.
**Fix:** Run the formatter / normalize to tabs. Consider adding a Spotless/format check to CI so this can't recur.

### N2 — `AdminWebMapper` / `AuthWebMapper` are `public`; sibling cross-aggregate mappers are package-private
**Location:** `iam/admin/.../AdminWebMapper.java:38`, `iam/auth/.../AuthWebMapper.java` vs `core/judge/.../JudgeWebMapper.java:34`, `core/division/.../DivisionWebMapper.java:37`
**Issue:** Web mappers are slice-internal presentation components consumed only by their own controller; the newer `core` mappers correctly declare them package-private. The two `iam` mappers being `public` is inconsistent with the visibility rule ("implementations are package-private") and with the newer slices — likely the convention tightened over time and `iam` wasn't backfilled.
**Fix:** Drop `public` from `AdminWebMapper`/`AuthWebMapper` unless something cross-package genuinely references them (grep suggests not). Low-risk, improves consistency.

### N3 — Two `TODO`s left in bootstrap seeders
**Location:** `core/judicialrank/infrastructure/bootstrap/JudicialRankBootstrap.java:34`, `core/prosecutionrank/infrastructure/bootstrap/ProsecutionRankBootstrap.java:34`
**Issue:** `// TODO(US-JRANK): confirm the canonical 9 judicial-rank names…` and the prosecution-rank equivalent — seed data pending domain-expert confirmation. Fine for now, but seed-data placeholders shipped to prod are a known footgun.
**Fix:** Track each behind a ticket and confirm the canonical names before go-live; the `TODO(US-…)` ticket-tagging is good practice — just make sure those US references resolve to live tracker items.

---

## question:

### Q1 — `Division.update` re-reads the parent court via `getCourt.getById` — behaviour if the court was soft-deleted after division creation?
**Location:** `core/division/application/DivisionApplicationService.java:98`
**Issue:** On update, `getCourt.getById(division.getCourtId().value())` re-resolves the parent court to re-validate the formation against its type. If the court has since been soft-deleted, does `getById` throw `CourtNotFoundException` (→ 404/500), and is that the intended UX for editing a division whose court vanished? The create path explicitly checks `existsById` + `isStatus()` first; the update path assumes the court still resolves.
**Fix / clarify:** Confirm the intended behaviour (block edit with a friendly 422 "court no longer available" vs. let it 404). If the former, mirror the create path's `resolveActiveCourtType` guard on update.

---

## Candidates for portfolio handbook entries (`/codify-rule`)

These `CLAUDE.md` conventions are strong, generalizable, and worth promoting to a portfolio-wide handbook (`handbooks/architecture/` or `handbooks/language/java/`) so Rex enforces them on *every* Java/DDD project, not just Moj:

1. **"Cross-aggregate web mappers must expose `toResponses(List)` and route `toResponse` through it"** — the N+1-by-construction pattern. This is the single best idea in the doc and is language-agnostic (applies to any batch-fetch presentation layer). → `handbooks/architecture/batch-mapper-n-plus-one.md`, candidate for `ENFORCEMENT: blocking`.
2. **"Domain layer carries no framework imports; only ports + cross-package domain types are public"** — already verifiable via ArchUnit/Modulith, but worth a handbook entry so adopters without those gates still get the rule flagged in review. → `handbooks/architecture/hexagonal-visibility.md`.
3. **"Two-factory rule: `register()` validates invariants, `rehydrate()` does not"** and **"value-object format invariants live in the domain VO, never only at the DTO edge"** (directly relevant to S4). → `handbooks/architecture/ddd-aggregate-factories.md`.
4. **"Cross-aggregate field errors use the shared `FieldValidationException`, never a slice-local exception+handler pair"** — prevents the most common DDD-in-Spring sprawl. → `handbooks/language/java/field-validation.md`.

---

## Verdict

**COMMENT — high-quality codebase, no blocking defects to merge gates.** The single BLOCKING-tier item (B1) is a missing-test gap on the richest domain invariant, not a code defect; close it plus S1–S5 in a small follow-up and this codebase is exemplary. Calibration takeaway for future Moj PRs: hold them to the `iam/admin` bar — it's the reference, and the team already meets it almost everywhere. Watch the `division` slice and any new multi-reference aggregate most closely, since complexity is where the (few) drifts clustered.

---
🤖 Reviewed by Rex (Code Reviewer Agent)
