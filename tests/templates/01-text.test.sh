#!/usr/bin/env bash
# Static checks on the templates and onboarding text: every details-file pointer in the CLAUDE.md template names a
# heading the details template has, and the rules the onboarding relies on are present.
. "$(dirname "$0")/../lib.sh"
cd "$T_ROOT" || exit 2
T=templates/CLAUDE.template.md
D=templates/claude-details.template.md
G=getting-started.claude.md
C=skills/checkpoint/SKILL.md
for f in "$T" "$D" "$G" "$C"; do check "$f exists" test -f "$f"; done

# GitHub-style heading slug: lowercase, drop everything but letters, digits, spaces, hyphens and underscores, spaces
# to hyphens. Lines inside fenced code blocks are not headings.
slugs() {
  awk '/^```/{f=!f; next} !f && /^#{1,6} /{sub(/^#+ /,""); print}' "$1" \
    | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9 _-]//g; s/ /-/g'
}
SLUGS="$(slugs "$D")"
has_heading() { printf '%s\n' "$SLUGS" | grep -qx -- "$1"; }
# Capture any character an anchor could contain, so a capital or an underscore is checked (and fails), not dropped.
ANCHORS="$(grep -o '<YOUR-DETAILS-FILE>#[A-Za-z0-9_.-]*' "$T" | sed 's/.*#//' | grep -vx 'anchor' | sort -u)"
check "the template has details-file pointers" test -n "$ANCHORS"
for a in $ANCHORS; do
  check "details template has a heading for #$a" has_heading "$a"
done
# The other direction: every top-level section of the details template (outside code fences, except its own
# Configuration block) is pointed to from the CLAUDE.md template, so no procedure is unreachable.
TOP="$(awk '/^```/{f=!f; next} !f && /^## /{sub(/^## /,""); print}' "$D" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9 _-]//g; s/ /-/g' | grep -v '^configuration')"
for h in $TOP; do
  check "CLAUDE.md template points to details section #$h" sh -c "printf '%s\n' \"\$1\" | grep -qx -- \"\$2\"" _ "$ANCHORS" "$h"
done
# The same check must fail for a heading that does not exist, and for a heading that only appears inside a code fence.
if has_heading 'no-such-heading-here'; then t_fail "a missing anchor is detected" "has_heading accepted a heading that does not exist"; else t_pass "a missing anchor is detected"; fi
FENCED="$(awk '/^```/{f=!f; next} f && /^#{1,6} [A-Za-z]/{sub(/^#+ /,""); print; exit}' "$D" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9 _-]//g; s/ /-/g')"
if [ -n "$FENCED" ] && has_heading "$FENCED"; then
  if grep -Eq "^#{1,6} " <(awk '/^```/{f=!f; next} !f' "$D" | grep -i -- "$(printf '%s' "$FENCED" | tr '-' ' ')"); then t_pass "a fenced comment is not a heading (also a real heading)"; else t_fail "a fenced comment is not a heading" "matched '$FENCED' from inside a code fence"; fi
else
  t_pass "a fenced comment is not a heading"
fi

# --- rules the onboarding and templates rely on ---------------------------------------------------------------------
check "template carries the pending-question rule" grep -q 'pending-questions' "$T"
check "details template has the Pending Questions section" grep -q '^## Pending Questions' "$D"
check "template model table has an Escalate when column" grep -q '| Escalate when |' "$T"
check "template forbids hand-rolled stashing; only ship's sync autostashes" sh -c 'grep -q "No hand-rolled \`git stash\` or \`pop\`: use a WIP commit" "$1" && grep -q "checkpoint never stashes (\`AUTOSTASH=no\`)" "$1"' _ "$T"
check "template: never push unless the user asks" grep -q '^\*\*Never push unless the user asks\.\*\*' "$T"
check "template: #1 RULE has a stack-specific examples slot, defined in Configuration" sh -c "[ \"\$(grep -c '<YOUR-FAIL-LOUDLY-EXAMPLES>' '$T')\" -ge 2 ] && ! grep -q '?? {}. or .|| \[\]\`\\.\$' '$T'"
check "template: the worktree setup step is conditional on POST_CREATE_CMD" sh -c "! grep -q 'Always run your package manager' '$T' && grep -q 'When the worktree skill.s \`POST_CREATE_CMD\`' '$T'"
check "template: CI/CD pre-commit line is stack-neutral" sh -c "! grep -q 'lint-staged hook' '$T'"
check "details template: no install-ledger wording, no non-YOUR fill-me placeholders" sh -c "! grep -qE 'adoption step|adoption ledger|<BASE_BRANCH>|<WORKTREE_ROOT>|<CLOUD_PROFILE_ENV>|<install command>' '$D'"
check "templates: slot placeholders are not wrapped in backticks" sh -c "! grep -qE '\`<YOUR-(HOOK-LIST|PROTECTED-FILES)>\`' '$T'"
check "template has the recommendation-mode slot" grep -q '<YOUR-RECOMMENDATION-MODE>' "$T"
for m in on-request always end; do
  check "template marks the recommendation-mode paragraph: $m" grep -qx "<!-- RECOMMENDATION-MODE: $m -->" "$T"
done
check "template has the class-guard threshold slot, used by the rule" sh -c "[ \"\$(grep -c '<YOUR-CLASS-GUARD-THRESHOLD>' '$T')\" -ge 2 ]"
check "onboarding asks the recommendation question" grep -q 'always recommend an option' "$G"
check "onboarding: the resume checks never search outside this project" grep -q 'on the rest of the machine or in the downloaded copy' "$G"
check "onboarding: the start skill is installed by a numbered step" grep -q '^5\. \*\*`review-plan`, then `start`\*\*' "$G"
check "onboarding: the harness and model question is its own question" grep -q '^- \*\*(e3) ' "$G"
check "onboarding: retro is installed by step 9, after the hooks step" sh -c 'grep -q "^8\. \*\*hooks\*\*" "$1" && grep -q "^9\. \*\*\`retro\`\*\*" "$1"' _ "$G"
check "onboarding: the plan names steps 1–9 wherever it counts them" sh -c '! grep -qE "1–8|eight artifact steps" "$1" && [ "$(grep -c "1–9" "$1")" -ge 3 ]' _ "$G"
check "onboarding: the ledger example has a retro row" grep -q '^| 9 | retro | pending | |$' "$G"
check "onboarding: the weekly calendar row names /retro" grep -q '^| Weekly | `/retro`' "$G"
check "onboarding: retro.env is a kept file on an update and filled from answers in hand" sh -c 'grep -q "(\`ship.env\`, \`worktree.env\`, \`retro.env\`);" "$1" && grep -q "^| \`retro.env\` (the \`retro\` skill, step 9) | Not asked" "$1"' _ "$G"
check "template: the threshold sits in the one sentence retro reads it from" grep -qF 'this fix included, reaches `<YOUR-CLASS-GUARD-THRESHOLD>`' "$T"
check "onboarding: retro's tracker comes from where issues live, not from whether gh can read issues" grep -q "TRACKER\` from (e)'s answer to where issues live" "$G"
check "onboarding: the threshold is filled in place, because retro reads its sentence" grep -q 'the `retro` skill reads the number from the rule' "$G"
STEP9="$(awk '/^9\. \*\*`retro`\*\*/{f=1} f && /^$/{exit} f' "$G")"
check "onboarding: step 9 was found" test -n "$STEP9"
check "onboarding: step 9 expects threshold and findings unavailable on a fresh install" sh -c 'printf "%s\n" "$1" | tr "\n" " " | grep -q "On a fresh install .threshold. and .findings. are expected"' _ "$STEP9"
check "onboarding: step 9 checks the threshold in the working-tree CLAUDE.md" sh -c 'printf "%s\n" "$1" | grep -qF "grep -c '"'"'this fix included, reaches \`[0-9][0-9]*\`'"'"' CLAUDE.md"' _ "$STEP9"
check "onboarding: step 9 routes exit 2 and FAIL through retro's own table" sh -c 'printf "%s\n" "$1" | grep -q "retro.s own routing table"' _ "$STEP9"
check "onboarding: the integration branch fills five places, retro.env among them" grep -q 'fills five places from the one answer: `BASE_BRANCH` in `worktree.env`, `BASE_BRANCH` in `ship.env`, `BASE_BRANCH` in `retro.env`' "$G"
check "onboarding: Phase 1 finds the commit-message style, in retro's two values" sh -c 'grep -q "^- \*\*Commit messages\*\* (feeds step 9 and the install" "$1" && grep -q "takes exactly these$" "$1" && grep -q "git log --no-merges -200" "$1" && ! grep -q "no → plain messages" "$1"' _ "$G"
check "onboarding: every question is tagged repo or you" sh -c "! grep -E '^- \*\*\([a-k][0-9]?\) ' \"\$1\" | grep -vqE '\[(repo|you)' " _ "$G"
check "onboarding: asks approval for a first pass" grep -q 'Approve doing a first pass' "$G"
check "onboarding: Phase 0 lists [repo] questions as one line each, asks none" sh -c 'grep -q "A \[repo\] question is listed, not asked" "$1" && grep -q "Questions:\*\* none in this message" "$1"' _ "$G"
check "onboarding: the commit-after-every-step note is at the top" sh -c 'head -20 "$1" | grep -q "It commits after every step" && grep -q "Then \*\*commit the step\*\*" "$1"' _ "$G"
check "onboarding: no time estimates anywhere" sh -c '! grep -qiE "human time|total time|time estimates? *(\||column)" "$1"' _ "$G"
check "template: a repository that declines every hook can still delete the hook paragraph" sh -c 'tr "\n" " " < "$1" | grep -q "No hooks installed yet: delete this paragraph"' _ "$T"
check "template: the session-start check runs hooks-check.sh, not ls of the hook list" sh -c 'grep -q "bash .claude/hooks/hooks-check.sh" "$1" && ! grep -q "ls <YOUR-HOOK-LIST>" "$1"' _ "$T"
check "template: 'Hooks: verified' only on exit 0" grep -q 'only when it exits 0' "$T"
check "template: the protected-file layer asks for approval, never a hard block" sh -c '! grep -q "hard-blocks" "$1" && grep -q "hold that edit until the human approves that one change" "$1"' _ "$T"
check "template: one protected list, .claude/protected-files.txt" grep -q '`.claude/protected-files.txt`' "$T"
check "onboarding: sections that do not apply are removed and listed" grep -q '^| Template sections that do not apply |' "$G"
check "onboarding: no tracker empties the whole issue group" grep -q 'the whole issue group is emptied' "$G"
check "onboarding: recommends the strongest model and checks it first, without stopping" sh -c 'head -25 "$1" | grep -q "Run it on your strongest model" && grep -q "That is a suggestion, not a stop" "$1"' _ "$G"
check "onboarding: a second dialog keeps the message's numbers" grep -q 'second dialog keeps those numbers' "$G"
check "onboarding: partial answers have a rule" grep -q '^\*\*Partial answers\.\*\*' "$G"
for ph in 0 1 2 3; do check "onboarding: Phase $ph has an explicit end" grep -q "Phase $ph ends\*\*" "$G"; done
check "template has a Project Rules section for carried-over rules" grep -q '^## Project Rules$' "$T"
check "onboarding: existing instructions are sorted duplicate / conflict / unique" grep -q '^- \*\*Existing instructions and agents\*\*' "$G"
check "onboarding: the user-level instruction file is read, never edited" grep -q 'user-level files are never edited' "$G"
check "onboarding: Step 1 is a merge when instruction files exist" grep -q 'this step is a merge, not a write' "$G"
check "onboarding: a user's own CLAUDE.md is not a partial install" grep -q 'are not a partial install' "$G"
check "bootstrap-agents: existing agents are mapped by role" grep -q '^\*\*1f — Existing agents, by role' skills/bootstrap-agents/SKILL.md
check "bootstrap-agents: no second agent for a covered role" grep -q 'never generate a second agent for a covered role' skills/bootstrap-agents/SKILL.md
check "bootstrap-claude-mds: folder files are checked against the root" grep -q '^\*\*1d-bis — Existing folder files against the root' skills/bootstrap-claude-mds/SKILL.md
check "onboarding: the lock is recorded after each step" grep -q 'hm-lock.sh record --from' "$G"
# The partial-install check names the template's marker lines verbatim; they must exist in the template, exactly.
for m in '## Configuration — fill these in for your repo' '# CLAUDE.md — a behavioral contract for your coding agent, not a style guide'; do
  check "onboarding names a marker line the template has: $m" sh -c 'grep -qxF "$2" "$1" && grep -qF "\`$2\`" "$3"' _ "$T" "$m" "$G"
