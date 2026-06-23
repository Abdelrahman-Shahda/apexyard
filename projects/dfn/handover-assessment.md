# DFN — Handover Assessment

**Date**: 2026-05-13
**Assessor**: Abdelrahman Shahda
**Status**: handover

> Static-read assessment built from the GitHub API (private repo, no local clone). Build / test / coverage checks were NOT executed — see "Open Questions" for what a follow-up local clone should confirm.

## Origin

- **Where it came from**: Internal Apes Solutions project; private repo under `apessolutions` org.
- **Original owner**: Abdelrahman Shahda (dominant contributor, 527 commits) with a small in-house team (mofarag-apes, Mahmoud3mmarr, AbdelrahmanMohamedEmam, OmarAhmedApes, ziadk432).
- **Repo location**: https://github.com/apessolutions/dfn (private, default branch `development`)
- **First commit date**: 2025-01-20
- **Last commit date**: 2026-05-05 (`8e2da05` — refactor: update user subscription repository and service)

## Current State

### Tech stack

- Language: TypeScript (~4.79 MB, dominant) with smaller pockets of Python (55 KB), Shell (78 KB), PowerShell (24 KB), PLpgSQL (5 KB), Handlebars (24 KB)
- Runtime: Node 20 (per `Dockerfile` base image `node:20-alpine`) — `package.json` does **not** declare an `engines` field
- Framework: **NestJS 10** (CQRS, BullMQ, JWT, Passport, Mongoose, TypeORM, Swagger) on the backend; **React 18 + MUI v5 + Vite** on the frontend, bundled together as an **Nx 20.2.2 monorepo**
- Database: **PostgreSQL 18** (TypeORM-managed, with `migration:*` scripts) **and** **MongoDB 6.0** (Mongoose) — dual-store
- Cache / queue: **Redis** (`cache-manager-redis-yet`, BullMQ + Bull, `@bull-board/*`)
- External services: AWS S3 (`@aws-sdk/client-s3`), Firebase Admin, Twilio, Nodemailer (SMTP), Z3 SAT solver (`z3-solver`)
- Test framework: Jest 29 + Vitest 1.3 (with dedicated `*-e2e` apps: `mobile-api-e2e`, `org-e2e`, `web-api-e2e`)
- Lint / format: ESLint 9 (with perfectionist, simple-import-sort, jsx-a11y, react-hooks, tanstack-query), Prettier 2.6, TypeScript-ESLint 8
- Package manager: **mixed** — both `package-lock.json` and `pnpm-lock.yaml` + `pnpm-workspace.yaml` are checked in. Dockerfile and (likely) deploy scripts use `pnpm`; `package.json` script bodies say `npm run typeorm …`. **Drift risk.**
- CI: GitHub Actions on **self-hosted runners**; three workflows (`ci-dev.yml`, `ci-prod.yml`, `ci-temp.yml`). The dev workflow builds Docker images locally on the runner, then SSHes to a hard-coded EC2 IP (`18.216.171.111`) and runs `sudo bash ./deploy.sh`.

### Apps & libs (Nx workspace)

- **Backend apps** (NestJS): `web-api`, `mobile-api`, `org`, `ai-engine`, `meal-engine`
- **Frontend apps** (React/Vite + MUI): `admin-dashboard`, `org` (overlaps with backend — needs clarification)
- **e2e apps**: `mobile-api-e2e`, `org-e2e`, `web-api-e2e`
- **Libs** (40+): `auth`, `payment-provider`, `meal-plan`, `meal-engine`, `workout-engine`, `recipes`, `ingredients`, `notifications`, `mail`, `i18n`, `database`, `redis`, `logger`, `audit-trail`, `auth-log`, `cart`, `promo-code`, `transaction`, `user-subscription`, `user-workflow`, `leads`, `campaigns`, `file`, `package`, `role`, `addon`, `banner`, … (domain-rich)

### Build status

- `pnpm install`: **not attempted** (no local clone)
- `pnpm nx build <app>`: **not attempted**
- `pnpm nx test`: **not attempted**
- `pnpm nx lint`: **not attempted**

