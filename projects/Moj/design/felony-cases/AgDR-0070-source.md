<!-- Source: ApexYard · templates/agdr.md · github.com/me2resh/apexyard · MIT -->

# Promote Case sub-resources to standalone aggregates

> In the context of the felony intake cycle (epic #321), facing that the Case sub-resources have individual add/edit/delete-by-id lifecycles (L3 CRUD) and that embedding them as `@OneToMany` children over-loads the case list, I decided to promote CivilClaimant, Exhibit, Attachment, and (last) Accused from Case child-entities to standalone aggregate roots — each its own sub-package + repository under the `judicialcase` module, referencing the case by `CaseId` — to achieve independent lifecycles and a lean list read, accepting a deliberate multi-aggregate intake transaction and the loss of the Case→child cascade (replaced explicitly).

**Status:** accepted (PO 2026-07-13; Tariq design-review SOUND-WITH-REFINEMENTS). **Supersedes** AgDR-0067/0068/0069 (sub-aggregate framing).

## Context

CivilClaimant/Exhibit (merged), Attachment (#367, held), and shipped Accused are currently child entities embedded in the `Case` aggregate (`@OneToMany(cascade=ALL, orphanRemoval=true)`), mutated via `Sync<X>(Case, List)` in dedicated `Case<X>ApplicationService`s and persisted by the Case cascade. `CasePersistenceMapper.toDomain` loads **all** children, so `CasePersistenceAdapter.findPage` (the list) over-loads them. The L3 APIs expose per-sub-resource add/edit/delete-by-id. The child tables already carry `id`/`case_id`/`created_at`/`updated_at`/`deleted_at`/`position` — already aggregate-shaped, so promotion needs **no migration**.

## Decision

Each sub-resource becomes an `AggregateRoot<X, XId>` with its own `XRepository`, in its own sub-package under the single `judicialcase` `@ApplicationModule` (NOT a separate module — one bounded context, tight `CaseId` coupling). Cross-aggregate reference is by `CaseId` only.

**Domain/persistence split (PO refinement, 2026-07-13):** the **domain `Case` drops the child collections** (lean domain; the persistence mapper stops loading them → the list never materialises them). BUT the **JPA `CaseJpaEntity` KEEPS the `@OneToMany(fetch=LAZY, cascade=ALL, orphanRemoval=true)`** for each child — purely so the **soft-delete cascade** (Case delete → child `@SQLDelete`) is preserved automatically. The child's JPA entity is therefore both a LAZY `@OneToMany` child (cascade path, never loaded on reads) AND has its own Spring Data repository backing the standalone aggregate's CRUD (direct `case_id` access). Same table, same entity, two access paths — no conflict. This is a deliberate, pragmatic persistence-vs-domain split: the persistence layer keeps the parent-child cascade convenience; the domain treats each child as its own aggregate; the read/list path loads none of them (LAZY + mapper skips).

## Consequences & required guards (from the design review)

1. **Intake composite = one `@Transactional`, multi-aggregate.** A composition service saves `Case` first, then each child aggregate via its own repository, in one transaction (single datasource, synchronous, all-or-nothing is desired). Deliberate, documented relaxation of one-aggregate-per-transaction — same spirit as `felonyintake`.
2. **Cascade RETAINED (resolves Tariq's risk 1).** By keeping the JPA `@OneToMany(cascade=ALL, orphanRemoval)` on `CaseJpaEntity` (LAZY, never loaded in the mapper), the soft-delete cascade Case → children is preserved automatically — `SoftDeleteCaseUseCase` and the courtsession cascade-soft-delete-case path keep working with **no explicit child-soft-delete code**. (This supersedes the design doc's "explicit cascade replacement" obligation.) Each extraction PR still adds a persistence IT asserting the case soft-delete cascades to its children.
3. **Lean list read model (CQRS-lite).** The list uses a scoped case projection + one batched `accusedNamesByCaseIds` query (names + charge names) — never the full aggregate, never claimant/exhibit/attachment. AccessScope applies to the driving case query; accused inherit scope via the page's caseIds.
4. **Accused specifics (promote LAST, with guards):**
   - **Positional-ordering contract (HIGH):** `courtsession.CommitSession.buildAccusedSnapshot` pairs commit inputs *by position* with the roster; the `syncAccused` return order is the renewal correctness contract. Reshape the cross-module port to `List<Accused> syncAccused(CaseId, List<SyncAccusedInput>)` (returns the ordered roster; `Accused` stays type-exposed via `judicialcase::ports` → graph stays acyclic). Pin with a renewal regression test.
   - **Track-dependent accused-minimum (MEDIUM):** accused is **required (≥1) for RENEWAL (تجديد) cases only; OPTIONAL (0 allowed) for FELONY (FELONY_FIRST)** — per the track-dependent rule (ticket #326 / AgDR-0064). The shipped `Case.register` currently requires ≥1 universally; that must become **case-type-dependent**, and the accused delete-by-id guard must reject deleting the *last* accused **only for renewal cases** (felony may go to zero). This folds the #326 track-dependent-minimum work into the accused promotion (step 5). Tariq's "≥1 guard" is therefore renewal-only, not universal.
   - Merge-gated on a full M1 courtsession/renewal regression.

## Rework sequence

1. Lean list projection (perf; folds into story-A read model).
2. CivilClaimant → standalone (introduces the composite-save seam).
3. Exhibit → standalone.
4. Attachment → standalone (reworks held #367).
5. Accused → standalone LAST, with the guards above + renewal regression.

Each step = one aggregate, one PR on the felony epic branch, its own Rex review; courtsession-touching PRs also run the renewal regression.

## Artifacts

- Epic #321 · Design doc: `projects/Moj/design/felony-cases/subresource-aggregate-promotion.md` · Supersedes AgDR-0067/0068/0069 · Related AgDR-0018/0029 (audit back-pointer), AgDR-0064 (felony data-modeling).
