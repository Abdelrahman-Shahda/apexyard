# Handbook: Hexagonal Port Visibility

**Scope:** PRs touching Java files (handbook lives under `language/java/` — Rex loads it when the diff includes `.java`).
**Enforcement:** advisory.

## The rule

In a hexagonal + DDD vertical-slice module, **only ports and cross-package domain contracts are `public`**:

- Public: the aggregate root, its id value-object, the repository **interface** (output port), use-case **interfaces** (input ports), command records, and domain exceptions.
- Package-private: every implementation — the `@Service` application service, the `@Repository` persistence adapter, the `@RestController`, JPA entities, Spring Data repositories, and the manual mappers.

A class is `public` only because something in another package legitimately depends on it through a defined contract. Default to package-private and widen only when a real cross-package consumer exists.

## Why

Visibility is the cheapest, most durable boundary enforcement there is — it's checked by the compiler on every build, with zero test or tooling cost. When implementations are `public`, another slice can reach in and call a controller or persistence adapter directly, the slice stops being interchangeable, and the Modulith/ArchUnit boundary tests that *would* have caught a cross-slice dependency never fire because the dependency went through a "legal" public type. Tight visibility is what makes the architecture verify in practice rather than only on the diagram.

## What Rex flags

- A `public class` on an application service (`*ApplicationService`), persistence adapter (`*PersistenceAdapter`), controller (`*Controller`), JPA entity (`*JpaEntity`), Spring Data repo (`*JpaRepository`), or mapper (`*Mapper`) — these should be package-private.
- A new cross-package `import` of another slice's implementation type (not its port/use-case interface or shared domain contract).
- A use case or repository exposed as a `public class` rather than a `public interface` + package-private impl.

## Sample finding

> **suggestion:** `FooApplicationService` is declared `public`, but it's an implementation of the `FooUseCase` input port — nothing outside this package should depend on the concrete service. Make it package-private (`@Service` works fine without `public`); callers depend on the `FooUseCase` interface. Mirrors `AdminApplicationService`.

## What's NOT a violation

- The aggregate, id VO, repository **interface**, use-case **interfaces**, command records, and domain exceptions being `public` — those are the contract; they're *supposed* to be public.
- A deliberately-shared cross-slice contract type (e.g. a `PermissionCatalog` interface that another slice implements by design) — these are explicitly-sanctioned public types; the rule is about *implementations* leaking, not contracts.
- `@Configuration` / `@Bean`-factory classes and `package-info.java`.
- `public` accessor methods on a package-private class — visibility of *members* is a different concern.

---

_Source: Rex code-quality calibration review during the **Moj** (MOJ Judiciary Portal) handover, 2026-06-08 — see `projects/Moj/code-review.md`. Documented as canonical in the project's `backend/CLAUDE.md` (§ "Visibility"); promoted here so Rex enforces it across every Java/DDD project in the portfolio._
