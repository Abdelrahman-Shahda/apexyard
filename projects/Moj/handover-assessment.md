# Moj — Handover Assessment

**Date**: 2026-06-08
**Assessor**: Abdelrahman Shahda
**Status**: handover

> **Update (2026-06-08, post-clone)**: the initial static read was taken against `main` (HEAD `46909d3`, Java 21, 314 files). The **active integration branch is `development`** (HEAD `27624a4`) — Java **25** (bumped in `27624a4`), **667 main + 61 test Java files**, with many more `core` aggregates (charge, court, division, judge, lawyer, participant-type, police-station, prosecution). Trunk-based development happens on `development`, not `main`. The three deep-dive reviews below were run against `development`. Stack/risk facts updated inline where they changed; harnessability re-confirmed `moderate` (still no JaCoCo/lint gate).

## Origin

- **Where it came from**: Internal Apes Solutions project — MOJ (Ministry of Justice) Judiciary Portal backend
- **Original owner**: Abdelrahman Shahda (sole contributor to date)
- **Repo location**: https://github.com/apessolutions/moj_judiciary (private)
- **First commit date**: 2026-06-02
- **Last commit date**: 2026-06-03 (clone HEAD); remote `pushedAt` 2026-06-07
- **Repo age**: ~6 days — greenfield, foundation-laying phase

## Current State

### Tech stack
- **Language**: Java 21
- **Runtime / framework**: Spring Boot 3.5.14, **Spring Modulith 1.4.11** (enforced module boundaries)
- **Architecture**: Hexagonal + DDD vertical slices, **jMolecules** (DDD model types) + jMolecules-ArchUnit
- **Database**: SQL Server (mssql-jdbc), **Flyway** migrations (per-module folders on one timeline)
- **Security**: Spring Security + JWT (jjwt 0.12.6), session aggregate with refresh-token rotation + reuse detection
- **Observability**: Actuator, Micrometer tracing → OpenTelemetry (OTLP exporter), Prometheus registry
- **Build extras**: GraalVM native-image plugin, Hibernate bytecode enhancement, Lombok
- **Test framework**: JUnit 5, Spring Boot Test, **Testcontainers** (MSSQL), spring-modulith-starter-test, spring-security-test
- **i18n**: 3 message bundles (messages / errors / validation), EN + AR, completeness-tested
- **CI**: none (no `.github/workflows`)

### Build status
- `mvnw test-compile` (Java 21, Docker-free): **ok** — 336 main + 52 test classes compiled clean
- `mvnw verify` (full suite, needs Docker): **not attempted**
- Lint: **n/a** — no linter configured (see Harnessability)
- Coverage: **n/a** — no coverage tooling configured

### Test coverage
- **Estimated**: unknown (no JaCoCo / coverage threshold). 33 test files against 314 source files. Strong **architectural** test gates present: `ModularityTests` (Spring Modulith + jMolecules verify), `PermissionCatalogIntegrityTest`, `MessageBundleCompletenessTest`. Domain/application tests use in-memory port fakes (no Spring/Docker); persistence tests use Testcontainers.

### Repo activity
- Commits in last 90 days: 13 (all of them — repo is 6 days old)
- Open issues: 0
- Open PRs: 0
- Top contributors: Abdelrahman Shahda (sole author)

## Harnessability assessment

**Overall verdict**: `moderate`

The codebase architecture is excellent — among the most disciplined in the portfolio. The `moderate` verdict comes purely from the two *mechanical-gate* dimensions: there is no enforced coverage threshold and no lint/format plugin. Both are scored `absent` by the rubric even though the project's `ModularityTests` + ArchUnit gates are a **stronger** correctness signal than a typical lint baseline. Rex's architecture handbooks will run cleanly here; the blocking gate is safe to enable once a lint/coverage baseline lands (see Next Steps).

| Dimension | Score | Evidence |
|-----------|-------|----------|
| Type safety | `strong` | Java 21 (statically strongly typed); jMolecules `@ValueObject` records with self-validating compact constructors enforce invariants at the type boundary |
| Module boundaries | `strong` | Spring Modulith `ModularityTests` calls `ApplicationModules.of(...).verify()`; jMolecules-ArchUnit on the DDD model; hexagonal `domain/application/infrastructure` vertical slice per aggregate; `shared/` is an open module forbidden from importing `iam/` |
| Framework opinionation | `strong` | `spring-boot-starter-parent` 3.5.14 with data-jpa + web + security + validation + AOP — full persistence + HTTP + DI + security opinionation |
| Test coverage signal | `absent` | No JaCoCo / coverage threshold in `pom.xml` (33 test files + architecture gates exist, but no enforced coverage %) |
| Lint baseline | `absent` | No Checkstyle / Spotless / PMD / google-java-format plugin in `pom.xml`; no `.editorconfig` or `.pre-commit-config.yaml` |

