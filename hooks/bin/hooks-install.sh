#!/usr/bin/env bash
# hooks-install.sh — install the hooks pack into the repository you run it from. Stays in the download; never
# installed. Needs jq (an install-time JSON merge).
#
#   bash <download>/hooks/bin/hooks-install.sh plan  --hooks <a,b,c> --settings <file> [--mode warn|enforce] [--update]
#        [--git-pre-commit]
#   bash <download>/hooks/bin/hooks-install.sh apply --hooks <a,b,c> --settings <file> [--mode warn|enforce] [--update]
#        [--git-pre-commit] --approved <hash>
#
#   --hooks            any of protected-file-guard, commit-check, pending-question-reprint, review-nudge
#                      (comma-separated). review-nudge needs the review-code and ship skills installed to do anything;
#                      in warn mode it only prints its reminder, in enforce mode it holds the stop once per session.
#   --settings         .claude/settings.json (committed, shared with the team) or .claude/settings.local.json (this
#                      machine only)
#   --mode             warn or enforce, written as HOOKS_MODE in .claude/hooks/hooks.env. warn: the guard and the commit
#                      check never ask or refuse, they allow and print what they would have done ("warn-only: ...");
#                      the settings files are still asked about. enforce: the normal behaviour. Without --mode the
#                      repository keeps the mode it has (enforce when hooks.env has none). The mode is in the plan and
#                      its hash. Switching on = the same plan and apply with --mode enforce. In warn mode the handlers
#                      are written without onFailure (a crash or timeout lets the call through) and the git pre-commit
#                      line warns instead of refusing; an explicit --mode re-registers the pack's handlers (no --update
#                      needed).
#   --update           replace installed scripts that differ from the download, and re-register the pack's own
#                      handlers when their wanted form changed. Without it a differing script is kept and reported.
#   --git-pre-commit   also install a git-native pre-commit hook that runs the same commit check (needs commit-check).
#                      Never overwrites an existing pre-commit hook, and is skipped when core.hooksPath is set; the
#                      plan then prints the line to add by hand.
#   --no-subagent-model
#                      do not set the default subagent model. Without it, the plan also sets ONE key outside the hooks
#                      block, env.CLAUDE_CODE_SUBAGENT_MODEL = "sonnet" (the mid tier), and only when the settings file
#                      does not set that key already (any value is kept, never overwritten; an env that is not an
#                      object is left alone and named). Why: a subagent dispatched without an explicit model otherwise
#                      runs on the session's model, usually the strongest and costliest tier, and ad-hoc subagents are
#                      the bulk of dispatches; an agent or dispatch that needs a higher tier still names it. The key is
#                      in the settings diff and the hashed plan like every handler.
#
# `plan` writes nothing. It prints the files it would copy (new / identical / differs), the handlers it would add, a
# unified diff of the settings file before and after, and two checked invariants: nothing outside the "hooks" block
# changes except that one key (added, never changed or removed), and every handler that is not the pack's is still present, in order (both compared as jq reads the file:
# the plan says so when the file is rewritten). With the commit check ticked it prints the COMMIT_CHECK_CMD that will
# run. Last line: `HOOKS-RESULT hooks-install PLAN hash=<h>`. `apply` recomputes the same plan and refuses unless its
# hash equals --approved: what is applied is exactly what was shown (the command included). The previous settings file
# is saved under the git directory (`git rev-parse --git-path hooks-install`), not in the tree; an existing settings
# file is written through (a symlink stays a symlink, the file keeps its mode).
# Blockers: the protected list missing, or spelled in a way the guard would refuse (checked with hook-lib.sh's own
# loader, so the plan fails where the guard would ask on every call); hooks.env malformed; COMMIT_CHECK_TIMEOUT_SECS
# not a whole number of seconds, 1 or more (base 10), with the commit check ticked.
# With --settings .claude/settings.local.json and that file not ignored by git, the plan prints the line to add to the
# repository's info/exclude file (outside the hashed plan). With --settings .claude/settings.json and that file ignored by
# git, the plan prints a WARNING naming the ignore rule and the lines that un-ignore it (the `dir/*` form when the whole
# .claude folder is ignored), also outside the hash; the installer writes nothing outside the settings file, the
# hooks folder and, with --git-pre-commit, the pre-commit hook.
# The handler's "onFailure": "block" is written only when `claude --version` is 2.1.295 or later; otherwise it is left
# out (an older harness's handling of the key is not documented) and the plan says that a crash of the guard (and of
# the commit check, when wired) lets the call through, until the harness is updated and the plan is run again.
#
# Exit: 0 plan printed / applied · 1 blocker (the plan names it; nothing written) · 2 usage, no jq, not a git work
# tree, a settings file that is not valid JSON · 4 the plan changed since it was approved (show it again).

