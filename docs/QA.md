# Operations Hub — QA Checklist

Owner: Student C — CI/CD, Infrastructure, and QA  
Scope: Current local development build  
Initial status: Not run. This document defines test cases; it does not certify that they pass.

## 1. Current Scope and Limitations

- The frontend uses Next.js; the backend uses Express and TypeScript.
- Tasks are connected to the backend API. Other screens primarily use mock data.
- Tasks are stored in memory. Browser refreshes should preserve changes while the backend stays running; restarting the backend restores seed data.
- Sign-in is a demo role/brand selection flow stored in localStorage. Real authentication, server-enforced authorization, and tenant isolation are not verified by this checklist.
- Database persistence and real authentication require separate acceptance tests when implemented.
- Recurrence and attachment fields do not by themselves prove that scheduling or file uploading is implemented.

References: [Frontend README](../client/README.md), [Backend README](../server/README.md), and [Development Guide](DEVELOPMENT.md).

## 2. Local Setup

Use Node.js 22 or later. Run all commands from the repository root.

```bash
node -v
npm ci
```

Start the backend in terminal 1:

```bash
npm run dev:server
```

Start the frontend in terminal 2:

```bash
npm run dev:client
```

- Frontend: http://localhost:3000
- Health endpoint: http://localhost:4000/api/health
- Tasks endpoint: http://localhost:4000/api/tasks
- Default frontend API URL: `http://localhost:4000/api`.
- No database credentials are needed for the current in-memory implementation.

Use a unique task label for each run, such as `QA-20261009-01-Restock napkins`. Use a date visible in the task screen's current filters. Record IDs returned by the API instead of assuming fixed IDs.

Perform mutations and resets only against a disposable local instance or a designated QA environment. Do not reset shared demonstration data. Stop local services with Ctrl+C after testing.

## 3. Recording Results

Use these statuses: **Not run**, **Pass**, **Fail**, **Blocked**, and **Not applicable**. Explain blocked or not-applicable cases. A failed case should reference a bug report and evidence.

Priority: **P0** = core flow or release blocker; **P1** = important regression coverage; **P2** = supplementary coverage.

## 4. Manual Frontend Checklist

| ID | Priority | Steps | Expected result |
| --- | --- | --- | --- |
| UI-01 | P0 | Open `/`; select a supported role and brand; enter the app. | Demo entry succeeds without a blank page or unhandled error. |
| UI-02 | P0 | Open `/tasks` with the backend running. Compare displayed tasks with the API, accounting for active filters. | Tasks load successfully and match the API. |
| UI-03 | P0 | As an editing-capable role, create a uniquely named task with label, category, and date. Refresh without restarting the backend. | One task is created and remains visible under matching filters after refresh. |
| UI-04 | P1 | Submit a task with a blank or whitespace-only label, or a missing required date. | Submission is blocked or rejected with useful feedback; no invalid task is created. |
| UI-05 | P0 | Edit the test task's label, category, and date. Refresh and adjust filters if necessary. | Changes persist in the running backend; unrelated fields remain unchanged. |
| UI-06 | P0 | Mark the task complete, refresh, then mark it incomplete and refresh. | Each state matches the API after refresh. |
| UI-07 | P0 | Delete the test task, completing any confirmation shown; refresh. | The task stays absent, and its API lookup returns 404. |
| UI-08 | P1 | Exercise the date, category, and status filters exposed by the UI; clear them again. | Displayed results match active filters; clearing filters restores the appropriate list. |
| UI-09 | P1 | Select a date/filter combination with no matching tasks. | A clear empty state appears without an error or stale tasks. |
| UI-10 | P1 | Open a create/edit dialog, change fields, then cancel or close it. | No changes are saved. Reopening does not unexpectedly reuse abandoned edits. |
| UI-11 | P1 | Stop the local backend and try loading, creating, updating, and deleting tasks. Restart and reload afterward. | Failures are visible; failed optimistic changes are rolled back or reconciled. The UI does not claim a failed save succeeded. |
| UI-12 | P1 | Check Dashboard, Knowledge, Training, and Compliance where the selected role permits access. | Screens render and supported controls work. Mock data is not reported as evidence of backend integration. |
| UI-13 | P1 | Compare task editing controls for a non-editing role and a manager/admin. Test Compliance access for allowed and disallowed roles, including direct navigation. | UI behavior matches documented role rules. This is a UI check, not proof of API authorization. |
| UI-14 | P1 | Clear the demo session and open a signed-in route directly. | The route guard returns the user to the demo sign-in flow. |
| UI-15 | P1 | Test at desktop width and approximately 390 px mobile width. Open navigation and the task dialog. | Essential content and actions remain visible and usable; no obstructive overflow occurs. |
| UI-16 | P2 | Navigate the main task flow using Tab, Shift+Tab, Enter, and Escape where supported. | Focus is visible, controls are reachable, and dialogs can be operated without a mouse. |
| UI-17 | P1 | Inspect browser console and network requests during the core flow. | No unexplained runtime errors or failed API requests; failures intentionally introduced in UI-11 are recorded separately. |

## 5. API Checklist

Base URL: `http://localhost:4000`. Use `Content-Type: application/json` for JSON request bodies. Each mutating test must own its fixtures and clean up afterward.

Example valid create body:

```json
{
  "label": "QA-20261009-01-Restock napkins",
  "cat": "Closing",
  "date": "2026-10-09"
}
```