done
check "onboarding: the download is checked for local edits" grep -qF 'git -C <download> status' "$G"
check "onboarding: a missing gh is handled" grep -q 'gh auth status' "$G"
check "onboarding: Phase 0 checks whether the remote is on GitHub before relying on gh" grep -q 'gh is not used: the remote is not on GitHub' "$G"
check "onboarding: Phase 0 asks through the dialog too" sh -c 'grep -q "Phase 0 is no exception" "$1" && grep -q "^\*\*Then ask through the dialog\*\*" "$1"' _ "$G"
check "onboarding: no internal jargon in dialog options" sh -c '! grep -q "Leave it UNVERIFIED" "$1" && grep -q "Not sure yet — decide later" "$1"' _ "$G"
check "onboarding: never ask what the agent can find out" grep -q 'Never ask what the agent can find out' "$G"
check "template: one tier map, no single cheap model" sh -c 'grep -q "<YOUR-MODEL-TIERS>" "$1" && ! grep -q "<YOUR-CHEAP-MODEL>" "$1"' _ "$T"
check "onboarding: the Phase 0 dialog has exactly its two decisions; (h) and (i) are stated defaults" sh -c 'grep -q "One dialog, two questions: decisions 1 and 2" "$1" && ! grep -q "One dialog, four questions" "$1" && ! grep -q "3\. \*\*Repeat bugs\*\*" "$1" && grep -q "^- \*\*Defaults taken\*\* (one line each, under Decisions): (h)" "$1"' _ "$G"
check "onboarding: feedback notes are asked in Phase 0 and never sent without approving the exact text" sh -c 'grep -q "2. \*\*Feedback notes\*\*" "$1" && grep -q "^## Feedback to the maintainers$" "$1" && grep -q "send --approved <the preview.s FINGERPRINT>" "$1" && grep -q "never mention a note in the chat" "$1"' _ "$G"
check "onboarding: feedback asks for an optional reply address and other feedback" sh -c 'grep -q "Would you like a reply?" "$1" && grep -q "Anything else you.d like to tell the maintainers" "$1"' _ "$G"
check "onboarding: feedback notes default to keeping notes (sending is a separate approval)" grep -q 'Default if you skip it: A (keeping notes sends nothing' "$G"
check "onboarding: a skipped decision 2 keeps notes everywhere it is read (no stale 'a skip is a no')" sh -c 'grep -q "is A, answered or taken as the default on a skip; only an explicit B" "$1" && grep -q "Present = decision 2 of Phase 0 is A (answered, or taken as the$" "$1" && grep -q "On A (answered or by default), create" "$1" && ! grep -q "a skipped decision is a no" "$1" && ! grep -q "decision 4 of Phase 0" "$1"' _ "$G"
check "onboarding: a yes to feedback notes is recorded by creating feedback.md, read on resume" sh -c 'grep -q "create \`feedback.md\` in the report folder right away" "$1" && grep -q "^\*\*Feedback notes, whatever the mode\.\*\*" "$1"' _ "$G"
# The feedback section alone, so each exit code is checked where it is routed.
FB="$(awk '/^## Feedback to the maintainers$/{f=1; next} f && /^## /{exit} f' "$G")"
fb_has() { printf '%s\n' "$FB" | grep -qF -- "$1"; }
check "onboarding: the feedback section was found" test -n "$FB"
check "onboarding: a declined offer is recorded and not offered again" fb_has 'create an empty `feedback.declined`'
check "onboarding: feedback is offered only with at least one note" fb_has 'Only when `feedback.md` has at least one numbered note'
check "onboarding: the feedback script runs from the project root in one command" sh -c 'grep -qF "cd <project root> && bash <download>/tools/hm-feedback.sh preview" "$1" && grep -qF "cd <project root> && bash <download>/tools/hm-feedback.sh send" "$1"' _ "$G"
for code in '- preview 0:' '- preview 2:' '- 3 (preview or send):' '- 4 (preview or send):' '- send 0:' '- send 2:' '- send 5:'; do
  check "onboarding: the feedback section routes exit code '$code'" fb_has "$code"
