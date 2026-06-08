ENFORCEMENT: blocking

# Handbook: N+1-Safe Batched Web Mappers

**Scope:** PRs touching Java files (handbook lives under `language/java/` — Rex loads it when the diff includes `.java`).
**Enforcement:** blocking.

## The rule

A web mapper that needs cross-aggregate reads (other use cases, a `MessageResolver`, etc.) must expose **both** `toResponse(X)` **and** `toResponses(List<X>)`, and the batched version must internalize the N+1 fix — fetch all referenced data in one query, then map row-by-row from the in-memory result. Controllers and callers must use `toResponses(...)` for list/collection endpoints; they must never loop and call `toResponse(...)` per row.

The single-item `toResponse` may delegate to the batched path (`toResponses(List.of(x)).get(0)`) so there is exactly one fetch strategy.

## Why

The classic N+1: a list endpoint returns N aggregates, and the mapper does one cross-aggregate lookup *per* aggregate → 1 + N queries. It passes every test (the data is correct), passes review if the reviewer doesn't think about row counts, and only shows up as a latency cliff in production once N grows. Making the batched method the *only* way to map a collection means a caller **cannot** reintroduce per-row fetch by accident — the safe path is the easy path. Audit-log enrichment (which resolves UUID reference lists into snapshots) has the same exposure and the same fix.

## What Rex flags

- A `*WebMapper` / `*Mapper` with cross-aggregate dependencies injected (a use-case port, a repository, a `MessageResolver`) that exposes **only** `toResponse(single)` and no `toResponses(List)`.
- A controller or service iterating a collection and calling the single-item mapper per element: `list.stream().map(mapper::toResponse)`, `for (var x : list) mapper.toResponse(x)`, `items.forEach(i -> ... toResponse ...)`.
- A `toResponses(List)` implementation that internally loops `toResponse` per element while that single-item method itself performs a cross-aggregate fetch (the batch is a fake — still N+1).
- Entity-side: an `@ElementCollection` or multi-row association feeding a list endpoint without `@BatchSize(...)`.

## Sample finding

> **BLOCKING — N+1 query.** `FooWebMapper.toResponse` fetches related Bars via `getBarsByIds` (cross-aggregate read), and `FooController.list` maps the page with `.map(fooWebMapper::toResponse)` — that's one Bar query per Foo row (1 + N). Add `toResponses(List<Foo>)` that batches the Bar lookup into a single call and map from the in-memory result, then call it from the controller. Mirror `AdminWebMapper.toResponses`.

## What's NOT a violation

- **Pure-projection mappers with no cross-aggregate reads** (e.g. `RoleWebMapper`) — a per-row `toResponse` is fine; there is no extra query to batch. Exposing only `toResponse` is acceptable here.
- A single-object endpoint (`GET /foo/{id}`) that legitimately maps one aggregate with `toResponse`.
- A `toResponses` that loops `toResponse` when `toResponse` does **no** cross-aggregate I/O (pure in-memory construction) — no N+1 exists.
- Repositories already returning the joined data eagerly (a single query with a fetch-join) — the batching has happened at the persistence layer.

---

_Source: Rex code-quality calibration review during the **Moj** (MOJ Judiciary Portal) handover, 2026-06-08 — see `projects/Moj/code-review.md`. The pattern is documented as canonical in the project's own `backend/CLAUDE.md` (§ "Mappers and controllers"); promoted here so Rex enforces it across every Java/DDD project in the portfolio._
