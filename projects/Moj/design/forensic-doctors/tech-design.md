# Forensic Doctors (الأطباء الشرعيون) — Technical Design

> **Spec (ACs):** Confluence [CRUD — طبيب شرعي](https://apessolutions.atlassian.net/wiki/spaces/MOJ/pages/1218248707/CRUD) — US-FDOC-001…006
> **Screens:** `projects/Moj/design/forensic-cycles/` (list + add form)
> **Repo:** apessolutions/moj_judiciary · **Base branch:** `development` — merged 2026-07-22 (#531, #533). Production is protected by cutting the release from `e9c14fa1`, the last commit before this epic; see the initiative doc for why that was chosen over a revert or a force-push.
> **Status:** REVIEWED (doc-only, 2026-07-22) — Tariq **CHANGES REQUESTED** (B1–B5), Hakim
> **CHANGES REQUESTED** (H1–H3, M1–M4). All findings are folded into the sections below or filed as
> tickets; see §7. **Gate 3b is NOT yet satisfied** — a doc-only review writes no marker. Re-run
> `/design-review <pr>` once the backend PR is cut, since it carries the migration AgDR.

---

## 1. Problem

مدير النظام needs a registry of forensic authority personnel (481 records in the source
`سجل الأطباء والكيميائيين 2026`) under a new الإدارة tab. Each doctor must also be a
platform principal who can log in and later see the forensic requests and sessions
assigned to him. Creating the doctor and creating his account are **one form, one save**.

**Out of scope for this epic (deliberately):** what a doctor actually *sees* after login.
The "only his assigned requests and sessions" rule is access-scoping work that belongs to
the forensic-requests cycle. This epic ships the registry, the account, and the role.

---

## 2. Spec corrections — resolved before design (CEO, 2026-07-22)

The Confluence page predates [AgDR-0075](https://github.com/apessolutions/moj_judiciary) and
describes a username-based login. That is no longer how this platform authenticates.

| Confluence says | Reality in code | Resolution |
|---|---|---|
| اسم المستخدم is the unique login credential | `admins.username` was **dropped** on 2026-07-16 (`V20260716160930`, AgDR-0075). `LoginCommand(phoneNumber, …)` | **Mobile is the login credential** |
| رقم الموبايل required, **duplicates allowed** (US-FDOC-001 §BR, Scenario 6) | `uq_admins_phone_number_active` — filtered-unique | **Mobile must be unique.** Cannot be otherwise: it *is* the login handle |
| Scenario 4 — "اسم المستخدم مستخدم مسبقاً" | no username exists | Becomes **"رقم الموبايل مستخدم مسبقاً"** |
| Scenario 6 — duplicate mobile *or* email accepted | — | **Splits**: duplicate email accepted, duplicate mobile rejected |
| اسم المستخدم entered by the admin at creation, shown as a list column | every username in the list screen is literally `doctor_<nationalId>` — a restatement of the national ID | **Dropped entirely** (CEO, 2026-07-22) — see §3.4 |

Email keeps the spec's rules unchanged: optional, non-unique, format-validated when present.

**Action:** Ziad to update the Confluence page to match. The ACs below are the build contract.

---

## 3. Backend design

### 3.1 Where the slice lives — `iam/forensicdoctor`

A doctor's account is an `admins` row, so the slice needs `iam`. The module rules
(`backend/CLAUDE.md` § "Things to never do") allow **`iam → core`** and forbid `core → iam`.
Putting the slice in `core/` (next to `lawyer`) would invert that and break `ModularityTests`.

So: **`iam/forensicdoctor`** — it may read `core`'s reference lookups through their
`@NamedInterface` ports, exactly as `iam/admin` already reads `CourtExistsUseCase`.

### 3.2 Data model — extension table, not columns on `admins`

```
admins  (shipped, untouched)              forensic_doctors  (new)
  id            ◄──────────────────────────  admin_id      UNIQUEIDENTIFIER NOT NULL (FK, UNIQUE)
  phone_number  UNIQUE  ← login + موبايل     id            UNIQUEIDENTIFIER NOT NULL (PK)
  full_name             ← اسم الطبيب         office_id     UNIQUEIDENTIFIER NOT NULL (FK) ← المقر
  national_id   UNIQUE  ← الرقم القومي       specialty_group_id  ... NOT NULL (FK) ← المجموعة النوعية
  password_hash                              email         NVARCHAR(255) NULL
  status                ← الحالة             created_at / updated_at / deleted_at
  role_id               ← طبيب شرعي
```

This mirrors **AgDR-0064** (felony sub-data went into `case_felony_details`, *not* the shared
`cases` table) — same reasoning, ten days old, already reviewed. Forensic-only fields must not
pollute the table every other principal shares.

**What this buys us for free** (no new code, no new constraint):

| AC | Already enforced by |
|---|---|
| الرقم القومي unique | `uq_admins_national_id_active` (filtered-unique index) |
| الرقم القومي valid 14-digit NID | `NationalId` VO → `NationalIds.isValid` |
| رقم الموبايل unique + Egyptian format | `uq_admins_phone_number_active` + `PhoneNumber` VO (E.164) |
| Deactivation blocks login | `AuthApplicationService:58` — `if (!admin.isStatus())` |
| Historical records preserved | soft delete + `admins` never hard-deleted (no delete endpoint exists) |
| Password policy | `@StrongPassword` |
| Admin password reset | `POST /admins/{id}/reset-password` (revokes sessions via `AdminPasswordResetEvent`) |
| Doctor self-service password change | `ChangePasswordUseCase` (`iam/auth`) — shipped |

US-FDOC-003 and US-FDOC-004 therefore need **zero backend work**. See §4.3.

> **Mobile is immutable (CEO, 2026-07-22) — resolving Hakim M3.**
>
> Hakim found that `UpdateAdminCommand` carries no phone number and `AdminApplicationService.update`
> never calls `changePhoneNumber`, and read that as a gap this epic would have to fill: since mobile
> is the login credential, changing it would need a uniqueness re-check *and* a session revocation,
> or the old session survives on the new number.
>
> It is not a gap — it is the shipped design. `Admin.changePhoneNumber`'s own javadoc says
> *"Retained for the audit integration test and for completeness; the public update flow does NOT
> call this — the phone number is immutable after creation."* Forensic doctors follow the same rule.
>
> So the immutable set is **الرقم القومي, اسم الطبيب, and رقم الموبايل** — all three enforced
> server-side by simply not appearing on `UpdateForensicDoctorRequest`. Only email, المقر and
> المجموعة النوعية are editable. `UpdateAdminUseCase` is not touched, and the revocation hole cannot
> exist because the credential cannot change.
>
> **This is a third correction to Confluence:** US-FDOC-002 Scenario 1 lists mobile among the
> editable fields. It isn't.

### 3.2b Doctors are hidden from the admins list (CEO, 2026-07-22)

`GET /api/v1/admins` must **not** return forensic doctor accounts — they belong only in the
الأطباء الشرعيون tab. A doctor is an `admins` row, so without this they would otherwise show up in
المستخدمون alongside مدير النظام and سكرتير جلسة.

**This is a backend filter, not a frontend one.** Filtering client-side would leave the admins
screen's `إجمالي X من Y` counter wrong and punch holes in its pagination, because the server would
still be paginating over the unfiltered set.

- **The discriminator is the presence of a live `forensic_doctors` row** — an `admins` row is
  forensic *iff* it has one. The admins list is an **anti-join**; the doctors list is the inner join.
- Excluded inside `AdminRepository.findPage(...)`'s `Specification` — **not** as an optional field
  on `AdminFilter`, so a client cannot switch it off.
- The exclusion applies to the **count query as well as the page query**, or `PaginatedData` reports
  a total that doesn't match its rows.
- **`GET /admins/{id}` stays unfiltered.** Only the list is affected; breaking id-addressed reads
  would break the audit trail and existing deep links.

**Why the extension row and not `role_id`, and not a new column.** An earlier revision filtered on
the resolved forensic `RoleId`. That's wrong: `PUT /admins/{id}` accepts `roleId`, so anyone with
`ADMIN_UPDATE` can move a doctor off the forensic role and he silently reappears in المستخدمون while
his `forensic_doctors` row still exists. The role is a mutable attribute; the extension row is the
fact.

A discriminator **column** on `admins` was also considered and rejected. It would duplicate a fact
the `forensic_doctors` row already carries — two sources of truth that can diverge — and it is
exactly the "role-specific column on the shared principal table" that AgDR-0064 rejected and that
this design's entire extension-table argument rests on (§3.2). Adding one here would undercut the
reasoning that justified the model.

**Correction on the precedent (CEO, 2026-07-22).** An earlier revision of this section claimed
row-presence is simply "the convention", citing AgDR-0064's felony/renewal discriminator
(*"presence of a `case_felony_details` row (felony list = inner join; renewal = anti-join)"*).
That citation is **stale**. The team subsequently added an explicit `proceeding_type` discriminator
column to `cases` (`AgDR-0083-migration-cases-proceeding-type`, on `feature/GH-321-felony-cases`,
not yet merged to `development`) and promoted `ProceedingType` to the `shared` module to scope
reference data. So both mechanisms coexist on the case side, and the direction of travel there is
toward an explicit column, not away from it.

The anti-join is still the right call **here**, for a reason that doesn't apply to `cases`:
`proceeding_type` is an intrinsic attribute of a case that many things branch on and that scopes
reference-data lookups, so materialising it earns its keep. "Is this principal a forensic doctor"
branches exactly one query — the admins list — and is already answered by a row that must exist
anyway. A column would buy one join's worth of convenience in return for a second source of truth
that `PUT /admins/{id}` can already desynchronise.

If a future epic needs to branch on principal type in several places, revisit this — the column
becomes additive at that point, and this note is the argument to weigh against.

### 3.2d Soft-delete cascades to the `admins` row (CEO, 2026-07-22)

Soft-deleting a `ForensicDoctor` **must soft-delete the paired `admins` row in the same
transaction**, and publish the session-revocation event.

Without the cascade, an orphaned `admins` row causes three separate problems:

- **The mobile and national ID stay locked forever.** Both unique indexes are filtered on
  `deleted_at IS NULL`, so that person can never be re-registered.
- **The two screens disagree about who exists.** The doctor is gone from الأطباء الشرعيون (inner
  join misses him) and *reappears* in المستخدمون (the anti-join no longer excludes him).
- **Live sessions survive** until token expiry. Login itself is blocked automatically once the admin
  row is soft-deleted — `@SQLRestriction("deleted_at IS NULL")` makes it unfindable — but
  already-issued tokens need an explicit revoke, mirroring `ToggleAdminStatusUseCase` /
  `AdminDeactivatedEvent`.

Precedent: **AgDR-0081** does exactly this shape for felony — *"Give `case_felony_details` its own
`deleted_at`, cascaded from the case soft-delete."*

**No public delete endpoint is added.** US-FDOC-005 is deactivation-only. The cascade lives in the
application service so it is correct **by construction** whenever a delete path is added later —
closing the gap Tariq flagged: *"`deleted_at` has no delete path… record what a future delete must
do to the paired `admins` row, otherwise someone implements it and orphans a live login account."*

> **Implementation note (Tariq B2 again):** `AdminJpaEntity` and `ForensicDoctorJpaEntity` are both
> package-private in different packages, so neither can reference the other in a Criteria query.
> Either make `ForensicDoctorJpaEntity` public — direct precedent in #480, which did this to
> `FelonyDetailsJpaEntity` for the same reason within one module — or use a `NOT EXISTS` subquery
> with no type-level reference.

### 3.2c Forensic info on the profile API

A logged-in doctor's client needs to know he *is* a doctor and which المقر / المجموعة النوعية he
belongs to, without a second call.

`AdminProfileResponse` gains a **nullable `forensicDoctor` block** — `null` for every non-doctor
principal — carrying the doctor's id, office and specialty-group summaries, and email.

Built in `AuthWebMapper`, which is already a `@Component` precisely because assembling a profile
needs cross-aggregate reads (role lookup + effective permissions), and which `backend/CLAUDE.md`
names as the pattern for exactly this. Same module, so no new module edge. Because
`toLoginResponse` delegates to `toProfile`, both `POST /auth/login` and `GET /auth/me` pick it up
with no extra wiring.

> **Open:** hiding doctors from the list does **not** gate mutation — a doctor remains reachable
> through `PUT /admins/{id}` and `PATCH /admins/{id}/toggle-status` for anyone holding the admin
> permissions. Whether those write paths should reject a forensic principal is a deliberate call, not
> something that should fall out of the list change by accident. Related to Hakim's H1 and M4, which
> both concern the two slices' write paths overlapping on the same row.

### 3.3 Reference lists — they do not exist yet

Confluence calls المقر and المجموعة النوعية "existing reference lists". They aren't — there is
no forensic table, module, or sidebar tab anywhere in the codebase. They are also *absent from
the admin nav*, so they are **seeded lookups with no CRUD UI**, not new admin screens.

Two minimal `core` aggregates, `id / name / status / audit`, seeded from the source register:

```
core/forensicoffice          → forensic_offices           GET /api/v1/core/forensic-offices/options
core/forensicspecialtygroup  → forensic_specialty_groups  GET /api/v1/core/forensic-specialty-groups/options
```

`/options` follows the uniform dropdown contract already consumed by `api/actions/options.ts`:
non-paginated `{ id, name }[]`, **enabled entries only** — which satisfies Scenario 8 with no
extra work. Each exposes an `ExistsUseCase` via `@NamedInterface("ports")` for §3.5 validation.

### 3.4 Username is dropped entirely (CEO, 2026-07-22)

Every username in the list screen is `doctor_<nationalId>` — it carries no information the national
ID doesn't already carry, and it authenticates nothing. An earlier revision of this design kept it
as a derived, display-only field. The CEO's call is to **drop the concept outright**.

So: no column, no index, no uniqueness check, no derivation, no response field, no form input, no
list column. `admins.username` was already deleted by AgDR-0075; nothing replaces it.

A doctor is **identified** by الرقم القومي and **authenticates** with his mobile. That is the whole
identity story.

Consequences for the screens: the list drops to **eight** columns, and the
`بيانات حساب المستخدم` card holds only كلمة المرور المبدئية. Both screenshots show a اسم المستخدم
field — they are stale on this point.

### 3.5 Atomic create (US-FDOC-001)

One `@Transactional` method on `ForensicDoctorApplicationService`:

```java
@Override
@Transactional
public ForensicDoctor create(CreateForensicDoctorCommand command) {
    var errors = FieldValidationException.builder();
    if (!officeExists.existsActiveById(command.officeId()))         errors.field("officeId", …);
    if (!specialtyGroupExists.existsActiveById(command.groupId()))  errors.field("specialtyGroupId", …);
    errors.throwIfAny();

    // Throws AdminAlreadyExistsException / NationalIdAlreadyExistsException —
    // the same transaction rolls back, so no orphan account can exist.
    Admin admin = registerAdmin.register(new RegisterAdminCommand(
            command.mobile(), command.initialPassword(), command.fullName(),
            command.nationalId(), forensicDoctorRoleId(), List.of(), List.of()));

    return repository.save(ForensicDoctor.register(
            ForensicDoctorId.newId(), new AdminId(admin.getId().value()),
            new ForensicOfficeId(command.officeId()),
            new SpecialtyGroupId(command.specialtyGroupId()),
            command.email() == null ? null : new Email(command.email())));
}
```

Both writes share one transaction → the spec's "no doctor without an account, no account without
a doctor" is a rollback property, not a compensating-action dance. `RegisterAdminUseCase` is a
public input port in the same module — no new cross-module edge.

### 3.6 The طبيب شرعي role — resolved by name, seeded by a bootstrap (CEO, 2026-07-22)

The role is **not selectable** — the server picks it. It is resolved **by name**, not by a fixed
UUID, and it is created by an `ApplicationRunner` seeder rather than by the migration. This follows
the pattern the codebase already uses for every other seeded reference list
(`ParticipantTypeBootstrap`, `JudicialRankBootstrap`, `HearingReasonBootstrap`, …).

**Use the existing `RoleBootstrap` — do not add a second runner.** One seed line:

```java
seed("طبيب شرعي", false, Set.of());   // empty permission set
```

`RoleBootstrap` already seeds four roles by Arabic name, including `seed("موظف الدعم الفني", false,
Set.of())` — an empty-permission placeholder of exactly this shape. An earlier revision of this
design proposed a new `ForensicDoctorRoleBootstrap` in `iam/forensicdoctor`; that was wrong on two
counts (a foreign slice constructing another slice's aggregate, and a second uncoordinated runner
writing `roles`). Resolve by name via `RoleRepository.findByName` with an **explicit fail-fast** if
the role is absent.

- The permission set lives **in code**, not in properties. `RoleBootstrapProperties` already carries
  this decision verbatim: a role→permission mapping is security-relevant and *belongs under review,
  not in a mutable properties file*. An earlier revision of this design made it a seeder property so
  it could be tuned without a code change — Hakim's review (H3) correctly killed that: a
  misconfiguration would silently re-grant every doctor, existing and new, on the next boot, with no
  diff and no AgDR.
- The seeder **reconciles permissions to the code-defined value on every boot** — not
  "create-if-absent, never overwrite". This is the load-bearing property; see below.
- It starts empty: access scoping is a later epic, so an early doctor login must land on an empty
  console.
- At creation time the service resolves via `RoleRepository.findByName(...)`. `AdminApplicationService`
  already injects `RoleRepository` directly — same `iam` module, no new cross-module edge.
- `RoleName` is pattern-validated (`^[A-Z\p{InArabic}][A-Z0-9_\p{InArabic} ]{2,39}$`); `طبيب شرعي`
  satisfies it. Pin that with a test so a future name that violates the pattern fails at build time.

**The by-name trade-off, stated honestly.** An earlier revision of this design justified by-name
resolution by claiming the seeder *self-heals* if an administrator renames the role. **That claim is
false**, and both reviewers landed on it independently:

- **On rename** (Tariq B1a): `findByName` misses, and `existsByNameIncludingDeleted` misses too —
  the row still exists, under the *new* name. So the seeder **creates a second role**. Existing
  doctors keep pointing at the renamed one; new doctors get a fresh empty one. That is silent
  divergence, and it is strictly *worse* than the fixed UUID it replaced, under which a rename is
  purely cosmetic.
- **On delete** (Tariq B1b): `existsByNameIncludingDeleted` is soft-delete-aware *by documented
  convention* — `SuperAdminBootstrap`'s javadoc states that operators deleting a seeded row expect
  it to stay gone, not resurrect. So a deleted role stays deleted and doctor creation stays broken
  across restarts, not "until restart".
- **On squatting** (Hakim H2): `RoleApplicationService.create` accepts an arbitrary name and
  arbitrary permissions, so an actor with `ROLE_CREATE` can pre-create a role named `طبيب شرعي`
  carrying anything; `findByName` then resolves it for every doctor minted afterwards.

**Decision (CEO, 2026-07-22): accept the risk, keep by-name, keep the seeder simple.** The frontend
only *displays* roles, and only the single administrator account can create or rename them — so the
actor every one of the findings above requires does not exist in this deployment. No reconcile loop,
no `is_system` flag, no second seeder.

The **fail-fast on absence is retained and is load-bearing**: it converts the rename case from silent
divergence into a loud, immediate failure. It is the one piece of protection this design keeps.

Consequence: the `iam` migration is **schema-only** — no `INSERT INTO roles`.

> **Rejected: resolve by a stable `RoleId` constant** (Hakim's preferred H2 fix, and the shape this
> design originally had). It is straightforwardly more robust — a UUID is neither operator-writable
> nor renameable, so all three failure modes above become impossible rather than merely improbable.
> Recorded here so that if the deployment ever gains a second role-administrator, the fix is already
> written down.

### 3.6b Open: doctor mutation through the admin endpoints

Hiding doctors from the admins **list** does not gate **writes**. `PUT /admins/{id}` and
`PATCH /admins/{id}/toggle-status` still reach a forensic principal for anyone holding the admin
permissions. Raised by Tariq (B3) and independently by the build agent; **not acted on** — it needs
a product call.

- **`PUT /admins/{id}` should reject a forensic principal.** It accepts `roleId`, so it can
  de-forensic a doctor invisibly — leaving a `forensic_doctors` row whose principal is no longer a
  doctor, which desynchronises both lists. It also edits `fullName` and `nationalId`, the exact
  identity fields §3.2 freezes on the doctor screen. An immutability rule enforced on one screen and
  not the other is not enforced.
- **`PATCH /admins/{id}/toggle-status` is defensible to leave open** — it is the same semantic
  operation the doctor screen already offers, so blocking it would be ceremony rather than
  protection.

### 3.7 List read model (US-FDOC-006)

The list needs columns from four tables (doctor + admin + office + group), with search on
name/NID and filters on group/office/status. Loading two aggregates per row would be an N+1.

Use the **dedicated read model** pattern the team just established in AgDR-0082 / AgDR-0070
story-A: a projection interface + a single joined query, bypassing `findPage`. One SQL statement
per page, no per-row fetch. Pin it with a no-N+1 property test, mirroring commit `38ccaa5d`.

```
ForensicDoctorFilter(String search, UUID officeId, UUID specialtyGroupId, Boolean status)
```

All fields nullable = "don't restrict"; filters combine with AND (Scenario 4). موقوف rows are
returned unless `status` is set (Scenario 3, "never hidden by default"). Default sort
`createdAt DESC`, server-controlled.

### 3.8 API contract — **frozen, build against this**

Base: `/api/v1/forensic-doctors`. Envelope: `{ data, statusCode, message }`. Permissions:
`FORENSIC_DOCTOR_{CREATE,READ,UPDATE,TOGGLE_STATUS}`.

| Method | Path | Request | Response |
|---|---|---|---|
| POST | `/` | `CreateForensicDoctorRequest` | 201 `ForensicDoctorResponse` |
| GET | `/` | `?search=&officeId=&specialtyGroupId=&status=&page=&limit=` | 200 `PaginatedData<ForensicDoctorResponse>` |
| GET | `/{id}` | — | 200 `ForensicDoctorResponse` |
| PUT | `/{id}` | `UpdateForensicDoctorRequest` | 200 `ForensicDoctorResponse` |
| PATCH | `/{id}/toggle-status` | — | 200 `ForensicDoctorResponse` |

```jsonc
// CreateForensicDoctorRequest        // UpdateForensicDoctorRequest — mutable fields ONLY
{                                     {
  "nationalId": "26701310102071",       "email":  null,
  "fullName":   "أيمن احمد حسان",        "officeId": "…",
  "mobile":     "+201090855321",        "specialtyGroupId": "…"
  "email":      "a@x.com",   // null ok }
  "officeId":   "uuid",
  "specialtyGroupId": "uuid",         // nationalId, fullName AND mobile are all absent by
  "initialPassword": "…"              // design — immutability is enforced server-side by the
}                                     // field not existing on the request, not by a read-only
                                      // input (US-FDOC-002 Scenario 2, DoD "not only in the UI").
                                      // Mobile is the login credential; see §3.2.

// ForensicDoctorResponse
{
  "id": "uuid", "adminId": "uuid",
  "nationalId": "26701310102071", "fullName": "أيمن احمد حسان",
  "mobile": "+201090855321", "email": null,   // no username field — §3.4
  "office":         { "id": "uuid", "name": "مكتب كبير" },
  "specialtyGroup": { "id": "uuid", "name": "الطب الشرعي الميداني" },
  "status": true, "createdAt": "2026-07-22T…"
}
```

`office` / `specialtyGroup` are built by injecting the owning slices' web mappers
(`backend/CLAUDE.md` § cross-slice DTOs) — never constructed inline.

**Error contract** — 422 with a flat dotted `errors` map:

| Field | Condition | Message key |
|---|---|---|
| `nationalId` | duplicate | `الرقم القومي مسجل مسبقًا` |
| `nationalId` | fails NID check | `الرقم القومي غير صالح` |
| `mobile` | duplicate | `رقم الموبايل مستخدم مسبقاً` |
| any | blank required | `هذا الحقل مطلوب` |

### 3.9 Files (backend)

```
db/migration/core/V<ts>__create_forensic_reference_lists.sql   # 2 tables + seed
db/migration/iam/V<ts>__create_forensic_doctors.sql            # table + role seed (+ is_system?)

core/forensicoffice/{domain,application,infrastructure}/…      # ~12 files, read-only slice
core/forensicspecialtygroup/…                                  # ~12 files, read-only slice
iam/forensicdoctor/
  domain/         ForensicDoctor · ForensicDoctorId · Email · ForensicDoctorFilter
                  ForensicDoctorRepository · ForensicDoctorListRepository (read model)
                  ForensicDoctorPermission · *NotFoundException
  application/    Create/Update/Get/List/ToggleStatus use cases + commands + AppService
  infrastructure/ persistence (entity, jpa repo, mapper, adapter, audit adapter, list adapter)
                  web (controller, web mapper, exception handler, dto/)
                  permissions/ForensicDoctorPermissionsConfig
```

Plus `messages{,_ar}.properties` + `MessageKeys` constants (`MessageBundleCompletenessTest`
fails otherwise) and `PermissionCatalogIntegrityTest` entries.

**Audit:** `ForensicDoctorAuditAdapter`, `type() = "ForensicDoctor"`, `relations()` for
office + specialty group, `snapshotByIds` via `findAllByIdIncludingDeleted`. **No secrets** —
the password hash lives on `admins` and is never in this snapshot.

---

## 4. Frontend design

### 4.1 Files

Mirrors `sections/core/users` (which already has the reset-password dialog) crossed with
`sections/core/lawyers` (filter toolbar shape):

```
src/api/actions/forensic-doctors.ts        # + getForensicOfficeOptions / getForensicSpecialtyGroupOptions in options.ts
src/api/types/forensic-doctor.ts
src/utils/axios.ts                         # endpoints.forensicDoctors.{root,byId,toggleStatus}
src/sections/core/forensic-doctors/
  columns.tsx                              # 8 columns (no username — §3.4); email "—" when null
  forensic-doctor-table-toolbar.tsx        # search + 3 dropdowns, all default "كل …"
  forensic-doctor-new-edit-form.tsx        # both modes; edit locks NID/name/username
  forensic-doctor-reset-password-dialog.tsx
  forensic-doctor-schema.ts                # zod: NID 14-digit, EG mobile, optional email
  view/{list,create,edit}-view.tsx
```

Route + الأطباء الشرعيون nav entry under الإدارة, between المحامون and المستخدمون (per screen).

### 4.2 Screen notes

- **List** — eight columns (§3.4 drops اسم المستخدم from the screenshot's nine); موقوف rows stay
  visible; row actions are edit + toggle-status only (no delete — matches the screen's two icons).
- **The `إجمالي X من Y` counter**: **X = records matching the current search + filters** (across all
  pages, not rows on the current page); **Y = total forensic doctors, unfiltered**. AC Scenario 5
  settles it — an empty result must read `إجمالي 0 من Y`, and Y can only survive a zero-match filter
  if it is filter-invariant. The mock confirms it: `469 من 469` on a paginated table showing ten
  rows, so X is not a page count.
  Y needs a second, unfiltered request — nothing in the pagination envelope carries an unfiltered
  count. Fetch it once on mount (`limit=1`, read the total, discard the row) under a **parameterless
  query key** so filter changes serve from cache; a create correctly invalidates it, because the
  grand total genuinely moved. Guard the first-mount gap so the counter never renders a Y smaller
  than X.
- **Create** — two cards (بيانات الطبيب / بيانات حساب المستخدم) as designed, **minus the
  اسم المستخدم field** (§3.4). The account card holds only كلمة المرور المبدئية; the توليد button
  generates a policy-compliant password. Keep the explanatory note verbatim.
- **Edit** — الرقم القومي and اسم الطبيب read-only with lock icon + tooltip
  "لا يمكن تعديل هذا الحقل بعد الإنشاء"; no password field; a
  "إعادة تعيين كلمة المرور" button opens the dialog.

### 4.3 Password flows reuse shipped endpoints

- **US-FDOC-003 (admin reset)** — the FE generates a policy-compliant password, shows it once,
  and POSTs it to the existing `/admins/{adminId}/reset-password`. Sessions are revoked
  server-side. **No backend change.**
- **US-FDOC-004 (doctor self-service)** — the shipped change-password screen and
  `ChangePasswordUseCase` already cover it. **No work unless** the settings route is
  role-gated away from طبيب شرعي — verify during build; if gated, it's a one-line route fix.

---

## 5. Ticket breakdown (proposed — none filed yet)

| Item | Layer | Blocked by |
|---|---|---|
| **Epic** — Forensic Doctors CRUD | — | — |
| A — `[Migration]` reference lists + `forensic_doctors` + role seed (one AgDR) | L1 | — |
| B — `[Feature]` reference-list slices + `/options` endpoints | L2 | A |
| C — `[Feature]` `iam/forensicdoctor` slice — create / get / update / toggle | L2 | A |
| D — `[Feature]` list read model + search/filters | L2 | A |
| E — `[Feature]` FE — list view, toolbar, columns | FE | contract §3.8 only |
| F — `[Feature]` FE — create + edit forms, reset-password dialog | FE | contract §3.8 only |

E and F build against the frozen contract in §3.8 from minute one — they do **not** wait for
C or D. That is the whole point of freezing it here.

**Packaging:** three PRs, not six — `A` · `B+C+D` · `E+F`. Rex runs once per PR at final HEAD.

---

## 6. Decisions (AgDRs to file during Build)

| # | Decision | Where |
|---|---|---|
| 1 | Mobile is the login credential; username **dropped entirely** (not derived, not display-only — see §3.4); Confluence corrected | **AgDR-0091** (extends AgDR-0075) ✅ written |
| 2 | `iam/forensicdoctor` + extension table, not columns on `admins` | **AgDR-0091** (cites AgDR-0064) ✅ written |
| 3 | Migration: 3 tables + role seed + import explicitly excluded | **AgDR-0092** (gate 3a) ✅ written |
| 4 | طبيب شرعي role seeded by one line in the existing `RoleBootstrap`, permissions **in code**, **no reconcile**, resolved by name, fail-fast at resolution | **AgDR-0091 + AgDR-0092** ✅ revised 2026-07-22 after Tariq D1 — both records now describe what shipped, not the two rejected revisions |
| 5 | Dedicated list read model rather than `findPage` | cites AgDR-0082 — no new record needed |

---

## 7. Security review — Hakim, 2026-07-22 (doc-only, pre-PR)

**Verdict: CHANGES REQUESTED.** Findings verified against the code, not against this document's
claims. The three blocking items are folded into the sections above; this section records the rest
so nothing is lost between review and Build.

**The good news first, because it was the thing most worth worrying about.** A doctor with an empty
permission set genuinely **cannot** reach admin functionality — `@perms.has` is fail-closed on null
auth, null code, and empty authorities, `SecurityConfig` chain 2 is `.anyRequest().authenticated()`,
and every `@RestController` was enumerated for per-method gating. The "empty permission set" claim in
§3.6 holds. Also confirmed sound: the atomic-create rollback property (§3.5), session revocation on
password reset, the password-hash exclusion from the audit snapshot (structurally guaranteed — there
is no password column on `forensic_doctors`), and the "admins untouched → zero regression risk" claim.
An administrator cannot mint an `isSuper` role through the API.

### Blocking — folded in above

| # | Finding | Where it landed |
|---|---|---|
| H1 | `FORENSIC_DOCTOR_CREATE` silently confers **principal creation** — it mints an `admins` row with a password hash and a role, exactly like `ADMIN_CREATE`, but reads like a registry permission and will be granted like one | §3.5 + the permission-catalog label |
| H2 | Role-resolution-by-name is a privilege-escalation primitive: an admin with `ROLE_CREATE` can pre-create a role named `طبيب شرعي` with arbitrary permissions, which `findByName` then resolves for every doctor | §3.6 — closed by reconcile-on-boot; `is_system` closes the residue |
| H3 | Property-driven permissions contradict a documented decision already in this codebase (`RoleBootstrapProperties`: the role→permission mapping *belongs under review, not in a mutable properties file*) | §3.6 — permissions now in code, in the existing `RoleBootstrap` |

**H1 remediation:** state plainly that this is a principal-minting permission of the same class as
`ADMIN_CREATE`. Either require both, or never grant it to a role not already trusted with admin
management. Test that the created admin's role is always the resolved forensic role and never
caller-supplied.

### Decide before Build

- **M1 — "empty permissions" ≠ "empty console".** 13 `/options` endpoints are gated
  `@PreAuthorize("isAuthenticated()")` per AgDR-0066, not on a permission. A zero-permission doctor
  can enumerate org-wide reference labels: courts, divisions, judges, **lawyers (id + full name)**,
  police stations, prosecutions, charges, case types, governorates, ranks, hearing reasons.
  AgDR-0066 accepted that for operational *admin* roles; it was never re-evaluated for a new,
  lower-trust principal class of 481 people. **Decide whether the doctor role belongs in that tier.**
- **M2 — `AUDIT_READ` exposes doctor PII, bypassing `FORENSIC_DOCTOR_READ`.** `AdminAuditAdapter`
  snapshots `nationalId`, `phoneNumber`, `fullName` and surfaces them via `displayColumns()`.
  `GET /audit/entities/{type}/{id}` is gated only on `AUDIT_READ`, which `RoleBootstrap` grants to
  **أمين السر**. Pre-existing behaviour, but this epic scales it from a handful of staff to 481
  people — that scale change wants a data-owner sign-off recorded in the AgDR.
- **M3 — mobile is mutable but unreachable.** Folded into §3.2.
- **M4 — `PATCH /{id}/toggle-status` flips `admins.status`.** Safe only if `adminId` is always
  derived from the loaded doctor row and never accepted from the caller — otherwise it is
  account-disabling DoS reaching مدير النظام. Explicit design constraint + test.

### Advisory

- **Client-side password generation is fine** — the administrator already sees the plaintext by
  design, so generating in the browser doesn't widen the audience, and it avoids putting a secret in
  a response body. Hard requirement: `crypto.getRandomValues()`, never `Math.random()`. Target ≥16
  chars, not the `@StrongPassword` floor of 8. Note this is new code — the shipped
  `user-reset-password-dialog.tsx` has no generator. Don't auto-copy to clipboard.
- **Logs are clean** — no request-body logging anywhere in `src/main`. Given AgDR-0067/0071 ship
  logs to Loki/Alloy, add an explicit "never log request bodies for `/admins/**` or
  `/forensic-doctors`" note.
- **No forced password change at first login is a real finding, but a platform gap, not this epic's.**
  The administrator retains every doctor's plaintext password indefinitely, which makes doctor
  actions repudiable and undercuts the audit trail this system otherwise invests heavily in. Every
  admin created via `POST /admins` already has this property — so file a platform ticket
  (`must_change_password BIT` on `admins`, forced through the shipped `ChangePasswordUseCase`)
  rather than blocking here. The 481-person scale is what turns a tolerable staff-scale gap into a
  real one.
- **The 422 enumeration oracle is real but not worth mitigating** — it is reachable only with
  `FORENSIC_DOCTOR_CREATE`, a caller who can already `GET /` the full list of NIDs and mobiles. An
  oracle revealing strictly less than a list endpoint the same caller can call is noise, and the
  distinct messages are required by the ACs. Login itself is clean: unknown phone, disabled account,
  and wrong password all throw the same `InvalidCredentialsException`.
- **Credential reuse after soft delete is not reachable today** — `AdminController` has no delete
  mapping and no use case soft-deletes an admin. If that ever changes, audit stays correctly
  attributed (rows key on the `adminId` UUID, not the phone), but a recycled number would need an
  explicit session revoke. One line in AgDR-0092's consequences covers it.
- **The deferred import fails loudly; the danger is the fix.** Force-importing hits
  `uq_admins_phone_number_active` and stops hard. The risk lives entirely in the remediation:
  dropping the unique index makes `findByPhoneNumber` non-unique and login resolves to an arbitrary
  one of N principals; synthesizing placeholder mobiles or NIDs collapses several real people onto
  one identity. Put an explicit rule on the import ticket — **never relax the uniqueness indexes,
  never synthesize a credential, hold unidentifiable records for manual triage.** Worth asking
  whether imported doctors need accounts on day one at all: registry-only rows until a doctor
  requests access would sidestep 481 admin-known passwords entirely.

## 8. Risks

| Risk | Mitigation |
|---|---|
| An admin renames/deletes the طبيب شرعي role → creation breaks | §3.6 open item — recommend `is_system` flag |
| 481-record import: 12 rows lack الرقم القومي; mobiles duplicate in source | Import is **not** in this epic. Duplicated mobiles now violate login uniqueness — the import needs a dedupe pass and its own ticket |
| Doctor logs in and sees the full admin console | Access-scoping is out of scope (§1) — but a doctor with the seeded role must land somewhere sane. Give the role an empty permission set at seed time; the console then renders nothing until the forensic-requests epic grants permissions |

---

*Part of the Moj portfolio under ApexYard. Related: [[project-moj-m1-status]], [[project-moj-access-scoping]].*
