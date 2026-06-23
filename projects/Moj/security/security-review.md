# Security Audit — Moj (MOJ Judiciary Portal Backend)

**Project**: Moj — Ministry of Justice Judiciary Portal (backend)
**Reviewer**: Hakim (Security Auditor)
**Date**: 2026-06-08
**Branch audited**: `development`
**Stack**: Java 25 · Spring Boot 3.5.14 · Spring Modulith · Spring Security + JWT (jjwt 0.12.6) · SQL Server + Flyway · Hibernate/JPA
**Scope**: Code-level OWASP / common-weakness audit (complementary to, not a substitute for, a STRIDE threat model). ~680 main Java files.

---

## Executive Summary

The codebase shows a **mature, well-considered security posture** for a greenfield judiciary system. The authentication subsystem is the standout: HS256 JWTs with explicit key-pinned verification (no jjwt alg-confusion exposure), opaque 256-bit `SecureRandom` refresh tokens stored only as SHA-256 hashes, refresh-token **rotation with reuse detection** that revokes every session on theft, generic credential errors that prevent username enumeration, password-change session invalidation, env-driven secrets, parameterised queries throughout, and gated stack-trace exposure. Authorization is consistently enforced via `@PreAuthorize` on every state-changing **and** read endpoint across all 15 domain controllers.

The posture is **conditional-pass**: there are **no Critical findings in source code**, but two issues must be resolved before any production-facing deployment. The single most important code-level gap is the **AuditController, which has no authorization at all** — any authenticated admin, including one holding zero permissions, can read the complete audit history of any entity and any other actor's activity (sensitive judiciary PII and insider-action trails). The second is **operational/config hygiene**: an enabled-by-default super-admin bootstrap with the well-known credential `admin/admin1234` and a JWT-secret placeholder fallback that boots silently if the env var is unset. Both are env-overridable but fail open if an operator forgets — for a judiciary system that is an unacceptable default. Additionally, there is **no rate limiting / brute-force protection on `/auth/login`**.

### Findings by severity

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High     | 3 |
| Medium   | 4 |
| Low      | 4 |
| Info / strengths | 6 |

---

## Findings

| ID | Severity | OWASP | Location | Finding |
|----|----------|-------|----------|---------|
| H-1 | **High** | A01 Broken Access Control | `shared/audit/web/AuditController.java:40,49` | Audit-query endpoints have **no `@PreAuthorize`** — any authenticated admin (even with zero permissions) reads the full audit trail of any entity and any actor. |
| H-2 | **High** | A07 Auth Failures / A05 Misconfig | `application.properties:47-49`; `iam/admin/.../bootstrap/SuperAdminBootstrap.java:47` | Super-admin seeder is **enabled by default** with default credentials `admin/admin1234`. Fresh boot without overrides yields a guessable god account. |
| H-3 | **High** | A02 Crypto / A05 Misconfig | `application.properties:21`; `iam/.../security/JwtService.java:33` | JWT secret falls back to the **committed placeholder** `change-me-please-use-a-32-byte-minimum-secret` when `APP_SECURITY_JWT_SECRET` is unset — app boots silently; anyone reading the repo can forge valid tokens. |
| M-1 | Medium | A07 Auth Failures | `iam/.../web/AuthController.java:72`; pom.xml (no dep) | **No rate limiting / lockout** on `/auth/login` or `/auth/refresh`. Online brute-force / credential-stuffing is unmitigated. |
| M-2 | Medium | A09 Logging / A04 Insecure Design | `iam/.../AuthApplicationService.java:163-172` | **Failed logins are not audited** (explicit design choice noted as "high-volume, low-signal"). For a judiciary system, absence of failed-auth trail hampers intrusion detection and forensics. |
| M-3 | Medium | A05 Misconfig | `application.properties:31`; `SecurityConfig.java:43` | Actuator chain is `permitAll()` for **all** exposed endpoints including `metrics`/`prometheus`. `health` is `when_authorized`, but metrics/prometheus leak operational internals to unauthenticated callers if the port is reachable. |
| M-4 | Medium | A07 Auth Failures | `iam/.../AuthController.java:107-113` | `X-Forwarded-For` is trusted unconditionally for the session-recorded client IP. A client can spoof the audited source IP (the session metadata used in reuse-detection forensics). |
| L-1 | Low | A07 Auth Failures | `RegisterAdminRequest.java:30`; `ChangePasswordRequest.java:14` | Password policy is **min-length 8 only** — no complexity, no breached-password (HIBP) check. Weak for privileged judiciary accounts. |
| L-2 | Low | A02 Crypto | `shared/security/PasswordEncoderConfig.java:14` | BCrypt at **default cost 10**. Acceptable today; for high-value judiciary admin accounts consider cost 12 or migrate to Argon2id. |
| L-3 | Low | A04 Insecure Design | `iam/.../AuthApplicationService.java:73` | No artificial constant-time delay on the `passwordEncoder.matches` path; the username-not-found branch (`InvalidCredentialsException` before any hash) skips BCrypt entirely → a **timing oracle** for valid-vs-invalid usernames. |
| L-4 | Low | A05 Misconfig | `shared/security/` (absent) | No explicit security-headers hardening (HSTS, CSP). Spring Security defaults (`X-Content-Type-Options`, `X-Frame-Options: DENY`, cache headers) apply, but HSTS for the judiciary domain should be explicit, not proxy-assumed. |