done
check "onboarding: the user's own comment is never reworded silently" fb_has 'never reword their words silently'
check "onboarding: the preview is the declared exception shown in full in the chat" fb_has 'The preview is the one thing in the onboarding shown in full in the chat'
check "onboarding: the plan's steps are shown in the message, in plain words" sh -c 'grep -q "the steps themselves are in the message" "$1" && grep -q "what the user gets, in plain words" "$1"' _ "$G"
check "onboarding: a 'decide later' answer is not asked again" grep -q 'is not asked again in this onboarding' "$G"
check "onboarding: plain words in questions and headers, including skills run in Phase 3" sh -c 'grep -q "Plain words everywhere the user reads" "$1" && grep -q "including the ones an installed skill asks" "$1"' _ "$G"
check "bootstrap-agents: an agent's model comes from its tier, never asked" grep -q 'so the model is never a question for the user' skills/bootstrap-agents/SKILL.md
TRY="$(awk '/^- \*\*A check command is tried once, read-only, before it is listed\.\*\*/{f=1} f && /^- \*\*Never ask/{exit} f' "$G")"
try_has() { printf '%s\n' "$TRY" | tr '\n' ' ' | tr -s ' ' | grep -qF -- "$1"; }
check "onboarding: the try-once rule was found" test -n "$TRY"
check "onboarding: a check is tried only inside the onboarding worktree, after Step 0" sh -c 'printf "%s" "$1" | tr "\n" " " | grep -q "only \*\*inside the onboarding worktree\*\*, *after Step 0"' _ "$TRY"
check "onboarding: a check is tried with toolchain downloads off" try_has 'GOTOOLCHAIN=local'
check "onboarding: a missing local service is reported apart from a real failure" try_has 'fails only because Docker is not running'
check "onboarding: a tried check becomes a follow-up, never a gate" try_has 'the command becomes a proposed follow-up, never a gate'
# --- step 8 (hooks): the text matches the pack in hooks/ -------------------------------------------------------------
# From step 8's heading to step 9's, so a sentence that moved into step 9 does not pass as step 8's.
S8="$(awk '/^8\. \*\*hooks\*\*/{f=1} f && /^9\. \*\*/{exit} f' "$G")"
s8_has() { printf '%s\n' "$S8" | grep -qF -- "$1"; }
check "onboarding: step 8 was found" test -n "$S8"
check "onboarding: no 'ships no hooks yet' text is left" sh -c '! grep -q "ships no hooks yet" "$1"' _ "$G"
for h in hooks/*.sh; do
  n="$(basename "$h" .sh)"
  case "$n" in hook-lib) continue ;; esac
  case "$n" in
    protected-file-guard) w='protected-file guard' ;; commit-check) w='commit check' ;; pending-question-reprint) w='pending-question reprint' ;; hooks-check) w='hooks-check.sh' ;; *) w="$n" ;;
  esac
  check "onboarding: step 8 names every script in hooks/: $n" s8_has "$w"
done
check "onboarding: step 8 plans before it writes, and applies only the approved hash" sh -c 'printf "%s\n" "$1" | grep -qF "hooks/bin/hooks-install.sh plan --hooks" && printf "%s\n" "$1" | grep -qF -- "--approved <the hash"' _ "$S8"
check "onboarding: step 8 has one decision, default A, with the CLAUDE.md lines in it" sh -c 'printf "%s\n" "$1" | grep -q "install exactly this, with the .CLAUDE.md. lines shown" && printf "%s\n" "$1" | grep -q "by hand later). Default if you skip it: A\." && ! printf "%s\n" "$1" | grep -q "needed before anything is wired"' _ "$S8"
check "onboarding: step 8's guard asks for approval and refuses only where nobody can be asked" sh -c 'printf "%s\n" "$1" | grep -q "asks you to approve any change to a protected file" && printf "%s\n" "$1" | grep -q "a permission mode that cannot ask you"' _ "$S8"
check "onboarding: step 8 verifies offline in this session (hooks-check runs the wired handler); the live check is a follow-up" sh -c 'printf "%s\n" "$1" | grep -qF "**Verify offline, in this session:** \`bash .claude/hooks/hooks-check.sh\` exits 0" && printf "%s\n" "$1" | tr "\n" " " | tr -s " " | grep -qF "runs the guard'"'"'s registered handler itself" && printf "%s\n" "$1" | tr "\n" " " | tr -s " " | grep -qF "is a follow-up for that first session"' _ "$S8"
check "onboarding: step 8 states the limits it could not verify" sh -c 'printf "%s\n" "$1" | tr -s "\n " "  " | grep -qF "$2"' _ "$S8" 'is not documented to reach you, so the guard refuses there instead' 
check "onboarding: step 8 says plainly what the shell guard cannot see, a script the agent writes included" sh -c 'printf "%s\n" "$1" | grep -q "What the shell guard can and cannot see" && printf "%s\n" "$1" | grep -q "a script the agent writes and then runs" && printf "%s\n" "$1" | grep -q "best-effort, not a guarantee"' _ "$S8"
check "onboarding: step 8 gives the recovery for a session where every call is blocked" sh -c 'printf "%s\n" "$1" | grep -qF "git checkout -- .claude/hooks" && printf "%s\n" "$1" | grep -q "disableAllHooks"' _ "$S8"
check "onboarding: step 8 says where each settings file is read from" sh -c 'printf "%s\n" "$1" | grep -q "only from the folder a session" && printf "%s\n" "$1" | grep -q "main$" && printf "%s\n" "$1" | grep -q "checkout.s root for any session"' _ "$S8"
check "onboarding: declining at step 8 leaves nothing behind" s8_has 'is deleted again, so nothing of the'
check "onboarding: the first install wires the guard and commit check in warn mode, never enforce" sh -c 'printf "%s\n" "$1" | grep -qF -- "plan --hooks protected-file-guard,commit-check,pending-question-reprint,review-nudge --settings <the file from (j)> --mode warn" && printf "%s\n" "$1" | tr -s "\n " "  " | grep -qF "always \`--mode warn\`, never \`--mode enforce\` or \`--git-pre-commit\` on the first install"' _ "$S8"
check "onboarding: warn mode never blocks, a crash or timeout included" sh -c 'printf "%s\n" "$1" | tr -s "\n " "  " | grep -qF "means \"prints a warning and lets the call through\"**, a hook that crashes or times out included"' _ "$S8"
check "onboarding: the follow-up switches the guards on with --mode enforce" s8_has 'pending-question-reprint,review-nudge --settings <the same file> --mode enforce'
check "onboarding: step 8 never holds the install's commits or merge, and needs no new session" sh -c 'printf "%s\n" "$1" | tr -s "\n " "  " | grep -qF "$2"' _ "$S8" "No hook here can stop the install's own commits or its merge, and nothing in this step needs a new session.**"
check "onboarding: the settings files are always protected, never a tickable option" sh -c 'grep -q "are not offered: the guard always protects them, listed or not" "$1" && ! grep -q "offered as candidates, ticked" "$1"' _ "$G"
check "onboarding: the first install fills COMMIT_CHECK_CMD with the candidate, marked warn mode" s8_has '`COMMIT_CHECK_CMD` gets the candidate (slot map), with a `#` line above it: "warn mode:'
check "onboarding: step 11 ends with switching the guards on" grep -q '^- \*\*Switch the guards on\*\* (always last, whenever step 8 installed hooks)' "$G"
check "onboarding: the git pre-commit is offered, never over an existing hook" sh -c 'printf "%s\n" "$1" | grep -q "pre-commit" && printf "%s\n" "$1" | grep -q "already exists"' _ "$S8"
check "onboarding: question (j) asks the commit check and where the wiring lives" sh -c 'grep -q "^- \*\*(j) Automatic guards\*\* \[repo, you\]" "$1" && grep -q "settings.local.json" "$1"' _ "$G"
check "onboarding: the slot map has the hook rows" sh -c 'grep -q "^| \`<YOUR-HOOK-LIST>\` |" "$1" && grep -q "^| \`COMMIT_CHECK_CMD\` (\`.claude/hooks/hooks.env\`) |" "$1" && grep -q "^| Hook wiring: " "$1"' _ "$G"
check "onboarding: Step 1 writes the one protected list" grep -q 'go to `.claude/protected-files.txt` in the same step' "$G"
check "onboarding: another harness gets the scripts described, not wired" grep -q '^- \*\*Another harness\*\* (not Claude Code)' "$G"
check "onboarding: an installed hook is a copy, updated through plan --update" sh -c 'grep -q "An installed hook is a copy too" "$1" && grep -qF "plan --update" "$1"' _ "$G"
check "onboarding: the settings file is never overwritten without a diff" grep -q 'the settings file step 8 wires the' "$G"
if command -v jq >/dev/null 2>&1; then
  for n in $(jq -r 'keys[]' hooks/settings.fragment.json | tr -d '\r'); do   # a Windows jq.exe writes CRLF
    check "the settings fragment names a script that exists: $n" test -f "hooks/$n.sh"
  done
fi
check "ship and review-code point at the one protected list" sh -c 'grep -q "see .claude/protected-files.txt" skills/ship/SKILL.md && grep -q "see .claude/protected-files.txt" skills/review-code/SKILL.md'
for f in skills/ship/SKILL.md skills/review-code/SKILL.md; do
  check "$f: the protected-list pointer also gates the guard's always-protected files" sh -c 'tr -s "\n " "  " < "$1" | grep -q "the gate checks the file.s globs PLUS the guard.s always-protected files: \`\*\*/.claude/settings.json\`, \`\*\*/.claude/settings.local.json\` (in any folder), \`.claude/hooks/\*\*\` and the list file itself"' _ "$f"
  check "$f: a missing or unreadable list file is a STOP, never none configured" sh -c 'tr -s "\n " "  " < "$1" | grep -q "The list file missing or unreadable → STOP, never \"none configured\""' _ "$f"
  check "$f: the list's globs follow the guard's spelling" sh -c 'tr -s "\n " "  " < "$1" | grep -qF "\`**/\` spans folders, \`*\` and \`?\` do not cross \`/\`"' _ "$f"
done
# --- step 8: first install vs update, the new session, and what the guard covers --------------------------------------
S8F="$(printf '%s\n' "$S8" | tr -s '\n ' '  ')"
s8f_has() { printf '%s\n' "$S8F" | grep -qF -- "$1"; }
check "onboarding: step 8 says no prompt appears during the install, apply included" s8f_has 'so no approval prompt appears during the install, `apply` included' 
check "onboarding: the guard asks at apply on an update or follow-up" sh -c 'tr -s "\n " "  " < "$1" | grep -qF "in a guarded session the guard asks before any \`hooks-install.sh … apply\`"' _ "$G"
check "onboarding: step 8 no longer promises a guard prompt at the first apply" sh -c '! printf "%s\n" "$1" | grep -q "second half of the user.s A\|The guard asks before this command too"' _ "$S8F"
check "onboarding: step 8 says the onboarding session itself is never guarded" s8f_has 'The session running the onboarding is never guarded' 
check "onboarding: no mid-install restart: no new session, no resume at sub-step 4, never failed for want of a session" sh -c '! printf "%s\n" "$1" | grep -qF "start a new session in the top folder of the onboarding worktree" && ! printf "%s\n" "$1" | grep -qF "applied; resume at sub-step 4" && printf "%s\n" "$1" | grep -qF "never \`failed\` for want of a new session"' _ "$S8F"
check "onboarding: the step is done (verified offline) on hooks-check exit 0" s8f_has 'Exit 0 → the step is `done (verified offline)`' 
check "onboarding: under B the primary copy is unguarded until the merge" s8f_has 'Under B, a session started in the primary copy is not guarded until the merge is pulled there' 
check "onboarding: the update path says the guard asks at apply, not that it cannot see the installer" sh -c 'tr -s "\n " "  " < "$1" | grep -qF "asks before any \`hooks-install.sh … apply\`, and that prompt is the second half of the approval" && ! grep -q "cannot see into" "$1"' _ "$G"
check "onboarding: the example message counts 4 handlers, both guards and the review nudge warn only" sh -c 'printf "%s\n" "$1" | grep -qF "adds 4 automatic handlers to \`.claude/settings.json\`: the protected-file guard and the commit check, both warn only" && printf "%s\n" "$1" | grep -qF "and the review nudge (warn only: it prints a reminder to run the code review)"' _ "$S8F"
# The review gate is ON (sentinel) whenever review-code is installed; manual is a fallback only, and then its "the user
# attests, never the agent" rule lives where the agent reads it at ship time (ship.env and CLAUDE.md).
check "step 6: sentinel whenever review-code is installed; manual only as the fallback" sh -c 'tr "\n" " " < "$1" | tr -s " " | grep -qF "\`REVIEW_GATE=sentinel\` when step 7 will install \`review-code\`" && tr "\n" " " < "$1" | tr -s " " | grep -qF "**Fallback only** (step 7 skipped, or the user kept their own review skill): \`REVIEW_GATE=manual\`"' _ "$G"
check "step 6: the fallback's manual-mode rule is written into ship.env and CLAUDE.md" sh -c 'tr "\n" " " < "$1" | tr -s " " | grep -qF "a \`#\` line above \`REVIEW_GATE=manual\` in \`ship.env\`, and one line under the Test Thoroughness Gate in \`CLAUDE.md\`, both saying \"manual mode: an attestation'"'"'s note quotes the user'"'"'s own confirmation, given in this session; the agent never attests its own review or tests\""' _ "$G"
check "slot map: REVIEW_GATE is sentinel with review-code, manual only as the fallback" grep -qF '| `REVIEW_GATE` (`ship`) | Not asked: `sentinel` whenever step 7 installs `review-code`' "$G"
check "no follow-up switches the review gate on: it is already on" sh -c '! grep -q "Switch ship.s review gate to review-code.s sentinels" "$1" && ! grep -qF "set \`REVIEW_GATE=sentinel\`" "$1" && ! grep -q "propose switching \`REVIEW_GATE\`" "$1"' _ "$G"
check "Phase 4: the first week's guard count is explained where the user reads it" grep -qF "The first week's guard count includes the install's own hook files: not a reason to change the repeat-bug number" "$G"
check "onboarding: a commit message or PR body naming a protected file is asked about" s8f_has 'a commit message or PR body that names a protected file is asked about (documented noise' 
check "onboarding: step 8 states where the settings files are protected" s8f_has 'a file edit of any `.claude/settings.json` or `.claude/settings.local.json` is asked about (this repository'"'"'s, another checkout'"'"'s or worktree'"'"'s, a subfolder'"'"'s, your own `~/.claude/`), and a shell command is asked about when it names them'
check "onboarding: the backstop for the shell guard's blind spots is ship and review-code's gates" s8f_has 'The protected-files gates before merge catch those: `ship` (Step 0-pre) and `review-code` (0b) check every changed file against the list and the guard'"'"'s always-protected files' 
check "onboarding: the guard's crash-blocks cell keeps the version condition" s8f_has 'a crash or a timeout blocks the call (Claude Code 2.1.295 or later'
check "onboarding: step 8 routes a settings file that is not valid JSON" s8f_has 'Exit 2 with `settings-unparseable`'
check "the exit routes step 8 names exist in the installer" sh -c 'for w in settings-unparseable no-jq "1 blocker" "4 the plan changed"; do grep -qF -- "$w" hooks/bin/hooks-install.sh || exit 1; done'
check "onboarding: step 8 says how to ignore a settings.local.json git does not ignore" s8f_has 'the file `git rev-parse --git-path info/exclude` names'
check "onboarding: one ledger wording for a declined step 8" sh -c '! grep -q "ledger says \"none installed\"" "$1" && grep -q "Every hook declined → they stay deleted and the ledger records \`skipped (declined at step 8)\`" "$1"' _ "$G"
check "onboarding: (j) asks only the wiring; the commit check's command is shown at step 8 and wired warn only" sh -c 'f="$(tr -s "\n " "  " < "$1")"; printf "%s\n" "$f" | grep -qF "Which check the commit check runs is not asked here" && printf "%s\n" "$f" | grep -qF "the first install wires it in warn mode only, so it reports and never refuses a commit" && ! printf "%s\n" "$f" | grep -qF "Command not answered"' _ "$G"
check "onboarding: Step 1 keeps the details file's hooks section (the pack arrives at step 8)" sh -c '! grep -q "(a tracker, hooks," "$1" && grep -qF "the details file'"'"'s \"Context Optimization Hooks\" section is never removed here" "$1"' _ "$G"
check "onboarding: Step 1 states the protected list's spelling rules and that the plan refuses a bad list" sh -c 'f="$(tr -s "\n " "  " < "$1")"; printf "%s\n" "$f" | grep -qF "no leading \`./\` or \`/\`, no trailing \`/\`, no \`{a,b}\`, no \`[..]\`, no \`!negation\`, no \`#\` after the glob on its line, and not all wildcards" && printf "%s\n" "$f" | grep -qF "step 8'"'"'s installer plan refuses such a list"' _ "$G"
# --- templates: what the pack installs and what hooks-check.sh checks --------------------------------------------------
check "details template: the guard and the commit check install warn-only; enforce is a later switch" sh -c 'tr -s "\n " "  " < "$1" | grep -qF "are installed in warn-only mode (\`--mode warn\`)" && tr -s "\n " "  " < "$1" | grep -qF "hooks-install.sh --mode enforce" && ! grep -q "Three guard hooks" "$1"' _ "$D"
check "details template: the reprint is a hook, not a guard; declined hooks are worded without install steps" sh -c 'tr -s "\n " "  " < "$1" | grep -qF "the pending-question reprint (a hook that" && tr -s "\n " "  " < "$1" | grep -qF "When the hooks were declined at install"' _ "$D"
check "template: hooks-check.sh checks the pack only; your own hooks are listed with ls" sh -c 'tr -s "\n " "  " < "$1" | grep -q "it checks the hooks pack.s scripts in <YOUR-HOOK-LIST>, nothing else); hooks of your own in that list are not checked by it, so also run .ls. on their paths"' _ "$T"
check "template: the pre-merge layer names the skills' protected-files gates" sh -c 'tr -s "\n " "  " < "$1" | grep -qF "the ship and review skills'"'"' protected-files gates"' _ "$T"
check "onboarding: drafts stay in the report folder until approved" grep -q 'A draft never goes to its target path before approval' "$G"
check "onboarding: each artifact is installed only at its own step" grep -q 'Each artifact is installed only at its own step' "$G"
check "bootstrap-agents: no brace globs in grep --include (grep does not expand them)" sh -c '! grep -q -- "--include=.\*\.{" "$1"' _ skills/bootstrap-agents/SKILL.md
check "onboarding: a slot's reason goes on its own line above, never after the value" grep -q 'on its own line, above' "$G"
check "onboarding: the repeat-bug question says why before it asks" grep -q 'Some bugs come back after they.re fixed' "$G"
check "onboarding: dialog options carry their letters" grep -q 'each label starting with its letter' "$G"
check "onboarding: findings are not folded into options" grep -q 'A finding is never folded into an option' "$G"
check "onboarding: the invariant question says what it is for" grep -q 'Every review, test and agent will check each change against it' "$G"
check "onboarding: Phase 0 writes its own report file" grep -q 'questions-report.md' "$G"
check "onboarding: the class-guard threshold is offered as 7, 5 or 3, default 7" sh -c 'tr "\n" " " < "$1" | tr -s " " | grep -qF "among **7** (the default: guards stay rare" && grep -q "\*\*5\*\*, or \*\*3\*\* (guards come sooner" "$1" && grep -q "Not answered → \`7\`" "$1" && ! grep -q "Not answered → \`3\`" "$1"' _ "$G"
# The threshold is a brake, not a trigger: below it a fix adds a class-level test and NO mechanical guard; a shared
# helper (a runtime chokepoint) is always allowed and is not a guard; a test is not a mechanical guard.
QI="$(awk '/^- \*\*\(i\) Repeat bugs/{f=1} f && /^- \*\*\(j\)/{exit} f' "$G" | tr '\n' ' ' | tr -s ' ')"
check "onboarding (i): the question was found" test -n "$QI"
check "onboarding (i): below the number a fix adds no mechanical guard, only its test" sh -c 'printf "%s" "$1" | grep -qF "below the number you pick, a fix adds no mechanical guard, only its test"' _ "$QI"
check "onboarding (i): every fix still sweeps and tests the class" sh -c 'printf "%s" "$1" | grep -qF "Every fix already sweeps the other places with the same bug and adds a test over all of them"' _ "$QI"
check "onboarding (i): a shared helper is always allowed; a test or helper is not offered as the guard" sh -c 'printf "%s" "$1" | grep -qF "routing the code through one shared helper is always allowed" && ! printf "%s" "$1" | grep -qF "(a lint rule, a test, or one shared helper"' _ "$QI"
check "onboarding (i): says why a guard is earned (it costs every later change)" sh -c 'printf "%s" "$1" | grep -qF "It costs time and false alarms on every change after it, so it is earned by repeats"' _ "$QI"
check "onboarding (i): the Default-taken line states the brake, not a trigger" sh -c 'tr "\n" " " < "$1" | tr -s " " | grep -qF "(i) \"No mechanical guard (lint rule, check script, hook) before the 7th fix of the same bug; every fix still gets its class-level test" && ! grep -q "A fix suggests a guard from the 3rd repeat" "$1"' _ "$G"
check "onboarding: the threshold slot is a floor, not a trigger" grep -qF 'It is a floor, not a trigger: below it a fix adds a class-level test and no mechanical guard.' "$G"
check "onboarding: retro's guard-growth keys are filled, budget a tripwire not a cap" sh -c 'grep -qF "\`GUARD_BUDGET_PER_MONTH=10\`, a tripwire the weekly report compares against, never a cap" "$1" && grep -qF "plus \`.claude/hooks/**\`)" "$1" && ! grep -qF "the guard-growth keys empty (off)" "$1"' _ "$G"
check "onboarding: step 9 says the first guard count includes the install's own hooks" sh -c 'printf "%s\n" "$1" | tr "\n" " " | tr -s " " | grep -qF "the first week'"'"'s guard count includes the install'"'"'s own hook files"' _ "$STEP9"
check "onboarding: the download is its own checkout before its status counts" grep -qF 'git -C <download> rev-parse --show-toplevel' "$G"
# Windows (Git Bash): git prints C:/... while the shell says /c/..., and the Microsoft Store python3 stub is found on
# the path but does not run.
check "onboarding: the download-path comparison normalizes both forms first" sh -c 'tr "\n" " " < "$1" | tr -s " " | grep -qF "normalize both first (\`cd <path> && pwd -P\`, or \`cygpath -u <path>\` where \`cygpath\` exists) and never compare the raw strings"' _ "$G"
check "onboarding: prerequisites are run, not looked up (python3 -c 1, jq -n 1)" sh -c 'tr "\n" " " < "$1" | tr -s " " | grep -qF "by running them (\`jq -n 1\`, \`python3 -c 1\`), never by looking the name up"' _ "$G"
check "onboarding: the Windows install line for the prerequisites" grep -qF 'install jqlang.jq GitHub.cli`' "$G"
check "onboarding: a reply that neither approves nor declines is handled" grep -q '^- \*\*Neither\*\*' "$G"
check "onboarding: no question is asked twice in the Phase 0 message" grep -q 'Nothing is asked twice' "$G"
check "onboarding: one layout for every message that waits for the user" grep -q '^## Every message that waits for the user$' "$G"
for part in '\*\*Where we are:\*\*' '\*\*Decisions\*\*' '\*\*Questions\*\*' '\*\*Full report:\*\*' '\*\*Next:\*\*'; do
  check "onboarding: the layout has $part" grep -q "^$part" "$G"