| ID | Priority | Request / scenario | Expected result |
| --- | --- | --- | --- |
| API-01 | P0 | `GET /api/health` | 200 and `{ "status": "ok" }`. |
| API-02 | P0 | `POST /api/tasks` with a valid body. | 201; response contains a generated ID and the submitted fields. |
| API-03 | P0 | `GET /api/tasks/:id` for the created task. | 200; returned values match the created task. |
| API-04 | P0 | `PATCH /api/tasks/:id` with `{ "done": true }`. | 200; `done` is true and unrelated fields are preserved. |
| API-05 | P0 | `DELETE /api/tasks/:id`, then retrieve it. | DELETE returns 204 with no body; subsequent GET returns 404. |
| API-06 | P1 | Omit each required field (`label`, `cat`, `date`) in separate create requests. | 400 with validation details; no task is created. |
| API-07 | P1 | Submit blank/whitespace labels; test labels of 500 and 501 non-whitespace characters. | Blank labels and 501-character labels are rejected; 500 characters are accepted with otherwise valid input. |
| API-08 | P1 | Submit an unsupported category or a string instead of a boolean for `done`. | 400 with a useful validation error. |
| API-09 | P1 | Submit a malformed date or an invalid time such as `25:00`. | 400. Also probe impossible calendar dates and report acceptance as a validation concern rather than assuming strict calendar validation. |
| API-10 | P1 | Submit an unsupported recurrence, a recurrence day outside 0–6, or non-string attachment entries. | 400; invalid values are not stored. |
| API-11 | P1 | Send an empty PATCH body; separately send malformed JSON. | 400 with a structured error. |
| API-12 | P1 | GET/PATCH/DELETE with ID `abc`, `0`, or `-1`; use a valid PATCH body. | 400 because the ID must be a positive integer. |
| API-13 | P1 | GET/PATCH/DELETE a confirmed absent positive integer ID; use a valid PATCH body. | 404 with an error message. |
| API-14 | P1 | Create fixtures across dates, categories, and completion states; query `date`, `from`, `to`, `cat`, and `done`, separately and together. | Every result satisfies the filters. Verify range boundaries with fixtures before, on, and after each boundary. |
| API-15 | P1 | Query with an invalid category. | 400. Invalid date-query and `done` values need separately agreed behavior; record current handling without assuming rejection. |
| API-16 | P1 | Request an unknown API route. | 404 with a structured error object. |
| API-17 | P2 | On an isolated local instance, mutate tasks and call `POST /api/tasks/reset`. | 200 with restored seed tasks; mutations are removed. |
| API-18 | P1 | Refresh the frontend after a mutation, then separately restart the backend. | Refresh preserves the mutation; backend restart restores seed data as currently documented. |

Error responses should use `{ "error": { "message": "..." } }`, with `details` where validation supplies them. Avoid matching entire error strings unless exact wording is part of the agreed contract.

## 6. Automated Regression Plan

The following tests are proposed work, not existing test commands:

1. Add API integration tests for API-01 through API-16, starting with CRUD and invalid input. Use an isolated process or explicitly reset local store state between cases; avoid concurrent tests sharing mutable fixtures.
2. Add one browser end-to-end test: demo sign-in → Tasks → create → refresh → edit → complete → delete → verify absence.
3. Add an API-failure browser case to verify error feedback and optimistic-update recovery.
4. Run API and browser tests on pull requests alongside existing checks. Start both services and wait for readiness before browser tests; retain failure logs, screenshots, and traces.

Use unique fixture names and explicit cleanup. Do not assume seed dates equal today's date. Do not silently skip failed tests or label build success as functional-test success.

## 7. Existing Checks and Deployment Smoke Test

Run the existing checks from the repository root:

```bash
npm run check
```

This runs frontend lint, backend type checking, and workspace builds. It does not currently run the proposed functional tests.

For an approved preview/staging deployment:

- [ ] Record the deployment URL and source commit.
- [ ] Confirm the deployed API URL points to the intended backend, not localhost.
- [ ] Confirm the frontend origin is permitted by the backend's CORS configuration.
- [ ] Verify health, demo entry, and task loading.
- [ ] If the environment is designated for QA mutations, repeat the core task flow using disposable data.
- [ ] Record frontend and backend deployment status separately.

Vercel deployment is handled by the existing GitHub integration described in the development guide. A successful frontend deployment alone does not verify backend availability.

## 8. Test Run Record

Copy this section for each run. All checklist cases begin as **Not run**.

| Field | Value |
| --- | --- |
| Tester | |
| Date and time | |
| Commit / source snapshot | |
| Environment and URLs | |
| Browser / operating system | |
| Role and brand | |
| Fixture prefix | |
| Existing checks result | |

| Case ID | Status | Actual result / evidence | Bug reference |
| --- | --- | --- | --- |
| UI-01 | Not run | | |
| API-01 | Not run | | |

Add a row for every case executed or explicitly excluded. Summarize pass, fail, blocked, not-applicable, and not-run counts.

## 9. Bug Report Template

```text
Title:
Severity / user impact:
Environment and commit:
Related test case:
Preconditions and test data:
Steps to reproduce:
1.
2.
3.
Expected result:
Actual result:
Evidence (screenshot, request/response, or relevant log):
Reproduction frequency:
```

Remove credentials and personal information from evidence. Retest fixed bugs and rerun affected core flows.

## 10. Completion Criteria

- [ ] Existing lint, type checks, and builds pass.
- [ ] Every applicable P0 case passes.
- [ ] P1 failures and blocked cases are documented and reviewed before release.
- [ ] Core task changes are verified through both UI and API results.
- [ ] Test fixtures are cleaned up and reset operations are limited to isolated environments.
- [ ] The report identifies untested functionality and current demo limitations.
- [ ] No claim of real authentication, cross-brand isolation, or durable persistence is made without corresponding implementation and tests.
