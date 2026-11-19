#!/usr/bin/env bash
# hooks-check.sh — is the installed hooks pack present, wired and answering as it should? Run at session start
# (`bash .claude/hooks/hooks-check.sh`) and at the end of the install. Read-only.
# hooks-pack: 1
#
# Checks the pack's own scripts only (protected-file-guard, commit-check, pending-question-reprint, review-nudge), for the
# repository this copy is installed in; hooks of your own are not checked here:
#   1. each installed pack script parses (`bash -n`) and carries the same pack version as hook-lib.sh;
#   2. hooks.env parses; the protected list loads (an empty list is reported, not failed);
#   3. each installed script is registered under its event in .claude/settings.json or .claude/settings.local.json,
#      no handler points at a pack script that is missing, and hooks are not switched off (disableAllHooks); with the
#      commit check installed, COMMIT_CHECK_TIMEOUT_SECS is a whole number of seconds, 1 or more (base 10), and the
#      handler's timeout allows for it;
#   4. synthetic inputs give the expected answers: an Edit of a protected file → "ask", a read of it → allowed, an
#      unlisted file → allowed; `git status` → commit check silent; a Stop with no question → reprint silent; a Stop
#      with stop_hook_active → review-nudge silent.
# Warn mode is reported as a NOTE, never a FAIL (the install itself runs in warn mode and must pass): it names what is
# not enforced and the command that switches it on, so the follow-up stays visible at every session start.
# This does not prove the harness runs the hooks: only a live probe in a session does. Claude Code reads
# .claude/settings.json from the folder a session starts in, and .claude/settings.local.json from the repository root
# (in a worktree, the main checkout's root); both files are checked here.
#
# Output: one line per finding, then `HOOKS-RESULT hooks-check PASS verified hooks=<n>` (exit 0) or
# `HOOKS-RESULT hooks-check FAIL <reason>` (exit 1). Exit 3 when a settings file cannot be read.

set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || exit 2
. "$HOOK_DIR/hook-lib.sh" || { echo "HOOKS-RESULT hooks-check FAIL hook-lib-missing"; exit 1; }

PACK="protected-file-guard commit-check pending-question-reprint review-nudge"
event_of() { case "$1" in pending-question-reprint|review-nudge) echo Stop ;; *) echo PreToolUse ;; esac; }
tools_of() { case "$1" in protected-file-guard) echo "Edit Write NotebookEdit Bash" ;; commit-check) echo Bash ;; *) echo "" ;; esac; }
# uncovered <matcher> <tools>: prints the tools the matcher does not match ('' and '*' match every tool).
uncovered() { case "$1" in ''|'*') return 0 ;; esac; for t in $2; do printf '%s\n' "$t" | grep -Eqx "($1)" 2>/dev/null || printf ' %s' "$t"; done; }
FAILS=""
fail() { echo "FAIL: $2"; FAILS="${FAILS:-$1}"; }
note() { echo "NOTE: $1"; }
ok() { echo "ok: $1"; }

TOP="$(hk_toplevel "$HOOK_DIR")" || { echo "HOOKS-RESULT hooks-check FAIL not-in-a-repository"; exit 1; }
case "$HOOK_DIR" in "$TOP/$HOOKS_DIR_REL") ;; *) note "running from $HOOK_DIR, not $TOP/$HOOKS_DIR_REL: checking the copy in $TOP/$HOOKS_DIR_REL" ;; esac
HD="$TOP/$HOOKS_DIR_REL"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/hookscheck.XXXXXX")" || exit 2
trap 'rm -rf "$TMPD"' EXIT

# 1. Scripts.
INSTALLED=""
for h in $PACK; do
  f="$HD/$h.sh"
  [ -f "$f" ] || continue
  INSTALLED="$INSTALLED $h"
  if ! bash -n "$f" 2>/dev/null; then fail script-broken "$h.sh does not parse (bash -n)"; continue; fi
  v="$(sed -n 's/^# hooks-pack: \([0-9][0-9]*\)$/\1/p' "$f" | head -1)"
  [ "$v" = "$HOOKS_PACK_VERSION" ] || fail version-mismatch "$h.sh is pack version '${v:-none}', hook-lib.sh is $HOOKS_PACK_VERSION: reinstall both from one download"