done
check "onboarding: a conflict offers keep yours / use the template's / combine / something else" sh -c 'grep -q "A) keep yours" "$1" && grep -q "B) use the template.s" "$1" && grep -q "C) combine" "$1" && grep -q "D) something else" "$1"' _ "$G"
check "onboarding: the layout is not asked; worktrees always" grep -q 'is never offered, and is set later by hand if ever' "$G"
check "onboarding: WORKTREE_LAYOUT is always siblings" grep -q '`WORKTREE_LAYOUT=siblings`, always' "$G"
check "onboarding: the invariant is asked after the first pass, with candidates" sh -c 'grep -q "asked at the end of Phase 1 as a decision, not in" "$1" && grep -q "The invariant (b) is not asked here" "$1"' _ "$G"
check "onboarding: decisions go through the harness's question dialog" grep -q 'AskUserQuestion' "$G"
check "onboarding: the report file repeats the decisions and questions" grep -q 'the file stands on its own' "$G"
check "onboarding: reports live in the git directory, never committed" grep -qF 'git rev-parse --git-common-dir)/humanmaxxing/' "$G"
check "onboarding: Phase 1 and Phase 2 use the layout" sh -c 'grep -q "both laid out per \"Every message that" "$1" && grep -q "^\*\*How the plan is shown:\*\*" "$1" && grep -q "rest of the layout per$" "$1"' _ "$G"
check "onboarding: one tag order only" sh -c '! grep -q "\[you, repo\]" "$1"' _ "$G"
PHASES="$(grep -c '^## Phase [0-9]' "$G")"
check "onboarding: the overview's phase count matches the phases ($PHASES)" sh -c '[ "$2" -eq 5 ] && grep -q "It runs five phases (0–4)" "$1"' _ "$G" "$PHASES"
# A word written twice in a row ("the answers answers fill it"), also across a line break. Code fences are skipped.
doubled() {
  awk 'BEGIN{prev=""} /^```/{f=!f; prev=""; next} f{next} /^[ \t]*$/ || /^#/{prev=""; next}
       { n=split(tolower($0), w, /[ \t]+/)
         for (i=1;i<=n;i++) { if (w[i]=="") continue; if (w[i]==prev && w[i] ~ /^[a-z]+$/) { print FILENAME":"NR": "w[i]; bad=1 } prev=w[i] } }
       END{exit bad?0:1}' "$1"
}
for f in "$G" "$T" "$D"; do
  if doubled "$f" >/dev/null; then OUT="$(doubled "$f")"; t_fail "no doubled word in $f"; else t_pass "no doubled word in $f"; fi
