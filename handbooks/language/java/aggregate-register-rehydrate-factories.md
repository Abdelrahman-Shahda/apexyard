# Handbook: Two-Factory `register` / `rehydrate` on Aggregates

**Scope:** PRs touching Java files (handbook lives under `language/java/` — Rex loads it when the diff includes `.java`).
**Enforcement:** advisory.

## The rule

A DDD aggregate root exposes exactly **two** construction paths, and no public constructor:

- **`register(...)`** (or `create(...)`) — the factory for **new** aggregates. It **validates invariants**: enforces required fields, value-object construction, and any cross-field rules. This is the only way a genuinely new aggregate comes into existence.
- **`rehydrate(...)`** — the factory used **only by the persistence mapper** to rebuild an aggregate from already-persisted state. It does **not** re-validate, because the data already passed validation when it was first registered.

Mutations happen through behaviour methods that enforce invariants — never through setters.

## Why

Conflating "new" and "loaded-from-DB" construction is a classic source of two opposite bugs. If the load path re-runs `register`-style validation, you can't load historical rows that were valid under older rules (a tightened invariant retroactively breaks reads). If the new-object path skips validation, invalid aggregates get created and only blow up later, far from the cause. Splitting the two factories makes the intent explicit at every call site: `register` is a business operation that can fail; `rehydrate` is a trusted reconstruction that can't. It also keeps the validation logic in exactly one place (the `register` path + value objects) instead of being duplicated or accidentally bypassed.

## What Rex flags

- A new aggregate root with a **`public` constructor**, or with `@Setter` / public setters on a domain type.
- A single factory used for both new creation and persistence reconstruction (the persistence mapper calling the same validating `register`/`create` the application service uses).
- A persistence mapper that constructs the aggregate via a validating factory instead of a dedicated `rehydrate`.
- Mutation via field assignment / setters rather than an invariant-enforcing behaviour method.

## Sample finding

> **suggestion:** `Foo` is rebuilt by `FooPersistenceMapper` using `Foo.register(...)`, which re-runs new-aggregate validation on every DB load. Add a `Foo.rehydrate(...)` factory for the mapper that reconstructs state without re-validating, and keep `register(...)` for genuinely new aggregates. Mirrors the `register` / `rehydrate` split on `Admin`.

## What's NOT a violation

- An aggregate with only `register(...)` and no `rehydrate(...)` because its persistence mapper genuinely doesn't exist yet / it isn't persisted — add `rehydrate` when persistence lands, not before.
- Value objects (records) with self-validating compact constructors — those *should* validate on every construction; the two-factory rule is about **aggregate roots**, not VOs.
- A protected/package-private no-arg constructor required by JPA on the **entity** class (`*JpaEntity`) — that's the dumb persistence object, not the domain aggregate.
- Test fixtures/builders constructing aggregates through `register` — tests exercising the validating path is correct.

---

_Source: Rex code-quality calibration review during the **Moj** (MOJ Judiciary Portal) handover, 2026-06-08 — see `projects/Moj/code-review.md`. Documented as canonical in the project's `backend/CLAUDE.md` (§ "Domain"); promoted here so Rex enforces it across every Java/DDD project in the portfolio._