CI signal as a proxy (last 5 runs on `development`):

| Date | Status | Commit |
|------|--------|--------|
| 2026-05-05 08:25 | ✅ success | refactor: update user subscription repository… |
| 2026-05-05 07:22 | ❌ **failure** | feat: add methods for shifting and locking user subscriptions… |
| 2026-05-04 20:00 | ✅ success | refactor: rename findActiveSubscriptionPeriod… |
| 2026-05-04 19:38 | ✅ success | feat: add reset script for user subscription state management |
| 2026-05-04 15:45 | ✅ success | chore: add workflow_dispatch trigger… |

4-of-5 green; the one failure was fixed in the next push. Baseline is reasonably healthy on the deploy-dev path, but coverage and lint thresholds aren't visible from the workflow alone.

### Test coverage

- Estimated: **unknown** — no coverage report wired into CI, no badge in README. Vitest + Jest are both configured, so the infrastructure exists; threshold is uncommitted.

### Repo activity

- Commits in last 90 days: **84** (high cadence — ~1 commit/day)
- Open issues: **0** (likely tracked elsewhere — Spark uses GitHub Issues, DFN may not yet)
- Open PRs: **1** (#65 — feat: Implement user seeding functionality)
- Top contributors:
  - Abdelrahman-Shahda — 527 commits (lead)
  - mofarag-apes — 192
  - Mahmoud3mmarr — 162
  - AbdelrahmanMohamedEmam — 76
  - OmarAhmedApes — 74
  - ziadk432 — 6

## Quality Risks

### Security

- **`.env.deployment` files are COPIED into the production Docker image** (see Dockerfile lines `COPY ./apps/org/.env.deployment ./apps/org/.env`, same for `web-api` and `mobile-api`). Secrets land in the image layer and survive image inspection. Should be injected at runtime (compose env vars / SSM / Vault), not baked.
- **Hard-coded EC2 IP in CI** (`18.216.171.111`) — single point of failure, undocumented host, no DNS abstraction.
- **No `LICENSE` file** — private repo, but absent license complicates future contractor / partnership / open-source decisions.
- **Self-hosted runners** — supply-chain risk if a malicious PR lands a step that exfiltrates secrets from the runner. No `pull_request` workflow seen for forks (mitigates the worst case, but the gap should be intentional).
- **Auth + crypto surface present**: `@nestjs/jwt`, `@nestjs/passport`, `passport-jwt`, `bcryptjs`, Firebase Admin, Twilio (SMS OTP via `otp-generator`). Standard NestJS auth shape, but a Security Auditor pass is warranted before considering this "active".

### Dependencies

- **Mixed package-manager lockfiles** — both `package-lock.json` and `pnpm-lock.yaml` checked in. Whichever the Dockerfile resolves (`pnpm`) is the production source of truth; npm-installed local dev environments can diverge silently.
- **`express ^5.2.1`** — Express 5 is still relatively new; middleware ecosystem maturity should be confirmed for the routes that use raw Express (most NestJS code is abstracted from this, but `multer`, `morgan`, `bull-board/express` touch it).
- **No declared `engines.node`** — local dev Node version drift across the 6-contributor team.
- Several dependencies pinned to broad caret ranges (`^`) with no Renovate / Dependabot config visible from the workflows directory.

### Technical debt

- **README is Nx scaffolding boilerplate** ("✨ Your new, shiny Nx workspace is ready ✨") — no domain summary, no architecture pointer, no how-to-run-locally, no deploy story.
- **Two apps named `org`** (one backend NestJS app, one frontend React app) — namespace collision; raises ambiguity in Nx commands and in this assessment.
- **`new_ingredients.json` + `old_ingredients.json`** sitting at repo root — looks like seeding artefacts that should live under `libs/database/.../seeds/` or be gitignored.
- **40+ libs, 5 backend apps, 2 frontend apps under one CI workflow** — full Nx graph rebuild on every push to `development`. Nx affected-graph caching could 5-10× the feedback cycle but isn't visible in `ci-dev.yml`.
- **TypeORM + Mongoose dual ORM** — increases cognitive load for the team and doubles the migration surface. Worth an AgDR if not already documented.

### Operational

- **No observability stack detected** in dependencies — only `winston` + `winston-daily-rotate-file` for logs. No Sentry, Datadog, New Relic, OpenTelemetry, CloudWatch SDK direct usage. Logs land on disk inside the EC2 box.
- **Deploy is `ssh && sudo bash deploy.sh`** to a pet server — rollback story, blue/green, health-check gating all unclear from the workflow alone.
- **No issue tracker activity** — 0 open issues despite 84 commits in 90 days. Either tracked off-GitHub (Linear / Jira / Notion) or not tracked. Either way, the SDLC gate "ticket exists before code" is currently informal.
- **No declared SLOs / alerting rules / runbooks** in repo.

## Integration Plan

### Roles that apply

- `tech-lead` — always
- `backend-engineer` — NestJS, TypeORM, BullMQ, CQRS work
- `frontend-engineer` — React/MUI/Vite work in `admin-dashboard` and `org` (frontend)
- `platform-engineer` — GH Actions workflows, Nx caching, Docker build
- `sre` — Dockerfile + EC2 deploy + self-hosted runner + observability gap
- `security-auditor` — JWT/Passport/bcrypt auth, Twilio OTP, secrets-in-image concern, payment-provider lib
- `data-engineer` — TypeORM migrations, dual Postgres+Mongo stores, seed scripts

### Workflows that kick in

- [ ] PR workflow (`.claude/rules/pr-workflow.md`) — every change goes through a PR (currently direct pushes to `development` are common; needs branch protection)
- [ ] AgDR for technical decisions (dual-ORM, Express 5 adoption, BullMQ vs raw Bull, self-hosted runner choice — all worth retroactive AgDRs)
- [ ] Code Reviewer agent on every PR
- [ ] Security Reviewer agent on first pass and high-risk PRs (auth, payment, file upload)
- [ ] `/audit-deps dfn` on adoption and monthly thereafter

### Hooks to enable

- [ ] `block-git-add-all`
- [ ] `block-main-push` (apply to `development` since that's the default branch)
- [ ] `validate-branch-name` — set `ticket_prefix: DFN` (or `GH` if migrating to GitHub Issues)
- [ ] `validate-pr-create`
- [ ] `pre-push-gate`
- [ ] `check-secrets` (high priority given `.env.deployment` pattern in Dockerfile)
- [ ] `require-migration-ticket` (TypeORM migration files live under `libs/database/src/lib/sources` — confirm and update `.claude/project-config.json` paths if needed)

### CI templates to copy in

- [ ] `golden-paths/pipelines/ci.yml` — combined quality + security + dependency-audit
- [ ] `golden-paths/pipelines/security.yml` — Semgrep + npm audit + secrets scan (especially relevant given the `.env.deployment` concern)
- [ ] `golden-paths/pipelines/pr-title-check.yml` — enforce `type(DFN-N): subject`
- [ ] `golden-paths/pipelines/review-check.yml` — block merge if Code Reviewer hasn't reviewed the latest commit

### Registry entry

Added to `apexyard.projects.yaml` at the root of the ops repo:

```yaml
- name: DFN
  repo: apessolutions/dfn
  workspace: workspace/dfn
  docs: projects/dfn
  status: handover
  roles:
    - tech-lead
    - backend-engineer
    - frontend-engineer
    - platform-engineer
    - sre
    - security-auditor
    - data-engineer
```

## Next Steps

1. **`/audit-deps dfn`** — triage the Express 5 surface and the unpinned-caret dependencies before any new feature work; confirm there are no transitive CVEs in `firebase-admin`, `twilio`, `multer-s3`, `sharp`.
2. **Standardise on `pnpm`** — delete `package-lock.json`, add `"packageManager": "pnpm@10.x"` to `package.json`, add `engines.node = "20.x"`. The Dockerfile already uses pnpm; the lock-file drift is the immediate risk.
3. **Pull secrets out of the Docker image** — replace the `COPY .env.deployment` pattern with runtime env injection (compose `env_file`, EC2 Parameter Store, or `docker run --env-file`). Audit the existing image layers to confirm no historical secrets leaked.
4. **`/decide` on observability** for DFN — likely candidates: Sentry + structured winston→CloudWatch OR Datadog APM. Currently disk-only winston logs on a pet server is below the SDLC bar.
5. **Set up test-coverage reporting** — both Jest and Vitest are present, so wire `--coverage` into a CI job and commit a baseline threshold (suggest 70% for domain libs to start).
6. **Establish issue-tracker baseline** — confirm where DFN tickets actually live (GitHub Issues with `DFN` prefix? Linear? Jira?) and set `ticket_prefix` in the registry accordingly. Currently 0 open issues despite 84 commits in 90 days is a gap.
7. **Rewrite the README** — replace the Nx scaffolding boilerplate with: one-paragraph product description, local-dev instructions (`pnpm install`, `docker-compose up dfn_db dfn_mongo dfn_redis`, `pnpm nx serve web-api`), the deploy story, a pointer to the L1+L2 architecture diagrams.
8. **Add the L1 context diagram** — `projects/dfn/architecture/context.md` is missing. Run `/c4` against a local clone once cloned.
9. **`/code-review` PR #65** (user seeding) as Rex — calibrates review standards against the existing codebase, surfaces conventions to codify.
10. **Stakeholder sync with the existing team** — Abdelrahman is both the assessor and the lead contributor here, so the "previous owner" handover is largely internal; even so, document context the static read can't surface (why dual-ORM, why self-hosted runners, deploy gotchas, SLA expectations).

## Post-Handover Checklist

- [ ] Review this assessment with the active DFN team (mofarag-apes, Mahmoud3mmarr, etc.)
- [ ] **Secrets-in-Docker-image risk** — close before the first feature PR on the new workflow
- [ ] **Pnpm/npm lockfile drift** — resolve in the first 2 weeks (delete `package-lock.json`, lock package manager, lock Node version)
- [ ] **Observability gap** — schedule the `/decide` + first instrumentation PR in the first 2 weeks
- [ ] Clone `workspace/dfn` locally so `/status`, `/inbox`, and `/code-review` have git access (`gh repo clone apessolutions/dfn workspace/dfn`)
- [ ] Add `dfn` to the weekly `/stakeholder-update` rollup
- [ ] Onboard the 7 roles listed above into the team's review rotation
- [ ] Set up a test coverage baseline (`pnpm nx test --coverage` per app, commit thresholds)
- [ ] Run `/audit-deps dfn` monthly for the next 3 months
- [ ] Add branch protection to `development` (require Rex + 1 human approval, require status checks green)
- [ ] Re-run `/handover dfn` against a local clone to fill in coverage %, lint status, and the architecture L1 diagram (this static-read pass left those as "unknown")

## Open Questions

- Are there active SLOs / paging rules / runbooks somewhere outside the repo? (None found in-repo.)
- Where do DFN tickets actually live today — GitHub Issues, Linear, Jira, Notion? The 0-open-issues + 84-commits signal says "tracked off-GitHub", but it could also mean "not tracked".
- The two `org` apps (one backend, one frontend) — are they intentionally co-named, or is the frontend the customer-facing portal and the backend a different bounded context?
- Why dual-ORM (TypeORM for Postgres + Mongoose for Mongo)? What's stored in each store? An AgDR retro would help future maintainers.
- Is there a staging environment distinct from "development → 18.216.171.111", and what's the production deploy path? `ci-prod.yml` exists but wasn't read in this pass.
- Self-hosted runner — who owns it, who patches it, what happens when it dies?
- Z3 SAT solver dependency (`z3-solver`) — what feature uses it? Worth an AgDR.
- Disk-only winston logs — how long are they retained, who monitors them, are they shipped anywhere?
