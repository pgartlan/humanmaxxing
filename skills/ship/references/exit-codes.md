# Exit codes and the contract

Every `bin/*.sh` script: **0** proceed · **10** deliberate SKIP of an optional action · **1** HALT · **2** usage or environment · **3** input unreadable or an external read failed · **4** wait or resolve, never proceed (WAIT: re-arm or wait for a result; a conflict or a suspicious finding: resolve it, then re-run) · **9** contract or skill-text mismatch · other codes **≥5** gate-specific. The last stdout line is always `SHIP-RESULT <script> PASS|SKIP|FAIL|WAIT <reason> [k=v …]`, preceded on a non-PASS by a `READ:` line pointing here. Route on the code and the result line. A missing result line means the harness bound killed the task: HALT, unverified, never green.

## Exit 9

Three results, one meaning: **the text you are following is not this worktree's current SKILL.md. Read it from disk and resume; state is kept.**

- `contract-mismatch want=N got=X` (any script): the pointer passed a contract number that is not `SKILL_CONTRACT` in `bin/ship-lib.sh`, or none. SKILL.md and `bin/` change together; a rebase can bring newer scripts (or a newer SKILL.md) mid-ship. Bumping the contract in the same change that alters a pointer's arguments or a script's exit codes makes every stale pointer fail loudly instead of running a new script with old arguments.
- `skill-changed` (any script but ship-init): `git hash-object` of this skill's SKILL.md differs from the blob `ship-init.sh` recorded. The script also writes `ship-skill-reload-pending`, so the ship-init re-run resumes (`reason=skill-changed`) instead of starting fresh, even though the same rebase moved the tree and made the step markers stale.
- `skill-dir-mismatch` (ship-init): the `--skill-dir` the harness reported is not this `bin/`'s skill directory. A session launched in one worktree and working in another loads the launch worktree's copy. Re-invoking the skill does not help; Read this worktree's file.

Per-script exception lists and measured bounds are deliberately not part of this skill: they are one repo's history.

## Background pointers

A pointer that says `run_in_background: true` also states a `timeout:` that exceeds the script's own bound. Every watch bounds itself and prints a `VERDICT:` (or `POST_MERGE_RESULT=`) line before its result line; the harness bound is a safety net. Re-arm on TIMEOUT; never end a turn narrating a wait with no bounded task armed in that turn.

## Per-script tables

Every script validates `ship.env` at start (exit 2 `ship-env-missing`, `ship-env-malformed`, `base-branch-unset`): a bad configuration never reaches a gate.

### ship-init
0 initialized (`START:` fresh or resume; resume reasons: ok markers, `skill-changed`, `pr-exists`, `sync-pending`) · 1 `sync-pending` (a rebase is in progress: nothing reset) · 2 `skill-dir-missing`, `skill-md-missing`, `bad-argument`, `unknown-argument`, `detached-head`, `write-failed` · 9 `skill-dir-mismatch`.
`--cleanup [--delete-remote-branch]`: 0 state removed · 1 `not-merged` (kept), `unsafe-path` · 3 `gh-unreadable` · 5 `remote-delete-failed` (state already gone).

### ship-status
0 · 2 `mode-missing` (ship-init never ran). `cfg <KEY>` prints one value with no result line (for `$(…)` substitution); exit 1 when the key is unset. `issues` prints every issue the branch targets on one line (empty when none) with no result line and works before ship-init; exit 3 when a source is unreadable or holds something other than positive integers.

