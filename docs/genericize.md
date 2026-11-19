# Genericizing an internal skill for release

Generic, publicly releasable versions of the Claude Code skills we use internally. Each skill under `skills/` is a self-contained directory (`SKILL.md` plus, where it earns one, a `references/` folder) that any team can drop into `.claude/skills/<name>/` and adapt via its Configuration block.

This README documents **how we make an internal skill generic**, so the process is repeatable for every future release. Follow it exactly; the failure mode it prevents is leaking internal details that are invisible to the author because they read as "just how the skill works."

---

## What makes a skill worth releasing

An internal skill mixes two kinds of content:

1. **Process patterns** — orchestration shapes, gates, sentinel/caching schemes, failure-triage policies, bounded-wait patterns, and the war stories that justify them. These transfer to any repo. **This is the product.**
2. **Repo facts** — our paths, commands, service names, thresholds, issue numbers, board IDs. These transfer to nobody and some of them are disclosures. **This is the residue.**

The genericization job is separating the two: keep every pattern, keep every lesson, strip every fact — and where a fact was load-bearing, replace it with a **configuration slot** or an **extension point** rather than deleting the capability.

---

## The six scrub categories

Classify every internal detail into one of these. Each has a fixed disposition.

### 1. Identity — SCRUB
Org/repo names, usernames, GitHub project/board GraphQL node and field IDs, cloud account hints, credential profile names, session-ID footers, internal URLs. Replace with placeholders (`{owner}/{repo}`) or drop entirely.

### 2. Architecture disclosure — SCRUB, replace with extension points
Anything that maps our production topology: service names and how they connect, the per-domain conditional-check matrix (which reveals what infrastructure exists), internal script names whose purpose describes a system component, path globs that describe the codebase layout. Replace the whole matrix with **one generic extension point** ("run your domain-conditional checks here") plus the transferable principle behind it (e.g. "locally run anything CI defers off the PR"). Path globs become configuration slots (`CRITICAL_GLOBS`).

### 3. Incident archaeology — KEEP THE LESSON, SCRUB THE CITATION
Internal issue/PR numbers, dates, PR titles, engineer-visible incident narratives. The lessons are the most valuable content in the skill — **never delete them**. Rewrite as anonymous war stories: "We once let 37 'not mine' test failures accumulate…" instead of "TICKET-1234: …". Test: a reader should learn the same lesson without being able to identify our tracker, repo, or timeline.

### 4. Internal process coupling — INLINE or DECLARE
Cross-references to our other skills by step number ("follow /pre-pr Step 0.7b"), internal hook filenames, custom CI labels and ruleset IDs, sentinel files written by skills we haven't released. Two options:
- **Inline** the referenced procedure if it's short (commit conventions, PR body skeleton).
- **Declare a companion dependency** if the coupling is essential (e.g. /ship checks a sentinel written by /review-code). Name the companion skill generically, describe the contract (what file, what format, what TTL), and give a manual fallback so the skill degrades gracefully standalone.

Never leave a dangling reference to a skill or hook the public reader doesn't have.

### 5. Sensitive gates — GENERALIZE THE PATTERN
A gate that names the specific file we're afraid of (a state-version marker, a pricing table) reveals our weak point. Keep the **pattern** (a configurable `PROTECTED_FILES` gate requiring explicit human approval), drop the specific filename and the description of what disaster it triggers in our system. Rule of thumb: the gate mechanism is releasable; the threat model instance is not.

### 6. Calibrated numbers — KEEP, MARK AS CALIBRATABLE
TTLs, poll bounds, test-count thresholds, heap sizes, worker counts. These are harmless to disclose but wrong for other repos. Keep them as **worked defaults** with an explicit "calibrate for your repo" note — a concrete number with provenance beats an empty placeholder.

---

## Structural transforms (every public skill gets these)