done
INSTALLED="${INSTALLED# }"
[ -n "$INSTALLED" ] || { echo "HOOKS-RESULT hooks-check FAIL no-hooks-installed"; exit 1; }
ok "installed: $INSTALLED"
note "only the pack's own scripts are checked here, not hooks of your own"

# 2. Configuration.
ENV="$TOP/$HOOKS_ENV_REL"
if [ ! -f "$ENV" ]; then
  fail config-missing "$HOOKS_ENV_REL is missing: every hook treats this repository as not governed"
else
  hk_kv_get "$ENV" PROTECTED_FILES_FILE >/dev/null; [ $? -eq 2 ] && fail config-malformed "$HOOKS_ENV_REL is malformed"
  for k in $HOOKS_ENV_KEYS; do
    hk_kv_get "$ENV" "$k" >/dev/null 2>&1; [ $? -eq 1 ] && note "$HOOKS_ENV_REL has no $k line (the download's hooks.env.example documents it)"
  done
fi
HMODE=enforce
if [ -f "$ENV" ]; then
  mv_="$(hk_kv_get "$ENV" HOOKS_MODE 2>/dev/null)" || mv_=""
  case "$mv_" in
    ''|enforce) ok "mode: enforce (the guard asks, the commit check refuses)" ;;
    warn) HMODE=warn; note "mode: warn — NOT ENFORCED: the guard and the commit check allow and print what they would have done, and review-nudge only prints its reminder (the settings files are still asked about). This is the first-install setting, a follow-up to switch on, not the end state. Switch on: bash <download>/hooks/bin/hooks-install.sh plan --hooks <the installed hooks> --settings <your settings file> --mode enforce, show the plan, then apply it with --approved <hash>" ;;
    *) fail mode-invalid "HOOKS_MODE in $HOOKS_ENV_REL is '$mv_', not warn or enforce (the hooks treat it as enforce)" ;;
  esac
fi
case " $INSTALLED " in *" protected-file-guard "*)
  hk_load_list "$TOP"
  case $? in
    0) n="$(grep -c -v -E '^[[:space:]]*(#|$)' "$TOP/$HK_LIST_REL")"
       if [ "$n" -eq 0 ]; then note "guard installed, the list is empty: protected are only the always-protected files (the hooks folder, $HK_LIST_REL, .claude/settings.json and .claude/settings.local.json; and, while this repository is governed, any .claude/settings.json or .claude/settings.local.json a file tool targets, wherever it is)"
       else ok "protected list $HK_LIST_REL: $n globs"; fi ;;
    1) : ;;
    *) fail list-broken "$HK_ERR" ;;
  esac ;;
esac
case " $INSTALLED " in *" commit-check "*)
  c="$(hk_kv_get "$ENV" COMMIT_CHECK_CMD 2>/dev/null)" || c=""
  if [ -n "$c" ]; then ok "commit check: $c"; else note "commit check installed but COMMIT_CHECK_CMD is empty: not configured, nothing is checked"; fi ;;
esac

# 3. Registration.
WIRED="$TMPD/wired"; : > "$WIRED"
# Claude Code reads settings.local.json from the main checkout's root, also in a worktree (its settings documentation).
MAINROOT="$TOP"
CDIR="$(cd "$TOP" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" \
  && [ "$(git -C "$CDIR" rev-parse --is-bare-repository 2>/dev/null)" = false ] && [ "$(basename "$CDIR")" = .git ] \
  && MAINROOT="$(dirname "$CDIR")"   # a submodule or a separate git directory: its parent is not a checkout