done
printf 'the answers\n   answers fill it\n' > "$T_TMP/dw.md"
if doubled "$T_TMP/dw.md" >/dev/null; then t_pass "the doubled-word check finds one across a line break"; else OUT=""; t_fail "the doubled-word check finds one across a line break"; fi
check "onboarding maps both new slots" sh -c "grep -q '| \`<YOUR-RECOMMENDATION-MODE>\` |' '$G' && grep -q '| \`<YOUR-CLASS-GUARD-THRESHOLD>\` |' '$G'"
check "details template: commit before a merge" grep -qi 'commit them first' "$D"
check "details template does not tell you to stash before a merge" sh -c "! grep -qi 'stash or commit first' '$D'"
check "onboarding: an unused command slot is left empty" grep -q 'A command slot you do not use is left empty' "$G"
check "onboarding: no rule fills unused slots with ':'" sh -c "! grep -q 'filled with \`:\`' '$G'"
check "onboarding: run the installed copy" grep -qi 'run the \*\*installed\*\* copy' "$G"
check "onboarding: review-plan is install-only until step 7" grep -qi 'install-only until step 7' "$G"
check "onboarding: updates merge, never copy over" grep -qi 'by \*\*merging\*\*, never by' "$G"
check "onboarding: the re-install keep-list names the detection table" grep -q 'references/detection-table.md' "$G"

# --- the first install never blocks itself; audit, follow-ups, merge ---------------------------------------------------
# Section text, flattened to one line with single spaces, so a check is not broken by where a line wraps.
flat() { tr '\n' ' ' | tr -s ' '; }
between() { awk -v a="$2" -v b="$3" 'index($0, a) == 1 {f=1} f && b != "" && index($0, b) == 1 && !(index($0, a) == 1) {exit} f' "$1" | flat; }
PRIN="$(between "$G" '## The first install never blocks itself' '## Every message that waits for the user')"
prin_has() { printf '%s' "$PRIN" | grep -qF -- "$1"; }
check "principle: its section was found" test -n "$PRIN"
check "principle: nothing the first install sets up blocks or delays its own commit and merge" prin_has 'Nothing the first install sets up may block or delay committing and merging the install itself.'
check "principle: checks become follow-ups, not gates" prin_has 'are recorded as **proposed follow-ups**, each with its evidence, and are not switched on during the install'
check "principle: a check that passed is still a follow-up, not on by default" prin_has 'is listed as "ready to switch on", and is still a follow-up, not on by default'
# The review gate is on from the install (sentinel), yet it cannot hold the install: the install never runs ship.
# Manual is a fallback only, and there the user attests, never the agent about its own work.
check "principle: the review gate is sentinel whenever review-code is installed, already on" prin_has '| `ship`'"'"'s review gate | `REVIEW_GATE=sentinel` whenever step 7 installs `review-code`: a pull request passes the review and end-to-end gates only on the sentinels a review-code run writes, never on the agent'"'"'s word.'
check "principle: the review gate cannot hold the install" prin_has 'It cannot hold the install, whose commits and merge do not go through `ship`'
check "principle: manual is a fallback, and the user attests, never the agent" prin_has 'Only when `review-code` is skipped or the user kept a review skill of their own: `REVIEW_GATE=manual`, where an attestation'"'"'s note quotes the user'"'"'s own in-session confirmation and the agent never attests its own review or tests | already on |'
check "install: the installed completion-review rule does not apply to the install itself" sh -c 'printf "%s" "$1" | grep -qF "applies to the first change after the merge, not to the install: step 10 is the install'"'"'s review"' _ "$PRIN"
check "step 11: default subagent model follow-up keeps explicit models winning" sh -c 'tr "\n" " " < "$1" | tr -s " " | grep -qF "A model named in the dispatch or in an agent'"'"'s own file still wins, so judgment work keeps its tier"' _ "$G"
check "step 11: audits use a read-only all-tenant role, per-transaction read-only through a pooler" sh -c 'tr "\n" " " < "$1" | tr -s " " | grep -qF "An audit run as the app'"'"'s own role sees one tenant'"'"'s rows and reports zeros that look real" && tr "\n" " " < "$1" | tr -s " " | grep -qF "made read-only per transaction, never with a session setting, which the pooler hands on to the next client"' _ "$G"
check "principle: the critical-path end-to-end gate is exempt until its follow-up, switched on by one command" sh -c 'printf "%s" "$1" | grep -qF "as \`# off: <glob>\` lines under a line saying why; comment lines are not read, so every diff is exempt" && grep -qF "one command, \`sed -i.bak '"'"'s/^# off: //'"'"'" "$2"' _ "$PRIN" "$G"
check "principle: the second opinion stays empty and its follow-up names the vendor" prin_has '| `SECOND_OPINION_CMD` (`review-plan`, `review-code`) | empty | a follow-up that names the vendor and says your diffs and plans are sent there |'
check "principle: the install's own commits and merge never run through checkpoint, ship or review-code" prin_has "The install's own commits and merge never run through \`checkpoint\`, \`ship\` or \`review-code\`."
check "principle: stated at the top of the file too" sh -c 'head -40 "$1" | grep -q "It never blocks its own merge"' _ "$G"
check "principle: step 7 installs the companion whose sentinels the gate reads; the install is not reviewed through it" sh -c 'tr "\n" " " < "$1" | tr -s " " | grep -qF "7. **\`review-code\`** — installs the code-review companion, whose sentinels \`ship\`'"'"'s review gate reads from the first pull request after the merge (\`REVIEW_GATE=sentinel\`, set at step 6). The install itself is never reviewed through it"' _ "$G"
check "principle: step 4's check slots stay empty with their follow-up above" grep -q '^   Its check slots are left empty during the install, each with its follow-up named in a comment$' "$G"
check "run it: checkpoint and review-code are not run on the install" grep -q '^   - \*\*`checkpoint` (step 4) and `review-code` (step 7) are not run\*\* on the install: no gate$' "$G"
check "run it: no 'the sentinel got written' check during the install" sh -c '! grep -q "sentinel got written" "$1"' _ "$G"

AUD="$(between "$G" '**10. Final audit.**' '**11. Follow-ups.**')"
aud_has() { printf '%s' "$AUD" | grep -qF -- "$1"; }
check "audit: its section was found" test -n "$AUD"
check "audit: a fresh subagent with no onboarding context" aud_has 'Never the conversation, the reports, the user'"'"'s answers or any conclusion of the onboarding'
check "audit: read-only" aud_has 'with read-only tools only'
check "audit: checks files the repository guards" aud_has 'Files the repository itself guards'
check "audit: checks commands the repository warns against" aud_has 'the repository'"'"'s own scripts or docs warn against'
check "audit: checks CLAUDE.md rules against code and documented decisions" aud_has 'contradict the code or a documented team decision'
check "audit: checks UNVERIFIED settings the repository could settle" aud_has '`UNVERIFIED` settings the repository could settle'
check "audit: checks installed files that conflict with each other" aud_has 'Installed files that conflict with each other'
check "audit: every finding carries evidence" aud_has 'each with its evidence'
check "audit: an install-fix defaults to fix now, grouped; gaps and enforcement are follow-ups" sh -c 'printf "%s" "$1" | grep -qF "**install-fix** only for a plain error in the install itself" && printf "%s" "$1" | grep -qF "gaps and for anything that would add enforcement (the default)" && printf "%s" "$1" | grep -qF "All install-fixes are one decision: **Fix these N now?**" && printf "%s" "$1" | grep -qF "Default if you skip it: A (they are errors in the install" && ! printf "%s" "$1" | grep -qF "Default if you skip it: B."' _ "$AUD"
check "audit: runs just before the merge decision" aud_has 'It runs just before the merge decision'
check "audit: a fix that would switch on a check or gate is always a follow-up" aud_has '**is a follow-up, whatever class the audit gave it**'

FUP="$(between "$G" '**11. Follow-ups.**' '**12. Merge.**')"
fup_has() { printf '%s' "$FUP" | grep -qF -- "$1"; }
check "follow-ups: its section was found" test -n "$FUP"
check "follow-ups: filed only with approval, one gh issue each" sh -c 'printf "%s" "$1" | grep -qF "no ticket is filed without the user'"'"'s approval" && printf "%s" "$1" | grep -qF "Each approved item is one \`gh issue create\`"' _ "$FUP"
check "follow-ups: a skip files nothing" fup_has 'C) file none: write them to the follow-ups file instead. Default if you skip it: C.'
check "follow-ups: with no tracker they are written to a file in the docs" fup_has '`<docs root>/humanmaxxing-follow-ups.md`'
check "follow-ups: each carries its evidence" fup_has 'its evidence'

MRG="$(between "$G" '**12. Merge.**' '**`maxx-start`**')"
mrg_has() { printf '%s' "$MRG" | grep -qF -- "$1"; }
check "merge: its section was found" test -n "$MRG"
check "merge: A merges: a fast-forward where nothing protects the branch, else a pull request merged the normal way" sh -c 'printf "%s" "$1" | grep -qF "A) **merge it** — where nothing protects the integration branch and the host needs no pull request: push it as a fast-forward" && printf "%s" "$1" | grep -qF "open a pull request" && printf "%s" "$1" | grep -qF "merge it the normal way once it may merge"' _ "$MRG"
check "merge: B keeps the branch for a pull request" mrg_has 'B) **keep the branch**'
check "merge: a skip merges (default A); C is not yet" sh -c 'printf "%s" "$1" | grep -qF "C) **not yet**" && printf "%s" "$1" | grep -qF "Default if you skip it: A: **a skip merges**" && ! printf "%s" "$1" | grep -qF "Default if you skip it: C."' _ "$MRG"
check "merge: a host with no pull requests is covered" mrg_has 'a host with no pull requests: push only' 
check "merge: no remote is covered" mrg_has 'With no remote, A merges locally'
check "merge: never bypasses branch protection or required checks" mrg_has 'Never an admin merge, a force push or a skipped required check, unless the user says so for this one merge' 
check "merge: never force-pushes; the push runs with the repository's git hooks off" sh -c 'printf "%s" "$1" | grep -qF "never \`--force\`" && printf "%s" "$1" | grep -qF "git -c core.hooksPath=<report folder>/no-hooks push"' _ "$MRG"
check "merge: an install left uncommitted is committed first" mrg_has 'A and B first commit the install as one commit'
check "ledger: has merge and maxx-start rows" sh -c 'grep -q "^| 12 | merge | pending | |$" "$1" && grep -q "^| — | maxx-start | pending | installed only after the merge |$" "$1"' _ "$G"
check "ledger: has audit and follow-ups rows" sh -c 'grep -q "^| 10 | audit | pending | |$" "$1" && grep -q "^| 11 | follow-ups | pending | |$" "$1"' _ "$G"
check "ledger: lives in the report folder, never committed, so no pending row reaches the main branch" sh -c 'grep -q "no \`pending\` row can reach the main branch" "$1" && ! grep -q "write this at the top of the onboarding worktree" "$1"' _ "$G"
check "ledger: Phase 3 can end with the merge done (the default), kept or not yet" grep -q 'the merge is `done` (the default), `branch kept` or `not$' "$G"
check "resume: a ledger with only the merge open is not a resume" grep -q 'whose only open rows are the merge (`not yet` or `branch kept`)' "$G"
check "plan: the close-out steps are in the plan" sh -c 'grep -q "^10\. \*\*Final audit\*\*" "$1" && grep -q "^11\. \*\*Follow-ups\*\*" "$1" && grep -q "^12\. \*\*Merge\*\*" "$1"' _ "$G"

