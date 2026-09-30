# Development

## Getting Started

The team should first confirm the backend choice:

- Express + TypeScript, or
- FastAPI + Python

After that, set up the frontend, backend, database migrations, local environment, and tests.

The repository should include an `.env.example` containing the names of required environment variables with placeholder values only.

Real credentials must never be committed.

## Branches

Create a new branch from `main` for each change.

Use a short, informative branch name that describes the work.

Examples:

```text
feature/user-authentication
feature/task-dashboard
feature/location-permissions
fix/login-redirect
```

Keep branches focused and short-lived.

## Pull Requests

All changes to `main` should go through a pull request.

Before opening or merging a pull request:

- make sure the application builds
- run the relevant tests
- make sure no credentials or local environment files are included
- include a short description of the change
- include screenshots when useful for UI changes

Follow the repository's existing branch protection and review rules.

## Database Changes

Database schema changes should be made through migrations and committed to the repository.

Do not make production dependencies or assumptions. The shared Supabase project is for capstone development and demonstration.

## Environment Variables

The team is responsible for defining the environment variables the applications need.

Keep their names documented in `.env.example`.

When the hosted application is ready, provide GCP with the required environment-variable names and values so they can be added to Vercel.

Do not use privileged credentials unless they are actually required.

## CI/CD

GitHub Actions should test the frontend and backend and run the relevant build checks on pull requests. All required tests and build checks must pass before merging into `main`.

Vercel handles deployment through the existing GitHub integration. Changes merged into `main` trigger a Vercel build and, if successful, update the hosted application. A separate GitHub Actions deployment job is not needed.

Vercel's build does not replace application tests. Resolve any failed build or deployment before considering the change complete.

Keep the pipeline simple and documented.

## Documentation

Every web app feature must include a short `README.md` in its feature folder. Explain what the feature does, how its main pieces fit together, and any relevant setup or API dependencies. Update it when the feature changes.

Keep the root README and development instructions current as well.

A new engineer should be able to understand the project structure, configure the required environment variables, run the applications, and understand how deployment works without relying on undocumented steps.
