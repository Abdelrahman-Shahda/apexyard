## Design Review: PR #449 — replace admin username with Egyptian phone login

**Commit**: `cc8a9688235a8b3607b3a3569d07200129fd6c67`
**Artifact**: `docs/agdr/AgDR-0075-migration-admin-phone-login.md` + the schema/auth change it governs
**Gate**: 3b (architecture review, Design → Build)

### Summary

The design replaces admin `username` login with an Egyptian mobile phone number as the *sole* identity — schema, domain VO, DTOs, JWT identity claim, audit, seeder, and Users CRUD. The migration adds `phone_number`, backfills the seed admin (`01066676249`) and other rows with generated unique valid placeholders, enforces NOT-NULL-then-filtered-unique, and drops `username` + its index. Validation mirrors the existing `@NationalId`/`NationalIds` pattern (dependency-free shared helper + Bean-Validation constraint + domain VO), and login is kept anti-enumeration-safe.

### Review Lens Results

- ✅ Quality attributes / NFRs: **Pass** — tiny `admins` table; ADD nullable column + ALTER-to-NOT-NULL + index create/drop are all fast/metadata-cheap at this scale; effectively seconds of downtime, correctly claimed.
- ✅ Design patterns & structure: **Pass** — `PhoneNumbers` in `shared/domain` (dependency-free), `@PhoneNumber` constraint in `shared/web/validation`, `PhoneNumber` VO in `iam/admin/domain` delegating to the shared helper. Domain never reaches into web; Modulith `iam` boundary respected; a faithful mirror of the NationalId trio.
- ✅ Technical debt: **Pass** — placeholder phone numbers for non-seed admins are explicit debt with a stated paydown ("operator sets the real number before they can log in"); no silent debt.
- ✅ Decisions (AgDR linkage): **Pass** — AgDR-0075 exists, captures context / three genuine options / decision / rollback / consumers / testing / observability / consequences, links ticket #448, and matches the core implemented decision. (One descriptive inaccuracy — see Traceability.)
- ✅ Risk: **Pass** — failure modes and blast radius addressed; the irreversible `DROP username` is honestly bounded by a pre-apply snapshot and a stated rollback window ("within the same deploy window / until first phone-only admin exists"). Adequate for a UAT-stage tiny table.
- ✅ Trade-off analysis: **Pass** — three real alternatives weighed (nullable-alongside, reuse-username-column); the placeholder-can't-log-in trade-off is named and accepted.
- ⚠️ Requirements traceability: **Concern (non-blocking)** — see finding T1: the AgDR describes the JWT identity model incorrectly.
- ✅ Migration safety: **Pass** — GO-batching rationale correct (per-batch parse-time name resolution), NOT-NULL-before-index ordering correct with the right error (4922) cited, filtered-unique `WHERE deleted_at IS NULL` matches the house convention, old index dropped by its real name (`uq_admins_username_active` from `V20260101000800`). Backfill uniqueness is provably safe: seed uses `010…`, generated rows use `011…` via `ROW_NUMBER()` (distinct from each other and from the seed), and the column had no prior values to collide with.
- N/A Adopter Handbooks: no blocking handbook applied to this diff.

### Blocking Findings

**None.** The design is sound and safe to build against — and, as it happens, already built and green (Rex approved this SHA; migration IT 5/0 on MSSQL). Nothing here holds up Build.

### Non-blocking Findings

- **T1 — AgDR mis-describes the JWT identity carrier (traceability).** AgDR-0075 states in three places that "the JWT `sub` claim carries the username" and "the JWT subject is now the phone number." The implementation does **not** do this: `JwtService` sets `.subject(adminId.toString())` — the `sub` is a stable admin **UUID** both before and after this change. What actually changed is a *secondary* claim rename, `username` → `phoneNumber` (JwtService/JwtAuthFilter). The code is in fact *safer* than the AgDR claims (the token subject is unchanged, so the "consumer that parsed the subject as a username" risk the AgDR raises never existed). This is a documentation defect in a durable decision record, not a design flaw — but please correct the Context, Cross-Service Consumers, and Consequences sections so future readers don't inherit the wrong mental model of where admin identity lives in the token.

- **N1 — Index-name typo in the PR body (cosmetic).** The PR summary calls the new index `ux_admins_phone_number`; the migration SQL correctly creates `uq_admins_phone_number_active` (matching the `uq_…_active` house convention and the dropped `uq_admins_username_active`). The SQL is right; only the PR prose is off. Worth fixing so a future "drop this index" migration greps the correct name.

### Suggestions

- Consider a follow-up operational note (runbook line, not a blocker) enumerating which non-seed UAT admins received `011000000NN` placeholders, so the operator has a checklist of numbers to reset before those accounts are expected to authenticate.

### Verdict

**APPROVED**

The decision is well-reasoned, the alternatives are genuine, the migration is correctly sequenced and provably safe on uniqueness/ordering, the rollback is honest about irreversibility, and the hexagonal/Modulith boundaries are clean. The two findings are documentation-accuracy items (T1 is worth correcting in the AgDR; N1 is cosmetic) and neither undermines the design's soundness — so they do not gate the merge. Please fold the T1 correction into the AgDR when convenient.

---

🏛️ Reviewed by Tariq (Solution Architect)
📌 Reviewed commit: `cc8a9688235a8b3607b3a3569d07200129fd6c67`
