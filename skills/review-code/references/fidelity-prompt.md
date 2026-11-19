# Requirement-fidelity prompt (Step 1b)

Dispatch on a deep-reasoning model, in the background. Fill every `{slot}` with a literal value.

```
You are performing a requirement-fidelity review: does the implementation address what was
actually asked for? You are not reviewing code quality — a separate pass does that.

## REQUIREMENTS SOURCE: {issue #N | plan <path> | synthetic from branch + commits}
## REQUIREMENTS (verbatim):
{requirements text}
## CHANGED FILES:
{changed-file list}
## KNOWN DEFERRALS (intentionally unbuilt — not gaps):
{KNOWN_DEFERRALS}
## COMPONENT ALIASES (easy to conflate — check the diff targets the one named):
{COMPONENT_ALIASES}

Read the changed files and determine:

1. COVERAGE — for each explicit requirement or acceptance criterion: ✅ implemented / ❌ missing.
2. SCOPE — beyond (gold-plating) or short (incomplete)? Classify every unrequested side-effect
   change: OUT-OF-SCOPE FIX (a real bug fixed in passing — fine), SCOPE CREEP (cleanup not
   asked for — note), UNINTENDED CHANGE (behavior the requirements didn't authorize — review).
2b. HUNK-SIZE ANOMALIES — a mechanical change (rename, path fix, constant) produces proportional
   hunks. A hunk removing N lines and adding M ≫ N (over 3×) for a stated mechanical change is
   the signature of accidental content restoration from a stale full-file overwrite, not
   authorship. Classify UNINTENDED CHANGE and describe the extra content. (We once shipped a
   "rename" hunk that quietly restored a hundred lines of a deleted policy section.)
3. INTENT vs LITERAL TEXT — requirements are written imprecisely. Solving the actual problem
   counts as ✅ even if the wording differs; solving a different problem is ❌ with what the code
   does vs what was asked.
4. BREAKING CHANGES — existing behavior changed without authorization?
5. COMPONENT FIDELITY — when a requirement names a boundary (A→B→C) or a specific component,
   confirm the diff targets it. Adjacent component changed instead → WRONG COMPONENT, CRITICAL
   even if the code is correct, because the named gap is still open. Only A of A→B→C → PARTIAL.
6. COVERAGE-CLAIM VERIFICATION — when the PR says a finding is "already covered by existing
   tests", open the cited test. If it mocks the exact boundary named and asserts nothing about
   what was sent to it → UNVERIFIED CLAIM. Mocked but with call-shape assertions → PARTIAL.
   A test calling real A which calls mock B never exercises A→B.
7. INFRA-BLOCKED vs WRONG COMPONENT — a boundary that genuinely can't be exercised without
   infrastructure the suite lacks is INFRA-BLOCKED, acceptable only if the PR says so and does
   not mark the finding closed. Never conflate the two.
8. CLOSE-OUT — does this diff fully complete every issue the work started from, so each closes at
   merge? Work left for "a later PR" or "release time" is CRITICAL unless the plan declares it
   with a hard blocker or the process tracks it as a post-merge obligation. The orchestrator's
   close-out check results are attached as context: {close-out results}.

If the source is synthetic, soften verdicts one tier — the source is weak.

## OUTPUT
COVERAGE: ✅/❌ per requirement
SCOPE ASSESSMENT · INTENT ALIGNMENT · BREAKING CHANGES
VERDICT: Fully addressed | Mostly addressed | Partially addressed | Misaligned
FINDINGS: for each gap — Requirement / Implementation / Gap / Type (WRONG COMPONENT, MOCKED
BOUNDARY, UNVERIFIED CLAIM, INFRA-BLOCKED unacknowledged, SCOPE CREEP, UNINTENDED CHANGE,
INTENTIONALLY DEFERRED) / Severity (CRITICAL: core missing, wrong component, or an unverified
coverage claim on a closed finding; WARNING: partial or side-effect).
```

**Reconciliation with the external second opinion (Step 1e):** same requirements and diff go to `SECOND_OPINION_CMD` with the same output format. Agree → consensus. Differ on severity → stricter. Conflict → present both, flagged, for the user.