---

## Detailed findings + remediation

### H-1 — AuditController has no authorization (Broken Access Control)

**Location**: `src/main/java/eg/judiciary/portal/shared/audit/web/AuditController.java:40` and `:49`
**Description**: Both `GET /api/v1/audit/entities/{type}/{id}` and `GET /api/v1/audit/admins/{id}/activity` carry **no `@PreAuthorize`**. They are merely `authenticated()` via the filter chain. Every other domain controller (Admin, Role, Court, Judge, Lawyer, etc.) gates *both reads and writes* on a typed permission. The audit log is the most sensitive read surface in the system — it exposes the full mutation history of judiciary entities (PII snapshots) and the action trail of every other admin (insider-threat reconnaissance). Any low-privilege account can read all of it.
**Impact**: Confidentiality breach of judiciary PII history + exposure of privileged users' activity to any authenticated principal. This is a classic A01 function-level authorization gap.
**Remediation**: Introduce an `AuditPermission` catalog (e.g. `AUDIT_READ`) per the project's permission convention and annotate both methods: `@PreAuthorize("@perms.has('" + AuditPermission.Authority.AUDIT_READ + "')")`. Consider further restricting `activityOf` so a non-super-admin cannot enumerate *other* admins' activity (object-level check), or scope it to super-admin only.
**CWE**: CWE-862 (Missing Authorization).

### H-2 — Default super-admin `admin/admin1234`, enabled by default

**Location**: `src/main/resources/application.properties:47-49`; `SuperAdminBootstrap.java:47`
**Description**: `app.bootstrap.super-admin.enabled` defaults to `true` and the username/password default to `admin` / `admin1234`. A fresh deployment that doesn't set the override env vars seeds a god account with a trivially guessable credential. The seeder is otherwise well-built (soft-delete-aware idempotency, goes through normal hashing + audit), but the **defaults fail open**.
**Impact**: Full system compromise via a publicly-known credential if any environment boots without overrides.
**Remediation**: (1) Default `enabled` to `false` (`matchIfMissing=false` already required, but the property default is `true`). (2) Remove the password default entirely so the app refuses to seed without an explicit strong secret — the runner already throws on blank username/password, so removing the `:admin1234` default converts "weak default" into "fail-closed". (3) Force a password change on first super-admin login.
**CWE**: CWE-798 (Use of Hard-coded Credentials), CWE-1392 (Default Credentials).