# --- first pass -------------------------------------------------------------------------------------------------------
check "first pass: reads guards, check scripts, procedure docs and decision comments" sh -c 'grep -q "^- \*\*Guards, checks and decisions the repository already has\*\*" "$1" && grep -q "decision comments at the top of code files" "$1"' _ "$G"
check "first pass: every install path is checked for ignore rules, with the folder/* form, default un-ignore" sh -c 'f="$(tr -s "\n " "  " < "$1")"; printf "%s\n" "$f" | grep -qF "\`.claude/protected-files.txt\`, \`.claude/humanmaxxing.lock\`, \`.claude/hooks/hooks.env\`, \`.claude/settings.json\`" && printf "%s\n" "$f" | grep -qF "its line becomes \`<folder>/*\` first" && printf "%s\n" "$f" | grep -qF "machine, and the plan says nothing it installs is shared. Default if you skip it: A."' _ "$G"
check "first pass: the remote URL is checked before any gh command" grep -q 'Check the remote.s URL$' "$G"
check "first pass: GitHub evidence counts only from this user's own commits or remotes" sh -c 'f="$(tr -s "\n " "  " < "$1")"; printf "%s\n" "$f" | grep -qF "GitHub evidence of **this user'"'"'s own**" && printf "%s\n" "$f" | grep -qF "An upstream'"'"'s pull-request numbers, \`.github/\` folder or merge-queue config in inherited history are not evidence" && ! grep -q "evidence counts as \"on GitHub\"" "$1"' _ "$G"
check "first pass: no 'read-only gh queries' promise where gh is not used" sh -c 'grep -q "The bracketed part is said only when \`gh\` will be used" "$1" && grep -q "only when Phase 0 found the remote on GitHub" "$1"' _ "$G"
check "first pass: an instruction file that forbids commits is a Phase 1 conflict" grep -q 'Any instruction file in the repository, or loaded in this session, that forbids commits' "$G"
check "first pass: the AGENTS.md shared-source choice is in Phase 1, with its conflicting lines edited" sh -c 'grep -q "^  - \*\*An \`AGENTS.md\` that other harnesses read:\*\*" "$1" && grep -q "edits that line in \`AGENTS.md\` to the resolved rule" "$1" && ! grep -q "offer to keep it as the shared source" "$1"' _ "$G"
check "first pass: the dominant branch-name pattern beats the template default" grep -q 'the template.s example is only the fallback when no pattern dominates' "$G"
check "first pass: the template's opinionated defaults are checked against evidence" grep -q '^| The template.s opinionated defaults | Not filled silently\.' "$G"
check "first pass: a remote test dispatcher is detected; no whole-suite command in an allowlist" sh -c 'grep -q "remote test dispatcher\*\*" "$1" && grep -q "no whole-suite or$" "$1"' _ "$G"
check "first pass: manifests at any depth" grep -q "git ls-files '\*package.json'" "$G"
check "first pass: existing skills are surveyed and named in the verdict line" sh -c 'grep -q "List each existing skill too" "$1" && grep -q "the skills \`<names>\`" "$1"' _ "$G"
check "later steps: steps 2 and 3 can reopen earlier lists before the audit" grep -q '^\*\*Later steps can reopen earlier lists\.\*\*' "$G"

# --- the rest ---------------------------------------------------------------------------------------------------------
check "decisions with no default still get guidance when recommendations are off" grep -q 'decision with no default still gets guidance, whatever (h) says' "$G"
check "step 2 saves the review rows; step 7 pastes them and checks every agent exists" sh -c 'grep -q "Save the rows it emits, as a ready-to-paste block, in \`step2-report.md\`" "$1" && grep -q "checks that every agent the$" "$1"' _ "$G"
check "a none tracker: start takes a task in words" grep -q 'With no tracker$' "$G"
check "step 0: the plan names the dependency install, what it reaches, and that it can be skipped" sh -c 'f="$(tr -s "\n " "  " < "$1")"; printf "%s\n" "$f" | grep -qF "what it reaches (the network, caches in the user'"'"'s home folder" && printf "%s\n" "$f" | grep -qF "B) approve, without the dependency install"' _ "$G"
check "step 0: an empty or skipped install has no status file to wait for; the create runs with hooks setup off" sh -c 'f="$(tr -s "\n " "  " < "$1")"; printf "%s\n" "$f" | grep -qF "\`setup=none\` (no command) or \`setup=skipped\` on the result line → nothing ran and there is no exit-status file to wait for" && printf "%s\n" "$f" | grep -qF -- "--background --no-hook-setup [--no-install] <branch>"' _ "$G"
check "plan approval defaults to not yet" grep -q 'Default if you skip it: D) not yet\.' "$G"
check "plugins: one multi-select question" grep -q '`multiSelect`' "$G"
check "plugins: the list is filtered to this project" grep -q 'claude plugin list --json' "$G"
check "editor: never opened in a session with no display" grep -q 'Never open one in a session with no display' "$G"
check "step 6 is skipped when there is no GitHub" grep -q '→ step 6 is `skipped` with that reason' "$G"
check "Phase 4: the calendar is shown only" grep -q 'The calendar is \*\*shown only\*\*' "$G"
check "the previous step's done line folds into the next message" grep -q 'it becomes the first half of the next message' "$G"
check "secrets and auth findings always get their own decision" grep -q 'A finding about secrets or sign-in' "$G"
check "the template's Configuration block is replaced as a whole, never search-and-replaced" grep -q 'Never one search-and-replace over the whole file' "$G"
check "feedback: each message numbers its items from 1" sh -c 'printf "%s\n" "$1" | grep -q "Each message numbers its own items from 1" && ! printf "%s\n" "$1" | grep -q "3\. \*\*Send\*\*" && ! printf "%s\n" "$1" | grep -q "ask decision 1 once more"' _ "$FB"
check "feedback: a note after a decline is kept and offered at the next stop" sh -c 'printf "%s\n" "$1" | tr "\n" " " | tr -s " " | grep -qF "It does not reopen the offer there and then; it is offered at the next of the points above"' _ "$FB"
check "template: never bypass required checks or branch protection unless the user says so for that instance" grep -q '^\*\*Never bypass required checks or branch protection\*\*' "$T"
check "template: the agent asks before a protected edit; the guard is warn-only until enforce" sh -c 'grep -q "you ask the user before every edit to a protected file" "$1" && grep -q "installed warn-only (\`--mode warn\`)" "$1" && ! grep -q "hard-blocks any agent edit" "$1"' _ "$T"

