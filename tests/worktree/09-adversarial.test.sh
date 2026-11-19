#!/usr/bin/env bash
# Adversarial cases the other worktree tests leave open: worktree-issue.sh fail-closed inputs and board-config
# hostility, the launcher installer's refusals and hostile paths, an uncreatable default folder, and the config
# comment guard in its leading-whitespace shapes. Real scripts; `gh` is the same file-answering fake as 06.
. "$(dirname "$0")/../lib.sh"
command -v jq >/dev/null 2>&1 || { OUT=""; t_fail "jq is installed"; t_done; exit 1; }
R='WORKTREE-RESULT worktree-install-launcher'

t_wt_fixture a1
GHD="$FIX/gh"; mkdir -p "$GHD" "$FIX/fakebin"
cat > "$FIX/fakebin/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GHD/calls.log"
case "$1 $2" in
  "repo view") echo "${FAKE_NWO:-acme/app}" ;;
  "api user") echo me ;;
  "issue view") echo "A title" ;;
  "api graphql") case "$*" in *updateProjectV2ItemFieldValue*) echo '{}' ;; *)
      prog=""; prev=""; for a in "$@"; do [ "$prev" = "--jq" ] && prog="$a"; prev="$a"; done
      o="$(jq -r "$prog" "$GHD/answer.json")" || exit $?; [ -z "$o" ] || printf '%s\n' "$o" | tr -d '\r' ;; esac ;;   # as gh would: LF only
esac
FAKE
chmod 755 "$FIX/fakebin/gh"
export GHD
I="$B/worktree-issue.sh"
issue() { local v="$1"; shift; PATH="$FIX/fakebin:$PATH" ISSUE="$v" BRANCH="7-x" run bash "$I" --config "$CFG" "$@"; }
t_wt_cfg nob.env
printf '{"data":{"repository":{"issue":{"state":"OPEN","assignees":{"nodes":[]},"projectItems":{"nodes":[]}}}}}\n' > "$GHD/answer.json"

# --- worktree-issue: fail closed ------------------------------------------------------------------------------------
issue "" guard; expect_rc 2 "an empty ISSUE is a usage error, never a pass"
issue "--help" guard; expect_rc 2 "an ISSUE that looks like a flag is refused"
issue "7 8" title; expect_rc 2 "an ISSUE with a space is refused"
issue 7 guard claim; expect_rc 2 "two verbs are refused"
issue 7; expect_rc 2 "no verb is refused"
PATH="$FIX/fakebin:$PATH" ISSUE=7 run bash "$I" --config "$FIX/does-not-exist.env" guard
expect_rc 2 "a missing config file is exit 2, not a guard pass"
printf '{"data":{"repository":{"issue":null}}}\n' > "$GHD/answer.json"
issue 7 guard; expect_rc 3 "an issue the API says does not exist refuses (exit 3), never passes"
printf '{"data":{"repository":{"issue":{"state":"OPEN","assignees":{"nodes":[]},"projectItems":{"nodes":[]}}}}}\n' > "$GHD/answer.json"
# gh absent from PATH: neither the fake one nor any real one (jq-less is fine: gh does the jq)
ISSUE=7 run env PATH="$(PATH="$FIX/fakebin:$PATH" t_path_without gh)" bash "$I" --config "$CFG" guard
expect_rc 3 "gh not installed is exit 3 (cannot read), never a guard pass"
FAKE_NWO="noslash" issue 7 guard; expect_rc 3 "an unexpected repository name from gh refuses"
FAKE_NWO="noslash" run env PATH="$FIX/fakebin:$PATH" ISSUE=7 BRANCH=b FAKE_NWO=noslash bash "$I" --config "$CFG" claim
expect_rc 3 "claim with an unreadable repository name makes no change (exit 3)"
check "and made no assign/comment call" sh -c '! grep -Eq "^issue (edit|comment)" "$1" 2>/dev/null' _ "$GHD/calls.log"