See AgDR-0042 for the scoring rationale and v1 thresholds.

## Quality Risks

### Security
- **Bootstrap super-admin default password is `admin1234`** (`app.bootstrap.super-admin.password`). Env-overridable (`APP_BOOTSTRAP_SUPER_ADMIN_PASSWORD`) and seeder is `@ConditionalOnProperty`, but a deploy that forgets the override ships a guessable super-admin. **Highest-severity finding.**
- **JWT signing secret defaults to a placeholder** (`change-me-please-use-a-32-byte-minimum-secret`). Env-overridable (`APP_SECURITY_JWT_SECRET`); a missed override means a publicly-known signing key. Deploy-time gate needed.
- Positives: no hardcoded secrets in `src/main`; `.env`/`*.env` gitignored; stack traces gated off by default (`app.errors.include-stack=false`); CORS origins env-driven; audit snapshots explicitly exclude secrets; refresh-token reuse detection (`SessionReuseException`).

### Dependencies
- Spring Boot 3.5.14 and jjwt 0.12.6 are current. No abandoned packages observed in `pom.xml`. No CVE scan performed yet — run `/audit-deps` to confirm.

### Technical debt
- **No top-level README** — only per-module READMEs (`shared/audit`, `iam/auth`). A newcomer can't learn how to run or deploy the service from the repo root.
- No enforced test-coverage threshold (JaCoCo absent).
- No lint/format baseline (Checkstyle/Spotless absent) — style consistency rests on author discipline.

### Operational
- **No CI pipeline** — every quality gate (ModularityTests, compile, tests) is local-only; nothing blocks a bad push.
- OTLP trace export disabled by default (`MANAGEMENT_OTLP_TRACING_EXPORT_ENABLED=false`) — no collector wired yet, so traces aren't leaving the app.
- No application Dockerfile or deployment automation. `compose.yaml` provisions a dev SQL Server only; there is no documented prod deploy path.

## Deep-dive reviews (2026-06-08, against `development`)

Three follow-up reviews were run by sub-agents against the `development` branch:

- [`security/threat-model.md`](security/threat-model.md) — STRIDE, **15 findings** (1 Critical · 4 High · 6 Medium · 4 Low)
- [`security/security-review.md`](security/security-review.md) — Security Auditor / OWASP pass, **11 findings** (0 Critical · 3 High · 4 Medium · 4 Low) + 6 verified strengths
- [`code-review.md`](code-review.md) — Rex code-quality calibration, **verdict A− (Excellent)**, 10 findings (1 BLOCKING-tier · 5 suggestion · 3 nit · 1 question)

### New high-severity findings NOT covered by issues #1–#6

| Finding | Severity | Source | Note |
|---------|----------|--------|------|
| `AuditController` has **zero `@PreAuthorize`** — any authenticated admin reads all judiciary entity history + other actors' activity | High (OWASP A01) | security-review H-1 | The one true **authorization gap**. Distinct from #1. Should be filed. |
| `Division` aggregate (richest invariant: `DivisionFormation` no-overlap, `Panel` shapes) has **zero domain tests** | BLOCKING-tier | code-review B1 | Highest-value test gap. Should be filed. |
| No rate limiting / lockout on `/auth/login` + `/auth/refresh` | High / Medium | threat-model T2, security-review M-1 | Unthrottled credential brute force. |
| All actuator endpoints (`metrics`, `prometheus`, `modulith` module map) `permitAll()` unauthenticated | High / Medium | threat-model T3, security-review M-3 | Recon surface. |
| `X-Forwarded-For` trusted verbatim (no trusted-proxy allowlist) → audit-log + session IP spoofing | High | threat-model T5 | Audit integrity (repudiation). |
| No transport-security enforcement (HSTS / `requiresSecure`) | High | threat-model T4 | Depends entirely on external TLS config. |

**Strengths both security reviews confirmed** (balanced view): no jjwt alg-confusion (`verifyWith` key-pinning + `requireIssuer`), refresh-token SHA-256 hashing + rotation with reuse-detection that survives rollback, BCrypt password storage, zero SQL-injection surface (named params / CriteriaBuilder), env-driven secrets, gated stack traces, deny-by-default chain, no-wildcard CORS, consistent `@PreAuthorize` + Bean Validation across all 15 domain controllers (except the `AuditController` gap above).

