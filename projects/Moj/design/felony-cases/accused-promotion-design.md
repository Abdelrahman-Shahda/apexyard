# Design — promote Accused to a standalone aggregate (the renewal-critical one)

> **Status:** Draft for `/design-review` (Tariq) — doc-only, pre-build
> **Author:** Tech Lead (Hisham) · **Part of:** AgDR-0070 (step 5, last) · epic #321
> **Why separate doc:** accused differs from the three merged promotions (claimant/exhibit/attachment) on four axes and touches shipped renewal — Tariq flagged it as the load-bearing risk.

## How accused differs (confirmed in code)

1. **Shared across court sessions.** Each session snapshots the case's accused into `court_session_accused` (positionally); accused have live downstream references.
2. **Additive-reconcile, NOT strict-mirror.** `SyncCaseAccusedUseCase.sync` never removes accused (issue #146) — removing one would break historical session snapshots. Must stay additive.
3. **Mandatory, universally.** `Case.register` throws `"At least one accused person is required"` for every case (line 86-87).
4. **Cross-module.** `courtsession.CourtSessionApplicationService` calls `syncCaseAccused.sync(Case, List) → Case` (lines 415, 803), then `buildAccusedSnapshot(synced, …)` pairs commit inputs with the returned roster **by position** — this order is the renewal correctness contract.

## The plan

### 1. Package move (same hybrid as the other three)

`Accused` → `judicialcase/accused` standalone `AggregateRoot<Accused, AccusedId>` holding `CaseId` + its charges + name/gender/etc.; own `AccusedRepository` (by-case, by-id CRUD, + the additive sync). Keep the `@OneToMany(LAZY, cascade=ALL, orphanRemoval)` on `CaseJpaEntity` (cascade-only, read-only join column) + the `setAccused`/re-attach-on-save mechanism (as done for attachment). Domain `Case` drops the accused collection. Move `CaseAccusedAuditAdapter` (keeps `chargeIds→Charge` relation + Case back-pointer). Move the `case_accused_charges` mapping with it.

### 2. Cross-module port reshape (the risky change)

`Case sync(Case theCase, List<SyncAccusedInput>)` **⟹** `List<Accused> syncAccused(CaseId caseId, List<SyncAccusedInput>)` — returns the **ordered** roster (additive-reconcile: named-in-input first in input order, then untouched others). `courtsession` consumes the returned `List<Accused>` directly for `buildAccusedSnapshot`, **preserving the positional pairing**. The port stays in `judicialcase`'s `@NamedInterface("ports")`; `Accused` stays type-exposed via the return type — so `courtsession → judicialcase` stays the only edge (acyclic; `ModularityTests` green). `courtsession` no longer round-trips a whole `Case` for the roster (it uses `GetCaseUseCase` for case identity as needed).

### 3. Additive-reconcile preserved

The sync stays additive (never removes accused). This is the opposite of claimant/exhibit/attachment's strict-mirror — do NOT copy their `replaceRoster`. Model it on the existing `SyncCaseAccused` reconcile.

### 4. Track-dependent minimum (folds in #326 / AgDR-0064)

`Case.register`'s universal `≥1 accused` becomes **case-type-aware**: **≥1 for renewal (تجديد), 0 allowed for felony (FELONY_FIRST)**. The L3 `DeleteAccusedUseCase` guard rejects deleting the *last* accused **only for renewal** (felony may go to zero). Since accused is now a separate aggregate, this cross-aggregate invariant lives in the accused delete/create use cases (which read the case's type).

### 5. Snapshot integrity

`court_session_accused` references `case_accused` (`case_accused_id`). Verify the move keeps that FK/reference and the soft-delete-aware `snapshotByIds` intact — a session's frozen snapshot must still resolve its accused after the promotion.

## Safety net (merge gate)

The full **M1 courtsession/renewal regression** must stay green: session commit-create, commit-edit with kept/added accused, finalize with per-accused rulings, and the cascade-soft-delete-case-when-last-session-deleted path. Plus new accused-aggregate tests (CRUD, additive sync ordering, track-dependent min, cascade, list-not-loaded).

## Open questions for the reviewer (Tariq)

1. **Port reshape correctness** — is `syncAccused(CaseId) → ordered List<Accused>` the right shape to preserve the positional `buildAccusedSnapshot` contract, and does it keep the module graph acyclic (Accused exposed only via the port return type)? Any subtlety in `courtsession` losing the round-tripped `Case`?
2. **Additive-reconcile in a standalone aggregate** — the sync loads existing accused by caseId, reconciles additively, returns the ordered roster. Any consistency concern now that it's a separate aggregate (vs mutating a passed `Case`)?
3. **Track-dependent min placement** — `Case.register` is on the Case aggregate but the accused now live in a separate aggregate. Where does the "≥1 for renewal" invariant best live at case-create time (the composite intake service? a domain check the intake calls?), and the delete-last guard in the accused delete use case — is that split sound?
4. **Snapshot integrity** — anything in the `court_session_accused → case_accused` relationship that the promotion could subtly break (soft-delete-aware resolution, the positional order after an additive sync)?
5. **Sequencing/rollback** — is there a safe intermediate (e.g. keep the old `sync(Case,List)` port as a thin delegate during transition) or should it be a single atomic PR with the regression gate?