# --- worktree-issue: hostile ISSUE_PROJECT ---------------------------------------------------------------------------
for bad in "acme/3/4" "/3" "ac me/3" "acme/x" "acme/" "acme/-1" 'acme;rm/3'; do
  t_wt_cfg hostile.env "ISSUE_PROJECT=$bad"; issue 7 guard
  expect_rc 2 "ISSUE_PROJECT '$bad' is a configuration error"
done

# --- the config comment guard: every leading-whitespace shape --------------------------------------------------------
create_cfg() { printf 'BASE_BRANCH=main\n%s\n' "$1" > "$FIX/c.env"; run bash "$B/worktree-create.sh" --config "$FIX/c.env" cmt-branch; }
create_cfg "COPY_FILES=#only a comment"; expect 2 'FAIL config-malformed' "a # with no space after = is refused"
create_cfg "$(printf 'PUSH_ON_ISSUE= \t # x')"; expect 2 'FAIL config-malformed' "mixed space and tab before # is refused"

# --- the launcher installer: refusals and hostile paths --------------------------------------------------------------
t_wt_cfg l.env "START_CMD=echo session"
run bash "$B/worktree-install-launcher.sh" --config "$CFG" --name -x --dir "$FIX/b1"; expect 2 "$R FAIL usage" "a name starting with - is refused"
run bash "$B/worktree-install-launcher.sh" --config "$CFG" --name '' --dir "$FIX/b1"; expect 2 "$R FAIL usage" "an empty name is refused"
run bash "$B/worktree-install-launcher.sh" --config "$CFG" --name 'a/b' --dir "$FIX/b1"; expect 2 "$R FAIL usage" "a name with a slash is refused"
run bash "$B/worktree-install-launcher.sh" --config "$CFG" --dir; expect 2 "$R FAIL usage" "--dir with no value is refused"
run bash "$B/worktree-install-launcher.sh" --config "$CFG" --dir ""; expect 2 "$R FAIL usage" "an empty --dir is refused (no fall back to HOME)"
run env -u HOME bash "$B/worktree-install-launcher.sh" --config "$CFG"; expect 2 "$R FAIL usage" "no --dir and no HOME is refused"
run bash "$B/worktree-install-launcher.sh" --config "$FIX/nope.env" --dir "$FIX/b1"; expect 2 'FAIL config-missing' "a missing config is exit 2"
SP="$FIX/dir with space"
run bash "$B/worktree-install-launcher.sh" --config "$CFG" --dir "$SP"; expect_rc 0 "a --dir with a space installs"
check "the written launcher parses as shell" bash -n "$SP/maxx-start"
t_wt_run_in "$T_TMP" "$SP/maxx-start" 'x y!'; expect 2 'WORKTREE-RESULT worktree-start FAIL usage' "a space path launcher still reaches the real launcher"
printf 'x\n' > "$FIX/afile"
run bash "$B/worktree-install-launcher.sh" --config "$CFG" --dir "$FIX/afile"; expect_rc 2 "a --dir that is a file is exit 2, not a write"
# The base branch checked out nowhere, so there is no primary copy to run from.
git -C "$FIX/primary" checkout -q --detach
run bash "$B/worktree-install-launcher.sh" --config "$CFG" --dir "$FIX/b2"; expect 2 'FAIL no-primary' "no working copy on BASE_BRANCH is exit 2"
check "and nothing was written" test ! -e "$FIX/b2/maxx-start"
git -C "$FIX/primary" checkout -q main

# --- the default worktree folder cannot be made ----------------------------------------------------------------------
t_wt_fixture p1; unpin_p() { grep -v '^WORKTREE_PARENT_DIR=' .claude/skills/worktree/worktree.env > "$T_TMP/we" && cp "$T_TMP/we" .claude/skills/worktree/worktree.env && git commit -qam u && git push -q origin main || exit 2; }
unpin_p
printf 'blocker\n' > "$FIX/primary-worktrees"
run bash "$B/worktree-create.sh" feat/blocked
expect 2 'FAIL config-parent-dir' "a default folder that cannot be made (a file is in the way) is exit 2"
check "and no branch was left behind" test -z "$(git for-each-ref refs/heads/feat/blocked)"
t_done
