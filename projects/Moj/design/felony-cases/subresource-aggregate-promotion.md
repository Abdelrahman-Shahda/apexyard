# Design — promote Case sub-resources to standalone aggregates

> **Status:** Draft for `/design-review` (Tariq) — doc-only, pre-rework
> **Author:** Tech Lead (Hisham) · **Trigger:** product-owner call (2026-07-13)
> **Affects:** merged #352 (civil claimant), #324 (exhibit), in-review #367 (attachment, held), + shipped Accused
> **Related:** AgDR-0067/0068/0069 (sub-aggregate framing — this supersedes it), AgDR-0018/0029 (child audit + back-pointer)

## Decision

Promote the four Case sub-resources — **CivilClaimant, Exhibit, Attachment, and Accused** — from **child entities embedded in the `Case` aggregate** to **standalone aggregate roots**, each in its own sub-package under the `judicialcase` `@ApplicationModule` (`judicialcase/civilclaimant`, `/exhibit`, `/attachment`, `/accused`), each with **its own repository** that references the owning case by **`CaseId`** (a value/FK), not by embedding. `Case` no longer holds child collections.

## Why (product-owner reasoning, validated)

The L3 APIs expose **individual add / edit / delete-by-id** per sub-resource (e.g. `POST /cases/{id}/civil-claimants`, `PUT …/{claimantId}`, `DELETE …/{claimantId}`). A thing you can independently create/mutate/delete *by its own identity* has its own lifecycle → it is an **aggregate**, not a value collection inside `Case`. Embedding them as `@OneToMany` children of `Case` also forces the **case list to load every child collection** (`CasePersistenceAdapter.findPage → CasePersistenceMapper.toDomain` materialises accused + claimants + exhibits + attachments for every row), which is the performance problem that surfaced this decision.

## Aggregate boundaries

- Each sub-resource is an `AggregateRoot<X, XId>` with its own `XRepository` (jMolecules), holding a `CaseId` field (the owning case).
- `Case` drops `accused`/`civilClaimants`/`exhibits`/`attachments` collections and their `@OneToMany` mappings. `Case` becomes lean: identity (number/year/station/type), felony detail (via `case_felony_details`), audit columns.
- Cross-aggregate reference is by `CaseId` only (no object nav from Case → children).

## The composite write (J / case intake)

Individual CRUD each load/mutate/save their **own** aggregate via its repository. The **case-intake composite** (J, "save the whole case + its parties/exhibits/attachments at once") becomes a **composition/application service** that, in **one `@Transactional`**, saves the `Case` then each child aggregate via its own repository. This relaxes the strict "one aggregate per transaction" guideline pragmatically for the intake use case — **document the trade-off in the AgDR** (it's a deliberate, bounded composite, same spirit as the earlier `felonyintake` orchestration decision). The `(Case, List)` sync signature from the child-entity design is replaced by per-aggregate repository saves keyed on `CaseId`.

## The list read model (the problem this fixes)

The case list uses a **lean read projection** — case columns + accused **names** + charge names (the actual list columns per the design), fetched via a targeted query, **never** the full aggregate and **never** the claimant/exhibit/attachment tables. Details (L) loads the case then queries each child aggregate by `CaseId`. This is CQRS-lite: aggregates for commands, a projection for the list query.

## No migration required

The child tables (`case_accused`, `case_civil_claimants`, `case_exhibits`, `case_attachments`) **already have a `case_id` FK** — exactly the shape a standalone aggregate needs. Promotion is a **pure code refactor** (embedded `@OneToMany` → standalone aggregate + repository); **no schema change, no data migration.**

## Audit

The sub-resources are already independently audited with a `Case` back-pointer (AgDR-0018/0029) — which is *consistent with* them being standalone aggregates (they always kept their own audit rows). The audit adapters stay; only the persistence ownership changes.

## Scope & risk

- **Felony three (claimant/exhibit/attachment):** rework the two merged slices (#352/#324) + the held #367. New code, contained in judicialcase — moderate.
- **Accused (included per PO):** **higher risk** — `SyncCaseAccused` is called by the shipped **courtsession** commit path (renewal-critical) and by the accused audit/snapshot. The rework must preserve renewal behaviour exactly; needs a full regression pass (the M1 courtsession ITs) and careful handling of the `courtsession → judicialcase` dependency (courtsession must reach the accused aggregate via a judicialcase `@NamedInterface` port, keeping the module graph acyclic).

## Rework plan (post-design-review)

1. One aggregate at a time, each its own PR on the felony epic branch: extract `X` into `judicialcase/<x>` as an aggregate root + repository (referencing `CaseId`); move its persistence/audit; add the by-id CRUD use cases (or stubs for L3); update the composite-save path.
2. Rework the list to the lean projection.
3. Accused last (highest risk) — with a full courtsession/renewal regression run.
4. File the superseding AgDR (AgDR-0070) in the repo with the rework.

## Open questions for the reviewer (Tariq)

1. Aggregate placement: sub-packages within the single `judicialcase` module (proposed) vs. separate `@ApplicationModule`s — confirm same-module is right given the tight `CaseId` coupling.
2. The composite-save multi-aggregate `@Transactional` — acceptable, or prefer a domain-event / saga shape? (Intake is synchronous and user-facing, so one tx seems right.)
3. Accused promotion across the shipped `courtsession` boundary — the safest sequencing to avoid a module cycle and preserve renewal behaviour.
4. Does the list projection need accused as a joined read model, or a separate `accused-by-case` query per page (batched)?
5. Is there any invariant that genuinely needs `Case` + a child mutated atomically *outside* the intake composite (which would argue for keeping that child embedded)?
