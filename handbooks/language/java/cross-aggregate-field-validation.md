# Handbook: Shared Exception for Cross-Aggregate Field Validation

**Scope:** PRs touching Java files (handbook lives under `language/java/` — Rex loads it when the diff includes `.java`).
**Enforcement:** advisory.

## The rule

Cross-aggregate / foreign-key / application-layer field errors (e.g. "this `roleId` doesn't exist") are raised from the application service by accumulating them into the **shared** field-validation exception (here `shared.web.FieldValidationException`) and throwing once, so the global handler maps them uniformly to a `422` with a flat, localized, dotted `errors` map:

```java
var errors = FieldValidationException.builder();
for (int i = 0; i < ids.size(); i++) {
    if (!repo.existsById(ids.get(i))) {
        errors.field("roleIds." + i, MessageKeys.Errors.UNKNOWN_ROLE_ID, ids.get(i));
    }
}
errors.throwIfAny();
```

Do **not** create a per-slice exception + `@RestControllerAdvice` pair for this case. (Slice-local exceptions remain correct for *domain* errors — not-found, conflict, invalid value object — mapped in that slice's own handler.)

## Why

Cross-aggregate "does this referenced id exist?" validation appears in nearly every slice. If each slice invents its own exception and handler for it, the 422 response shape drifts (different JSON keys, different localization, some handlers forgetting the dotted-index form for list fields), and the same logic is reimplemented N times. Routing all field-level application errors through one shared accumulator gives every endpoint an identical, localized, machine-parseable 422 contract — and the accumulate-then-throw-once shape means a client sees *all* bad fields in one response instead of fixing them one round-trip at a time.

## What Rex flags

- A **new** slice-local exception class whose purpose is "referenced id / foreign key doesn't exist", plus a matching `@RestControllerAdvice` mapping it to 422 — duplicating what the shared `FieldValidationException` + global handler already do.
- An application service throwing a generic exception (or a domain not-found) for a *cross-aggregate existence* check that should be a field error on the request, rather than using the shared field-validation builder.
- Cross-aggregate existence checks performed in the **domain** layer (they belong in the application service, surfaced as field validation) — see also the layering handbook.
- Manual `Map<String,String>` error assembly in a controller for field errors instead of the shared exception.

## Sample finding

> **suggestion:** `AssignBarsService` introduces `UnknownBarException` + a dedicated `@RestControllerAdvice` to return 422 when a referenced `barId` is missing. That duplicates the shared `FieldValidationException` path. Accumulate field errors via `FieldValidationException.builder().field("barIds." + i, ...)` and `throwIfAny()` — the global handler already maps it to a localized 422. Drop the slice-local exception+advice pair.

## What's NOT a violation

- Slice-local exceptions for genuine **domain** errors — not-found on the primary aggregate, state conflicts, invalid value objects — mapped in the slice's own `*ExceptionHandler`. The rule is specifically about *cross-aggregate field* errors.
- Bean-Validation (`@NotBlank`, `@Pattern`, …) failures on request DTOs — those already flow through the framework's `MethodArgumentNotValidException` handling; they don't need the builder.
- A project that hasn't got a shared field-validation exception at all (different stack/framework) — this rule presumes the shared-handler pattern exists; flag it as a suggestion to adopt, not a hard miss.

---

_Source: Rex code-quality calibration review during the **Moj** (MOJ Judiciary Portal) handover, 2026-06-08 — see `projects/Moj/code-review.md`. Documented as canonical in the project's `backend/CLAUDE.md` (§ "DTOs, validation, and 422 errors"); promoted here so Rex enforces it across every Java/DDD project in the portfolio._
