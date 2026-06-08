# Moj — MOJ Judiciary Portal

ApexYard-managed docs for **Moj**, the Ministry of Justice Judiciary Portal backend.

- **Repo**: https://github.com/apessolutions/moj_judiciary (private)
- **Stack**: Java 25 · Spring Boot 3.5 · Spring Modulith · jMolecules DDD · SQL Server · Flyway · JWT
- **Status**: handover (onboarded 2026-06-08 via `/handover`)
- **Owner**: Abdelrahman Shahda
- **Roles**: tech-lead · backend-engineer · security-auditor · sre · platform-engineer

## Docs

- [`handover-assessment.md`](handover-assessment.md) — onboarding assessment + harnessability score (`moderate`)
- [`architecture/container.md`](architecture/container.md) — C4 L2 container diagram (auto-stubbed, refine me)

## Top next steps

1. Gate the bootstrap super-admin password + JWT secret defaults before any prod deploy
2. Stand up CI (`./mvnw verify`)
3. Add a JaCoCo coverage threshold
4. Add a lint/format baseline (Spotless / Checkstyle)
5. Write a top-level README in the repo itself

See the assessment for the full list.