**Codify-rule candidates** (from code-review, worth promoting to portfolio handbooks): the batched-`toResponses` N+1-by-construction pattern (candidate for `ENFORCEMENT: blocking`), hexagonal visibility rules, the two-factory `register`/`rehydrate` pattern, and the shared `FieldValidationException` pattern.

## Integration Plan

### Roles that apply
- `tech-lead` (always)
- `backend-engineer` (Java/Spring domain + application + infrastructure code)
- `security-auditor` (JWT, Spring Security, password encoding, session/auth surface)
- `sre` (OpenTelemetry + Prometheus + Actuator observability surface; prod operability)
- `platform-engineer` (CI pipeline + golden-path adoption — imminent, see Next Steps)

### Workflows that kick in
- [ ] PR workflow (`.claude/rules/pr-workflow.md`) — every change goes through a PR
- [ ] AgDR for technical decisions
- [ ] Code Reviewer agent (Rex) on every PR
- [ ] Security Reviewer agent (Hakim) on first pass + auth/crypto PRs
- [ ] `/audit-deps Moj` on adoption and monthly thereafter
- [ ] Migration gate — Flyway migrations under `db/migration/**` will trip `require-migration-ticket.sh`; use `/migration`

### Hooks to enable
- [ ] `block-git-add-all`
- [ ] `block-main-push`
- [ ] `validate-branch-name` (set `ticket_prefix: MOJ` for this project)
- [ ] `validate-pr-create`
- [ ] `pre-push-gate`
- [ ] `check-secrets`

### CI templates to copy in
- [ ] `golden-paths/pipelines/ci.yml` (adapt to Maven/Java: `./mvnw verify`)
- [ ] `golden-paths/pipelines/security.yml`
- [ ] `golden-paths/pipelines/pr-title-check.yml`

### Registry entry

```yaml
- name: Moj
  repo: apessolutions/moj_judiciary
  workspace: workspace/Moj
  docs: projects/Moj
  status: handover
  roles:
    - tech-lead
    - backend-engineer
    - security-auditor
    - sre
    - platform-engineer
  ticket_prefix: MOJ
```

## Next Steps

All six filed as tracker tickets in `apessolutions/moj_judiciary` on 2026-06-08.

1. ~~**Gate the bootstrap super-admin password + JWT secret defaults**~~ → Filed as [#1](https://github.com/apessolutions/moj_judiciary/issues/1) (`[Bug]`)
2. ~~**Set up CI** (`./mvnw verify` + branch protection)~~ → Filed as [#2](https://github.com/apessolutions/moj_judiciary/issues/2) (`[CI]`)
3. ~~**Add a JaCoCo coverage threshold**~~ → Filed as [#3](https://github.com/apessolutions/moj_judiciary/issues/3) (`[Testing]`)
4. ~~**Add a lint/format baseline** (Spotless + google-java-format)~~ → Filed as [#4](https://github.com/apessolutions/moj_judiciary/issues/4) (`[Chore]`)
5. ~~**Write a top-level README**~~ → Filed as [#5](https://github.com/apessolutions/moj_judiciary/issues/5) (`[Docs]`)
6. ~~`/audit-deps Moj` — confirm no CVEs~~ → Filed as [#6](https://github.com/apessolutions/moj_judiciary/issues/6) (`[Chore]`)

## Post-Handover Checklist

- [ ] Review this assessment with the project owner (Abdelrahman Shahda)
- [ ] Gate the bootstrap super-admin password + JWT secret defaults — close before the first production deploy
- [ ] Stand up CI (`./mvnw verify`) in the first 2 weeks
- [ ] Add `Moj` to the weekly `/stakeholder-update` rollup
- [ ] Onboard the listed roles (tech-lead, backend-engineer, security-auditor, sre, platform-engineer) into review rotation
- [ ] Add a JaCoCo coverage baseline (run `./mvnw verify` with the jacoco plugin and commit the threshold)
- [ ] Run `/audit-deps Moj` monthly for the next 3 months

## Open Questions

- Is there a frontend repo for the portal (the config sets `APP_CORS_ORIGINS` default `http://localhost:3000`), or is this backend-only under MOJ governance?
- What is the target deployment environment (on-prem MOJ datacentre vs cloud)? No Dockerfile / IaC present to infer from.
- Is the SQL Server licensing/edition for production decided (compose uses `express`)?
- Will an OTLP collector be provisioned so the already-wired tracing actually exports?
