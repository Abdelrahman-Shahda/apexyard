# Design — Enriched transcript read + speaker audit-relation (post-#210)

> Status: **designed, ready to build** (Tech Lead spec, source-verified). Builds on merged PR #210.
> Feature ticket: TBD (GitHub issue-create API was hanging at authoring time — file before the code build).
> AgDR: **amends AgDR-0036** (no new schema; code-only).

## CEO decision (the through-line)

Speakers must resolve through the **standard audit relation-expansion** — exactly like `chargeIds → ("charges","Charge")` on `SessionAccusedAuditAdapter` — **not** a transcript-special-case resolver. That is *why* the transcript change body is a `{field:{old,new}}` snapshot. Pragmatic constraints:

- The speaker is made **auditable only as a relation-resolution target**: an adapter with `escapedActions()` = ALL (writes no rows of its own).
- Referenced speakers can't be deleted once the session starts → enforced by a **courtsession-internal status guard** (no migration, no soft-delete, no transcript dependency → no module cycle).

## Two source-verified facts the design hinges on

- **Fact A** — `TranscriptLineApplicationService.recordNewChanges` already writes a SPEAKER change as `{"speakerId":{"old":<id>,"new":<id>}}` (raw id strings under `old`/`new`).
- **Fact B** — `AuditQueryService.resolveChanges → resolveRelationSides → RelationExpansion.expandValue` already resolves ids **inside** the `{old,new}` map (not just top-level snapshot fields). So once `TranscriptLineAuditAdapter.relations()` declares `speakerId → ("speaker","Speaker")` **and** a `Speaker` adapter is registered, the existing `changeSetsOf` read emits `{"speaker":{"old":{id,name},"new":{id,name}}}` with **no read-path code**. `AuditAdapterRegistry` indexes adapters by `type()` regardless of `escapedActions()`, so an all-escaped adapter is a first-class relation target.

> **Load-bearing risk to guard with a blocking test:** if the `Speaker` adapter is ever removed ("it writes no rows"), `speakerId` silently regresses to raw ids (no error). The relation-expansion integration test must be blocking.

## Build plan (file-by-file)

### New (courtsession)

- `infrastructure/persistence/SessionSpeakerAuditAdapter.java` — `type()="Speaker"`; `escapedActions()` = `AuditAction.values()` (all, derived not hardcoded); `displayNamesByIds(ids)` is the load-bearing method for relation expansion (batch, via the shared resolver); `snapshot`/`displayName` for completeness; `displayColumns()=["speakerType","name"]`. `snapshotByIds` uses plain `findAllById` (speaker table has **no** soft-delete; referenced speakers aren't deleted per the guard). Package-private `@Component`, mirrors `SessionAccusedAuditAdapter`.
- `infrastructure/persistence/SessionSpeakerNameResolver.java` — shared polymorphic name resolution, used by BOTH the audit adapter and the live summary (kills duplication). Resolves by `speakerType` + `referenceId` (which points at the **session-scoped child snapshot** ids, all courtsession-internal):
  - JUDGE → `court_session_judges.name`
  - ACCUSED → `court_session_accused.accused_name`
  - LAWYER → `court_session_accused_lawyers.lawyer_name`
  - PROSECUTOR → localized literal (`speaker.prosecutor`, referenceId null)
  - OTHER → null/literal (future)
  Batch `resolveNames(...)` = one query per type (no N+1). Null name tolerated downstream (`idName(id,null)`).
- `domain/CourtSessionSpeakersFrozenException.java` — → 409 in the session exception handler (`COURT_SESSION_SPEAKERS_FROZEN_TITLE/_DETAIL`, both locales).
- `application/ListSessionSpeakersUseCase.java` (`list(sessionId): List<SpeakerSummary>`) + `ResolveSessionSpeakersUseCase.java` (`resolve(Collection<UUID>): Map<UUID,SpeakerSummary>`, batch) — added to `@NamedInterface("ports")`.
- `infrastructure/web/.../SpeakerWebMapper.java` — `@Component`, owns `SpeakerSummary` construction via the resolver.
- `infrastructure/web/dto/SpeakerSummary.java` — `{ id, name, speakerType, referenceId, micSlot, position }` in the `@NamedInterface("dto")` package (embeddable by transcript).

### Modified

- `transcript/infrastructure/persistence/TranscriptLineAuditAdapter.java` — `relations()` returns `Map.of("speakerId", new AuditRelation("speaker","Speaker"))` (one-liner; keep `escapedActions()={UPDATED}` and `displayColumns()` listing `speakerId`).
- `transcript/infrastructure/web/dto/TranscriptLineResponse.java` — add `SpeakerSummary speaker` (null when no speaker) + `List<AuditChangeSetResponse> changes` (inline).
- `transcript/infrastructure/web/TranscriptWebMapper.java` — inject `AuditQueryService` (or a thin port) + `ResolveSessionSpeakersUseCase`; **one** `changeSetsOf("TranscriptLine", allLineIds)` call, group by `targetId` (line id), attach per line; resolve all line speakers in one `resolve(...)` call. Batch-only public entry (no N+1 bypass).
- `courtsession/domain/CourtSession.java` — `ensureSpeakersMutable()` (throws `CourtSessionSpeakersFrozenException` unless `PENDING`). Reads only `this.status` → no transcript dependency.
- `courtsession/application/CourtSessionApplicationService.java` — `syncSpeakers` first line calls `session.ensureSpeakersMutable()`; implement the two new use cases.
- `courtsession/application/package-info.java` — add the two ports to `@NamedInterface("ports")`.
- `courtsession/infrastructure/web/detentionrenewal/dto/CourtSessionResponse.java` — add `List<SpeakerSummary> speakers`.
- `courtsession/infrastructure/web/detentionrenewal/CourtSessionWebMapper.java` — populate `speakers[]` (intra-module via `SpeakerWebMapper`).
- session controller exception handler — map the new 409.
- `messages*.properties` (+`_ar`) + `MessageKeys` — `speaker.prosecutor`, the frozen title/detail.
- `docs/agdr/AgDR-0036-*.md` — amendment section.

## Cycle-safety (the key constraint)

The guard reads only `CourtSession.status`; the audit adapter + resolver read only courtsession-internal entities. **Zero** `courtsession → transcript` imports. `transcript → courtsession` stays the only edge. `ModularityTests` is the regression guard — call it out in the PR.

## Why no migration / no AgDR-0036 reversal

`syncSpeakers` (delete-all + re-add) is reachable only from `commit` (creates PENDING) and `edit` (PENDING-gated). Transcription requires AWAITING_VERDICT. So a speaker is provably never deleted while a transcript line could reference it — the **lifecycle is the guard**; `ensureSpeakersMutable()` just makes the invariant explicit + future-proof.

## Test surface

- Domain: `ensureSpeakersMutable` passes PENDING, throws on AWAITING_VERDICT/FINISHED.
- Adapter: `type()=="Speaker"`, all actions escaped (loop the enum), `displayNamesByIds` resolves each type + literal, unknown id → absent.
- **Relation-expansion integration (blocking):** a `{"speakerId":{old,new}}` body through `resolveChanges` with the `Speaker` adapter registered → `{"speaker":{old:{id,name},new:{id,name}}}`; with the adapter absent → falls back to raw `speakerId`.
- Web: transcript read returns inline `changes` (assert single `changeSetsOf` call) + resolved `speaker`; session read returns `speakers[]`.
- `ModularityTests` green (no cycle); `MessageBundleCompletenessTest` (both locales).
