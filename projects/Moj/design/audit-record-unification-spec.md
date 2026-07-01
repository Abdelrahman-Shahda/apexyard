# Design — Unify auto + manual audit record creation (refactor)

> Status: **designed, not built** (Tech Lead spec). Separate refactor PR, lands after the enriched-read PR. Its own AgDR + Tariq design-review (Gate 3b).
> Motivation: CEO asked for a common record-creation core + a strategy split between auto-diff and explicit old/new body-building.

## Key finding

The terminal write (`AuditRecorder.write(...)`) is **already** the de-facto common core — both paths converge there (auto goes `PendingAudit → AuditBuffer → recorder.recordWith → write`; manual calls `record(...) → write`). The refactor formalises a seam that ~80% exists; it does not invent one.

## Design

1. **`AuditRecordFactory.create(context, action, type, id, changesBody, relatedTargets, occurredAt) → UUID`** — the single create-and-persist seam (package-private `@Component`, **not** `@Transactional` — runs in caller's tx). `serialize()` + `mapRelated()` move here from `AuditRecorder.write`. Both paths route through it. (Acceptable smaller-diff alternative: rename `AuditRecorder.write → create` in place. Lead prefers the dedicated class for the responsibility split.)
2. **Body-builder strategies** (same `{field:{old,new}}` LinkedHashMap output, byte-identical to today):
   - `AutoDiffBodyStrategy` — relocate the listener's `diff()`/`sideOnlyChange()`/`renderValue()`/`isSoftDeleteTransition()` + `IGNORED/SENSITIVE_PROPERTIES` out of `AuditingListener` into a `@Component`. Pure move → output guaranteed identical.
   - `ExplicitChangeBody` (public builder) — `.change(field, old, new).build()`, null-safe (LinkedHashMap, since `Map.of` rejects null). Replaces hand-built maps in the transcript caller.
   No runtime `Strategy` interface (no polymorphic dispatch point + the two inputs differ fundamentally) — the unifying contract is the **output type**, not a method signature.
3. **Buffering asymmetry is permanent-by-design (the load-bearing call): manual events stay INLINE, NOT routed through `AuditBuffer`.** Routing manual through the buffer would (a) **drop** `recordCritical` failure audits (the buffer's drop-on-rollback deletes the very rows `recordCritical` exists to keep), and (b) **collapse** the transcript's N-distinct-per-change rows (the buffer's `mergeUpdate` coalesces multiple UPDATEDs on one target → destroys the per-change receipts). So the buffer stays an auto-only coalescing stage that ultimately calls the same `AuditRecordFactory.create`.

## Transcript caller migration (the demonstration, ships in this PR)

`TranscriptLineApplicationService.recordNewChanges`: replace the hand-built `Map.of(field, LinkedHashMap(old,new))` with `ExplicitChangeBody.builder().change(fieldKey, oldVal, newVal).build()`. The `record(...)` call + the running-old replay are unchanged; N-distinct-rows behaviour preserved.

## Scope / risk

- **Separate PR** (not bundled with a feature). 23 adapters + 2 manual callers (`AuthApplicationService` untouched, transcript migrated) + ~795 tests ride on `shared/audit`.
- Blast radius: behavioural for the auto path's emitted bytes — guarded by `AutoDiffBodyStrategy` being a verbatim move + a characterization test diffing persisted `changes` JSON before/after on CREATE/UPDATE/soft-delete/collection-change.
- Risks: LinkedHashMap ordering drift (characterization test); proxy-boundary regression on `recordCritical` REQUIRES_NEW (factory must NOT be `@Transactional`; propagation stays on `AuditRecorder`); a future dev routing manual through the buffer (AgDR records the asymmetry as intent).
- Tests to keep green: `AuditingListenerIntegrationTest`, `AuditEntityCentricReadIntegrationTest`, `CaseAuditWritePathIntegrationTest`, the SPI guard/registry/relation-expansion tests, + the transcript change-set ITs.

## AgDR

One AgDR: extract `AuditRecordFactory` as the single seam; `AutoDiffBodyStrategy` + `ExplicitChangeBody`; keep manual inline (don't route through buffer) — accepting the buffering asymmetry as permanent-by-design. Options: (A) single core + strategy + keep asymmetry [chosen]; (B) route all through buffer [rejected — drops critical events, collapses transcript rows]; (C) leave two paths [rejected — the duplication flagged].