# --- checkpoint: the push lease and the unused-slot rule ----------------------------------------------------------
check "checkpoint: the push pins its lease" grep -q 'force-with-lease="refs/heads/' "$C"
check "checkpoint: no bare --force-with-lease push" sh -c "! grep -qE 'git push --force-with-lease( |\`)' '$C'"
check "checkpoint: the lease is checked against local history" grep -q 'merge-base --is-ancestor' "$C"
check "checkpoint: an autostash conflict is checked after the rebase" grep -q 'An autostash conflict still exits 0' "$C"
check "checkpoint: an empty slot is not configured, never a pass" grep -q 'not configured' "$C"
check "checkpoint: secret scan default is not the ignored-files scan" sh -c "! grep -qE 'SECRET_SCAN_CMD +— e\\.g\\. gitleaks detect --source \\. --no-git' '$C'"
# --- round 5: no mid-install restart, hooks off for the install's commits, merge by default, fewer decisions ----------
check "principle: the install's commits and push run with the repository's git hooks off, never --no-verify elsewhere" sh -c 'printf "%s" "$1" | grep -qF "Every one runs as \`git -c core.hooksPath=<report folder>/no-hooks commit …\`" && printf "%s" "$1" | grep -qF "every later commit runs the hooks as before, \`--no-verify\` is never used" && ! printf "%s" "$1" | grep -qF "never bypass it (\`--no-verify\`)"' _ "$PRIN"
check "top note: skipping the merge decision merges, never through a bypass" sh -c 'head -25 "$1" | tr "\n" " " | tr -s " " | grep -qF "whether to merge, and skipping it merges (through a pull request where the branch is protected or > the host needs one; never a bypass)"' _ "$G"
check "decisions: every decision has a default; 'none' only for the invariant, the first pass, Step 1's drafts and the roster" sh -c 'tr -s "\n " "  " < "$1" | grep -qF "\"none: needed before …\" is allowed only for the invariant (b), the read-only first pass, and approving Step 1'"'"'s drafts and step 2'"'"'s roster"' _ "$G"
check "decisions: exactly two 'Default if you skip it: none' lines (first pass, Step 1's drafts) plus the invariant" sh -c '[ "$(grep -c "Default if you skip it: none" "$1")" -eq 2 ] && grep -q "Default if you skip it: none: needed before$" "$1" && grep -q "Default if you skip it: none: needed before Step 1 writes" "$1"' _ "$G"
check "decisions: safe defaults are Defaults taken in the report, not dialog items" grep -q 'is not asked: it is listed in the report under \*\*Defaults taken\*\*' "$G"
check "decisions: two or more conflicts are one decision, with a default" sh -c 'f="$(tr -s "\n " "  " < "$1")"; printf "%s\n" "$f" | grep -qF "Default if you skip it: C when a combined rule can be written, otherwise A. Two or more conflicts are one decision"' _ "$G"
check "decisions: a secrets finding is named in Where we are and a follow-up by default, never its value" sh -c 'f="$(tr -s "\n " "  " < "$1")"; printf "%s\n" "$f" | grep -qF "is always named in **Where we are** and becomes a proposed follow-up by default" && printf "%s\n" "$f" | grep -qF "never with the secret'"'"'s value, in a report, a draft, a follow-up or an issue"' _ "$G"
check "dialog: a multi-select may mark several recommendations; the first option is A" grep -q 'in a multi-select,$' "$G"
check "editor: a non-interactive run is defined" grep -qF 'no terminal on standard input, or a session started by a script' "$G"
check "verdict: a user-level CLAUDE.md counts only when it is not empty; the compare clause is for a fresh install only" sh -c 'f="$(tr -s "\n " "  " < "$1")"; printf "%s\n" "$f" | grep -qF "user-level instruction file exists and is not empty" && printf "%s\n" "$f" | grep -qF "on a fresh install only, \", Phase 1 compares them with the template\""' _ "$G"
check "stop: a user stop gets the ledger path and how to resume" grep -qF 'the ledger'"'"'s path and "say '"'"'continue'"'"' in a new session' "$G"
check "invariant candidates are checked against the code, with exceptions written in" grep -qF 'checks each against the code before' "$G"
check "first pass: ports and dev servers are read, so UNVERIFIED is only where none is named" sh -c 'grep -q "^- \*\*Ports and dev servers\*\*" "$1" && grep -qF "fill \`E2E_PORT\` / \`QA_PORT\`" "$1"' _ "$G"
check "first pass: a hooks manager the install would switch on is found and kept off" grep -qF 'a hooks manager the dependency install would switch on' "$G"
check "first pass: a skill overlap is a Default taken, enabled plugins' skills included" sh -c 'f="$(tr -s "\n " "  " < "$1")"; printf "%s\n" "$f" | grep -qF "Enabled plugins'"'"' skills count too" && printf "%s\n" "$f" | grep -qF "Each overlap is a stated default, \"install beside it\""' _ "$G"
COPY="$(between "$G" '- **A remote that is not on GitHub**' '- **Branch names** (e, f)')"
copy_has() { printf '%s' "$COPY" | grep -qF -- "$1"; }
check "copy of a GitHub repository: defined" copy_has '**A copy of a GitHub repository** means: the team'"'"'s pull requests, reviews and merges happen on GitHub, in a repository the user names (`owner/repo`)'
check "copy: offered only with the user's own evidence; the name is a Question" copy_has 'Offered only with this user'"'"'s own GitHub evidence (Phase 0)'
check "copy: ship needs gh for that repository, its protection counts at step 12, issues default to GitHub when found" sh -c 'printf "%s" "$1" | grep -qF "needs \`gh\` signed in for that repository" && printf "%s" "$1" | grep -qF "its protection counts at step 12" && printf "%s" "$1" | grep -qF "defaults to GitHub issues when its board, its issues or issue-numbered branches are found"' _ "$COPY"
check "copy: the first option is lettered A; without evidence only B-D, relettered" copy_has 'Without the evidence only B–D are offered, relettered A–C'
check "branch names: no dominant shape decides now, issue-first shapes drop the number" sh -c 'f="$(tr -s "\n " "  " < "$1")"; printf "%s\n" "$f" | grep -qF "No shape dominates → the template'"'"'s example (\`feature/\`), decided now" && printf "%s\n" "$f" | grep -qF "names the onboarding branch without one"' _ "$G"
S1="$(between "$G" '1. **`CLAUDE.md` from the template**' '2. **`bootstrap-agents`**')"
check "step 1: restates UNVERIFIED-only-where-empty and the template-default search, with the search cited" sh -c 'printf "%s" "$1" | grep -qF "\`UNVERIFIED\` exactly where the survey came up empty (the ports included" && printf "%s" "$1" | grep -qF "Never write \"nothing in the repository says otherwise\" without that search"' _ "$S1"
check "step 1: the details file's Configuration block follows the same fill rule" sh -c 'printf "%s" "$1" | grep -qF "The same rule fills the details file'"'"'s block"' _ "$S1"
check "step 1: one fixed decision block, each with its default" sh -c 'printf "%s" "$1" | grep -qF "**Step 1'"'"'s one message:** 1. **Write these drafts?**" && printf "%s" "$1" | grep -qF "default A), and \"Out-of-Scope\" with a candidate" && printf "%s" "$1" | grep -qF "default B). The docs and details-file paths are Defaults taken"' _ "$S1"
S2="$(between "$G" '2. **`bootstrap-agents`**' '3. **`bootstrap-claude-mds`**')"
check "step 2: restates the allowlist evidence check and the whole-suite rule; critical paths default to the invariant's code" sh -c 'printf "%s" "$1" | grep -qF "**Restated for this step:** every generated agent'"'"'s allowed commands are checked against the repository'"'"'s docs, CI comments, check-script headers and test-dispatch scripts" && printf "%s" "$1" | grep -qF "default: the code the invariant names"' _ "$S2"
S4="$(between "$G" '4. **`checkpoint`**' '5. **`review-plan`, then `start`**')"
check "step 4: tried once, and checkpoint's commit and stash behaviour follow the installed CLAUDE.md" sh -c 'printf "%s" "$1" | grep -qF "tried once (once: never again for evidence)" && printf "%s" "$1" | grep -qF "\`COMMIT=ask\` when it says to ask before every commit; \`AUTOSTASH=no\` when it forbids stashing"' _ "$S4"
# checkpoint is commit-only (pull requests are ship's) and its test-update guard must never halt its first use: a named
# critical list with no test globs halts, so the list is named only with TEST_GLOBS filled.
check "step 4: checkpoint is commit-only, no optional PR, no pass sentinel" sh -c 'printf "%s" "$1" | grep -qF "It is commit-only: pull requests go through \`ship\` (step 6), and it writes no pass sentinel." && ! printf "%s" "$1" | grep -q "optional PR"' _ "$S4"
check "slot map: checkpoint names the critical list only with TEST_GLOBS filled, never halting its first use" sh -c 'tr "\n" " " < "$1" | grep -qF "a named list with no test globs halts every checkpoint, so with no test globs \`CRITICAL_GLOBS_FILE\` stays empty" && grep -q "^| \`TEST_GLOBS\` (\`checkpoint\`, \`ship\`) |" "$1" && grep -q "^| \`DEV_SERVER_PATTERN\` (\`checkpoint\`) |" "$1"' _ "$G"
check "slot map: checkpoint's allowed-tools has no pull-request create, watch or merge" sh -c 'grep "^| \`checkpoint\`.s \`allowed-tools\`" "$1" | grep -qF "it is commit-only, so no command that opens, watches or merges a pull request" && ! grep "^| \`checkpoint\`.s \`allowed-tools\`" "$1" | grep -qF "gh pr create"' _ "$G"
check "slot map: peer-review's merge slots point at ship.env, one copy" grep -qF '`MERGE_METHOD`, `QUEUE_LABEL` and `MERGE_FLAGS` = `see ship.env` when `ship` is installed (one copy, never two)' "$G"
S7="$(between "$G" '7. **`review-code`**' '8. **hooks**')"
check "step 7: the test row covers every critical path, no catch-all row; CLAUDE.md never claims a live gate" sh -c 'printf "%s" "$1" | grep -qF "the test row covers every confirmed critical path, and no row is a catch-all" && printf "%s" "$1" | grep -qF "\"not switched on yet: the critical paths are off until their follow-up\""' _ "$S7"
check "audit: the auditor knows the follow-ups file comes later; matches a user choice and duplicates are handled" sh -c 'printf "%s" "$1" | grep -qF "the follow-ups file is written at step 11, after this audit" && printf "%s" "$1" | grep -qF "\"confirm with the team\" follow-up" && printf "%s" "$1" | grep -qF "is not added twice"' _ "$AUD"
check "follow-ups: the comparison's lessons are proposed with evidence, not enforced" sh -c 'for w in "**Switch on the critical-path gate:** one command" "**Widen the critical paths** to the folders with the most fix commits" "**A reviewer for each high-churn area with no detection-table row**" "**Rules the repository already enforces elsewhere**" "destructive database statements" "a raw infrastructure apply where a wrapper is required" "opening a pull request without the test pass" "**No AI attribution in commits and pull requests**" "step 8'"'"'s live check in the first session after the merge"; do printf "%s" "$1" | grep -qF "$w" || { echo "missing: $w"; exit 1; }; done' _ "$FUP"
check "follow-ups: with no tracker, the titles are shown and the file is a Default taken" fup_has 'the titles are listed in the message'
check "feedback: 'not now' keeps the notes and offers them at the next stop" sh -c 'printf "%s\n" "$1" | tr "\n" " " | tr -s " " | grep -qF "C) not now: the notes are kept and offered again at the next stop" && printf "%s\n" "$1" | tr "\n" " " | tr -s " " | grep -qF "Reply C → stop here"' _ "$FB"
check "the shared settings file's ignore warning becomes a step 8 option" s8f_has 'ignored by git: the decision gets C) un-ignore it with the lines the plan names'
check "step 10 audit: first pass cross-checks repo facts and template defaults" sh -c 'grep -qF "(item 0 is the first pass)" "$1" && grep -qF "flag it \"not found in code\"" "$1" && grep -qF "template text or sections that do not apply here" "$1"' _ "$G"
check "step 9: a read-only network notice, not a question, before the data script" sh -c 'f="$(tr -s "\n " "  " < "$1")"; printf "%s\n" "$f" | grep -qF "**Network notice, not a question:**" && printf "%s\n" "$f" | grep -qF "Nothing about your project is sent." && printf "%s\n" "$f" | grep -qF "then runs it without waiting"' _ "$G"
check "invariant: names cite file:line; a wrong name is corrected by default, a change of meaning is a decision defaulting to the correction" sh -c 'f="$(tr -s "\n " "  " < "$1")"; printf "%s\n" "$f" | grep -qF "cites the \`file:line\` you read it at" && printf "%s\n" "$f" | grep -qF "is corrected like any plain error, without a question" && printf "%s\n" "$f" | grep -qF "**A) use the corrected wording \`<text>\`** (default)"' _ "$G"
check "step 7 installs peer-review and trim with no question, and the slot map fills peer-review" sh -c 'f="$(tr -s "\n " "  " < "$1")"; printf "%s\n" "$f" | grep -qF "installs the two small companions, with no question" && printf "%s\n" "$f" | grep -qF "**\`peer-review\`**" && printf "%s\n" "$f" | grep -qF "**\`trim\`**" && grep -q "^| \`peer-review\` (step 7) | Not asked." "$1"' _ "$G"
check "trim's file never defaults to a shared temp folder" sh -c 'grep -qF "worked default \$HOME/.cache/trim" "$1" && ! grep -q "worked default /tmp" "$1"' _ skills/trim/SKILL.md
check "a same-name skill or command of the user's is kept, never overwritten, with each dependent step's cost named" sh -c 'f="$(tr -s "\n " "  " < "$1")"; printf "%s\n" "$f" | grep -qF "**It is kept, never overwritten, and nothing of ours is written into its folder.**" && printf "%s\n" "$f" | grep -qF "\`review-code\`: step 7 is skipped, and so are \`review-plan\` and \`start\`" && printf "%s\n" "$f" | grep -qF "\`worktree\`: Step 0 makes the onboarding folder with plain \`git worktree add\`" && printf "%s\n" "$f" | grep -qF "never overwrite the user'"'"'s own skill or command of the same name at all" && printf "%s\n" "$f" | grep -qF "check that the folder does not exist yet" && printf "%s\n" "$f" | grep -qF "No installed skill touched one of the user'"'"'s own" && ! printf "%s\n" "$f" | grep -qF "hm-<name>" && ! printf "%s\n" "$f" | grep -qF "B) replace it"' _ "$G"
check "partial-install mode needs evidence the folder is ours, not just its name" sh -c 'f="$(tr -s "\n " "  " < "$1")"; printf "%s\n" "$f" | grep -qF "that is evidently this download'"'"'s skill" && printf "%s\n" "$f" | grep -qF "A folder that only shares the name is the user'"'"'s own skill"' _ "$G"
check "Phase 4 ends with the optional dashboard sign-up line: disclosed, never asked, never run" sh -c 'f="$(tr -s "\n " "  " < "$1")"; printf "%s\n" "$f" | grep -qF "**Optional: see your numbers.**" && printf "%s\n" "$f" | grep -qF "https://humanmaxxing.ai/signup" && printf "%s\n" "$f" | grep -qF "It sends your agents'"'"' usage data to the hosted service; nothing is set up unless you do it." && printf "%s\n" "$f" | grep -qF "never asked as a question, never run, and never a follow-up"' _ "$G"
check "maxx-start is a Default taken, not a decision" sh -c 'grep -qF "a Default taken, \"not installed: say '"'"'install" "$1" && ! grep -q "A) install it (writes \`~/bin/maxx-start\`" "$1"' _ "$G"