SEEN_S=""   # one settings file per line (a path may contain spaces)
for sf in "$TOP/.claude/settings.json" "$TOP/.claude/settings.local.json" "$MAINROOT/.claude/settings.local.json"; do
  [ -f "$sf" ] || continue
  case "
$SEEN_S" in *"
$sf
"*) continue ;; esac
  SEEN_S="$SEEN_S$sf
"
  s="$sf"; [ "$MAINROOT" = "$TOP" ] && s="${sf#"$TOP"/}"
  if command -v jq >/dev/null 2>&1; then
    jq -e . "$sf" >/dev/null 2>&1 || { echo "FAIL: $s is not valid JSON"; echo "HOOKS-RESULT hooks-check FAIL settings-unreadable"; exit 3; }
    [ "$(jq -r '.disableAllHooks // false' "$sf")" = true ] && fail hooks-disabled "$s sets disableAllHooks: no hook runs"
    jq -r --arg s "$s" '(.hooks // {}) | to_entries[] | .key as $e | .value[]? | (.matcher // "") as $m | .hooks[]? | select(.command != null) | "\($e)\t\(.command)\t\($s)\t\($m)"' "$sf" >> "$WIRED" \
      || { echo "HOOKS-RESULT hooks-check FAIL settings-unreadable"; exit 3; }
  else
    note "no jq: registration read by name only from $s"
    grep -q '"disableAllHooks"[[:space:]]*:[[:space:]]*true' "$sf" && fail hooks-disabled "$s sets disableAllHooks: no hook runs"
    for h in $PACK; do grep -q "$HOOKS_DIR_REL/$h\.sh" "$sf" && printf '%s\t%s\t%s\t?\n' "$(event_of "$h")" "$HOOKS_DIR_REL/$h.sh" "$s" >> "$WIRED"; done
  fi
done
for h in $PACK; do
  line="$(grep -F "$HOOKS_DIR_REL/$h.sh" "$WIRED" | head -1)"
  case " $INSTALLED " in
    *" $h "*)
      if [ -z "$line" ]; then fail not-wired "$h.sh is installed but no settings file registers it"
      elif [ "$(printf '%s' "$line" | cut -f1)" != "$(event_of "$h")" ]; then fail wrong-event "$h.sh is registered under $(printf '%s' "$line" | cut -f1), not $(event_of "$h")"
      elif m="$(printf '%s' "$line" | cut -f4)" && [ "$m" != "?" ] && [ -n "$(uncovered "$m" "$(tools_of "$h")")" ]; then
        fail wrong-matcher "$h.sh is registered with matcher '$m', which misses:$(uncovered "$m" "$(tools_of "$h")"). Run the download's hooks/bin/hooks-install.sh plan --update and apply it."
      else ok "$h.sh wired under $(event_of "$h") in $(printf '%s' "$line" | cut -f3)"; fi ;;
    *) [ -z "$line" ] || fail wired-but-missing "a handler runs $HOOKS_DIR_REL/$h.sh, which is not installed: every call it matches fails" ;;
  esac
done

