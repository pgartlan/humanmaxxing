#!/usr/bin/env bash
# Static checks on the product text the worktree skill depends on: the layout key, the stop rule in start, the exit-4
# wording in ship, the bash-3.2 constructs banned from the scripts, and the reason tokens the skill must list.
. "$(dirname "$0")/../lib.sh"
cd "$T_ROOT" || exit 2
W=skills/worktree
has() { grep -Eq -- "$1" "$2" 2>/dev/null; }
# code lines only: comments may explain what is banned
code() { grep -hv '^[[:space:]]*#' "$@" 2>/dev/null; }

# --- the layout key and the stop rule -----------------------------------------------------------------------------------------
check "worktree SKILL.md exists" test -f $W/SKILL.md
check "worktree SKILL.md names WORKTREE_LAYOUT" grep -q 'WORKTREE_LAYOUT' $W/SKILL.md
check "getting-started names WORKTREE_LAYOUT" grep -q 'WORKTREE_LAYOUT' getting-started.claude.md
check "start's SKILL.md names WORKTREE_LAYOUT" grep -q 'WORKTREE_LAYOUT' skills/start/SKILL.md
check "start names both layouts" sh -c "grep -q siblings skills/start/SKILL.md && grep -q single skills/start/SKILL.md"
check "start says an unset layout stops (and asks)" has '([Uu]nset|not set|is empty|empty).*([Ss]top|ask)|([Ss]top|ask).*([Uu]nset|not set)' skills/start/SKILL.md
check "start's stop rule is next to the layout key" sh -c "grep -E 'WORKTREE_LAYOUT' skills/start/SKILL.md | grep -Eiq 'unset|stop|ask'"

# --- ship's exit-4 wording ------------------------------------------------------------------------------------------------------
check "exit-codes.md: the exit-4 line says never proceed" sh -c "grep -E '(^|[^0-9])4([^0-9]|\$)' skills/ship/references/exit-codes.md | grep -q 'never proceed'"
check "ship-lib.sh: the exit-4 line says never proceed" sh -c "grep -E '(^|[^0-9>=])4([^0-9]|\$)' skills/ship/bin/ship-lib.sh | grep -q 'never proceed'"

# --- constructs banned from the scripts ---------------------------------------------------------------------------------------------
for s in worktree-lib worktree-create worktree-list worktree-remove worktree-start worktree-sweep; do
  check "$s.sh exists" test -f "$W/bin/$s.sh"
done
for pair in 'declare -A|declare[[:space:]]+-A' 'mapfile|mapfile|readarray' 'lowercase expansion|\$\{[a-z_]*,,' 'uppercase expansion|\$\{[a-z_]*\^\^' \
            'local -n|local[[:space:]]+-n[[:space:]]' '[[ -v|\[\[[[:space:]]+-v' 'wait -n|wait[[:space:]]+-n' 'realpath|realpath' \
            'readlink -f|readlink[[:space:]]+-f' 'sed -i|sed[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-i'; do
  name="${pair%%|*}"; pat="${pair#*|}"
  hits="$(code "$W"/bin/*.sh | grep -E -- "$pat")"
  if [ -z "$hits" ]; then t_pass "no $name in $W/bin/*.sh"
  else OUT="$hits"; t_fail "no $name in $W/bin/*.sh" "found a banned construct"; fi