set -u
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 2
. "$SRC/hook-lib.sh" || exit 2
ONFAILURE_MIN=2.1.295
PACK="protected-file-guard commit-check pending-question-reprint review-nudge"

result() { echo "HOOKS-RESULT hooks-install $*"; }
usage() { echo "usage: hooks-install.sh plan|apply --hooks <a,b,c> --settings .claude/settings.json|.claude/settings.local.json [--mode warn|enforce] [--update] [--git-pre-commit] [--no-subagent-model] [--approved <hash>]" >&2; result "FAIL usage${1:+ $1}"; exit 2; }

ACTION="${1:-}"; shift 2>/dev/null || true
case "$ACTION" in plan|apply) ;; *) usage ;; esac
HOOKS=""; SETTINGS=""; UPDATE=0; GITPC=0; APPROVED=""; WANTMODE=""; SUBMODEL=1
SUBMODEL_KEY=CLAUDE_CODE_SUBAGENT_MODEL; SUBMODEL_VALUE=sonnet
while [ "$#" -gt 0 ]; do
  case "$1" in
    --hooks) [ "$#" -ge 2 ] || usage; HOOKS="$2"; shift 2 ;;
    --mode) [ "$#" -ge 2 ] || usage; case "$2" in warn|enforce) WANTMODE="$2" ;; *) usage "mode-must-be-warn-or-enforce" ;; esac; shift 2 ;;
    --settings) [ "$#" -ge 2 ] || usage; SETTINGS="$2"; shift 2 ;;
    --approved) [ "$#" -ge 2 ] || usage; APPROVED="$2"; shift 2 ;;
    --update) UPDATE=1; shift ;;
    --git-pre-commit) GITPC=1; shift ;;
    --no-subagent-model) SUBMODEL=0; shift ;;
    *) usage "unknown-argument" ;;
  esac
done
case "$SETTINGS" in .claude/settings.json|.claude/settings.local.json) ;; *) usage "settings-must-be-.claude/settings.json-or-.claude/settings.local.json" ;; esac
[ -n "$HOOKS" ] || usage "no-hooks"
TICKED=""
for h in $(printf '%s' "$HOOKS" | tr ',' ' '); do
  case " $PACK " in *" $h "*) ;; *) usage "unknown-hook-$h" ;; esac
  case " $TICKED " in *" $h "*) ;; *) TICKED="$TICKED $h" ;; esac
done
TICKED="${TICKED# }"
if [ "$GITPC" = 1 ]; then case " $TICKED " in *" commit-check "*) ;; *) usage "git-pre-commit-needs-commit-check" ;; esac; fi
[ "$ACTION" = plan ] || [ -n "$APPROVED" ] || usage "apply-needs-approved-hash"
command -v jq >/dev/null 2>&1 || { echo "jq is required to merge the settings file. Install jq, or wire the handlers by hand (the plan's handler list) and check with hooks-check.sh." >&2; result "FAIL no-jq"; exit 2; }
TOP="$(hk_toplevel "$PWD")" || { echo "run this from inside the repository to install into" >&2; result "FAIL not-a-repository"; exit 2; }
cd "$TOP" || exit 2

