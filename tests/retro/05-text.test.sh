#!/usr/bin/env bash
# Static checks on the retro skill's text: the Configuration block and the example file agree, the report has every
# section, the exit codes the skill routes on are the script's, no release URL is written into the product, and the
# skill stays read-only in what it permits.
. "$(dirname "$0")/../lib.sh"
cd "$T_ROOT" || exit 2
S=skills/retro/SKILL.md; E=skills/retro/retro.env.example; D=skills/retro/bin/retro-data.sh
for f in "$S" "$E" "$D"; do check "$f exists" test -f "$f"; done

# Every key the example file sets (or shows commented out) is documented in SKILL.md's Configuration block, and every
# key the block documents is in the example file and read by the script.
BLOCK="$(awk '/^## Configuration/{c=1} c && /^```$/{n++; if (n==2) exit; next} c && n==1' "$S")"
EXKEYS="$(sed -n 's/^#\{0,1\} \{0,1\}\([A-Z][A-Z_]*\)=.*/\1/p' "$E" | sort -u)"
check "the example file sets keys" test -n "$EXKEYS"
for k in $EXKEYS; do
  case "$k" in FIX_WORDS|FEAT_WORDS|DOCS_WORDS|CHORE_WORDS) want="$k" ;; *) want="^$k " ;; esac
  check "SKILL.md documents $k" sh -c 'printf "%s\n" "$1" | grep -q -- "$2"' _ "$BLOCK" "$want"
  check "the script reads $k" grep -q "cfg $k\|\"\$CONFIG\" $k" "$D"
done
for k in $(printf '%s\n' "$BLOCK" | sed -n 's/^\([A-Z][A-Z_]*\) .*/\1/p'); do
  check "the example file has $k" sh -c 'printf "%s\n" "$1" | grep -qx -- "$2"' _ "$EXKEYS" "$k"
done

# The report shape: every section, in order.
SECTIONS="Summary|What shipped|What broke|Recurring patterns|Class-fix audit|Framework currency|Process suggestions|Metrics to watch"
GOT="$(grep -E "^## ($SECTIONS)$" "$S" | sed 's/^## //' | tr '\n' '|' | sed 's/|$//')"
check "the report has every section, in order" test "$GOT" = "$SECTIONS"

# The exit codes and result tokens SKILL.md routes on are the ones the script prints.
for tok in 'PASS complete' 'PARTIAL unavailable=' 'FAIL'; do
  check "SKILL.md routes on '$tok'" grep -qF "$tok" "$S"
  check "the script prints '$tok'" grep -qF "$(printf '%s' "$tok" | sed 's/ .*//')" "$D"
done
check "the script's exits are 0, 2 and 3 only" sh -c '! grep -oE "exit [0-9]+|die [0-9]+" "$1" | grep -vE " (0|2|3)$"' _ "$D"

# No release location is written into the product: it is a configuration slot.
check "no URL in the retro skill" sh -c '! grep -rnE "https?://|git@|github\.com" "$1"' _ skills/retro
check "the example file leaves the release URL empty" grep -qx 'RELEASE_REPO_URL=' "$E"

# Read-only by construction: the script never fetches, pushes, records or writes through gh.
check "the script never fetches or pushes" sh -c '! grep -nE "git (fetch|push|pull|commit|tag|update-ref)" "$1"' _ "$D"
check "the script calls hm-lock status, never record" sh -c 'grep -q "hm-lock.sh\" status" "$1" && ! grep -q "hm-lock.sh\" record" "$1"' _ "$D"
check "the script's gh calls are list queries" sh -c '! grep -nE "gh (issue|pr) (create|edit|close|comment|merge)|gh api" "$1"' _ "$D"
check "the skill says it writes one report file and nothing else" grep -q 'It writes one report file and changes nothing else' "$S"
check "each suggestion waits for the user's answer" grep -q 'Nothing is filed, edited or updated before the user answers that item' "$S"
check "the skill never updates the install itself" grep -q 'The retro never updates anything itself' "$S"
check "the question asked of the user is in plain words" grep -q 'in plain words' "$S"
check "the skill never fetches on its own: a fetch is the user's call" grep -q 'Never fetch on your own' "$S"
check "at most four suggestions, so one dialog holds them" sh -c 'grep -q "At most four suggestions" "$1" && grep -q "four at most, so one dialog holds them all" "$1"' _ "$S"
check "a skipped suggestion files nothing" grep -q 'Default if you skip it: C (nothing is filed or changed)' "$S"
check "findings are read from the base branch, not the checkout" grep -qF 'git show <REF>:<path>' "$S"
AT="$(grep -m1 '^allowed-tools:' "$S")"
check "allowed-tools grants no blanket bash, git or gh" sh -c '! printf "%s\n" "$1" | grep -qF -e "Bash(bash *)" -e "Bash(git *)" -e "Bash(gh *)"' _ "$AT"
check "allowed-tools names the data script" sh -c 'printf "%s\n" "$1" | grep -qF "Bash(bash .claude/skills/retro/bin/retro-data.sh *)"' _ "$AT"
check "the tool grant covers only reads and the report" grep -q 'tool grant covers only its reads and the report' "$S"
check "folder-missing's usual meaning is explained" grep -q 'reason=folder-missing` usually means no findings file has reached the base branch yet' "$S"
check "the skill says where an approved rules edit lands" grep -q 'An approved rules edit lands on its own branch' "$S"
check "the rules-file option is offered only for a rules suggestion" grep -q 'Option B is offered only when the suggestion lands in the rules file' "$S"
# The class-fix audit runs in both directions: a guard below the threshold is flagged with the same weight as an
# instance-only fix, and guard growth is a brake (a budget), never a target. A runtime chokepoint is not a guard.
check "2d audits over-guarding: a guard below the threshold" grep -qF '5. **Over-guarded (the same audit, the other direction).**' "$S"
check "over-guarded carries the same weight as instance-only" grep -qF 'with the same weight as instance-only' "$S"
check "a below-threshold class-level test with no guard is correct" grep -qF 'A below-threshold fix that closed the class with a class-level test and no guard is correct' "$S"
check "a runtime chokepoint is never flagged as a guard" grep -qF 'is not a guard and is never flagged here' "$S"
check "the report has an over-guarded line" grep -qF -- '- Over-guarded (a guard added below the threshold):' "$S"
check "the budget is a tripwire the report compares against, not a cap" grep -qF 'The budget is a tripwire the report compares against, not a cap' "$S"
check "the example's budget is a tripwire with a worked value" sh -c 'grep -qx "GUARD_BUDGET_PER_MONTH=10" "$1" && grep -q "It is a tripwire," "$1"' _ "$E"
check "the threshold options list 7 as the default" grep -qF 'the onboarding offers 7, the default, 5 or 3' "$S"
check "deploy whack-a-mole is looked for" grep -qF 'deploy whack-a-mole' "$S"
check "reviewer signal versus noise is reported when the files say" grep -qF 'mostly real (fixed) and which were mostly noise' "$S"
NOSCRIPT="$(awk '/^## Without the script$/{f=1; next} f && /^## /{exit} f' "$S")"
check "the Without-the-script section was found" test -n "$NOSCRIPT"
check "the Without-the-script commands name no fixed remote or branch" sh -c '! printf "%s\n" "$1" | grep -q "origin/main"' _ "$NOSCRIPT"
t_done