### ship-run
`start`: 0 PASS · 1 FAIL (rc in the result line; log tail printed), `superseded` (a fresh init or newer start took over: result discarded) · 10 `already-running` · 3 `exit-write-failed` (the task ran but its result could not be recorded: not green) · 2 usage, `mode-missing`, `empty-command` (an empty command or `bash -c ''`: never launched, it would record green), `configured-task` (a `CHECK_TASKS` name given a typed command: run `start <name>` alone).
`required`: 0, the `CHECK_TASKS` names for this mode (none printed = unset). Any script: 2 `ship-env-malformed` when a `CHECK_TASKS` entry has an empty `CHECK_CMD_<name>`.
`collect [names] [--same-tree]`: 0 all green · 1 `red tasks=…`, `stale-tree tasks=…` (with --same-tree: ended on another check binding, the base moved while it ran, or its tree or base was not recorded; `binding format changed` = written by an older ship); on PASS with --same-tree a `collect: binding <value>` line · 4 `pending tasks=…` (no exit file: running, never started, or killed by the bound; a killed task never writes one, so re-run it) · 3 `unreadable`, `fingerprint-error`.
`reset`: 0.

### ship-sentinel
`fingerprint [--critical|--raw|--phase1]`: 0 · 3 `fingerprint-error` (the `SENTINEL-ERROR:` line says why; never a hash). `--phase1` is ship-internal (the check binding).
`untracked`: 0 `untracked relevant=N ignored=N` (`RELEVANT`/`IGNORED` lines; RELEVANT = near a change of this branch) · 3 `merge-base-unresolved` (fetch the base branch), `untracked-unreadable` (never "nothing untracked").
`attest review|e2e --note … --user …`: 0 · 2 `not-manual` (REVIEW_GATE is sentinel), `no-user-confirmation` (no `--user`: the agent never attests its own work; ask the user, class `waiver`), usage · 3.
`test-guard -- <TEST_GLOBS>`: 0 `test-guard-no-critical` or `test-guard` (a test path changed, tracked or untracked) · 1 `critical-without-tests` (the `NONEXEMPT` files are listed: add or update the covering tests) · 3 `test-guard-unreadable` (categorize could not compute: an unreadable globs file, merge-base or diff; never read as clean), `merge-base-unresolved`, `diff-unreadable` · 2 usage (no pathspec).
`categorize`: 0 `nonexempt n=N` · 10 `all-exempt` · 3 `merge-base-unresolved`, `diff-unreadable`, `filter-unbuildable` (CRITICAL_GLOBS_FILE named but unreadable, or a glob spelling the converter cannot honour: the offending line is printed), `filter-invalid`.
`verify review|e2e|gates`: 0 valid (`FRESH`, `EXEMPT` (in manual mode also a diff with no critical path), `CHAIN review=… reviewed=0|1 unreviewed_delta: …` for a fix push on top of an anchor review, `MANUAL-ATTESTED` in manual mode) · 1 invalid (`ABSENT`, `HASH-MISMATCH`, `STALE`, `STALE-EXEMPT`, `MALFORMED` (incl. a future epoch, a hash form over an empty critical set, or an attestation without the user's words), `CHAIN-UNANCHORED` (no review ever anchored the chain), `CHAIN-BROKEN` (another session's commits were integrated after the last review), `MANUAL-ABSENT`, `MANUAL-STALE`) · 3 `reader-error` (SENTINEL-ERROR, or the sentinel itself carries one: delete it and re-earn).
`verify phase1 [--committed]`: 0 · 1 `phase1-absent`, `phase1-malformed`, `phase1-tree-moved` (an edit, a base move, or `binding format changed`), `tree-not-committed`, `untracked-relevant` (--committed: untracked files near this branch's changes) · 3 `reader-error`, `merge-base-unresolved`, `untracked-unreadable`.
`write phase1`: 0 written (bound to the binding `collect` checked the tasks against) · 1 `tasks-not-green` (a recorded task is red, unrecorded or ran on another tree, or the tree changed while they were being checked; nothing written), `no-tasks` · 3 · 2 usage (no list is accepted), `write-failed`.
`invalidate phase1`: 0.

### ship-sync
`--integrate-remote`: 0 integrated (then re-run the plain sync; next push `--remote-integrated`) · 10 `already-integrated` · 4 · 5 · 3 · 2.
`--merge`: 0 merged (then re-run the plain sync) · 4 `merge-conflict` (resolve, commit, plain sync) · 5 `autostash-conflict` (your work is in the printed stash) / `unmerged-paths` · 3 `stash-failed`, `stash-unlocated`, `fetch-failed`.
Plain: 0 `synced rebased=0|1` · 4 `rebase-conflict` (rebase in progress; `CONFLICT_FILES:`) · 5 `autostash-conflict` (`UU:`, `AUTOSTASH:`) or `unmerged-paths` · 6 `head-not-on-tip` · 8 `merge-only-content` (`MERGE-ONLY:` lines; nothing rebased) · 1 `sync-pending`, `remote-branch-unseen`, `on-base-branch` · 3 `fetch-failed`, `base-unreadable`, `ls-remote-failed`, `merge-base-unresolved` · 2 `detached-head`.
`--continue`: 0 synced (plus `DROP-HINT` when an autostash entry exists) · 4 `still-conflicted`, `rebase-conflict` · 5 `autostash-conflict` · 1 `rebase-aborted` (record cleared) · 2 `nothing-to-continue`.
`audit`: 0 `no-merges` only · 4 any merge commit: `merges-present-audit-required` (audit every `BOTH_SIDES` file) or `audited-suspicious suspicious=N` (`IDENTICAL_TO_PARENTn` lines: another side dropped) · 3 `rev-list-failed`, `merge-base-unresolved`, `diff-unreadable` (never clean).
`scan-conflicts`: 0 clean · 1 `conflict-markers` (file:line lines) · 3 `scan-failed` (never clean).

### ship-push
0 pushed (`PUSHED:` line; `(leased)` when the recorded remote tip is not in HEAD's history) · 1 `detached-head`, `phase1-invalid` (always checked in `--local`), `push-failed git_rc=N` (any git failure other than a rejected lease: a hook or protection message included) · 2 usage (incl. `--kind fix|conflict|rebase` without `--review`) · 3 `no-lease-record` (rebased or rewritten with no usable record: re-run the sync, never a bare lease), `git-unreadable`, `merge-base-unresolved` (fetch the base branch, re-run), `untracked-unreadable` · 5 `lease-rejected` (the remote moved under you: fetch, inspect, re-run the sync; never force) · 6 `nothing-to-push` · 7 `dirty-tree`, `untracked-relevant` (untracked files near this branch's changes; checked in every mode before the Phase-1 gate; dirty-tree is reported first) · 2 usage, `mode-missing`.

### ship-watch
`ci`: 0 concluded (`VERDICT:` CI_GREEN (same non-empty green set on two polls) | CI_FAILED <names> (two reads; names saved for the census) | NO_CHECKS (also when only ignored contexts are registered) | REQUIRED_MISSING <names> (only when no PR-event run is active) | CONFLICTING | HEAD_MISMATCH <sha> | CLOSED_UNMERGED | MERGED; PASS means concluded, not green) · 4 WAIT `timeout` (re-arm) · 2 usage · 3 `gh-unreadable` (3 blind polls), `required-set-unreadable` (REQUIRED_CHECKS_CMD failed or printed nothing).
`queue`: 0 concluded (MERGED | CONFLICTING | CLOSED_UNMERGED | HEAD_MISMATCH | LABEL_MISSING | DEQUEUED | NEVER_QUEUED) · 4 · 2 · 3 (also `queue-state-unreadable`: QUEUE_STATE_CMD failed).
`postmerge`: 0 `POST_MERGE_RESULT=GREEN` (at least one push-event run, a run count stable across two polls, all concluded green) · 1 `FAILED <names>` · 124 `RUNNING` (re-arm) · 3 `ERROR` (gh unreadable, or no push-event runs registered for 15 min) · 10 `NOT-CONFIGURED` (POSTMERGE_CI=none).
`monitor [--until-advance]`: 0 `bound-elapsed` (re-arm while the guarded wait runs), `bound-elapsed-no-pr` (no PR yet: conflict detection was off, so it is not a "no conflict" reading) · 13 `base-advanced` (`--local`, or any mode with `--until-advance`; prints `MONITOR_BASELINE=`) · 11 `conflicting` · 12 `gh-blind` · 1 `already-running` · 3 `fetch-failed`. `monitor --stop`: 0 stopped · 10 nothing running.

### ship-gate
`body-check --file <body>`: 0 `body-check` (every started issue closed, or owned by a banner the reviewed plan backs) / `body-check-warned` (`WARN started-issue-not-closed`, `WARN banner-not-in-plan`: warnings, never a refusal; name them in the report) · 3 `body-unreadable`, `issues-unreadable` · 2 usage.
`branch --protected '<ERE>'`: 0 shippable · 1 `detached-head`, `protected-branch`, `nothing-to-ship` (a wrong-worktree signal; `git worktree list` printed) · 2 usage (an empty or unsubstituted ERE, an invalid ERE) · 3 `merge-base-unresolved` (fetch the base branch), `git-unreadable`.
`ci-skip-label`: 0 the label may go on (`--local`, Phase 1 valid for the committed tree) · 1 `offload-never`, `phase1-invalid` · 3 `phase1-unreadable`.
`flip --pr N [--check-only]`: 0 `flipped` / `flip-check` · 1 `pr-not-open`, `pr-not-this-branch`, `head-moved`, `tree-not-committed`, `head-not-on-remote`, `ci-not-green-at-head` (no CI_GREEN recorded for HEAD: re-watch), `phase1-absent` (a sync removed it: re-run 1c, write phase1), `e2e-invalid`, `conflicting`, `detached-head` · 2 usage (incl. a flip in `--local`) · 3 `gh-unreadable`, `remote-unreadable`, `git-unreadable`, `e2e-unreadable`, `ready-failed` (never a pass).
`enqueue --pr N [-- <MERGE_FLAGS>]`: 0 `enqueued` (label read back) / `merge-requested` · 10 `label-present` (never re-stamp; watch) · 1 `no-merge` (the user's pause: wait for "merge"), `draft`, `title-closing-keyword`, `commit-closing-keyword`, `gate-invalid`, and every flip refusal above (a started issue with no closing line only WARNs: `WARN started-issue-not-closed`, `WARN banner-not-in-plan`) · 2 usage, `admin-refused` · 3 `gh-unreadable`, `issues-unreadable`, `label-write-failed`, `label-not-applied`, `merge-failed`, `gates-unreadable`.

### ship-census
Census: 0 built (`FAILED_JOBS=N work=W reported=R`, blocks printed, `UNMAPPED_REQUIRED=` when a red required context has no failed job; file `ship-census.txt`) · 1 `no-watched-sha`, `census-empty` (only when no red required context was recorded) · 3 `incomplete` (a gh or jq read failed, a job log could not be fetched, a red context exists outside Actions, or REQUIRED_CHECKS_CMD failed; never push on it).
`--pre-push [--wait]`: 0 clear · 5 `new-required-red` · 4 WAIT `running` (fire `--wait` in the background; after the 20-minute `--wait` with `ceiling_passed=no|unknown`: re-arm, never push) · 6 `pre-push-wait-expired` (`ceiling_passed=yes`: the run is past PRE_PUSH_CEILING_MINUTES; push with a `pushed-before-<run>` note) · 3 `incomplete`, `no-census` · 1 `no-watched-sha`.
`--round-gate [--extend]`: 0 `fix-round=N` (counter written; `TELL_USER:` at the last allowed round) · 1 `round-cap` (STOP AND ASK) · 2 `extend-not-needed` · 3 `counter-corrupt`, `counter-unwritable`.
`--rerun --run <id>`: 0 fired · 1 `already-rerun` · 3 `gh-failed` · 2 usage.

### ship-log
0 always for an event (`ledger=written|gap`) · `summary` 0 · `mark <step>` 0 · 3 `fingerprint-error` · 2 usage.