# Where Claude Code reads the file: .claude/settings.json from the folder a session starts in; .claude/settings.local.json
# from the repository root, and in a worktree from the main checkout's root (Claude Code's settings documentation).
SPATH="$SETTINGS"; LOCAL_NOTE=""
if [ "$SETTINGS" = .claude/settings.local.json ]; then
  CDIR="$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)" || { result "FAIL git-unreadable"; exit 2; }
  if [ "$(git -C "$CDIR" rev-parse --is-bare-repository 2>/dev/null)" = true ]; then
    LOCAL_NOTE="Note: this repository's worktrees share a bare repository, and which settings.local.json Claude Code reads for a worktree of a bare repository is not documented. It is written here, in this worktree's top folder; check with /status in a session that it loaded."
  else
    MR="$(dirname "$CDIR")"
    if [ "$(basename "$CDIR")" != .git ]; then
      # A submodule or a --separate-git-dir repository: the git directory's parent is not a checkout.
      LOCAL_NOTE="Note: this repository's git directory ($CDIR) is not a .git folder at a checkout's root (a submodule or a separate git directory), and which settings.local.json Claude Code reads then is not documented. It is written here, in this checkout's top folder; check with /status in a session that it loaded."
    else
      if [ "$MR" != "$TOP" ]; then SPATH="$MR/.claude/settings.local.json"; fi
      LOCAL_NOTE="Note: settings.local.json is read from the main checkout's root ($MR) for every session in this repository, worktrees and subfolders included, so it is written there."
    fi
  fi
fi

