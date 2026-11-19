---
name: trim
description: Generates a /compact command tailored to this conversation, for the user to copy and paste: what to keep (decisions, reasoning, open questions, pending work) and what to drop (redundant tool output). Before a compact that leads to a ship or a commit of unreviewed code, it checks the companion ship skill's review sentinel and runs the review-code skill first.
user-invocable: true
allowed-tools: Bash(git rev-parse *), Bash(git status *), Bash(git diff *), Bash(test -f *), Bash(bash */.claude/skills/ship/bin/ship-sentinel.sh *), Read, Write, Glob, Skill
---

# /trim — a compact command written for this conversation

A bare `/compact` summarizes everything with the same weight. `/trim` reads the conversation and writes the instructions for that summary: which decisions, files and open questions must survive, and which tool output can go. The user pastes one line; the compaction keeps what matters.

---

## Configuration

```
COMPACT_DIR       — where the compact statement file is written (worked default $HOME/.cache/trim; any folder outside
                    the repository that only you can read. Never a shared temp folder such as /tmp: the file holds a
                    summary of the conversation)
SHIP_CONTEXT_LINE — optional: a context-window setting for a long ship run (for example `/autocompact 500000`),
                    printed under a ship-bound compact; empty = nothing printed. It is the first half of a pair: set it
                    together with the ship skill's CONTEXT_RESTORE_LINE (the line that puts the setting back when the
                    ship ends), and leave both empty or fill both
```

**Companions (optional).** A ship skill with a review gate, installed in the repository (its `bin/ship-sentinel.sh` reads the review sentinel or, with a manual gate, the attestation), and a review-code skill (it writes that sentinel). Without ship, the pre-flight gate is skipped and the reply says so; the compact is still generated. The `--contract=2` below is the ship contract this text was written against; a ship that moved on answers exit 9, which is handled as a failed check, never as a pass.

---

## Design principles

1. **A compact before a ship is where review gets skipped.** Compaction throws away the implementation context a reviewer needs, and the ship skill's review gate halts on a missing sentinel anyway. So review first, then compact: the user still gets the command, after the review rather than before it.
2. **The gate follows the code, not the word.** A compact to shed context, a docs-only or plan-only session, or a mid-work checkpoint with no unreviewed implementation needs no check.
3. **Never fail open.** A sentinel the reader could not read is not a fresh one.
4. **Only the user can run `/compact`.** It is a built-in command typed at the prompt. A scheduled prompt, a loop, or the Skill tool cannot run it: a scheduled `/compact` arrives as a plain message and nothing is compacted. Hand the line back; never try to run it.

---

## Pre-flight: review gate (first, before generating anything)

**Applies when** the compact is headed for a ship or a commit of code (the user said "trim, then ship", or the obvious next step is the ship skill or a commit; a commit's code reaches ship's gate later) and the branch carries code changes, committed or not (`git status --short`, and `git diff --stat <base>...HEAD` against the branch's base; when unsure, run the check). Whether that code was reviewed is the sentinel's answer, not a guess: run the check. Otherwise skip to Generate.

1. **Is ship installed?** Resolve the repository root first: `git rev-parse --show-toplevel`, and substitute the printed path for `<root>` below. Root not resolvable → handle as exit 3 below (never as "not installed"). Then `test -f <root>/.claude/skills/ship/bin/ship-sentinel.sh`. Absent → say "ship is not installed here; skipping the review-sentinel check" and go to Generate.
2. **Check the sentinel the way ship's review gate does:**
   ```bash
   bash <root>/.claude/skills/ship/bin/ship-sentinel.sh --contract=2 verify review
   ```
   - **Exit 0** (`REVIEW: FRESH`, `REVIEW: CHAIN …`, or `REVIEW: MANUAL-ATTESTED` when ship runs with a manual review gate) → go to Generate.
   - **Exit 1** (no valid review for this tree) → say in one line: "No fresh review: running review-code first (after a compaction the reviewer loses the implementation context, and ship would halt on it anyway). The compact follows." Then invoke the review-code skill with the Skill tool, with no question. If the Skill call fails because review-code is not installed, say that ship will halt at its review gate until a review is recorded, and continue. Then generate the compact. trim records nothing for ship's gate itself: with a manual review gate (the line starts `REVIEW: MANUAL-`), the attestation is the user's, made through ship.
   - **Exit 3, or any other exit** (the reader failed, ship is misconfigured, or exit 9: this skill's `--contract` no longer matches the installed ship) → report the printed line. Never treat it as fresh or as a skip: generate the compact with a note that ship will halt at the same check, and that it has to be fixed before shipping.
3. If the user was already told this change is too small to review, skip the review-code run, and say in the same message that ship's review gate still requires a sentinel or an attestation: skipping the review does not satisfy the gate.

This is not a refusal and not a question. The user gets their command either way.

---

## Generate

Read the whole conversation and write a compact statement tailored to it. Baseline rules, adapted to what was actually discussed:

- **Keep** every decision and the reasoning behind it (why, not only what), open questions, pending work and the next step, and the files, branches and identifiers that work touches.
- **Drop** tool output that is clearly redundant: large diffs, repeated status output, whole-file reads that were needed only for a moment.
- **Drop** what is truly stale: discussions fully resolved, decisions later reversed, context no longer relevant.
- **End with "Resume context":** the last two or three user inputs and replies, and whether the conversation stopped mid-task (keep working), mid-discussion (continue it), or at a natural stop (ask what's next).

**Be specific.** Name this conversation's topics, files and decisions: "keep the decision to move session checks into middleware, and the list of files changed for it", "keep the review findings for PR #123 (the missing deny patterns)". The more specific the statement, the better the compaction.

**Output.** Write the statement to `COMPACT_DIR/compact-<slug>-<rand5>.md`, where `<slug>` names the work in a few words and `<rand5>` is five random letters and digits (so two sessions never write the same file). Never paste the statement inline. Then print the pre-flight's notes, if any, and exactly one line for the user to copy, and nothing else (the one exception is `SHIP_CONTEXT_LINE`, below):

```
/compact @COMPACT_DIR/compact-<slug>-<rand5>.md
```

(with `COMPACT_DIR` replaced by its value, `$HOME` expanded to the absolute path: the prompt does not expand variables, and the Write tool takes an absolute path).

**When the compact is headed for a ship and `SHIP_CONTEXT_LINE` is set**, print that line two blank lines below the copy line, so the user can copy both, and nothing else. Why: a long ship run carries a large context on every turn, and a smaller window compacts it sooner. Only the user can set it: like `/compact`, it is a command typed at the prompt, and a settings-file write does not reach a running session. It stays set for later sessions too, which is why the ship skill ends with `CONTEXT_RESTORE_LINE`.

Such a setting is usually **per model**: it applies to the model the session is on when it is pasted. Read `SHIP_MODEL` from the ship skill's configuration (the Configuration block of `<root>/.claude/skills/ship/SKILL.md`, or its `ship.env`); when it is set and differs from the model this session runs on, say in the same message to switch to that model first and paste the line after the switch. Otherwise the setting lands on the wrong model, and the ship's restore line, which runs on the ship's model, leaves it there. **Use `@`, not `$(cat …)`:** the prompt is not a shell. `$(cat file)` reaches `/compact` as literal text, so the summarizer never sees the file and runs an unguided compact. An `@` mention is resolved by the prompt and attaches the file's contents.