# The commit check's handler timeout is written at install from COMMIT_CHECK_TIMEOUT_SECS + 10; a later change to the
# key leaves the harness killing the hook first (which, with onFailure block, refuses every commit).
want=60
if [ -f "$ENV" ]; then
  w="$(hk_kv_get "$ENV" COMMIT_CHECK_TIMEOUT_SECS 2>/dev/null)" || w=""
  case "$w" in
    '') ;;
    *[!0-9]*) want=""; case " $INSTALLED " in *" commit-check "*) fail timeout-invalid "COMMIT_CHECK_TIMEOUT_SECS in $HOOKS_ENV_REL is '$w', not a whole number of seconds: the commit check refuses every commit" ;; esac ;;
    ???????*) want=""; case " $INSTALLED " in *" commit-check "*) fail timeout-invalid "COMMIT_CHECK_TIMEOUT_SECS in $HOOKS_ENV_REL is '$w', more than six digits" ;; esac ;;
    *) want=$((10#$w))   # base 10: a leading zero (08) is not octal
       if [ "$want" -eq 0 ]; then want=""; case " $INSTALLED " in *" commit-check "*) fail timeout-invalid "COMMIT_CHECK_TIMEOUT_SECS in $HOOKS_ENV_REL is 0: the commit check refuses every commit (it must be 1 or more)" ;; esac; fi ;;
  esac
fi
if command -v jq >/dev/null 2>&1 && [ -f "$ENV" ] && [ -n "$want" ]; then
  while IFS= read -r sf; do
    [ -n "$sf" ] || continue
    got="$(jq -r '[(.hooks.PreToolUse // [])[] | .hooks[]? | select((.command // "") | contains(".claude/hooks/commit-check.sh")) | .timeout // empty] | first // empty' "$sf" 2>/dev/null)"
    case "$got" in ''|*[!0-9]*|???????????*) continue ;; esac
    if [ "$((10#$got))" -lt $((want + 10)) ]; then
      fail timeout-mismatch "the commit check's handler timeout is ${got}s but COMMIT_CHECK_TIMEOUT_SECS is ${want}s: the harness would stop it first. Run the download's hooks/bin/hooks-install.sh plan --update and apply it."
    fi
  done <<EOF_S
$SEEN_S
EOF_S
fi

# 4. Probes.
probe() {  # probe <script> <json> — sets P_RC, P_OUT
  P_OUT="$(printf '%s' "$2" | PENDING_QUESTIONS_DIR="$TMPD/pq" bash "$HD/$1.sh" 2>&1)"; P_RC=$?
}
J() { printf '%s' "$1" | hk_json_escape; }
case " $INSTALLED " in *" protected-file-guard "*)
  if [ "$HMODE" = warn ]; then
    probe protected-file-guard "{\"tool_name\":\"Edit\",\"permission_mode\":\"default\",\"cwd\":\"$(J "$TOP")\",\"tool_input\":{\"file_path\":\"$(J "$TOP/$HOOKS_ENV_REL")\"}}"
    case "$P_RC:$P_OUT" in
      *permissionDecision*) fail probe-guard "warn mode, but the guard answered a decision for an edit of $HOOKS_ENV_REL (rc=$P_RC): $P_OUT" ;;
      0:*warn-only:*) ok "guard (warn mode) allows an edit of $HOOKS_ENV_REL and prints what it would have asked" ;;
      *) fail probe-guard "warn mode, but the guard did not warn about an edit of $HOOKS_ENV_REL (rc=$P_RC): $P_OUT" ;;
    esac
  fi
  PFILE="$HOOKS_ENV_REL"; [ "$HMODE" = warn ] && PFILE=.claude/settings.json
  probe protected-file-guard "{\"tool_name\":\"Edit\",\"permission_mode\":\"default\",\"cwd\":\"$(J "$TOP")\",\"tool_input\":{\"file_path\":\"$(J "$TOP/$PFILE")\"}}"
  case "$P_RC:$P_OUT" in *'"permissionDecision":"ask"'*) ok "guard asks before an edit of $PFILE" ;; *) fail probe-guard "guard did not ask before an edit of $PFILE (rc=$P_RC): $P_OUT" ;; esac
  probe protected-file-guard "{\"tool_name\":\"Edit\",\"permission_mode\":\"default\",\"cwd\":\"$(J "$TOP")\",\"tool_input\":{\"file_path\":\"$(J "$TOP/hooks-check-probe.unlisted")\"}}"
  if [ "$P_RC" = 0 ] && [ -z "$P_OUT" ]; then ok "guard allows an unlisted file"; else fail probe-guard "guard did not allow an unlisted file (rc=$P_RC): $P_OUT"; fi
  if [ "$(hk_parser)" = none ]; then note "no jq or python3: the guard asks before any command naming a protected file, reads included"
  else
    probe protected-file-guard "{\"tool_name\":\"Bash\",\"permission_mode\":\"default\",\"cwd\":\"$(J "$TOP")\",\"tool_input\":{\"command\":\"cat $HOOKS_ENV_REL\"}}"
    if [ "$P_RC" = 0 ] && [ -z "$P_OUT" ]; then ok "guard allows a read"; else fail probe-guard "guard did not allow a plain read (rc=$P_RC): $P_OUT"; fi
  fi
  # The registered handler itself, run the way the harness runs it (a shell, CLAUDE_PROJECT_DIR = this folder), so a
  # wiring string that cannot find the script fails here, offline, instead of at the first live session.
  wl="$(grep -F "$HOOKS_DIR_REL/protected-file-guard.sh" "$WIRED" | head -1)"
  if [ -n "$wl" ] && [ "$(printf '%s' "$wl" | cut -f4)" != "?" ]; then
    hc="$(printf '%s' "$wl" | cut -f2)"
    P_OUT="$(printf '%s' "{\"tool_name\":\"Edit\",\"permission_mode\":\"default\",\"cwd\":\"$(J "$TOP")\",\"tool_input\":{\"file_path\":\"$(J "$TOP/$PFILE")\"}}" \
      | (cd "$TOP" && CLAUDE_PROJECT_DIR="$TOP" bash -c "$hc") 2>&1)"; P_RC=$?
    case "$P_RC:$P_OUT" in
      *'protected-file guard script is missing'*) fail probe-wired "the registered guard handler did not find the guard script from $TOP: $P_OUT" ;;
      *'"permissionDecision":"ask"'*) ok "the registered guard handler, run as the harness runs it, asks before an edit of $PFILE" ;;
      *) fail probe-wired "the registered guard handler did not ask before an edit of $PFILE (rc=$P_RC): $P_OUT" ;;
    esac
  else note "the registered guard handler was not run: no wired line with a readable matcher (jq missing, or the guard is not wired); only the script was probed"; fi ;;