1. **Configuration block at the top.** Every value the skill references more than once — base branch, command slots (`TEST_CMD`, `LINT_CI_CMD`, …), glob sets, protected files, state directory — defined once, referenced everywhere. No scattered copies (drift between copies is the bug the internal skills already learned to avoid; keep that discipline public).
2. **Design Principles section.** Internal skills accumulate their "why" in inline comments tied to incidents. The public version hoists the why into a short principles section up front — that's the HumanMaxxing value-add over a bare procedure.
3. **Self-containment audit.** The skill must run for a reader who has *only* this skill's directory plus declared companions. A skill is `SKILL.md` (the procedure, read every run) plus an optional `references/` folder for material loaded only at the step that needs it: long agent prompts, a detection table another skill also reads, an audit catalog with an onboarding extension point, per-harness mechanics. Keep `SKILL.md` to the procedure so it stays cheap to load; never split the step order itself across files. Every referenced internal script either becomes an inline snippet, a config slot, or is cut.
4. **Fail-safe defaults survive.** Wherever the internal skill fails conservative (absent classification file → run the full gate; scoped test selection returns zero → escalate to full suite; hash uncomputable → HALT with an error token, never a degenerate value), the public version must preserve that direction. Genericizing must never soften a fail-closed design into fail-open.
5. **Portable bash stays; environment-specific bash goes.** Keep: PIPESTATUS capture, bounded monitor loops, sentinel read/write, merge-base diff patterns, `comm`-based overlap detection. Cut or slot: anything invoking our scripts, our npm run aliases (→ command slots), our cloud CLIs with our profiles.
6. **Length target: 25–40% of the internal skill.** Most of the delta is the conditional-check matrix and incident commentary. If the public version is >50% of the internal length, you probably kept repo facts; if it's <20%, you probably deleted lessons.

---

## The repeatable procedure

1. **Read the entire internal skill.** Not the first page — a partial read is how a scrub misses the identity leak on line 1400.
2. **Map the section structure** (grep headers) and decide per section: keep / genericize / collapse to extension point / cut.
3. **Write the Configuration block first** — collecting the slots forces you to find every repo fact.
4. **Rewrite section by section**, applying the six categories above. Keep the step architecture and gate ordering identical to the internal skill unless internal-only machinery makes a step meaningless.
5. **Anonymize every war story** — lesson intact, citation gone.
6. **Declare companions** and write the standalone fallback for each.
7. **Run the leak grep** (below) on the output. Zero hits required.
8. **Final read as an outsider:** does any sentence require knowledge of our repo, our infra, or our tracker to parse? Fix it.

### Leak grep — run on every public skill before release

Build a single `grep -niE` pattern from these identifier classes and run it on the output. **Keep the concrete pattern list itself private** — it names everything it protects, so publishing it would leak in one line what the whole process scrubs. (This README ships with the skills; your real list does not.)

- Your org, repo, and product names; usernames and emails
- Your infrastructure service names and internal component/codenames
- Cloud credential profile names and account identifiers
- Tracker artifact IDs (issue/PR number formats, board/field node IDs)
- Internal hook paths, custom CI label names, ruleset IDs
- Protected filenames from category 5

Illustrative shape (fabricated values):

```bash
grep -niE 'acmecorp|widget-api|jdoe|stream-processor-x|cloud-admin-profile|BOARD_NODE_|TICKET-[0-9]+|internal-ci-label' skills/<name>/SKILL.md
```

Extend your private list whenever a new internal identifier class appears. A hit is a release blocker, not a judgment call — if the term is genuinely generic in context, rewrite the sentence rather than allowlisting the term.

---

## Release checklist (per skill)

- [ ] Full internal skill read end-to-end
- [ ] Configuration block present; no repo facts outside it
- [ ] All six scrub categories applied
- [ ] Companions declared with contracts + standalone fallback
- [ ] Fail-safe directions preserved (audit every gate's absent/error branch)
- [ ] War stories anonymized, lessons intact
- [ ] Leak grep clean
- [ ] Outsider read-through done