done
hits="$(code "$W"/bin/*.sh | grep -E '^[[:space:]]*set[[:space:]]+(-[a-z]*e|-o[[:space:]]+(errexit|pipefail))')"
if [ -z "$hits" ]; then t_pass "no set -e or pipefail in the scripts"; else OUT="$hits"; t_fail "no set -e or pipefail in the scripts"; fi
check "the scripts use set -u" sh -c "grep -l 'set -u' $W/bin/worktree-lib.sh"
for f in "$W"/bin/*.sh; do
  first="$(head -1 "$f")"
  if [ "$first" = '#!/usr/bin/env bash' ]; then t_pass "$(basename "$f") starts with the env bash shebang"
  else OUT="$first"; t_fail "$(basename "$f") starts with the env bash shebang"; fi
done

# --- the skill lists every reason token --------------------------------------------------------------------------------------------------
for tok in usage config- guard-refused path-exists branch-exists create-in-progress no-commits fetch-failed ls-remote-failed title-failed \
           marker-unreadable post-create-failed copy-failed push-failed claim-failed findings is-base is-current not-found not-a-checkout \
           only-copy setup-died created clean removed launching; do
  if grep -Fq -- "$tok" $W/SKILL.md 2>/dev/null; then t_pass "SKILL.md lists the reason token $tok"
  else OUT="(grep for $tok in $W/SKILL.md)"; t_fail "SKILL.md lists the reason token $tok"; fi
done
for k in WORKTREE-RESULT BASE_BRANCH BASE_REMOTE POST_CREATE_CMD ISSUE_GUARD_CMD ISSUE_CLAIM_CMD START_CMD; do
  if grep -Fq -- "$k" $W/SKILL.md 2>/dev/null; then t_pass "SKILL.md names $k"; else OUT="(grep for $k)"; t_fail "SKILL.md names $k"; fi
done

# --- getting-started: the stop rule and the ledger example ----------------------------------------------------------------------
check "getting-started says an unset WORKTREE_LAYOUT stops and asks" sh -c "grep -E 'WORKTREE_LAYOUT' getting-started.claude.md | grep -Eiq '(unset|not set|UNVERIFIED).*(stop|ask)|(stop|ask).*(unset|not set)'"
ledger="$(awk '/^# HumanMaxxing adoption/{f=1} f&&/^\| [0-9]+ \|/{gsub(/[^0-9|]/,"",$0); split($0,c,"|"); print c[2]} /^```$/{if(f&&seen)exit} f&&/^\| 0 /{seen=1}' getting-started.claude.md | tr '\n' ' ')"
check "the ledger example has numbered rows" test -n "$ledger"
want=""; i=0; for _ in $ledger; do want="$want$i "; i=$((i + 1)); done
check "its rows are numbered 0, 1, 2, ... without a gap" test "$ledger" = "$want"
check "start's Step 0 stops at the first non-number segment" sh -c "grep -Eq 'first segment that is not a number' skills/start/SKILL.md && grep -q '12-13-fix-login' skills/start/SKILL.md"

# --- reason tokens by exit code, and the details template's cleanup chain ------------------------------------------------------------
for tok in add-failed config-remote status-failed compare-failed branch-deleted delete-failed create-failed marker-failed -- --discard-commits; do
  [ "$tok" = -- ] && continue
  if grep -Fq -- "$tok" $W/SKILL.md; then t_pass "SKILL.md names $tok"; else OUT="(grep for $tok)"; t_fail "SKILL.md names $tok"; fi
done
exit6="$(grep -E '\*\*6:\*\*' $W/SKILL.md | sed 's/.*\*\*6:\*\*//')"; exit6="${exit6%%. *}"
case "$exit6" in *marker-failed*) t_pass "marker-failed is in the exit-6 group" ;; *) OUT="$exit6"; t_fail "marker-failed is in the exit-6 group" ;; esac
case "$exit6" in *\`create-failed\`*) OUT="$exit6"; t_fail "create-failed is not in the exit-6 group" ;; *) t_pass "create-failed is not in the exit-6 group" ;; esac
check "start's pre-flight compares resolved paths" sh -c "grep -E 'git-common-dir' skills/start/SKILL.md | grep -q 'pwd -P'"
check "the remote-branch delete sits on the same && chain as the ancestry check" sh -c "grep -A3 'merge-base --is-ancestor <branch>' templates/claude-details.template.md | grep -q '&&.*push origin --delete'"

# --- the list states the SKILL documents ---------------------------------------------------------------------------------------------
check "SKILL.md documents the list state unreadable" sh -c "grep -E 'The state is' $W/SKILL.md | grep -q '\`unreadable\`'"
check "SKILL.md documents the list state missing" sh -c "grep -E 'The state is' $W/SKILL.md | grep -q '\`missing\`'"

# --- removal safety and the sweep: the qualifiers, not only the headline -----------------------------------------------------------
for tok in in-use mount-below live-unknown mount-unknown sweep-incomplete swept recent-edits setup-running not-swept 'restore: git branch'; do
  if grep -Fq -- "$tok" $W/SKILL.md; then t_pass "SKILL.md names $tok"; else OUT="(grep for $tok)"; t_fail "SKILL.md names $tok"; fi
done
check "no flag overrides in-use or mount-below" grep -qF 'are refusals no flag overrides' $W/SKILL.md
check "the sweep needs the user's batch approval, per batch" sh -c "grep -qF 'wait for the user'\''s approval of the batch' $W/SKILL.md && grep -qF 'an approval covers that batch only, never a later sweep' $W/SKILL.md"
check "the sweep re-judges each approved name before removing it" grep -qF 'Each name is judged again right before it is removed' $W/SKILL.md
check "the sweep skips a squash-merged branch (one at a time through remove)" grep -qF 'A squash-merged branch is skipped too' $W/SKILL.md
check "recent edits are a skip because the in-use check cannot see subagent worktrees" grep -qF "an isolated subagent's worktree is not its process's working directory" $W/SKILL.md
check "the sweep never touches a remote branch" grep -qF 'The sweep never touches a remote branch' $W/SKILL.md
check "the sweep never forces a removal" sh -c "! grep -n 'worktree remove --force' $W/bin/worktree-sweep.sh"
check "the 72-hour window is the sweep's" grep -qx 'RECENT_HOURS=72' $W/bin/worktree-sweep.sh
check "squash-merged has criteria: into the base itself, its tip, not reverted" sh -c "grep -qF 'merged into the base itself, with this branch'\''s tip as the commit that PR merged, and was not reverted afterwards' $W/SKILL.md && grep -qF 'A PR merged into another branch, or merged and then reverted, is not merged into the base' $W/SKILL.md"
check "an orchestrated run may make one worktree per team" grep -qF 'may create one worktree per team' $W/SKILL.md
check "hidden untracked files are counted (status.showUntrackedFiles)" sh -c "grep -qF -- '--untracked-files=all' $W/bin/worktree-lib.sh && grep -c 'status.showUntrackedFiles=all worktree remove' $W/bin/worktree-remove.sh | grep -qx 2"

t_done