# A machine-only settings file that git does not ignore would be committed by the next `git add -A`. The plan names
# the line to add; it is printed outside the hashed plan (adding the line between plan and apply changes nothing).
XNOTE=""
if [ "$SETTINGS" = .claude/settings.local.json ]; then
  SROOT="$TOP"; case "$SPATH" in /*) SROOT="$(dirname "$(dirname "$SPATH")")" ;; esac
  git -C "$SROOT" check-ignore -q .claude/settings.local.json 2>/dev/null; irc=$?
  if [ "$irc" -eq 1 ]; then
    XF="$(git -C "$SROOT" rev-parse --git-path info/exclude 2>/dev/null)" && case "$XF" in /*|[A-Za-z]:[/\\]*) ;; *) XF="$SROOT/$XF" ;; esac
    XNOTE="Note: $SROOT/.claude/settings.local.json is not ignored by git, so a \`git add -A\` would commit this machine-only file. To keep it out of git, add this line to ${XF:-.git/info/exclude} (the installer does not write it): /.claude/settings.local.json"
  fi
else
  # The shared file is meant to be committed: a git-ignored one would silently stay on this machine.
  # -q decides (a tracked file, or one a '!' line re-includes, is not ignored); -v only names the rule.
  if git check-ignore -q .claude/settings.json 2>/dev/null; then
    IGN="$(git check-ignore -v .claude/settings.json 2>/dev/null)"
    RULE="$(printf '%s' "$IGN" | cut -f1)"
    if git check-ignore -q .claude/ 2>/dev/null; then
      # The folder itself is ignored: a '!' line cannot reach into it, so the folder line becomes a contents line.
      FIXL="change that line so it ignores the folder's contents, not the folder (for example '.claude/' becomes '.claude/*'), then add '!/.claude/settings.json' and '!/.claude/hooks/' below it"
    else
      FIXL="add '!/.claude/settings.json' and '!/.claude/hooks/' below that line"
    fi
    XNOTE="WARNING: .claude/settings.json is ignored by git ($RULE), so the hooks wired into it would stay on this machine and never reach the team. To commit it, $FIXL; or wire into .claude/settings.local.json instead (the installer does not change ignore rules)."
  fi
fi

W="$(mktemp -d "${TMPDIR:-/tmp}/hooksinstall.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT
BODY="$W/body"; : > "$BODY"
say() { printf '%s\n' "$*" >> "$BODY"; }
BLOCK=""

# --- files -------------------------------------------------------------------------------------------------------
say "Install into: $HOOKS_DIR_REL/ of this repository"
say "Files:"
COPY=""; KEPT=""
for f in $(for h in $TICKED; do echo "$h.sh"; done) hook-lib.sh hooks-check.sh; do
  dst="$HOOKS_DIR_REL/$f"
  if [ ! -f "$dst" ]; then say "  new        $dst"; COPY="$COPY $f"
  elif cmp -s "$SRC/$f" "$dst"; then say "  identical  $dst"
  elif [ "$UPDATE" = 1 ]; then say "  replace    $dst (differs from the download; --update)"; COPY="$COPY $f"
  else say "  KEPT       $dst differs from the download: a fix not yet taken, or a local edit to move into hooks.env. Run the plan with --update to replace it."; KEPT="$KEPT $f"; fi
done
# A script copied beside a kept, different hook-lib.sh would run the download's code on an older library.
if [ -n "$COPY" ]; then case " $KEPT " in *" hook-lib.sh "*)
  say "  BLOCKER    $HOOKS_DIR_REL/hook-lib.sh is kept while other scripts are copied from the download: they would run on a library that differs from theirs. Run the plan with --update."; BLOCK="$BLOCK mixed-pack-version" ;;
esac; fi
ENV="$HOOKS_ENV_REL"
if [ -f "$ENV" ]; then
  say "  kept       $ENV (this repository's values)"
  hk_kv_get "$ENV" PROTECTED_FILES_FILE >/dev/null 2>&1; [ $? -eq 2 ] && BLOCK="$BLOCK $ENV-malformed"
  for k in $HOOKS_ENV_KEYS; do hk_kv_get "$ENV" "$k" >/dev/null 2>&1; [ $? -eq 1 ] && say "             $ENV has no $k line: add it by hand from hooks.env.example"; done
else
  say "  new        $ENV (from hooks.env.example; fill it in before wiring)"
fi
# Mode: --mode, else the mode this repository already has (so a `plan --update` without --mode never switches a warn
# install on), else enforce. Its line is in the hashed plan, with the current value: a different mode is another hash.
CURMODE=absent
if [ -f "$ENV" ]; then cm="$(hk_kv_get "$ENV" HOOKS_MODE 2>/dev/null)" && CURMODE="${cm:-empty}"; fi
NEWMODE="$WANTMODE"
[ -n "$NEWMODE" ] || NEWMODE="$( [ -f "$ENV" ] && hk_mode "$TOP" || echo enforce)"
MODE_WRITE=1; [ "$CURMODE" = "$NEWMODE" ] && MODE_WRITE=0
if [ "$NEWMODE" = warn ]; then
  say "Mode: warn (HOOKS_MODE=warn in $ENV; now: $CURMODE). The hooks never ask or refuse: they allow and print what they would have done, prefixed warn-only:. Still asked: .claude/settings.json and .claude/settings.local.json. Switch on later with this same install run with --mode enforce (plan, then apply)."
else
  say "Mode: enforce (HOOKS_MODE=enforce in $ENV; now: $CURMODE). The hooks ask and refuse as documented."
fi
LIST="$HOOKS_LIST_DEFAULT"
if [ -f "$ENV" ]; then v="$(hk_kv_get "$ENV" PROTECTED_FILES_FILE 2>/dev/null)" && [ -n "$v" ] && LIST="$v"; fi
case " $TICKED " in *" protected-file-guard "*)
  if [ -f "$LIST" ]; then
    say "  kept       $LIST (the protected list: $(grep -c -v -E '^[[:space:]]*(#|$)' "$LIST") globs)"
    # Load it the way the guard will (hook-lib.sh from this download): a spelling it rejects makes it ask on every call.
    if [ -f "$ENV" ]; then hk_load_list "$TOP"; lrc=$?
    else   # hooks.env is new: the guard will read it as copied from hooks.env.example
      V="$W/listcheck"; mkdir -p "$V/$HOOKS_DIR_REL" "$V/$(dirname "$LIST")" && cp "$SRC/hooks.env.example" "$V/$HOOKS_ENV_REL" && cp "$LIST" "$V/$LIST" || exit 2
      hk_load_list "$V"; lrc=$?
    fi
    if [ "$lrc" -eq 2 ]; then say "  BLOCKER    the guard would refuse this list and ask on every call: $HK_ERR"; BLOCK="$BLOCK list-broken"; fi
  else say "  BLOCKER    $LIST is missing: write the protected list first (one glob per line), or every edit would be asked about"; BLOCK="$BLOCK list-missing"; fi ;;
esac
case " $TICKED " in *" commit-check "*)
  c=""; [ -f "$ENV" ] && { c="$(hk_kv_get "$ENV" COMMIT_CHECK_CMD 2>/dev/null)" || c=""; }
  if [ -n "$c" ]; then say "Commit check: before each commit the agent makes, this runs from the repository's top level: $c"
  else say "Commit check: COMMIT_CHECK_CMD is empty, so nothing is checked until it is set in $ENV"; fi ;;
esac

# --- handlers ------------------------------------------------------------------------------------------------------
CV="$(claude --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
newer() {  # newer <a> <b>: 0 when a >= b
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]
}
# The PreToolUse hooks onFailure applies to (the reprint is a Stop hook: onFailure has no effect there).
GUARDS=""
case " $TICKED " in *" protected-file-guard "*) GUARDS="the protected-file guard" ;; esac
case " $TICKED " in *" commit-check "*) GUARDS="${GUARDS:+$GUARDS or }the commit check" ;; esac
ONF=1
if [ "$NEWMODE" = warn ]; then ONF=0; [ -z "$GUARDS" ] || say "onFailure: left out (warn mode). A crash or timeout of $GUARDS lets the call through; switching to --mode enforce writes it back."
elif [ -z "$CV" ]; then ONF=0; [ -z "$GUARDS" ] || say "onFailure: left out (claude --version did not answer). A crash or timeout of $GUARDS lets the call through, until this plan is run again where claude answers $ONFAILURE_MIN or later."
elif ! newer "$CV" "$ONFAILURE_MIN"; then ONF=0; [ -z "$GUARDS" ] || say "onFailure: left out (Claude Code $CV is older than $ONFAILURE_MIN). A crash or timeout of $GUARDS lets the call through, until the harness is updated and this plan is run again."
else [ -z "$GUARDS" ] || say "onFailure: block (Claude Code $CV): a crash or timeout of $GUARDS blocks the call."; fi
TO=70
if [ -f "$ENV" ]; then
  t="$(hk_kv_get "$ENV" COMMIT_CHECK_TIMEOUT_SECS 2>/dev/null)" || t=""
  tbad=""
  case "$t" in
    '') ;;
    *[!0-9]*) tbad="'$t', not a whole number of seconds" ;;
    ???????*) tbad="'$t', more than six digits" ;;
    *) if [ "$((10#$t))" -eq 0 ]; then tbad="0 (it must be 1 or more)"; else TO=$((10#$t + 10)); fi ;;   # base 10: 08 is not octal
  esac
  case " $TICKED " in *" commit-check "*)
    if [ -n "$tbad" ]; then say "  BLOCKER    COMMIT_CHECK_TIMEOUT_SECS in $ENV is $tbad: the commit check would refuse every commit. Fix it, then plan again."; BLOCK="$BLOCK timeout-invalid"; fi ;;
  esac
fi

OLD="$W/old.json"; NEW="$W/new.json"
if [ -f "$SPATH" ]; then
  jq -e 'type == "object" and ((.hooks // {}) | type == "object" and all(.[]; type == "array" and all(.[]; type == "object" and ((.hooks // []) | type == "array"))))' "$SPATH" >/dev/null 2>&1 || { echo "$SPATH is not a valid JSON object, or its hooks key is not an object of arrays of handler groups; nothing was written. Fix it by hand, then plan again." >&2; result "FAIL settings-unparseable"; exit 2; }
  jq --indent 2 . "$SPATH" > "$OLD" || exit 2
else
  echo '{}' > "$OLD"
fi
cp "$OLD" "$NEW" || exit 2
[ -z "$LOCAL_NOTE" ] || say "$LOCAL_NOTE"
say "Handlers ($SPATH):"
for h in $TICKED; do
  p="$HOOKS_DIR_REL/$h.sh"
  grp="$(jq -c --arg h "$h" --argjson onf "$ONF" --argjson to "$TO" '
      .[$h] as $d | ($d.handler
        | (if $h == "commit-check" then .timeout = $to else . end)
        | (if $onf == 0 then del(.onFailure) else . end)) as $hd
      | {event: $d.event, group: ((if $d.matcher then {matcher: $d.matcher} else {} end) + {hooks: [$hd]})}' "$SRC/settings.fragment.json")" \
    || { result "FAIL fragment-unreadable"; exit 2; }
  ev="$(printf '%s' "$grp" | jq -r .event)"
  # Compared with its event and matcher: a handler registered under another event or matcher is "another form".
  have="$(jq -c --arg p "$p" '[(.hooks // {}) | to_entries[] | .key as $e | .value[]? | (.matcher // null) as $m | .hooks[]? | select((.command // "") | contains($p)) | {e: $e, m: $m, h: .}]' "$NEW")" || { result "FAIL settings-unreadable"; exit 2; }
  want="$(printf '%s' "$grp" | jq -c '[{e: .event, m: (.group.matcher // null), h: .group.hooks[0]}]')" || { result "FAIL fragment-unreadable"; exit 2; }
  # An explicit --mode re-registers the pack's handler like --update (the mode decides onFailure).
  if [ "$have" != "[]" ] && [ "$UPDATE" = 0 ] && [ -z "$WANTMODE" ]; then
    if [ "$have" = "$want" ]; then say "  already wired  $h"; else say "  already wired  $h (in another form than the download's: plan with --update to re-register it)"; fi
    continue
  fi
  if [ "$have" = "$want" ]; then say "  already wired  $h"; continue; fi
  if [ "$have" != "[]" ]; then
    jq --indent 2 --arg p "$p" '.hooks |= with_entries(.value |= (map(.hooks |= map(select(((.command // "") | contains($p)) | not))) | map(select((.hooks | length) > 0))))' "$NEW" > "$W/t" && mv "$W/t" "$NEW" || exit 2
    say "  re-register    $h ($ev): its old entry is removed and the download's added"
    say "                 (--update removes every handler whose command contains $p, a wrapper of your own included)"
  else
    say "  add            $h ($ev$(printf '%s' "$grp" | jq -r 'if .group.matcher then ", matcher " + .group.matcher else "" end'))"
  fi
  jq --indent 2 --argjson g "$grp" '.hooks[$g.event] = ((.hooks[$g.event] // []) + [$g.group])' "$NEW" > "$W/t" && mv "$W/t" "$NEW" || exit 2
done

# The default subagent model: one key outside "hooks", added only when absent.
if [ "$SUBMODEL" = 0 ]; then
  say "Subagent model: not set (--no-subagent-model)."
elif ! jq -e '(.env // {}) | type == "object"' "$NEW" >/dev/null 2>&1; then
  say "Subagent model: not set: \"env\" in $SETTINGS is not an object, so it is left as it is."
elif jq -e --arg k "$SUBMODEL_KEY" '(.env // {}) | has($k)' "$NEW" >/dev/null 2>&1; then
  say "Subagent model: kept env.$SUBMODEL_KEY = $(jq -c --arg k "$SUBMODEL_KEY" '.env[$k]' "$NEW") (already set in $SETTINGS; never overwritten)."
else
  jq --indent 2 --arg k "$SUBMODEL_KEY" --arg v "$SUBMODEL_VALUE" '.env = ((.env // {}) + {($k): $v})' "$NEW" > "$W/t" && mv "$W/t" "$NEW" || exit 2
  say "Subagent model: sets env.$SUBMODEL_KEY = \"$SUBMODEL_VALUE\" in $SETTINGS (the mid tier): a subagent dispatched without a model then runs on it instead of the session's model; an agent or a dispatch that names a model still gets that one. Opt out: --no-subagent-model."
fi

# Invariants: nothing outside "hooks" changes except the subagent-model key, which may only be added (an existing value
# is never changed or removed); every handler that is not the pack's survives, in order.
OUTSIDE='del(.hooks) | if (.env | type) == "object" then (.env |= del(.[$k])) | (if .env == {} then del(.env) else . end) else . end'
same_outside="$( [ "$(jq -S -c --arg k "$SUBMODEL_KEY" "$OUTSIDE" "$OLD")" = "$(jq -S -c --arg k "$SUBMODEL_KEY" "$OUTSIDE" "$NEW")" ] \
  && { [ "$(jq -c --arg k "$SUBMODEL_KEY" '.env[$k]? // null' "$OLD")" = null ] \
       || [ "$(jq -c --arg k "$SUBMODEL_KEY" '.env[$k]' "$OLD")" = "$(jq -c --arg k "$SUBMODEL_KEY" '.env[$k]' "$NEW")" ]; } && echo yes || echo NO)"
FOREIGN='[(.hooks // {}) | to_entries[] | .key as $e | .value[]? | (.matcher // "") as $m | .hooks[]? | select(((.command // "") | test("\\.claude/hooks/(protected-file-guard|commit-check|pending-question-reprint|review-nudge)\\.sh")) | not) | {e: $e, m: $m, h: .}]'
same_foreign="$( [ "$(jq -S -c "$FOREIGN" "$OLD")" = "$(jq -S -c "$FOREIGN" "$NEW")" ] && echo yes || echo NO)"
say "Invariants: everything outside \"hooks\" unchanged, except env.$SUBMODEL_KEY added when absent: $same_outside; every other handler still present, in order: $same_foreign"
[ "$same_outside" = yes ] && [ "$same_foreign" = yes ] || BLOCK="$BLOCK invariant-broken"
if [ -f "$SPATH" ] && ! cmp -s "$SPATH" "$OLD"; then say "Note: $SPATH is rewritten in jq's two-space layout. The diff below and the invariants above compare the file as jq reads it, not its bytes: a key that appears twice keeps only its last value, and a number too large for jq may be rounded, and neither would show here."; fi
say "Settings diff:"
if cmp -s "$OLD" "$NEW"; then say "  (no change)"
else diff -u --label "a/$SETTINGS" --label "b/$SETTINGS" "$OLD" "$NEW" >> "$BODY"; fi

# --- git-native pre-commit ------------------------------------------------------------------------------------------
# Like the harness handler: where the pack is absent (a branch from before the install) the check is off, not a
# refusal of every commit; a missing script with COMMIT_CHECK_CMD still set refuses.
PC_LINE='d="$(git rev-parse --show-toplevel)"; f="$d/.claude/hooks/commit-check.sh"; if [ -f "$f" ]; then exec bash "$f" --git-hook; fi; v="$(grep -E "^COMMIT_CHECK_CMD=" "$d/.claude/hooks/hooks.env" 2>/dev/null | tail -1)"; case "${v#COMMIT_CHECK_CMD=}" in *[![:space:]]*) if tr -d "\r" 2>/dev/null < "$d/.claude/hooks/hooks.env" | grep -qx "HOOKS_MODE=warn"; then echo "warn-only: would have refused this commit (enforce mode blocks it): hooks pack: $f is missing but hooks.env sets COMMIT_CHECK_CMD, so the check was not run" >&2; exit 0; fi; echo "hooks pack: $f is missing but hooks.env sets COMMIT_CHECK_CMD, so the check was not run: restore .claude/hooks, or reinstall" >&2; exit 1 ;; esac; echo "hooks pack: commit-check is not installed in this folder, so it is off here" >&2'
PC_DO=0
if [ "$GITPC" = 1 ]; then
  HP="$(git config core.hooksPath 2>/dev/null)"
  PC="$(git rev-parse --git-path hooks/pre-commit)" || exit 2
  printf '#!/bin/sh\n# hooks-pack: the commit check, for commits made outside the agent too (installed by hooks-install.sh)\n%s\n' "$PC_LINE" > "$W/pre-commit"
  if [ -n "$HP" ]; then say "Git pre-commit: not installed (core.hooksPath is $HP: a hooks manager owns the hooks). Add this line to its pre-commit: $PC_LINE"
  elif [ -f "$PC" ] && cmp -s "$PC" "$W/pre-commit"; then say "Git pre-commit: identical  $PC"
  elif [ -f "$PC" ]; then say "Git pre-commit: not installed ($PC already exists and is not the pack's). Add this line to it: $PC_LINE"
  else say "Git pre-commit: new        $PC"; PC_DO=1; fi
fi

# The hash also covers what would be copied: a script changed in the download after the plan changes the hash.
say "Download content:"
for f in protected-file-guard.sh commit-check.sh pending-question-reprint.sh review-nudge.sh hook-lib.sh hooks-check.sh hooks.env.example settings.fragment.json; do
  say "  $(cksum < "$SRC/$f" | awk '{print $1 "-" $2}')  $f"
done
HASH="$(cksum < "$BODY" | awk '{print $1 "-" $2}')"
if [ "$ACTION" = plan ]; then
  cat "$BODY"
  [ -z "$XNOTE" ] || printf '%s\n' "$XNOTE"
  if [ -n "$BLOCK" ]; then result "FAIL blocker${BLOCK}"; exit 1; fi
  result "PLAN hash=$HASH"
  exit 0
fi

# --- apply -----------------------------------------------------------------------------------------------------------
if [ -n "$BLOCK" ]; then cat "$BODY"; result "FAIL blocker${BLOCK}"; exit 1; fi
if [ "$APPROVED" != "$HASH" ]; then
  echo "The plan for these arguments is not the one approved (approved $APPROVED, now $HASH): something changed. Run plan again and show it." >&2
  result "FAIL plan-changed"; exit 4
fi
mkdir -p "$HOOKS_DIR_REL" || { result "FAIL write-failed"; exit 1; }
for f in $COPY; do cp "$SRC/$f" "$HOOKS_DIR_REL/$f.tmp.$$" && mv -f "$HOOKS_DIR_REL/$f.tmp.$$" "$HOOKS_DIR_REL/$f" || { result "FAIL write-failed $f"; exit 1; }; done
[ -f "$ENV" ] || cp "$SRC/hooks.env.example" "$ENV" || { result "FAIL write-failed hooks.env"; exit 1; }
# The mode: the HOOKS_MODE line replaced (or added), every other line kept; written through like the settings file.
if [ "$MODE_WRITE" = 1 ] || [ "$(hk_kv_get "$ENV" HOOKS_MODE 2>/dev/null)" != "$NEWMODE" ]; then
  awk -v m="$NEWMODE" 'BEGIN { done = 0 } /^HOOKS_MODE=/ { if (!done) print "HOOKS_MODE=" m; done = 1; next } { print } END { if (!done) print "HOOKS_MODE=" m }' "$ENV" > "$W/env" \
    && cat "$W/env" > "$ENV" || { result "FAIL write-failed hooks.env (mode)"; exit 1; }
fi
if ! cmp -s "$OLD" "$NEW"; then
  BK="(no previous file)"
  if [ -f "$SPATH" ]; then
    BK="$(git rev-parse --git-path hooks-install)" && mkdir -p "$BK" && cp "$SPATH" "$BK/$(basename "$SPATH" .json).$(date +%Y%m%d%H%M%S).json" \
      || { result "FAIL backup-failed"; exit 1; }
  fi
  jq -e . "$NEW" >/dev/null || { result "FAIL write-failed $SPATH"; exit 1; }
  if [ -e "$SPATH" ] || [ -L "$SPATH" ]; then
    # Written through, after the backup: a symlinked settings file stays a symlink, and the file keeps its mode.
    cat "$NEW" > "$SPATH" || { result "FAIL write-failed $SPATH (the previous file is saved in $BK)"; exit 1; }
  else
    mkdir -p "$(dirname "$SPATH")" && cp "$NEW" "$SPATH.tmp.$$" && mv -f "$SPATH.tmp.$$" "$SPATH" \
      || { rm -f "$SPATH.tmp.$$"; result "FAIL write-failed $SPATH"; exit 1; }
  fi
fi
if [ "$PC_DO" = 1 ]; then
  mkdir -p "$(dirname "$PC")" && cp "$W/pre-commit" "$PC" && chmod +x "$PC" || { result "FAIL write-failed pre-commit"; exit 1; }
fi
echo "Applied. Next: bash $HOOKS_DIR_REL/hooks-check.sh (it also runs the wired guard handler); the live check is the first session started in the top folder afterwards."
result "PASS applied"
exit 0