# --- rules ported from the battle-tested originals: each check pins the qualifier, and a paired one the old text gone --
has() { printf '%s' "$1" | grep -qF -- "$2"; }
hasnt() { ! has "$@"; }
FTC="$(between "$T" '## Fix the Class' '## Domain Accuracy')"
INFRA="$(between "$T" '## Infrastructure Permission Model' '## Out-of-Scope')"
PLAN="$(between "$T" '### Planning Mode' '## Subagent Dispatch')"
DISP="$(between "$T" '## Subagent Dispatch' '## Parallelism')"
TOOL="$(between "$T" '## Tool Discipline' '## Git Merge Protocol')"
WTS="$(between "$T" '## Worktrees' '## CI/CD')"
SWC="$(between "$D" '### Subagent worktree cleanup' '## Cross-System')"
DEV="$(between "$D" '## Dev Server Management' '## PRD')"
SO="$(between "$D" '## Subagent Orchestration' '## Token-Efficient')"
TEO="$(between "$D" '## Token-Efficient Orchestration' '## Post-Compact')"
TDD="$(between "$D" '## Tool Discipline' '')"
for v in FTC INFRA PLAN DISP TOOL WTS SWC DEV SO TEO TDD; do eval "check \"section \$v was found\" test -n \"\$$v\""; done
# budget mode: the middle mode is the default, never asked; the loosest is opt-in only
check "budget: the default is Parallel, not asked" has "$PLAN" 'the default mode is **Parallel** (the middle one). **Don'"'"'t ask;**'
check "budget: Max Parallel is opt-in only" has "$PLAN" 'is opt-in only, when the user asks for it'
check "budget: no 'least-restrictive' default anywhere" sh -c '! grep -q "least-restrictive" "$1" "$2"' _ "$T" "$D"
check "budget: the details file does not ask either" sh -c 'has() { printf "%s" "$1" | grep -qF -- "$2"; }; has "$1" "Don'"'"'t ask. Use the default, **Parallel**" && ! has "$1" "Ask once, up front"' _ "$TEO"
# dispatch trigger is mode-qualified; Frugal stays inline
check "dispatch: the trigger names Parallel and Max Parallel" has "$DISP" '**Dispatch trigger (Parallel and Max Parallel):**'
check "dispatch: Frugal does not dispatch by default" has "$DISP" '**Frugal does not dispatch by default:**'
check "dispatch: the anti-inline rule no longer names a mode that doesn't exist" hasnt "$DISP" 'stricter than frugal'
check "dispatch: small is judged per batch, by the pre-flight" has "$DISP" '"Small" is judged per batch, never per edit'
check "pre-flight: partition per batch, dispatch before the inline share" sh -c 'printf "%s" "$1" | grep -qF "**Partition per batch, never per edit.**" && printf "%s" "$1" | grep -qF "**Dispatch before doing your inline share,**"' _ "$TEO"
check "critical work is one at a time in every mode, not a soft hint" sh -c 'printf "%s" "$1" | grep -qF "**Critical work runs one at a time, in every mode.**" && ! printf "%s" "$1" | grep -qF "1 critical worker at once"' _ "$TEO"
# agent worktree cleanup: gated, never by pattern, never forced
check "agent cleanup: no forced remove, no pattern delete" sh -c '! printf "%s" "$1" | grep -qE -- "worktree remove --force|branch -D \"worktree-agent"' _ "$SWC"
for r in 'a process is inside' 'edited in the last 3 days' 'uncommitted changes' 'commits not in $BASE' 'cannot check for live processes'; do
  check "agent cleanup skips: $r" has "$SWC" "SKIP \$WT: $r"
done
check "agent cleanup: a skip is never forced past" has "$SWC" 'never add `--force` to get past one'
check "worktrees rule: no force exception for agent copies" sh -c 'printf "%s" "$1" | grep -qF "never by name pattern and never with force" && ! printf "%s" "$1" | grep -qF "are the one exception"' _ "$WTS"
# Fix the Class: the threshold is a brake
check "class: the count is a brake, not a trigger" has "$FTC" 'the count is a brake on guards, not a trigger'
check "class: below the threshold, no mechanical guard" has "$FTC" 'the fix adds **no mechanical guard**'
check "class: a class-level test at every count" has "$FTC" '**Prove the class in tests, at every count.**'
check "class: sibling sites are the class size, never repeats" has "$FTC" 'the sibling sites this PR'"'"'s own sweep finds are the class size, never repeats'
check "class: at the threshold a guard is allowed, not required; the user decides" sh -c 'printf "%s" "$1" | grep -qF "a mechanical guard is earned, which means allowed, not required" && printf "%s" "$1" | grep -qF "the user decides whether this PR adds it" && ! printf "%s" "$1" | grep -qF "why none is feasible"' _ "$FTC"
check "class: reaching the threshold without a guard is not instance-only" hasnt "$FTC" 'reached the threshold'
check "review gate: belongs to the owning session, never started by a worker on its own" has "$PLAN" 'The gate belongs to the session that owns the change'
check "critical work: by kind, not by critical-path location" has "$TEO" 'is not critical by location alone'
check "class: a runtime chokepoint is not a guard" has "$FTC" '**A runtime chokepoint is always allowed and is not a guard.**'
check "class: over-guarding is sampled too, against a budget" sh -c 'printf "%s" "$1" | grep -qF "is over-guarded" && printf "%s" "$1" | grep -qF "monthly guard budget"' _ "$FTC"
check "class: the guard is no longer the default path" sh -c '! printf "%s" "$1" | grep -qF "Add a class guard, or state why none exists" && ! printf "%s" "$1" | grep -qF "they are optional"' _ "$FTC"
check "class: a token-presence check doesn't prove runtime behaviour; the legal case is fixtured" sh -c 'printf "%s" "$1" | grep -qF "**A token-presence check doesn'"'"'t prove runtime behaviour.**" && printf "%s" "$1" | grep -qF "with a fixture for the legal case"' _ "$FTC"
# exit capture, waits, re-runs
check "exit: same-line capture into a variable" has "$TOOL" 'PS=("${PIPESTATUS[@]}")'
check "exit: no blanket pipefail, in either template" sh -c 'printf "%s" "$1" | grep -qF "Don'"'"'t turn on a blanket \`set -o pipefail\`" && ! printf "%s" "$1" | grep -qF "Run \`set -o pipefail\` first" && printf "%s" "$2" | grep -qF "Don'"'"'t use a blanket \`set -o pipefail\`" && ! printf "%s" "$2" | grep -qF "The portable fix is \`set -o pipefail\`"' _ "$TOOL" "$TDD"
check "waits: one bounded process gated on the condition" has "$TOOL" '**one bounded process that exits on the condition**'
check "waits: sleep-and-check is banned, and no second wait on a tracked task" sh -c 'printf "%s" "$1" | grep -qF "is model-level polling, a full turn per wake, and is banned" && printf "%s" "$1" | grep -qF "never arm a second wait on the same completion"' _ "$TOOL"
check "re-run: only on a changed input; cite the earlier green" sh -c 'printf "%s" "$1" | grep -qF "a re-run is earned by a changed input" && printf "%s" "$1" | grep -qF "cite the earlier green"' _ "$TOOL"
check "tests: a whole-suite run needs a named reason" has "$TOOL" 'A whole-suite run needs a named reason'
# dev server probe
check "dev server: the probe is LISTEN-only with an ss fallback" sh -c 'printf "%s" "$1" | grep -qF -- "-sTCP:LISTEN -t" && printf "%s" "$1" | grep -qF "ss -lntp" && ! printf "%s" "$1" | grep -qF "lsof -i :<DEV_PORT> -t"' _ "$DEV"
# database reads
check "db: read-only per transaction, never a session setting through a pooler" sh -c 'printf "%s" "$1" | grep -qF "\`BEGIN READ ONLY; …; ROLLBACK;\`" && printf "%s" "$1" | grep -qF "transaction-mode connection pooler"' _ "$INFRA"
check "db: tenant-scoped audit reads return silent zeros" has "$INFRA" 'returns silent zeros'
# review gate
check "review gate: automatic, qualified on the skill being installed" sh -c 'printf "%s" "$1" | grep -qF "**Code review gate (automatic: no ask, no pause).** Once your code-review skill is installed" && printf "%s" "$1" | grep -qF "\"ready to ship\"" && printf "%s" "$1" | grep -qF "state that reason and ask"' _ "$PLAN"
# workers: what they may run, and checking what they return
check "dispatch: every prompt says what it may run; the gate runs once after the agents land" sh -c 'printf "%s" "$1" | grep -qF "says what it may run locally" && printf "%s" "$1" | grep -qF "runs the full gate once, after the agents land"' _ "$DISP"
check "briefing: default-deny block in the details file" sh -c 'printf "%s" "$1" | grep -qF "Anything not on ALLOWED is FORBIDDEN" && printf "%s" "$1" | grep -qF "**Default-deny.**" && printf "%s" "$1" | grep -qF "N siblings never each get a typecheck"' _ "$SO"
check "result check: capped Done, invented identifiers, should-pass, same-tier split" sh -c 'for w in "reports \"Done\" exactly like one that finished" "**Grep the identifiers it claims to have created**" "**\"Should pass\" is not a run.**" "split its scope, same tier"; do printf "%s" "$1" | grep -qF "$w" || { echo "missing: $w"; exit 1; }; done' _ "$SO"
check "model: mechanical edits go cheapest only with the exact change; never strongest for routine work" sh -c 'grep -qF "| Mechanical edit, the exact change in the prompt | cheapest tier |" "$1" && grep -qF "Never the strongest tier for routine or" "$1"' _ "$T"
check "orchestrator tier follows its job" has "$DISP" 'a run that only routes mechanical steps'
check "dispatch is authorized within the mode, without asking" has "$DISP" '**Dispatching workers within the active budget mode is authorized in this repository.**'
t_done
