# Step 6 audits — main-thread, same turn as reviewer dispatch

Each audit is a **trigger** (decided from the changed-file list) and a **procedure** you run yourself with Read/Grep, synchronously, in the turn that dispatches the reviewers. They are deliberately not delegated: they catch what reviewers who focus on the diff window systematically miss, and they must be done before synthesis.

Every CRITICAL raised here needs a `VERIFIED:` line (file:line + snippet, docs URL + section, or script output), exactly like a reviewer's.

---

## Built-in 1 — Test quality (ALWAYS RUNS)

**1a — Inline stubs.** For each changed test file: does it import the function under test from source, or define its own copy inline? A test that tests its own arithmetic passes forever regardless of the real code. → WARNING with file:line.

**1b — Silent ignore (schema ↔ runtime).** For each new or changed field in any schema or type in the diff: find where runtime code reads it. Defined but never read → CRITICAL ("users can configure this and it does nothing"). Also the reverse: runtime stopped reading a field the schema still accepts. High-risk shapes: filter/condition/rule fields; cadence/interval/proration fields; new optional API body fields (does the service pass them through, does storage persist them); new migration columns no query selects.

**1c — Adversarial coverage, three rounds.**
- Round 1: categorize every test case in changed test files as HAPPY PATH or ADVERSARIAL (error, invalid input, auth rejection, empty/null/zero, partial failure, concurrency, boundary, malformed, duplicate, timeout, rollback). Over 80% happy-path → WARNING naming the missing categories.
- Round 2: for each changed non-test file, list the adversarial cases that SHOULD exist and don't — inputs that break assumptions, dependencies failing mid-operation, what a malicious tenant could do, two requests racing, exactly-at-threshold boundaries. Each → WARNING.
- Round 3: combinations and cascades — concurrent + partial failure + retry; step 2 failing after step 1 committed; cache stale after a failed write. SUGGESTION unless it involves data corruption or financial accuracy, then WARNING.

---

## Built-in 2 — Real E2E coverage (ALWAYS RUNS; feeds Step 10)

**Trigger:** any changed file matching `CRITICAL_GLOBS`. No match → record the exemption category and reason, done.

For each matching file: identify what it exposes (a route and its methods, a service function, a handler). Search your E2E directories for a spec that exercises it at a **real boundary** — real HTTP through the real handler, a real browser, a real datastore. Then:
- No real spec → CRITICAL.
- Spec covers only the happy path → CRITICAL (needs auth rejection, validation failure, error responses, read-back after mutation).
- A file under the E2E directory that mocks the datastore or imports the handler in-process → CRITICAL ("integration test mislabeled as E2E"). Mechanical check: grep E2E dirs for your mocking framework's mock calls and for direct client imports paired with a mock.
- Spec exists but has not been EXECUTED in-session against this tree with green output → CRITICAL. Existence is not execution.

Print a table, one line per file, then hand the result to Step 10.

---

## Your audits — extension point

<!-- ONBOARDING: add one block per repo-specific mandatory audit here. Each needs a trigger
     glob/signal and a procedure runnable with Read/Grep in one turn. Delete the worked
     examples that don't apply; keep the ones that do and localize their triggers. -->

### Worked example A — Wire-contract neighborhood

**Trigger:** the diff touches a schema that crosses a language or process boundary (a validation schema, a serialized POJO, an orchestration definition that names downstream functions, a handler's request/event type).

Three sub-checks, each from an incident where both sides' own tests passed:
1. **Name reconciliation** between an orchestration definition and the resource it invokes — a stray naming-convention prefix on one side failed a large fraction of workflow executions.
2. **Field-name drift** across every side of the boundary — one layer named a field differently than its consumer expected.
3. **Strictness vs producer annotations** — a strict schema rejected a field the producer always sent and required one it sometimes omitted.

For each changed schema: find its counterpart(s) on the other side of the boundary and diff field names, optionality, and strictness by hand. Mismatch → CRITICAL with both file:lines.

### Worked example B — Config existence

**Trigger:** the diff adds a newly-required runtime configuration value (an env var added to a required list, a new required secret).

For each deploy target your code runs in, check the value is actually provisioned — not just where you tested. Missing anywhere → CRITICAL. (We once shipped a newly-required variable to two of three targets; the third crashed at cold start and a whole QA session ran against 500s before anyone traced it.)

### Worked example C — Generated-artifact propagation

**Trigger:** the diff changes a query generator, compiler, template renderer, or config builder.

Is the output persisted or cached anywhere (a stored compiled query, a materialized config, a cached template)? If so, does the diff regenerate or invalidate the stored copies? Persisted output with no regeneration step → CRITICAL. (A full review plus an external gate both passed a generator fix that production never executed, because a stored, previously-compiled copy was what actually ran.)

### Worked example D — Test-helper payload validation

**Trigger:** the diff adds a reusable test helper that calls a real API.

Grep existing passing tests for at least one call to each API method the helper uses and compare payload shapes structurally (field names, types, single vs batch). Drift → CRITICAL. No working precedent for a method → the helper is untested surface, not tested surface; CRITICAL until executed end-to-end. (A review converged with zero dissent on a helper whose payload matched nothing real; it failed most of its scenarios at runtime.)

### Worked example E — Vertical integration for financial logic

**Trigger:** the diff touches money — pricing, rate calculation, invoicing, credits, currency.

Does the changed logic have end-to-end scenario coverage through the real pipeline, not unit tests with mocked stores? If a migration added a column, does the query that reads the row back actually SELECT it? (A column that exists in the database but is never selected is invisible to every code path that depends on it.) Gap → CRITICAL.