esac
case " $INSTALLED " in *" commit-check "*)
  probe commit-check "{\"tool_name\":\"Bash\",\"cwd\":\"$(J "$TOP")\",\"tool_input\":{\"command\":\"git status\"}}"
  if [ "$P_RC" = 0 ] && [ -z "$P_OUT" ]; then ok "commit check stays out of a non-commit command"; else fail probe-commit "commit check answered a non-commit command (rc=$P_RC): $P_OUT"; fi ;;
esac
case " $INSTALLED " in *" pending-question-reprint "*)
  probe pending-question-reprint '{"session_id":"hooks-check-probe"}'
  if [ "$P_RC" = 0 ] && [ -z "$P_OUT" ]; then ok "reprint is silent with no open question"; else fail probe-reprint "reprint answered with no open question (rc=$P_RC): $P_OUT"; fi ;;
esac
case " $INSTALLED " in *" review-nudge "*)
  probe review-nudge "{\"session_id\":\"hooks-check-probe\",\"cwd\":\"$(J "$TOP")\",\"stop_hook_active\":true}"
  if [ "$P_RC" = 0 ] && [ -z "$P_OUT" ]; then ok "review-nudge is silent on a repeated stop (stop_hook_active)"; else fail probe-nudge "review-nudge answered a repeated stop (rc=$P_RC): $P_OUT"; fi
  if [ ! -f "$TOP/.claude/skills/review-code/SKILL.md" ] || [ ! -f "$TOP/.claude/skills/ship/bin/ship-sentinel.sh" ]; then
    note "review-nudge installed, but the review-code or ship skill is not: it stays silent until both are installed"
  fi ;;
esac

if [ -n "$FAILS" ]; then echo "HOOKS-RESULT hooks-check FAIL $FAILS"; exit 1; fi
echo "HOOKS-RESULT hooks-check PASS verified hooks=$(printf '%s\n' $INSTALLED | grep -c .)"
exit 0
