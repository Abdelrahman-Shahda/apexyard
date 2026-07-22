# Initiative — Forensic Doctors CRUD (الأطباء الشرعيون)

> **Goal:** ship the forensic-doctor registry — list / add / edit / deactivate a doctor, with his platform account (role طبيب شرعي) created in the same atomic save.
> **Spec (ACs):** Confluence [CRUD — طبيب شرعي](https://apessolutions.atlassian.net/wiki/spaces/MOJ/pages/1218248707/CRUD) (US-FDOC-001 … 006) · **Screens:** `projects/Moj/design/forensic-cycles/`
> **Technical design:** [`../design/forensic-doctors/tech-design.md`](../design/forensic-doctors/tech-design.md)
> **Repo:** apessolutions/moj_judiciary · **Base branch:** `development` — **merged**
> (#531 → `648f57b0`, #533 → `95ae58e2`, both 2026-07-22).

> ⚠️ **Base-branch choice should have been a CEO decision and wasn't.** This document and the
> technical design both said `development` (trunk-based, no integration branch) from the first draft,
> reasoning that forensic doctors is a separate epic from felony. **That was an inference, never
> checked.** The felony initiative had already established the opposite pattern in plain sight —
> renewal ships from clean `development` while felony stays isolated on an integration branch — so
> the question "which side of that line is this epic on?" should have been asked before the first
> worktree was created, not after both PRs merged.
>
> **Resolution (pending CEO confirmation of cut point + version):** rather than rewrite shared
> history, cut a `release/1.0.0` branch + tag from **`e9c14fa1`** — the last commit before forensic
> doctors — so the shipped artifact excludes this epic while `development` keeps it. This avoids
> both a force-push (which breaks any clone that already pulled) and a revert (which would collide
> as an add/delete conflict if the felony branch ever carried the same code under different SHAs).
> It also gives the repo its first tag: there are currently none, and `main` sits 345 commits behind.
>
> A port onto `feature/GH-321-felony-cases` was built and **verified green (1946 tests)** as a
> fallback, confirming the code composes with felony's `ProceedingType`/`shared` changes. Not used
> under the release-branch plan; both it and the revert branch are dead and get deleted.
>
> **Consequence to track:** the *next* release cut from `development` includes this epic. **#527 is
> the gate** — 17 endpoints check authentication only, so a doctor account reaches a lawyer
> directory and a context-free media download. Close it before any release that carries this work.
> **Epic:** [#519](https://github.com/apessolutions/moj_judiciary/issues/519) · **Started:** 2026-07-22

## Why this one is small

Unlike felony, this epic has almost no foundation to build. A forensic doctor **is** a platform
principal — his account is an `admins` row — so the registry inherits every identity guarantee
`admins` already enforces. The only genuinely new data is المقر and المجموعة النوعية.

| AC | Already enforced by | New code |
|---|---|---|
| الرقم القومي unique + valid 14-digit NID | `uq_admins_national_id_active` · `NationalId` VO | none |
| رقم الموبايل unique + Egyptian E.164 | `uq_admins_phone_number_active` · `PhoneNumber` VO | none |
| Deactivation blocks login | `AuthApplicationService:58` | none |
| No hard delete | soft delete; no delete endpoint exists | none |
| Password policy · admin reset · self-service change | `@StrongPassword` · `ResetAdminPasswordUseCase` · `ChangePasswordUseCase` | none |

**US-FDOC-003 and US-FDOC-004 ship with zero backend work.** That is the payoff of putting the
doctor in `iam` on an extension table rather than modelling him as standalone reference data.

## Spec corrections (CEO, 2026-07-22)

The Confluence page predates AgDR-0075 (phone login, shipped 2026-07-16) and is stale in two ways:

1. **Mobile is the login credential**, so it is unique. Confluence says username is the credential
   and mobile is explicitly non-unique — both cannot hold. Scenario 4 becomes
   "رقم الموبايل مستخدم مسبقاً"; Scenario 6 splits (duplicate email accepted, duplicate mobile rejected).
2. **اسم المستخدم is dropped entirely** — not stored, not derived, not returned, not displayed.
   `doctor_<nationalId>` restates the national ID. The list is eight columns, not the nine on the
   screenshot.

Confluence to be updated by @Ziad. Until then the tech design + AgDR-0091 are the build contract.

## Also corrected during design

Confluence calls المقر and المجموعة النوعية "existing reference lists". **They did not exist** —
no table, no module, no sidebar entry. They are also absent from the الإدارة nav, which is what
makes them seeded reference data with no CRUD UI. Added as two minimal `core` slices.

## Delivery model: contract-first, two parallel tracks

The API contract was frozen in tech design §3.8 **before** any code was written, so backend and
frontend ran concurrently in separate worktrees from minute one — the frontend never waited on an
endpoint to exist.

```
Design (tech-design §3.8 frozen)  ──┬──►  BE: migrations → reference slices → doctor slice → list read model
                                    └──►  FE: list + toolbar → create/edit forms → reset-password dialog
```

## Filed (2026-07-22)

| # | Ticket | Layer |
|---|---|---|
| [#519](https://github.com/apessolutions/moj_judiciary/issues/519) | Epic — Forensic Doctors CRUD | epic |
| [#520](https://github.com/apessolutions/moj_judiciary/issues/520) | `[Migration]` reference lists + `forensic_doctors` (schema-only) + role bootstrap | L1 |
| [#521](https://github.com/apessolutions/moj_judiciary/issues/521) | Reference-list slices + `/options` | L2 |
| [#522](https://github.com/apessolutions/moj_judiciary/issues/522) | `iam/forensicdoctor` slice — create/get/update/toggle | L2 |
| [#523](https://github.com/apessolutions/moj_judiciary/issues/523) | List read model + search & filters | L3 |
| [#524](https://github.com/apessolutions/moj_judiciary/issues/524) | FE — list, toolbar, columns | FE |
| [#525](https://github.com/apessolutions/moj_judiciary/issues/525) | FE — create/edit forms + reset-password dialog | FE |

## Filed during Build (2026-07-22)

Follow-ups surfaced by the two reviews and by the frontend build. None block the epic; #527 blocks
*onboarding*.

| # | Ticket | Why |
|---|---|---|
| [#527](https://github.com/apessolutions/moj_judiciary/issues/527) | Re-gate the `isAuthenticated()` `/options` tier before onboarding doctors | **Gate on first doctor login.** 15 `/options` endpoints + both `MediaController` routes check authentication only, never permissions — so an empty permission set protects nothing there |
| [#528](https://github.com/apessolutions/moj_judiciary/issues/528) | FE password regex looser than `StrongPasswordValidator` | Pre-existing users-module bug; forensic flow unaffected |
| [#529](https://github.com/apessolutions/moj_judiciary/issues/529) | `npm ci` fails — lockfile desync on `development` | Pre-existing; will break CI on an unrelated PR |
| [#530](https://github.com/apessolutions/moj_judiciary/issues/530) | Gate FE routes + nav on `FORENSIC_DOCTOR_*` | Blocked by #522 — constants are generated from the backend enum |

### Review outcomes (doc-only, 2026-07-22)

Both reviewers returned **CHANGES REQUESTED**; neither faulted the core architecture. Tariq verified
slice placement, the extension table, the atomic-create rollback property, and the single status
flag against the code and would approve all four unchanged. Hakim confirmed `@perms.has` is
fail-closed, so a permissionless doctor genuinely cannot reach permission-gated admin functionality.

What they caught was a cluster of claims stated as fact that the code did not support:

- **The list read model was not buildable as designed** — every JPA entity is package-private, there
  are zero cross-package entity imports, and `core` never publishes `infrastructure.persistence`, so
  the four-table join was a Modulith violation. AgDR-0082 was also mis-cited: it returns aggregates,
  not a projection.
- **The frozen 422 contract could not be produced** — `AdminExceptionHandler` is scoped to
  `AdminController`, so those exceptions reach `ForensicDoctorController` as 500s. Catch-and-convert
  is impossible inside a participating transaction.
- **"The seeder self-heals on rename" was false** — `findByName` and `existsByNameIncludingDeleted`
  both miss a renamed row, so the seeder creates a *second* role and diverges silently. Risk
  accepted by the CEO (only one account can change roles); the fail-fast is retained.
- **Mobile was listed as editable but is immutable** — resolved by the CEO in favour of immutability,
  matching shipped admin behaviour.

### Build outcomes (2026-07-22)

**Frontend — PR [#531](https://github.com/apessolutions/moj_judiciary/pull/531), Rex APPROVED at
`acd47c0`.** 25 files, +2,625, 679 tests. Rex verified the three risky claims by *mutation* rather
than by reading — reverting each one made the relevant tests fail, so they aren't passing vacuously.
The counter turned out structurally safe, not just behaviourally: its query key is a static tuple
and the hook takes no arguments, so no call site could re-key Y by a filter.

Two findings from that review:

- **§3.8's update-request snippet still listed `mobile`**, contradicting §3.2. The frontend was
  correct; the *design* was wrong. Fixed. This is exactly the drift that freezing a contract is
  meant to prevent — §3.2 was edited when mobile became immutable and the frozen block wasn't
  propagated.
- **Nothing pinned the CSPRNG requirement** — swapping `crypto.getRandomValues()` for
  `Math.random()` left all 51 tests green. Shipped code correct, regression guard missing. Sent back.

**Backend — 5 commits, 141 files, +7,270.** Key implementation decisions:

- **Read model: aggregates + batched mapper**, joining only `forensic_doctors × admins` (same
  module, JPQL by entity name so no package-private type is imported). Office and group names come
  through the `core` slices' published batch ports rather than a join — sidestepping the Modulith
  violation in Tariq's B2 entirely. Three batched reads per page, pinned by a counting test.
- **`AdminExistsUseCase` was viable**, so the 422 path accumulates every field error into one
  response instead of surfacing them one at a time — the better of the two fixes Tariq offered.
- **`ForensicDoctorRoleLookup`** — a small port rather than a raw `RoleRepository` injection,
  because two callers need the same by-name resolution with different failure semantics (fatal on
  registration, no-op for the list).
- Consequence of the accepted squatting risk: a pre-existing role named `طبيب شرعي` is used
  **as-is**, permissions included. Exposure is small — `RoleApplicationService.create` hardcodes
  `isSuper=false`, so that cannot be set through the API.

## AgDRs

| # | Decision |
|---|---|
| [AgDR-0091](https://github.com/apessolutions/moj_judiciary/blob/development/docs/agdr/AgDR-0091-forensic-doctors-slice-and-identity.md) | `iam/forensicdoctor` placement, extension table, mobile-as-identity, username dropped |
| [AgDR-0092](https://github.com/apessolutions/moj_judiciary/blob/development/docs/agdr/AgDR-0092-forensic-doctors-migration.md) | Migration — 3 additive tables, schema-only; `admins` and `roles` untouched; role seeded by a bootstrap runner; import excluded |

Both cite existing reviewed precedent rather than re-litigating it: AgDR-0075 (phone login),
AgDR-0064 (felony extension tables), AgDR-0082 (dedicated list read model).

## Deliberately out of scope

- **Access scoping** — "a doctor sees only his assigned requests and sessions" belongs to the
  forensic-requests cycle. This epic ships the registry, the account, and the role. The role is
  seeded **permissionless** so a doctor who logs in early lands on an empty console rather than a
  populated admin one.
- **The 481-record register import** — blocked. The source has duplicated mobile numbers, which now
  violate login uniqueness, and 12 records with no national ID. Needs a dedupe-and-triage pass and
  its own ticket.
- **The full المقر list** — only the six offices confirmed from the approved screens are seeded.
  Guessing the rest would put unverified reference data in front of an operator with no way to tell
  it from the real list. The remainder lands with the import.

## Role seeding — by name, via a bootstrap runner (CEO, 2026-07-22)

The طبيب شرعي role is resolved **by name** and created by an idempotent
`ForensicDoctorRoleBootstrap` `ApplicationRunner`, matching the `*Bootstrap` + `*BootstrapProperties`
pattern every other seeded reference list here already uses. The role name and the doctor's default
permission set are both properties the seeder reads, so the defaults can be tuned without a
migration. The `iam` migration is schema-only.

This supersedes an earlier fixed-UUID-in-the-migration approach. The concern that motivated the
UUID — `RenameRoleUseCase` makes name lookup fragile — is inverted by the seeder: a renamed role is
re-created under the configured name on the next boot, so the system self-heals instead of staying
broken until someone edits config.

## Open for architecture review

`roles` has no system/reserved flag. The seeder covers rename and delete-then-restart, but an
administrator deleting the role *while the app is running* fails the next doctor creation until a
restart. An additive `is_system BIT` on a four-row table closes it (≈30 min) — raised in tech design
§3.6 for Tariq to rule on. Not blocking.

---

*Part of the Moj portfolio under ApexYard. Related: [[project-moj-m1-status]], [[project-moj-access-scoping]].*
