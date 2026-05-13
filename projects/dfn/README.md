# DFN

> **Status**: handover (assessment in progress — see `handover-assessment.md`)

## What it is

DFN is an Apes Solutions Nx monorepo combining a multi-tenant NestJS backend (web, mobile, and org APIs plus AI / meal engines) with a React + MUI admin dashboard. It runs on PostgreSQL + MongoDB + Redis and integrates AWS S3, Firebase Admin, Twilio (SMS OTP), and SMTP email. Production deploys to a self-hosted EC2 host via GitHub Actions self-hosted runners.

Domain coverage (visible from the `libs/` graph) includes: meal planning, workout planning, recipes & ingredients, user subscriptions, payments / cart / promo codes / transactions, leads & campaigns, notifications & mail, audit & auth logging.

## Repo

- GitHub: https://github.com/apessolutions/dfn (private)
- Default branch: `development`
- Local clone path (once cloned): `workspace/dfn/`

## Ownership

- **Lead**: Abdelrahman Shahda (`Abdelrahman-Shahda`)
- **Active contributors**: mofarag-apes, Mahmoud3mmarr, AbdelrahmanMohamedEmam, OmarAhmedApes, ziadk432

## ApexYard docs

| Doc | Path |
|-----|------|
| Handover assessment | [`handover-assessment.md`](handover-assessment.md) |
| L1 context diagram | _missing — run `/c4` once cloned_ |
| L2 container diagram | [`architecture/container.md`](architecture/container.md) (stub, refine) |
| Roadmap | _to be created — `/roadmap`_ |
| Stakeholder updates | `updates/` (none yet) |

## Active roles

`tech-lead`, `backend-engineer`, `frontend-engineer`, `platform-engineer`, `sre`, `security-auditor`, `data-engineer`

## Tech stack at a glance

- **Backend**: NestJS 10 (CQRS, BullMQ, JWT/Passport, Swagger), TypeORM, Mongoose
- **Frontend**: React 18 + MUI v5 + Vite
- **Build**: Nx 20.2.2 (pnpm workspace)
- **Data**: PostgreSQL 18 + MongoDB 6 + Redis
- **Integrations**: AWS S3, Firebase Admin, Twilio, Nodemailer, Z3
- **Runtime**: Node 20 (Alpine in Docker)
- **CI/CD**: GitHub Actions on self-hosted runner → Docker build → SSH deploy to EC2