### H-3 — JWT secret placeholder fallback boots silently

**Location**: `src/main/resources/application.properties:21`; consumed at `JwtService.java:33`
**Description**: `app.security.jwt.secret=${APP_SECURITY_JWT_SECRET:change-me-please-use-a-32-byte-minimum-secret}`. If the env var is unset, the app boots successfully using the **committed** 32+ byte placeholder. jjwt only enforces *length*, not *secrecy* — so anyone with repo access can sign forged tokens for any admin id, including a fabricated super-admin subject (though authorities are re-resolved per-request, a forged token for a real super-admin's UUID grants full access).
**Impact**: Complete authentication bypass / token forgery if any environment runs on the default secret.
**Remediation**: Remove the fallback so a missing `APP_SECURITY_JWT_SECRET` is a **fail-closed startup error** (mirror the seeder's `IllegalStateException` pattern). Optionally add a startup assertion rejecting the known placeholder value.
**CWE**: CWE-321 (Hard-coded Cryptographic Key), CWE-1188 (Insecure Default Initialization).

### M-1 — No brute-force protection on authentication

**Location**: `AuthController.java:72-85`; no `bucket4j`/`resilience4j` in `pom.xml`
**Description**: There is no rate limiting, account lockout, or backoff on `/auth/login` or `/auth/refresh`. Combined with the min-8 password policy (L-1), online password guessing and credential stuffing are unmitigated.
**Remediation**: Add per-IP + per-username rate limiting (bucket4j filter, gateway/WAF rule, or a lockout counter on the Admin aggregate with exponential backoff). At minimum, throttle `/auth/login`.
**CWE**: CWE-307 (Improper Restriction of Excessive Authentication Attempts).

### M-2 — Failed logins not audited

**Location**: `AuthApplicationService.java:66-88` and the class javadoc (`:163-172` region)
**Description**: Only `TOKEN_REUSE_DETECTED` and `PASSWORD_CHANGED` are audited; login/logout/refresh and **failed login attempts** are deliberately excluded. For a Ministry of Justice system, the absence of a failed-auth trail materially weakens intrusion detection and post-incident forensics.
**Remediation**: Emit a low-cardinality `LOGIN_FAILED` audit (or at least a security log event with username + source IP + timestamp), ideally rate-aggregated to avoid log flooding. Pairs naturally with M-1's lockout counter.
**CWE**: CWE-778 (Insufficient Logging).

### M-3 — Actuator metrics/prometheus exposed unauthenticated

**Location**: `application.properties:31`; `SecurityConfig.java:41-44`
**Description**: The `@Order(1)` actuator chain `permitAll()`s **every** exposed endpoint. Exposed set is `health,info,metrics,prometheus,modulith`. `health` is correctly `when_authorized`, but `metrics`, `prometheus`, and `modulith` are reachable without auth and leak operational/topology internals.
**Remediation**: Restrict the actuator chain to require authentication (or a monitoring role) for `metrics`/`prometheus`/`modulith`, or bind the management port to an internal-only interface. Keep only `health`/`info` public if a load balancer needs them.
**CWE**: CWE-200 (Exposure of Sensitive Information).

### M-4 — Spoofable client IP in session forensics

**Location**: `AuthController.java:107-113` (`clientIp`)
**Description**: `X-Forwarded-For` is trusted unconditionally and the first token is recorded as the session source IP — the same IP that feeds reuse-detection forensics. A client controls this header end-to-end unless a trusted proxy overwrites it.
**Remediation**: Only honour `X-Forwarded-For` from a configured trusted-proxy allowlist (Spring's `ForwardedHeaderFilter` / `server.forward-headers-strategy=FRAMEWORK` behind a known proxy); otherwise use `getRemoteAddr()`.
**CWE**: CWE-348 (Use of Less Trusted Source).

### L-1 / L-2 / L-3 / L-4

- **L-1** Strengthen password policy: complexity or, better, length-forward (min 12) + HIBP breached-password check for privileged accounts. (`RegisterAdminRequest.java:30`, `ChangePasswordRequest.java:14`)
- **L-2** Raise BCrypt cost to 12 or adopt `Argon2PasswordEncoder` via `DelegatingPasswordEncoder` (keeps existing hashes upgradable). (`PasswordEncoderConfig.java:14`)
- **L-3** Username-enumeration timing oracle: the not-found branch returns before BCrypt runs. Run a dummy BCrypt comparison on the not-found path to equalise timing. (`AuthApplicationService.java:163-172`)
- **L-4** Add explicit HSTS (and a minimal CSP if any HTML is ever served) in `SecurityConfig` rather than relying on proxy termination.

---

## Strengths (verified, not assumed)

These were checked in code and are genuinely well-handled — call-outs so the report is balanced:

1. **No JWT alg-confusion exposure** — `JwtService.parse` uses `Jwts.parser().verifyWith(key)` (jjwt 0.12.x), which pins the verification key and rejects tokens whose alg doesn't match the key type. There is no `parse` path that trusts a client-supplied algorithm. `requireIssuer` is also enforced. (`JwtService.java:52-59`)
2. **Refresh-token reuse detection** — presenting a revoked refresh token revokes *all* sessions for the admin and records a `recordCritical` audit row that survives transaction rollback. Excellent insider/theft-response design. (`AuthApplicationService.java:97-105`)
3. **Tokens stored as hashes, never raw** — refresh tokens are 256-bit `SecureRandom`, base64url-encoded, and persisted only as SHA-256 hashes via the `TokenHash` value object (raw value never hits the DB). SHA-256 (not BCrypt) is the correct choice here given the tokens are already high-entropy. (`JwtTokenIssuer.java`, `TokenHash.java`)
4. **No SQL/JPQL injection surface** — every `@Query` (native and JPQL) uses named parameters; the dynamic filter layer uses CriteriaBuilder `Specification`s with bound predicates (`Specs.java`). No string concatenation of user input into queries anywhere in the codebase.
5. **Env-driven secrets + gated stack traces** — all secrets are externalised to env vars; `app.errors.include-stack` defaults to `false` so production 500s never leak traces; the generic handler logs server-side and returns a localized generic message. (`GlobalExceptionHandler.java:167-177`)
6. **Consistent authorization + input validation** — every domain controller gates reads and writes with typed `@PreAuthorize` permission constants; request DTOs use Bean Validation (`@NotBlank`/`@Pattern`/`@Size`/`@NotEmpty`); pagination is server-capped (max 100 globally, audit capped at 200); deny-by-default `@Order(3)` chain; stateless sessions; CORS uses an explicit origin allowlist (no wildcard) even with `allow-credentials=true`; devtools is `optional`/`runtime` (excluded from the prod artifact). Generic `InvalidCredentialsException` prevents username enumeration at the response level (timing aside, see L-3).

---

## Recommendations (priority order)

1. **H-1** — Add `@PreAuthorize` (new `AUDIT_READ` permission) to both AuditController endpoints **before any deployment**.
2. **H-3** — Make missing `APP_SECURITY_JWT_SECRET` a fail-closed startup error; reject the known placeholder.
3. **H-2** — Default the super-admin bootstrap to disabled; remove the `admin1234` password default; force first-login rotation.
4. **M-1 + M-2** — Add login rate limiting/lockout and audit failed logins together.
5. **M-3** — Lock down actuator `metrics`/`prometheus`/`modulith`.
6. **M-4, L-1–L-4** — Schedule in the current/next sprint.

> Dependency CVE scanning is tracked separately as issue #6. Spot-check here: Spring Boot 3.5.14 and jjwt 0.12.6 are current; mssql-jdbc/Flyway pulled via BOM — no obviously-outdated pin spotted in `pom.xml`. Defer the full transitive CVE sweep to #6.
