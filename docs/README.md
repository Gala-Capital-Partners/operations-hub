# Operations Hub

Internal capstone prototype for a multi-brand restaurant operations platform.

## Tech Stack

| Component | Technology |
| --- | --- |
| Frontend | Next.js + TypeScript |
| Backend | Express + TypeScript **or** FastAPI + Python |
| Database | Supabase PostgreSQL |
| Authentication | Supabase Auth |
| Hosting | Vercel |
| CI/CD | GitHub Actions for tests/build checks; Vercel for automatic deployment |
| License | MIT |

The capstone team should confirm the backend choice before development begins.

## Architecture

```text
Browser
   |
   v
Next.js
   |
   v
Express / FastAPI API
   |
   v
Supabase PostgreSQL

Supabase Auth handles authentication.
```

Application data should go through the backend API rather than being queried directly from the frontend.

Tenant and permission boundaries must be enforced in the API and database.

## General Requirements

- Use synthetic data only.
- Do not use or connect to GCP production systems or production data.
- Keep secrets and credentials out of the repository.
- Store environment-specific values in environment variables.
- Track database schema changes through version-controlled migrations.
- Keep development setup and deployment reproducible and documented.
- Include a short `README.md` in each web app feature folder and keep it updated.
- Use the existing company-owned GitHub, Supabase, and Vercel projects.

## Scope

The initial work should focus on the core platform, identity/access, and tasks/checklists.

File uploads, object storage, photo evidence, attachments, and document-management features are not part of the current scope. They may be considered later if time allows and GCP approves them.
