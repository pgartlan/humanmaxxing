#!/usr/bin/env bash
# ship-lib.sh — shared helpers for every ship `bin/*.sh` script. SOURCED, never executed.
#
# Every script starts with:
#   LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ship-lib.sh"; source "$LIB" || { echo "ship-lib missing/broken" >&2; exit 2; }
#   ship_lib_init <script-name>
#
# Conventions this file owns:
#   - bash 3.2 clean (macOS /bin/bash): no `declare -A`, `mapfile`, `${v,,}`, `local -n`, `[[ -v`, `wait -n`.
#   - `set -u`; no `set -e`; no `pipefail`. Gate logic never pipes a producer into `grep -q` (SIGPIPE can
#     invert it on large input): capture first, then `case`.
#   - Exit codes: 0 proceed · 10 deliberate SKIP · 1 HALT · 2 usage/environment · 3 unreadable input or a
#     failed external read · 4 wait or resolve, never proceed (a result not in yet, a conflict to resolve) ·
#     9 contract or skill-text mismatch · >=5 gate-specific (named at the pointer).
#     The LAST stdout line of every script is `SHIP-RESULT <script> PASS|SKIP|FAIL|WAIT <reason> [k=v ...]`.
#   - State files are data: parsed with ship_kv_get or read line by line, never `source`d.
#   - Configuration comes from `ship.env` next to SKILL.md (key=value, written by onboarding), read with ship_cfg.

set -u

# ---------------------------------------------------------------------------------------------------------
# Contract check. Runs AT SOURCE TIME, before anything else in this file.
#
# SKILL.md carries `ship-contract: <N>` in its frontmatter and every bin/ pointer in it passes `--contract=<N>`
# as its FIRST argument. A rebase or pull can bring newer bin/ scripts than the SKILL.md text the model loaded;
# this check turns that skew into a loud stop (exit 9) instead of a script running against instructions it was
# not written for. Bump SKILL_CONTRACT in the same change that alters a pointer's arguments or a script's exit
# codes, and update the `ship-contract:` line with it.
#
#   * The first argument of the script that sources this file. `--contract=<N>` is STRIPPED from the caller's
#     positional parameters (this file is sourced with no arguments, so `shift` here shifts the CALLER's "$@").
#   * MANDATORY: a script run from a script file with no `--contract=` argument exits 9 (a missing contract is
#     a stale SKILL.md or a hand-typed pointer; fail closed).
#   * Script-to-script calls: after a successful check SHIP_CONTRACT_VERIFIED=<N> is exported; a child run
#     without the argument is accepted when it matches. An explicit argument always wins over the variable.
#   * Exit 9 is ALSO used for SKILL.md freshness: `skill-changed` (ship_lib_init, below) and
#     `skill-dir-mismatch` (ship-init.sh). All three mean "Read this worktree's SKILL.md from disk and resume".
#   * Not enforced when sourced from `bash -c` or an interactive shell (BASH_SOURCE[1] unset): how tests probe helpers.
#   * Scripts other skills may call without knowing the contract go in SKILL_OPTIONAL_SCRIPTS: they skip the
#     MISSING check; a wrong explicit number still fails.
# ---------------------------------------------------------------------------------------------------------
SKILL_CONTRACT=2
SKILL_OPTIONAL_SCRIPTS=" ship-log "

# The directory holding this file (the skill's `bin/`) and the skill directory above it.
SHIP_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SHIP_SKILL_DIR="$(cd "$SHIP_BIN/.." && pwd -P)"

# On Windows (Git for Windows' bash, Cygwin) a native jq.exe ends every output line with CRLF: a one-line answer, or the
# last tab-separated field, would carry the CR. Every jq call in the ship scripts goes through this wrapper there. @tsv
# escapes a CR inside a value, so a raw CR is only ever a line end. Only when a jq is installed: the function would
# otherwise make `command -v jq` (the scripts' jq-missing check) answer yes with no jq to run.
case "${OSTYPE:-}" in
  msys*|cygwin*) command -v jq >/dev/null 2>&1 && jq() { local o rc; o="$(command jq "$@")"; rc=$?; [ -z "$o" ] || printf '%s\n' "$o" | tr -d '\r'; return "$rc"; } ;;
esac

ship_read_line() {  # ship_read_line <script> <reason> — the READ: pointer printed before every non-PASS result
  case "${2:-}" in
    contract-mismatch|skill-changed|skill-dir-mismatch) printf 'READ: references/exit-codes.md § Exit 9\n' ;;
    *) printf 'READ: references/exit-codes.md § %s\n' "${1:-}" ;;
  esac
}

_SHIP_FROM_SCRIPT=0
if [ -n "${BASH_SOURCE[1]:-}" ]; then
  _SHIP_C_NAME=$(basename "${BASH_SOURCE[1]}" .sh)
  _SHIP_C_GOT="none"; _SHIP_C_EXPLICIT=0
  case "${1:-}" in --contract=*) _SHIP_C_GOT="${1#--contract=}"; _SHIP_C_EXPLICIT=1; shift ;; esac
  if [ "$_SHIP_C_EXPLICIT" -eq 0 ] && [ -n "${SHIP_CONTRACT_VERIFIED:-}" ]; then _SHIP_C_GOT="$SHIP_CONTRACT_VERIFIED"; fi
  _SHIP_C_OK=0
  if [ "$_SHIP_C_GOT" = "$SKILL_CONTRACT" ]; then _SHIP_C_OK=1
  elif [ "$_SHIP_C_GOT" = "none" ]; then case "$SKILL_OPTIONAL_SCRIPTS" in *" $_SHIP_C_NAME "*) _SHIP_C_OK=1 ;; esac
  fi
  if [ "$_SHIP_C_OK" -ne 1 ]; then
    echo "STOP: ship contract mismatch: the instructions you are following pass contract '${_SHIP_C_GOT}' but this bin/ is at contract ${SKILL_CONTRACT}."
    echo "   SKILL.md and bin/ are out of step (a rebase brought newer scripts, or the pointer lacks --contract=${SKILL_CONTRACT})."
    echo "   Read ${SHIP_SKILL_DIR}/SKILL.md from disk and resume (state kept)."
    ship_read_line "$_SHIP_C_NAME" contract-mismatch
    echo "SHIP-RESULT ${_SHIP_C_NAME} FAIL contract-mismatch want=${SKILL_CONTRACT} got=${_SHIP_C_GOT}"
    exit 9
  fi
  export SHIP_CONTRACT_VERIFIED="$SKILL_CONTRACT"
  _SHIP_FROM_SCRIPT=1
  unset _SHIP_C_NAME _SHIP_C_GOT _SHIP_C_EXPLICIT _SHIP_C_OK
fi

# ---------------------------------------------------------------------------------------------------------
# Result and logging
# ---------------------------------------------------------------------------------------------------------
ship_log() { printf '%s\n' "$*" >> "${SHIP_LOG:-/dev/null}" 2>/dev/null; return 0; }

ship_result() {  # ship_result <script> <PASS|SKIP|FAIL|WAIT> [reason] [k=v ...] — always the LAST stdout line
  local s="$1" t="$2"; shift 2
  case "$t" in PASS|SKIP) ;; *) ship_read_line "$s" "${1:-}" ;; esac
  echo "SHIP-RESULT $s $t $*" | sed 's/ *$//'
  ship_log "SHIP-RESULT $s $t $*"
}

ship_die() {  # ship_die <rc> <reason> <message...> — MAIN SHELL ONLY. Prints the message, the FAIL line, exits rc.
  local rc="$1" reason="$2"; shift 2
  [ "$#" -gt 0 ] && echo "STOP: $*"
  ship_log "DIE rc=$rc reason=$reason: $*"
  ship_result "${SHIP_SCRIPT:-unknown}" FAIL "$reason"
  exit "$rc"
}

# ---------------------------------------------------------------------------------------------------------
# Init: resolve ship-state (per worktree, never /tmp), cd to the repo toplevel, check SKILL.md freshness
# ---------------------------------------------------------------------------------------------------------
ship_lib_init() {
  SHIP_SCRIPT="${1:-unknown}"
  local p top
  p=$(git rev-parse --git-path ship-state 2>/dev/null) || p=""
  if [ -z "$p" ]; then
    echo "ship-state unresolvable: not inside a git work tree ($(pwd))" >&2
    ship_result "$SHIP_SCRIPT" FAIL ship-state-unresolvable; exit 2
  fi
  mkdir -p "$p/logs" "$p/tasks" 2>/dev/null || { echo "ship-state unwritable: $p" >&2; ship_result "$SHIP_SCRIPT" FAIL ship-state-unresolvable; exit 2; }
  SHIP_STATE="$(cd "$p" && pwd -P)" || { ship_result "$SHIP_SCRIPT" FAIL ship-state-unresolvable; exit 2; }
  SHIP_LOG="$SHIP_STATE/logs/$SHIP_SCRIPT.log"
  { echo "=== $SHIP_SCRIPT $(date -u +%Y-%m-%dT%H:%M:%SZ) pid=$$ args: $*"; } >> "$SHIP_LOG" 2>/dev/null
  top=$(git rev-parse --show-toplevel 2>/dev/null) && top="$(cd "$top" && pwd -P)" || top=""
  [ -n "$top" ] || { echo "repo toplevel unresolvable from $(pwd)" >&2; ship_result "$SHIP_SCRIPT" FAIL toplevel-unresolvable; exit 2; }
  # Every script runs from the repo root: pathspecs and `git diff --name-only` output are cwd-relative, and a
  # ship run from a subdirectory must not read as "nothing changed". SHIP_STATE is absolute, so the cd cannot move it.
  cd "$top" || { ship_result "$SHIP_SCRIPT" FAIL toplevel-unresolvable; exit 2; }
  SHIP_TOPLEVEL="$top"
  export SHIP_STATE SHIP_BIN SHIP_LOG SHIP_SKILL_DIR
  ship_cfg_validate
  # GH_REPO=owner/repo in ship.env: every `gh` this script (and any *_CMD it runs) calls targets that repository, not
  # the one gh would infer from the remotes (a mirror checkout's origin is not the GitHub copy). Empty or absent:
  # the environment is left as it is, so gh resolves the repository its own default way.
  local ghr; ghr=$(ship_cfg GH_REPO "")
  if [ -n "$ghr" ]; then GH_REPO="$ghr"; export GH_REPO; fi
  if [ "$_SHIP_FROM_SCRIPT" -eq 1 ] && [ "$SHIP_SCRIPT" != "ship-init" ]; then
    case "$SKILL_OPTIONAL_SCRIPTS" in *" $SHIP_SCRIPT "*) ;; *) ship_skill_fresh_check ;; esac
  fi
}

# ship_skill_fresh_check — compares `git hash-object` of this skill's SKILL.md with the blob ship-init.sh recorded.
# A difference means a rebase, merge or pull changed the text on disk after the model loaded its copy: exit 9
# `skill-changed` (Read SKILL.md from disk and resume with state kept; ship-init re-records the blob). An absent
# record is not checked (ship-init never ran; the callers' own "no ship-mode" paths exit 2).
ship_skill_fresh_check() {
  local f="$SHIP_STATE/ship-skill-blob" rec cur
  [ -f "$f" ] || return 0
  rec=$(sed -n 1p "$f" 2>/dev/null | tr -d '[:space:]')
  cur=$(git hash-object "$SHIP_SKILL_DIR/SKILL.md" 2>/dev/null) || cur=""
  [ -n "$cur" ] && [ "$cur" = "$rec" ] && return 0
  ship_fixloop_log skill-changed "old=$(printf '%.12s' "${rec:-none}")" "new=$(printf '%.12s' "${cur:-missing}")"
  # Remember this exit 9 so the ship-init re-run RESUMES instead of starting fresh: the rebase that changed
  # SKILL.md also changed the tree, and tree-bound step markers alone would read as "stale" and wipe the ship.
  ship_write_atomic "$SHIP_STATE/ship-skill-reload-pending" "$(date +%s)" 2>/dev/null || ship_log "could not write ship-skill-reload-pending"
  echo "STOP: the ship skill text changed under this run (SKILL.md blob $(printf '%.12s' "${cur:-missing}"), this run loaded $(printf '%.12s' "${rec:-none}"))."
  echo "   Read $SHIP_SKILL_DIR/SKILL.md in full from disk NOW, then resume per its Resume block (state kept). Do not continue from the text you already have."
  ship_result "$SHIP_SCRIPT" FAIL skill-changed
  exit 9
}

# ---------------------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------------------
ship_write_atomic() {  # ship_write_atomic <file> [line ...] — temp file in the same dir, then mv. Non-zero on failure.
  local f="$1" tmp; shift
  tmp=$(mktemp "$(dirname "$f")/.ship-write.XXXXXX" 2>/dev/null) || return 1
  if [ "$#" -gt 0 ]; then printf '%s\n' "$@" > "$tmp" || { rm -f "$tmp"; return 1; }; fi
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

ship_kv_get() {  # ship_kv_get <file> <key> — value of `key=value` in a data file (never sourced). 1 absent, 2 unreadable/malformed.
  local f="$1" want="$2" line k v found=1 val=""
  [ -r "$f" ] || return 2
  while IFS= read -r line || [ -n "$line" ]; do
    # A CRLF line end (Git for Windows checks text out that way by default) is a line end, never part of the value;
    # a carriage return anywhere else in the line is still malformed.
    line="${line%$'\r'}"
    case "$line" in *$'\r'*) return 2 ;; ''|'#'*|*=*) ;; *) return 2 ;; esac
    case "$line" in ''|'#'*) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in ''|*[!A-Za-z0-9_]*) return 2 ;; esac
    # A value that starts with # is a trailing comment, never a value: run as a command it would exit 0 and read green.
    case "$v" in *'#'*) case "$(printf '%s' "$v" | sed 's/^[[:space:]]*//')" in '#'*) return 2 ;; esac ;; esac
    if [ "$k" = "$want" ]; then val="$v"; found=0; fi
  done < "$f"
  [ "$found" -eq 0 ] || return 1
  printf '%s\n' "$val"
}

# ship_cfg <KEY> [default] — a value from ship.env (next to SKILL.md; onboarding writes it). Prints the value or the
# default. A malformed ship.env is exit 2 from any script: configuration is never guessed.
ship_cfg() {
  local f="$SHIP_SKILL_DIR/ship.env" v rc
  if [ ! -f "$f" ]; then [ "$#" -ge 2 ] && { printf '%s\n' "$2"; return 0; }; return 1; fi
  v=$(ship_kv_get "$f" "$1"); rc=$?
  case "$rc" in
    0) [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }; [ "$#" -ge 2 ] && { printf '%s\n' "$2"; return 0; }; return 1 ;;
    1) [ "$#" -ge 2 ] && { printf '%s\n' "$2"; return 0; }; return 1 ;;
    *) echo "ship.env is malformed (only KEY=value lines and # comments on their own lines are allowed; a value may not begin with #): $f" >&2; return 2 ;;
  esac
}

# ship_cfg_validate — MAIN SHELL ONLY, called from ship_lib_init: a missing or malformed ship.env, an unset BASE_BRANCH, a bad
# enum or a non-numeric number is exit 2 BEFORE any gate runs (a helper used inside $(...) cannot exit the script, so the one
# check is here).
ship_cfg_validate() {
  local v k
  [ -f "$SHIP_SKILL_DIR/ship.env" ] || { echo "ship.env missing: copy $SHIP_SKILL_DIR/ship.env.example to ship.env and fill it (onboarding does this)" >&2; ship_result "$SHIP_SCRIPT" FAIL ship-env-missing; exit 2; }
  ship_kv_get "$SHIP_SKILL_DIR/ship.env" BASE_BRANCH >/dev/null 2>&1; case $? in 2) echo "ship.env is malformed (only KEY=value lines and # comments on their own lines are allowed; a value may not begin with #): $SHIP_SKILL_DIR/ship.env" >&2; ship_result "$SHIP_SCRIPT" FAIL ship-env-malformed; exit 2 ;; esac
  v=$(ship_cfg BASE_BRANCH ""); [ -n "$v" ] || { echo "BASE_BRANCH is not set in ship.env" >&2; ship_result "$SHIP_SCRIPT" FAIL base-branch-unset; exit 2; }
  v=$(ship_cfg DEFAULT_MODE offload); case "$v" in local|offload) ;; *) echo "DEFAULT_MODE must be local|offload (got '$v')" >&2; ship_result "$SHIP_SCRIPT" FAIL ship-env-malformed; exit 2 ;; esac
  v=$(ship_cfg MERGE_METHOD direct); case "$v" in queue|direct) ;; *) echo "MERGE_METHOD must be queue|direct (got '$v')" >&2; ship_result "$SHIP_SCRIPT" FAIL ship-env-malformed; exit 2 ;; esac
  v=$(ship_cfg REVIEW_GATE sentinel); case "$v" in sentinel|manual) ;; *) echo "REVIEW_GATE must be sentinel|manual (got '$v')" >&2; ship_result "$SHIP_SCRIPT" FAIL ship-env-malformed; exit 2 ;; esac
  v=$(ship_cfg POSTMERGE_CI required); case "$v" in required|none) ;; *) echo "POSTMERGE_CI must be required|none (got '$v')" >&2; ship_result "$SHIP_SCRIPT" FAIL ship-env-malformed; exit 2 ;; esac
  v=$(ship_cfg GH_REPO ""); [ -z "$v" ] || ship_is_owner_repo "$v" || { echo "GH_REPO must be owner/repo or empty (got '$v')" >&2; ship_result "$SHIP_SCRIPT" FAIL ship-env-malformed; exit 2; }
  # CHECK_TASKS binds the Phase-1 task list to configured commands: every entry is name:local|offload|both and needs a
  # non-blank CHECK_CMD_<name> (a blank command exits 0 and would record a green that checked nothing: fail closed here).
  v=$(ship_cfg CHECK_TASKS "")
  if [ -n "$v" ]; then
    local e n m c
    for e in $(printf '%s' "$v" | tr ',' ' '); do
      n=${e%%:*}; m=${e#*:}; [ "$n" != "$e" ] || m=both
      case "$n" in ''|*[!A-Za-z0-9_]*) echo "CHECK_TASKS entry '$e': the name must be [A-Za-z0-9_]" >&2; ship_result "$SHIP_SCRIPT" FAIL ship-env-malformed; exit 2 ;; esac
      case "$m" in local|offload|both) ;; *) echo "CHECK_TASKS entry '$e': the mode must be local|offload|both" >&2; ship_result "$SHIP_SCRIPT" FAIL ship-env-malformed; exit 2 ;; esac
      c=$(ship_cfg "CHECK_CMD_$n" "")
      [ -n "$(printf '%s' "$c" | tr -d '[:space:]')" ] || { echo "CHECK_TASKS lists '$n' but CHECK_CMD_$n is empty: an empty command would record green (remove the entry or give it a command)" >&2; ship_result "$SHIP_SCRIPT" FAIL ship-env-malformed; exit 2; }
    done
  fi
  v=$(ship_cfg RELEASE_ACTIONS none); case "$v" in none) ;; file-ledger)
      for k in RELEASE_ACTION_LINT_CMD RELEASE_ACTION_HARVEST_CMD RELEASE_LEDGER_DIR; do
        [ -n "$(ship_cfg "$k" "" | tr -d '[:space:]')" ] || { echo "RELEASE_ACTIONS=file-ledger needs $k (an empty command would read as clean / harvested)" >&2; ship_result "$SHIP_SCRIPT" FAIL ship-env-malformed; exit 2; }
      done ;;
    *) echo "RELEASE_ACTIONS must be none|file-ledger (got '$v')" >&2; ship_result "$SHIP_SCRIPT" FAIL ship-env-malformed; exit 2 ;; esac
  for k in REVIEW_TTL_SECONDS E2E_TTL_SECONDS FIX_ROUND_CAP PRE_PUSH_CEILING_MINUTES; do
    v=$(ship_cfg "$k" 1); case "$v" in ''|*[!0-9]*) echo "$k must be a number (got '$v')" >&2; ship_result "$SHIP_SCRIPT" FAIL ship-env-malformed; exit 2 ;; esac
  done
}

# ---- the close-out check: every started issue is closed by this PR's body, or owned by a declared additional PR -----------
# ship_md_visible <file> — the RENDERED text: fenced code blocks and HTML comments removed (a quoted example or a hidden
# note neither closes an issue nor declares a banner). CR stripped.
ship_md_visible() {
  tr -d '\r' < "$1" | awk '
    { line = $0 }
    infence { if (line ~ /^[[:space:]]*(```|~~~)/) infence = 0; next }
    incomment { p = index(line, "-->"); if (!p) next; line = substr(line, p + 3); incomment = 0 }
    line ~ /^[[:space:]]*([>][[:space:]]*)?([-*+][[:space:]]+)?(```|~~~)/ { infence = 1; next }
    {
      out = ""
      while ((p = index(line, "<!--")) > 0) {
        out = out substr(line, 1, p - 1); rest = substr(line, p + 4); q = index(rest, "-->")
        if (q == 0) { incomment = 1; line = ""; break }
        line = substr(rest, q + 3)
      }
      print out line
    }'
}
SHIP_BANNER_ERE='^[[:space:]]*([-*+][[:space:]]+)?(\*\*|__)?⚠[^A-Za-z]*ADDITIONAL PR REQUIRED'
SHIP_CLOSE_ERE='(^|[^[:alnum:]_])(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]*:?[[:space:]]*#'
# ship_body_closing <file> — issue numbers named after a closing keyword in the rendered body, banner lines excluded (they
# name issues ANOTHER PR closes), sorted unique. rc 3 unreadable.
ship_body_closing() {
  local v; v=$(ship_md_visible "$1") || return 3
  printf '%s\n' "$v" | grep -vE "$SHIP_BANNER_ERE" | grep -ioE "${SHIP_CLOSE_ERE}[0-9]+" | grep -oE '[0-9]+$' | LC_ALL=C sort -un
  return 0
}
# ship_banner_owned <file> — issue numbers a rendered line-start `⚠️ ADDITIONAL PR REQUIRED` banner names after `owns`; the
# owns segment ends at `blocker:`, at the first ` — ` / ` – ` / ` - ` separator, or at the end of the line (`owns none —
# needs #19 first` owns nothing). Sorted unique.
ship_banner_owned() {
  local v; v=$(ship_md_visible "$1") || return 3
  printf '%s\n' "$v" | grep -E "$SHIP_BANNER_ERE" | awk '
    { l = tolower($0); if (!match(l, /(^|[^a-z])owns([^a-z]|$)/)) next
      seg = substr($0, RSTART + RLENGTH)
      cut = length(seg) + 1
      for (i = 1; i <= length(seg); i++) {
        t = substr(seg, i)
        if (t ~ /^[[:space:]]+(—|–|-)[[:space:]]/ || tolower(t) ~ /^[[:space:]]*(—|–|-)*[[:space:]]*blocker[[:space:]]*:/) { cut = i; break }
      }
      seg = substr(seg, 1, cut - 1)
      while (match(seg, /#[0-9]+/)) { print substr(seg, RSTART + 1, RLENGTH - 1); seg = substr(seg, RSTART + RLENGTH) } }' | LC_ALL=C sort -un
  return 0
}
# ship_plan_owned <issues> — issue numbers the reviewed plan(s) give to an additional PR: the Owns column (2nd) of every
# table row under `## PRs` whose `User-approved?` (4th) column says yes, in PLANS_DIR/<N>-*.md (worked default docs/plans)
# for each started issue N. rc 3 when a plan exists but cannot be read.
ship_plan_owned() {
  local dir n f top acc="" one
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 3
  dir=$(ship_cfg PLANS_DIR docs/plans)
  for n in $1; do
    for f in "$top/$dir/$n"-*.md; do
      [ -e "$f" ] || continue
      [ -r "$f" ] || return 3
      one=$(awk '/^## /{ inprs = ($0 ~ /^## PRs[[:space:]]*$/); next }
           inprs && /^[[:space:]]*\|/ { row = $0; gsub(/\\\|/, " ", row); split(row, c, "|"); if (tolower(c[5]) !~ /yes/) next; s = c[3]; while (match(s, /#[0-9]+/)) { print substr(s, RSTART + 1, RLENGTH - 1); s = substr(s, RSTART + RLENGTH) } }' "$f") || return 3
      acc="$acc
$one"
    done
  done
  printf '%s\n' "$acc" | grep . | LC_ALL=C sort -un
  return 0
}
# ship_started_unclosed <body-file> — for each started issue (ship_issues) not closed by the body: `FAIL <N>`, or `WARN <N>`
# when a banner owns it AND the reviewed plan declares it, or `UNDECLARED <N>` when a banner owns it but no plan backs the
# banner (the banner is written at ship time, after review: it cannot excuse on its own). A banner excuses only the issues
# it owns. rc 0 · 3 a source unreadable (never "nothing unclosed").
ship_started_unclosed() {
  local body="$1" iss closing owned planned="" n
  iss=$(ship_issues) || return 3
  [ -n "$iss" ] || return 0
  [ -r "$body" ] || return 3
  closing=$(ship_body_closing "$body") || return 3
  owned=$(ship_banner_owned "$body") || return 3
  if [ -n "$owned" ]; then planned=$(ship_plan_owned "$iss") || return 3; fi
  for n in $iss; do
    case "
$closing
" in *"
$n
"*) continue ;; esac
    case "
$owned
" in
      *"
$n
"*) case "
$planned
" in *"
$n
"*) echo "WARN $n" ;; *) echo "UNDECLARED $n" ;; esac ;;
      *) echo "FAIL $n" ;;
    esac
  done
  return 0
}

# ship_ceiling_passed <ISO-8601 UTC start> <minutes> — prints yes (older than the ceiling) | no | unknown (empty or
# unparseable start). Only `yes` lets a pre-push wait push past a running required run.
ship_ceiling_passed() {
  local s="${1:-}" c="${2:-}" e
  case "$c" in ''|*[!0-9]*) echo unknown; return 0 ;; esac
  [ -n "$s" ] || { echo unknown; return 0; }
  e=$(date -u -d "$s" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$s" +%s 2>/dev/null) || e=""
  case "$e" in ''|*[!0-9]*) echo unknown; return 0 ;; esac
  if [ $(( $(date +%s) - e )) -ge $(( c * 60 )) ]; then echo yes; else echo no; fi
}

# ship_required_tasks <mode> — the CHECK_TASKS names that apply to the mode, one per line (validated at init). Empty when
# CHECK_TASKS is unset: then the required list is the launched list (tasks.list), and the PR body says so.
ship_required_tasks() {
  local v e n m
  v=$(ship_cfg CHECK_TASKS "") || return 0
  for e in $(printf '%s' "$v" | tr ',' ' '); do
    n=${e%%:*}; m=${e#*:}; [ "$n" != "$e" ] || m=both
    case "$m" in both|"$1") printf '%s\n' "$n" ;; esac
  done
}

ship_is_owner_repo() {  # ship_is_owner_repo <s> — 0 when s is exactly owner/repo (GitHub name characters, no host, no extra /)
  case "${1:-}" in */*/*|/*|*/|-*|*[!A-Za-z0-9._/-]*) return 1 ;; */*) return 0 ;; esac
  return 1
}

ship_base_branch() { ship_cfg BASE_BRANCH; }   # validated at init: always prints after ship_lib_init
ship_base_ref() { local b; b=$(ship_cfg BASE_BRANCH) || return 2; printf 'origin/%s\n' "$b"; }

ship_mktemp() { mktemp "${TMPDIR:-/tmp}/ship.XXXXXX"; }   # with a template: BSD mktemp needs one

# ship_sha256 < file — 64 hex on stdout; GNU sha256sum or BSD shasum -a 256 (identical output). Non-zero and nothing
# printed when neither works or the output is not 64 hex: a caller never gets a partial hash.
ship_sha256() {
  local h
  if command -v sha256sum >/dev/null 2>&1; then h=$(sha256sum 2>/dev/null) || return 1
  elif command -v shasum >/dev/null 2>&1; then h=$(shasum -a 256 2>/dev/null) || return 1
  else return 1; fi
  h=$(printf '%s' "$h" | cut -c1-64); _ship_hex64 "$h" || return 1
  printf '%s\n' "$h"
}
ship_branch() { git branch --show-current 2>/dev/null; }

ship_merge_base() {  # merge-base of HEAD and origin/<BASE_BRANCH>. Non-zero and no output when unresolvable: callers never default it.
  local mb
  mb=$(git merge-base HEAD "$(ship_base_ref)" 2>/dev/null) || return 1
  case "$mb" in ''|*[!0123456789abcdef]*) return 1 ;; esac
  printf '%s\n' "$mb"
}

ship_mode() {  # prints `local` or `offload` from ship-mode. Returns 2 when absent or malformed (ship-init never ran). Never defaults.
  local f="${SHIP_STATE:-}/ship-mode" m
  [ -f "$f" ] || return 2
  m=$(sed -n 1p "$f" 2>/dev/null | tr -d '[:space:]')
  case "$m" in local|offload) printf '%s\n' "$m" ;; *) return 2 ;; esac
}
ship_require_mode() {  # sets SHIP_MODE in the main shell (never call it inside $(...): the die could not stop the script)
  SHIP_MODE=$(ship_mode) || ship_die 2 mode-missing "ship-init never ran for this worktree (no $SHIP_STATE/ship-mode): run the Mode selection pointer first."
}

ship_pr_num() {  # the open PR for the current branch; non-zero and no output when none or gh failed
  local n
  n=$(gh pr view --json number --jq .number 2>/dev/null) || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$n"
}

_ship_epoch_ok() { case "${1:-}" in ''|0*|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
_ship_hex40() { case "${1:-}" in *[!0123456789abcdef]*|'') return 1 ;; esac; [ "${#1}" -eq 40 ]; }
_ship_hex64() { case "${1:-}" in *[!0123456789abcdef]*|'') return 1 ;; esac; [ "${#1}" -eq 64 ]; }

# ---------------------------------------------------------------------------------------------------------
# Fix-loop ledger (v1 placeholder: a TSV in SHIP_STATE). Best-effort telemetry; NEVER changes an exit code.
# Line: <epoch>\t<event>\t<k=v>... (tabs and newlines in values become spaces). ship-status.sh summarizes it;
# Step 5 archives it as a PR comment. The real ledger (archive + retro scorecard) is a roadmap item.
# ---------------------------------------------------------------------------------------------------------
ship_fixloop_log() {
  local f="${SHIP_STATE:-}/fixloop.tsv" ev="${1:-}" line a
  SHIP_FIXLOOP_LAST=gap
  [ -n "$ev" ] && [ -n "${SHIP_STATE:-}" ] || return 0
  case "$ev" in *[!A-Za-z0-9_-]*) echo "WARN fixloop-bad-event: $ev" >&2; return 0 ;; esac
  shift
  line="$(date +%s)	$ev"
  for a in "$@"; do line="$line	$(printf '%s' "$a" | tr '\t\n' '  ')"; done
  if printf '%s\n' "$line" >> "$f" 2>/dev/null; then SHIP_FIXLOOP_LAST=written; else echo "WARN fixloop-unwritable: $f" >&2; fi
  return 0
}

# ---------------------------------------------------------------------------------------------------------
# Content fingerprint — THE sentinel contract shared with the review-code skill (its references/sentinels.md is
# the normative text; this is the reference implementation). Writer and reader must agree byte for byte.
#
#   ship_fingerprint <base-ref> [include-regex-file] [exclude-regex-file]
#     prints 64 hex chars on stdout and returns 0, or prints `SENTINEL-ERROR: <why>` and returns 1.
#     Inputs: every changed path from merge-base(HEAD, base-ref) to the WORKING TREE (committed, staged, unstaged
#     and untracked), one record `<status>\t<path>\t<sha256-of-current-content|DELETED>` per path, renames expanded
#     (`--no-renames`), records sorted bytewise (LC_ALL=C) and hashed together. The optional include file holds
#     extended-regex patterns matched against `<status>\t<path>` lines (ship_globs_to_ere makes it from a glob
#     list); the optional exclude file removes matching lines. An empty record set hashes the empty input: a
#     legitimate, stable value. No error path can reach the final hash: an unresolvable merge-base, an unreadable
#     file or an empty path is SENTINEL-ERROR, never a value.
# ---------------------------------------------------------------------------------------------------------
ship_fingerprint() {
  local base_ref="$1" inc="${2:-}" exc="${3:-}" BASE RAW LIST RECORDS status path h rc
  [ -n "$base_ref" ] || { echo "SENTINEL-ERROR: base ref empty"; return 1; }
  BASE=$(git merge-base HEAD "$base_ref" 2>/dev/null) || { echo "SENTINEL-ERROR: merge-base unresolved"; return 1; }
  local D; D=$(mktemp -d "${TMPDIR:-/tmp}/ship-fp.XXXXXX") || { echo "SENTINEL-ERROR: mktemp failed"; return 1; }
  RAW="$D/raw"; LIST="$D/list"; RECORDS="$D/records"; : > "$RECORDS"   # an empty filtered set hashes the empty input
  _fp_fail() { echo "SENTINEL-ERROR: $1"; rm -rf "${D:?}"; return 1; }
  # Each producer is checked on its own (no pipefail in this library): a failing git never hides behind a successful sort.
  git -c core.quotePath=false diff --name-status --no-renames "$BASE" > "$RAW" || { _fp_fail "diff unreadable"; return 1; }
  git -c core.quotePath=false ls-files --others --exclude-standard > "$RAW.u" || { _fp_fail "untracked list unreadable"; return 1; }
  # An untracked file is recorded as an add ("A"), the status `git diff` gives it once it is staged or committed: the
  # fingerprint must not change when the reviewed bytes are committed. (A literal tab: BSD sed has no \t.)
  sed "s/^/A$(printf '\t')/" "$RAW.u" >> "$RAW" || { _fp_fail "untracked list unreadable"; return 1; }
  LC_ALL=C sort -u "$RAW" > "$LIST" || { _fp_fail "sort failed"; return 1; }
  if [ -n "$inc" ]; then
    grep -E -f "$inc" "$LIST" > "$LIST.f"; rc=$?
    [ "$rc" -le 1 ] || { _fp_fail "include filter invalid (grep rc=$rc)"; return 1; }
    mv -f "$LIST.f" "$LIST"
  fi
  if [ -n "$exc" ]; then   # DOCS_ALLOWLIST as an ERE over the PATH field; DOCS_KEEP_BOUND re-includes check inputs (part of the contract: see sentinels.md)
    # ENVIRON, not -v: awk -v processes backslash escapes and would turn `\.md$` into `.md$`
    SHIP_FP_EXC="$exc" SHIP_FP_KEEP="$(ship_cfg DOCS_KEEP_BOUND "")" awk -F"$(printf '\t')" '$2 !~ ENVIRON["SHIP_FP_EXC"] || (ENVIRON["SHIP_FP_KEEP"] != "" && $2 ~ ENVIRON["SHIP_FP_KEEP"])' "$LIST" > "$LIST.f" || { _fp_fail "exclude filter invalid"; return 1; }
    mv -f "$LIST.f" "$LIST"
  fi
  while IFS="$(printf '\t')" read -r status path; do
    [ -n "$path" ] || { _fp_fail "empty path in diff"; return 1; }
    if [ -f "$path" ]; then h=$(ship_sha256 < "$path") || { _fp_fail "unreadable $path"; return 1; }
    else h=DELETED; fi
    printf '%s\t%s\t%s\n' "$status" "$path" "$h" >> "$RECORDS"
  done < "$LIST"
  h=$(ship_sha256 < "$RECORDS") || { _fp_fail "hash failed"; return 1; }
  rm -rf "${D:?}"
  printf '%s\n' "$h"
}

# ship_globs_to_ere < globs > eres — ONE glob per line in, one anchored ERE per line out, matching `<status>\t<path>`
# lines. This conversion is part of the contract (sentinels.md "Glob filter"): `**/` → `(.*/)?`, `**` → `.*`,
# `*` → `[^/]*`, `?` → `[^/]`, every other regex metacharacter escaped. Blank lines and `#` comments are dropped.
ship_globs_to_ere() {
  local tab; tab="$(printf '\t')"
  grep -v -E '^[[:space:]]*(#|$)' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    -e 's/[].[()+{}|^$\\]/\\&/g' \
    -e 's#\*\*/#__DSTAR_SLASH__#g' -e 's/\*\*/__DSTAR__/g' -e 's#\*#[^/]*#g' -e 's#?#[^/]#g' \
    -e 's#__DSTAR_SLASH__#(.*/)?#g' -e 's/__DSTAR__/.*/g' \
    -e "s#^#^[^${tab}]*${tab}(#" -e 's#$#)$#'
}

# ship_critical_ere_file — the include-regex file built from CRITICAL_GLOBS_FILE (ship.env). Prints the temp path; callers rm it.
# An UNSET key is the explicit opt-out (an empty regex file matches nothing: every diff is E2E-exempt, as review-code treats an
# empty CRITICAL_GLOBS). A key that names a file which is missing or unreadable is an ERROR (return 1), never "no globs".
ship_critical_ere_file() {
  local gf out
  gf=$(ship_cfg CRITICAL_GLOBS_FILE "") || gf=""
  if [ -n "$gf" ] && [ ! -r "$gf" ]; then echo "CRITICAL_GLOBS_FILE=$gf is configured but unreadable (an empty value is the explicit opt-out)" >&2; return 1; fi
  if [ -n "$gf" ]; then
    local bad; bad=$(grep -v -E '^[[:space:]]*(#|$)' "$gf" | grep -nE '^[[:space:]]*\./|/[[:space:]]*$|[{}!]|[^[:space:]][[:space:]]+#' | head -5)
    [ -z "$bad" ] || { echo "CRITICAL_GLOBS_FILE=$gf has glob spellings the converter cannot honour (no leading ./, no trailing /, no {a,b}, no !negation, no inline # comment): $bad" >&2; return 1; }
  fi
  out=$(ship_mktemp) || return 1
  if [ -n "$gf" ]; then ship_globs_to_ere < "$gf" > "$out" || { rm -f "${out:?}"; return 1; }; fi
  printf '%s\n' "$out"
}

# ship_docs_ere — DOCS_ALLOWLIST as an ERE over PATHS (worked default `(\.md$|\.txt$|^docs/|(^|/)CHANGELOG)`), applied by
# ship_fingerprint's exclude argument to the path field with awk. Docs the documentation subagent writes after the checks
# ran must not invalidate Phase 1. Prints the ERE (empty when unset).
ship_docs_ere() { ship_cfg DOCS_ALLOWLIST "" || true; }

# ship_fp_tree — the REVIEW FINGERPRINT (the contract's "tree" fingerprint): every changed path EXCEPT DOCS_ALLOWLIST matches (minus DOCS_KEEP_BOUND).
# Both review-code (writer) and ship (reader) use it for review-code-ran line 1, the EXEMPT form's line 3, manual
# attestations, the review chain and the step markers other than `phase1`, so a documentation subagent writing after the
# review does not invalidate them, and a base sync does not force a re-review. Check results bind to ship_fp_phase1 instead.
ship_fp_tree() { ship_fingerprint "$(ship_base_ref)" "" "$(ship_docs_ere)"; }

# _ship_hex_tree <value> — a git tree id: 40 hex (SHA-1 repository) or 64 hex (SHA-256 repository).
_ship_hex_tree() { case "${1:-}" in *[!0123456789abcdef]*|'') return 1 ;; esac; [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ]; }

# ship_issue_marker_path — ISSUE_MARKER_FILE (ship.env) as a toplevel-relative path, or nothing when unset. One spelling for
# every reader: the check binding's exclusion, the untracked relevance exemption and `ship-status.sh issues`.
ship_issue_marker_path() {
  local m top
  m=$(ship_cfg ISSUE_MARKER_FILE "" 2>/dev/null) || m=""
  [ -n "$m" ] || return 0
  top=$(git rev-parse --show-toplevel 2>/dev/null) && top=$(cd "$top" && pwd -P) || top=""
  case "$m" in
    /*) local d; d=$(cd "$(dirname "$m")" 2>/dev/null && pwd -P) && m="$d/$(basename "$m")"   # one spelling for symlinked paths
        [ -n "$top" ] && case "$m" in "$top"/*) m=${m#"$top"/} ;; esac ;;
  esac
  while :; do case "$m" in ./*) m=${m#./} ;; *) break ;; esac; done
  printf '%s\n' "$m"
}

# ---------------------------------------------------------------------------------------------------------
# ship_fp_phase1 — the CHECK BINDING. What the local checks saw is the content on disk, so that is what their results bind
# to: `git write-tree` over a scratch copy of the index into which every tracked and every not-ignored untracked file has
# been staged. The user's own index is never written. The Phase-1 sentinel, each task's exit file and the `phase1` step
# marker bind to it. Unlike the review fingerprint (changed paths only, so a base
# sync does not force a re-review), it covers the whole tree: checks that ran on an older base never vouch for a newer one.
# It is the same value before and after a commit of unchanged content. Paths matching DOCS_ALLOWLIST (except
# DOCS_KEEP_BOUND) and the ISSUE_MARKER_FILE are left out, so the docs step and the marker do not invalidate Phase 1.
# Prints the id (40 or 64 hex) and returns 0, or prints `SENTINEL-ERROR: <why>` and returns 1. Never a guessed value:
#   - the throwaway index is seeded from the real one (`cp -p` keeps its mtime, so git's racy-entry check still works);
#     a missing real index is an error unless HEAD is unborn (an unseeded index drops tracked files that match .gitignore);
#   - unmerged paths are an error (`git add -A` would stage the conflicted files, markers included, as resolved);
#   - assume-unchanged entries are re-read (--really-refresh) and skip-worktree is cleared for files present on disk;
#     entries absent on disk (a sparse checkout) keep their recorded content;
#   - a path containing a newline, or an untracked nested repository, is an error.
# Known blind spots: the working tree of a dirty submodule (only its recorded commit counts). `git add -A` runs clean
# filters (a failing required filter is an error) and writes objects for changed and untracked files (`git gc` reclaims
# them). Needs `git add --sparse` (git 2.34 or later).
# ---------------------------------------------------------------------------------------------------------
ship_fp_phase1() {
  (
    unset GIT_INDEX_FILE; LC_ALL=C; export LC_ALL
    # The scratch index must not run the user's hooks (post-index-change) or leave a split index's shared file behind.
    git() { command git -c core.hooksPath=/dev/null -c core.splitIndex=false "$@"; }
    D=""
    _p1_fail() { echo "SENTINEL-ERROR: $1"; [ -z "$D" ] || rm -rf "${D:?}"; exit 1; }
    ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || _p1_fail "not inside a git work tree"
    cd "$ROOT" || _p1_fail "cannot enter the toplevel $ROOT"
    REAL=$(git rev-parse --git-path index 2>/dev/null) || _p1_fail "the index path is unresolvable"
    case "$REAL" in /*|[A-Za-z]:[/\\]*) ;; *) REAL="$ROOT/$REAL" ;; esac   # Git for Windows: C:/… is absolute
    D=$(mktemp -d "${TMPDIR:-/tmp}/ship-fp.XXXXXX") || { D=""; _p1_fail "mktemp failed"; }
    if [ -e "$REAL" ]; then
      cp -p "$REAL" "$D/index" 2>/dev/null || _p1_fail "the real index is unreadable ($REAL)"
    elif git rev-parse -q --verify HEAD >/dev/null 2>&1; then
      _p1_fail "the real index is missing ($REAL) although HEAD exists"
    fi
    GIT_INDEX_FILE="$D/index"; export GIT_INDEX_FILE
    git ls-files -u -z > "$D/unmerged" 2>/dev/null || _p1_fail "the index is unreadable"
    [ ! -s "$D/unmerged" ] || _p1_fail "unmerged paths: finish the rebase or merge first"
    git ls-files -z > "$D/tracked" 2>/dev/null || _p1_fail "the index is unreadable"
    git ls-files --others --exclude-standard -z > "$D/untracked" 2>/dev/null || _p1_fail "the untracked list is unreadable"
    # Newline-separated processing below is safe only because no path holds a newline.
    [ "$(tr -d -c '\n' < "$D/tracked" | wc -c | tr -d ' ')" = 0 ] || _p1_fail "a tracked path contains a newline"
    [ "$(tr -d -c '\n' < "$D/untracked" | wc -c | tr -d ' ')" = 0 ] || _p1_fail "an untracked path contains a newline"
    # Without --directory, git ends an untracked entry with `/` only for an embedded repository (at any depth).
    NESTED=$(tr '\0' '\n' < "$D/untracked" | grep '/$' | head -1)
    [ -z "$NESTED" ] || _p1_fail "untracked nested repository $NESTED: move it out of the checkout, or list it in the file \`git rev-parse --git-path info/exclude\` names (shared by every worktree of this repository)"
    if [ -e "$D/index" ]; then
      git update-index -q --really-refresh >/dev/null 2>&1 || _p1_fail "the index could not be refreshed"
      git ls-files -v -z > "$D/flags" 2>/dev/null || _p1_fail "the index is unreadable"
      : > "$D/present"
      tr '\0' '\n' < "$D/flags" | while IFS= read -r l; do
        case "$l" in "S "*) p=${l#S }; if [ -e "$p" ] || [ -L "$p" ]; then printf '%s\n' "$p"; fi ;; esac
      done > "$D/present" || _p1_fail "the skip-worktree list is unreadable"
      if [ -s "$D/present" ]; then
        tr '\n' '\0' < "$D/present" | git update-index --no-skip-worktree -z --stdin >/dev/null 2>&1 || _p1_fail "skip-worktree could not be cleared"
      fi
    fi
    git add -A --sparse >/dev/null 2>"$D/add.err" || _p1_fail "git add -A --sparse failed in the throwaway index ($(head -1 "$D/add.err")); ship needs git 2.34 or later"
    EXC=$(ship_docs_ere); KEEP=$(ship_cfg DOCS_KEEP_BOUND "" 2>/dev/null) || KEEP=""; MARK=$(ship_issue_marker_path)
    if [ -n "$EXC" ] || [ -n "$MARK" ]; then
      git ls-files -z > "$D/all" 2>/dev/null || _p1_fail "the index is unreadable"
      tr '\0' '\n' < "$D/all" | SHIP_P1_EXC="$EXC" SHIP_P1_KEEP="$KEEP" SHIP_P1_MARK="$MARK" awk '
        $0 == ENVIRON["SHIP_P1_MARK"] { print; next }
        ENVIRON["SHIP_P1_EXC"] != "" && $0 ~ ENVIRON["SHIP_P1_EXC"] && !(ENVIRON["SHIP_P1_KEEP"] != "" && $0 ~ ENVIRON["SHIP_P1_KEEP"]) { print }
      ' > "$D/drop" || _p1_fail "the docs filter is invalid"
      if [ -s "$D/drop" ]; then
        tr '\n' '\0' < "$D/drop" | git update-index --force-remove -z --stdin >/dev/null 2>&1 || _p1_fail "the docs paths could not be dropped"
      fi
    fi
    T=$(git write-tree 2>/dev/null) || _p1_fail "git write-tree failed"
    _ship_hex_tree "$T" || _p1_fail "git write-tree printed no tree id"
    rm -rf "${D:?}"
    printf '%s\n' "$T"
  )
}

# ship_untracked_relevant — sorts every untracked, not-ignored file (the ISSUE_MARKER_FILE excepted) by whether it sits
# NEAR A CHANGE: its folder, or a folder above it (the top level excluded), directly holds a file this branch changes; a
# top-level file is near a change when the branch changes a top-level file. Changed files = `git diff --name-only
# --no-renames <merge-base>` (tracked changes up to the working tree).
#   RELEVANT<TAB><path>  near a change: it may belong in the PR, so it is committed, deleted or moved out before a push.
#   IGNORED<TAB><path>   anywhere else: not blocking at the gate (it still moves the check binding, like any untracked file).
# Callers run from the toplevel (ship_lib_init changes there): both lists are toplevel-relative only from there.
# Returns 0, or prints `SENTINEL-ERROR: <why>` and returns 3: never "nothing untracked".
ship_untracked_relevant() {
  local mb d rc
  mb=$(ship_merge_base) || { echo "SENTINEL-ERROR: merge-base unresolved"; return 3; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/ship-ut.XXXXXX") || { echo "SENTINEL-ERROR: mktemp failed"; return 3; }
  git diff --name-only --no-renames -z "$mb" > "$d/changed" 2>/dev/null || { rm -rf "${d:?}"; echo "SENTINEL-ERROR: diff unreadable"; return 3; }
  git ls-files --others --exclude-standard -z > "$d/untracked" 2>/dev/null || { rm -rf "${d:?}"; echo "SENTINEL-ERROR: untracked list unreadable"; return 3; }
  if [ "$(tr -d -c '\n' < "$d/changed" | wc -c | tr -d ' ')" != 0 ] || [ "$(tr -d -c '\n' < "$d/untracked" | wc -c | tr -d ' ')" != 0 ]; then
    rm -rf "${d:?}"; echo "SENTINEL-ERROR: a path contains a newline"; return 3
  fi
  tr '\0' '\n' < "$d/changed" > "$d/changed.n" && tr '\0' '\n' < "$d/untracked" > "$d/untracked.n" || { rm -rf "${d:?}"; echo "SENTINEL-ERROR: list conversion failed"; return 3; }
  # One awk pass; directories compare as strings, never as patterns. `part` is set between the two files (an empty first
  # file would break the usual FNR==NR test).
  SHIP_UT_MARK="$(ship_issue_marker_path)" LC_ALL=C awk -v T="$(printf '\t')" '
    part == 1 { if ($0 == "") next; n = split($0, a, "/"); if (n == 1) dir["."] = 1; else { p = a[1]; for (i = 2; i < n; i++) p = p "/" a[i]; dir[p] = 1 }; next }
    part == 2 {
      if ($0 == "") next
      f = $0; sub(/\/$/, "", f)
      if (f == ENVIRON["SHIP_UT_MARK"]) next
      n = split(f, a, "/"); rel = 0
      if (n == 1) { if ("." in dir) rel = 1 }
      else { p = a[1]; if (p in dir) rel = 1; for (i = 2; i < n && !rel; i++) { p = p "/" a[i]; if (p in dir) rel = 1 } }
      print (rel ? "RELEVANT" : "IGNORED") T $0
    }' part=1 "$d/changed.n" part=2 "$d/untracked.n"; rc=$?
  rm -rf "${d:?}"
  [ "$rc" -eq 0 ] || { echo "SENTINEL-ERROR: relevance pass failed"; return 3; }
  return 0
}

# ship_issues — every issue this branch targets (the started issues), numerically sorted, space-separated, one line (empty
#   when none). ONE derivation, as the reference implementation has it: the worktree skill's per-worktree file
#   `worktree-issues` (git dir; exactly `n1-n2-…`: positive integers, no leading zeros, single dashes — anything else,
#   a CR or an empty file included, is refused, never guessed at) PLUS the branch's leading decimal digits (the whole
#   branch name: `18201-foo` → 18201, `12` → 12; `feat/7-x` names none; the name is never parsed for further numbers);
#   plus ISSUE_MARKER_FILE (numbers separated by whitespace, commas or dashes).
# Returns 0, or 3 when a source exists but cannot be read or is malformed, or the branch cannot be read.
ship_issues() {
  local wt b num mark all t out=""
  all=""
  wt=$(git rev-parse --git-path worktree-issues 2>/dev/null) || return 3
  if [ -e "$wt" ] || [ -L "$wt" ]; then
    [ -f "$wt" ] && [ -r "$wt" ] || return 3
    all=$(cat "$wt") || return 3
    case "$all" in ''|*[!0-9-]*|-*|*-|*--*|0*|*-0*) return 3 ;; esac
    all=$(printf '%s' "$all" | tr '-' ' ')
  fi
  b=$(git branch --show-current 2>/dev/null) || return 3
  num=$(printf '%s\n' "$b" | sed -n 's/^\([0-9][0-9]*\).*/\1/p')
  case "$num" in *[1-9]*) all="$all $num" ;; esac   # an all-zero prefix names no issue
  mark=$(ship_issue_marker_path)
  if [ -n "$mark" ] && { [ -e "$mark" ] || [ -L "$mark" ]; }; then
    [ -f "$mark" ] && [ -r "$mark" ] || return 3
    t=$(cat "$mark") || return 3
    [ -z "$(printf '%s' "$t" | tr -d '0-9, \t\r\n-')" ] || return 3   # digits and separators only (CRLF allowed)
    all="$all $(printf '%s' "$t" | tr ',\t\r\n-' '     ')"
  fi
  set -f   # the tokens are validated above; never let one expand as a glob
  for t in $all; do
    case "$t" in *[!0-9]*) set +f; return 3 ;; esac
    t=${t#"${t%%[!0]*}"}          # strip leading zeros as text (no octal arithmetic)
    [ -n "$t" ] || { set +f; return 3; }       # 0 is not an issue
    out="$out$t
"
  done
  set +f
  out=$(printf '%s' "$out" | grep . | LC_ALL=C sort -n -u | tr '\n' ' ')
  printf '%s\n' "${out% }"
  return 0
}

# Manual attestation (REVIEW_GATE=manual): $SHIP_STATE/manual-<review|e2e> = <fp> / <epoch> / <note> / <the user's words>.
# Written only by `ship-sentinel.sh attest`, bound like the sentinel it stands in for (review: the tree fingerprint; e2e:
# the critical-path fingerprint, as review-code's E2E sentinel is), never spelled FRESH: the PR body says "manual
# attestation" and quotes the user's words. Line 4 is mandatory: the shipping agent never attests its own work (a gate the
# agent clears for itself is the self-override the review and test gates exist to prevent); only the user waives it.
_ship_manual_fp() { if [ "$1" = e2e ]; then _ship_fp_critical; else ship_fp_tree; fi; }
_ship_fp_critical() { local inc fp rc; inc=$(ship_critical_ere_file) || { echo "SENTINEL-ERROR: critical-path filter unbuildable"; return 1; }; fp=$(ship_fingerprint "$(ship_base_ref)" "$inc"); rc=$?; rm -f "${inc:?}"; printf '%s\n' "$fp"; return $rc; }
_ship_manual_wellformed() {  # $1 kind — 0 when manual-<kind> has the 4-line shape (any tree): the anchor test for the chain
  local f="$SHIP_STATE/manual-$1" l1 l2 l4
  [ -f "$f" ] || return 1
  l1=$(sed -n 1p "$f" | tr -d '[:space:]'); l2=$(sed -n 2p "$f" | tr -d '[:space:]'); l4=$(sed -n 4p "$f" | tr -d '[:space:]')
  _ship_hex64 "$l1" && _ship_epoch_ok "$l2" && [ "$l2" -le $(( $(date +%s) + 300 )) ] && [ -n "$l4" ]
}
_ship_verify_manual() {  # $1 kind, $2 label
  local f="$SHIP_STATE/manual-$1" l1 l2 l3 l4 fp
  [ -f "$f" ] || { echo "$2: MANUAL-ABSENT no attestation for this tree (ask the user; then ship-sentinel.sh attest $1 --note \"…\" --user \"<their words>\")"; return 1; }
  _ship_manual_wellformed "$1" || { echo "$2: MALFORMED attestation (an attestation without the user's words is not one: attest again with --user)"; return 1; }
  l1=$(sed -n 1p "$f" | tr -d '[:space:]'); l2=$(sed -n 2p "$f" | tr -d '[:space:]'); l3=$(sed -n 3p "$f"); l4=$(sed -n 4p "$f")
  fp=$(_ship_manual_fp "$1") || { echo "$2: ERROR $fp"; return 3; }
  [ "$fp" = "$l1" ] || { echo "$2: MANUAL-STALE the bound content changed since the attestation; attest again"; return 1; }
  echo "$2: MANUAL-ATTESTED ${l3:-no note} — user: \"$l4\" (age=$(( $(date +%s) - l2 ))s)"; return 0
}

# The review chain ($SHIP_STATE/review-chain, appended by ship-push.sh): `<fp tree>\t<call>\t<round>\t<reviewed 0|1>\t<files>\t<lines>`.
# The pre-merge re-gate accepts the LAST link when it equals the current tree, whatever the call, but only on top of an
# anchor (a well-formed review sentinel or manual review attestation from earlier in this ship): a fix push does not
# re-open the full review, unreviewed deltas of any size can merge, and every unreviewed one is reported (the final report
# and `REVIEW-DELTA: large`). `reviewed=1` only when ship-push.sh saw a review covering exactly the pushed tree; `manual`
# (the shipping agent's own look) never counts as reviewed.
_ship_review_anchor() {  # prints the anchor's epoch and returns 0 when a well-formed anchor exists
  local f="$SHIP_STATE/review-code-ran" l1 l2
  if [ "$(ship_cfg REVIEW_GATE sentinel)" = manual ]; then
    _ship_manual_wellformed review || return 1; sed -n 2p "$SHIP_STATE/manual-review" | tr -d '[:space:]'; return 0
  fi
  [ -f "$f" ] || return 1
  l1=$(sed -n 1p "$f" | tr -d '[:space:]'); l2=$(sed -n 2p "$f" | tr -d '[:space:]')
  _ship_hex64 "$l1" && _ship_epoch_ok "$l2" || return 1
  printf '%s\n' "$l2"
}
_ship_verify_chain() {  # $1 current tree fp — 0 the last link covers it (prints the CHAIN line) · 1 no link for this tree · 2 HALT
  local chain crev cround crv anc brk
  [ -f "$SHIP_STATE/review-chain" ] || return 1
  chain=$(tail -n 1 "$SHIP_STATE/review-chain"); [ "$(printf '%s' "$chain" | cut -f1)" = "$1" ] || return 1
  anc=$(_ship_review_anchor) || { echo "REVIEW: CHAIN-UNANCHORED a fix-push link exists but no review sentinel (or manual review attestation) anchors this ship: run the review-code skill"; return 2; }
  # A break (a push that integrated another session's commits) after the anchor: the chain cannot carry the gate past it.
  brk=$(awk -F'\t' -v a="$anc" '$2 ~ /^break/ && ($7 == "" || $7+0 >= a+0) { n++ } END { print n+0 }' "$SHIP_STATE/review-chain" 2>/dev/null) || brk=1
  [ "${brk:-1}" -eq 0 ] || { echo "REVIEW: CHAIN-BROKEN commits from another session were integrated after the last review: run the review-code skill on this tree"; return 2; }
  crev=$(printf '%s' "$chain" | cut -f2); cround=$(printf '%s' "$chain" | cut -f3); crv=$(printf '%s' "$chain" | cut -f4)
  echo "REVIEW: CHAIN review=$crev round=${cround:-?} reviewed=${crv:-0} unreviewed_delta: $(ship_chain_unreviewed)"
  return 0
}
ship_chain_unreviewed() {  # prints `files=<n> lines=<n> links=<n>` summed over every unreviewed link (an unknown size counts as ?)
  awk -F'\t' 'BEGIN{f=0;l=0;n=0;u=0} NF{ if ($4!="1") { n++; if ($5 ~ /^[0-9]+$/) f+=$5; else u=1; if ($6 ~ /^[0-9]+$/) l+=$6; else u=1 } }
    END{ printf "files=%s%d lines=%s%d links=%d\n", (u?">=":""), f, (u?">=":""), l, n }' "$SHIP_STATE/review-chain" 2>/dev/null || echo "files=? lines=? links=?"
}

# ---------------------------------------------------------------------------------------------------------
# Sentinel readers (review-code writes these; ship reads them). Each prints one `<NAME>: <VERDICT> <detail>` line
# and returns 0 valid · 1 invalid (missing, mismatch, stale, malformed) · 3 the reader itself could not compute.
# Hash and TTL are checked INDEPENDENTLY; existence is never validity. SENTINEL-ERROR anywhere → 3.
# ---------------------------------------------------------------------------------------------------------
_ship_lines() { awk 'NF{n++} END{print n+0}' "$1" 2>/dev/null; }

ship_verify_review() {  # $SHIP_STATE/review-code-ran: <fp tree> / <epoch> / <HEAD when reviewed>; or the fix-push review chain
  local f="$SHIP_STATE/review-code-ran" ttl l1 l2 now fp crc
  fp=$(ship_fp_tree) || { echo "REVIEW: ERROR $fp"; return 3; }
  # The review chain first, in both modes: a fix push recorded by ship-push.sh covers the pushed tree (see _ship_verify_chain).
  _ship_verify_chain "$fp"; crc=$?
  case "$crc" in 0) return 0 ;; 2) return 1 ;; esac
  [ "$(ship_cfg REVIEW_GATE sentinel)" = manual ] && { _ship_verify_manual review REVIEW; return $?; }
  ttl=$(ship_cfg REVIEW_TTL_SECONDS 43200)
  now=$(date +%s)
  [ -f "$f" ] || { echo "REVIEW: ABSENT no $f (run the review-code skill)"; return 1; }
  l1=$(sed -n 1p "$f" | tr -d '[:space:]'); l2=$(sed -n 2p "$f" | tr -d '[:space:]')
  case "$l1" in *SENTINEL-ERROR*) echo "REVIEW: ERROR the sentinel carries SENTINEL-ERROR; delete it and re-earn"; return 3 ;; esac
  _ship_hex64 "$l1" || { echo "REVIEW: MALFORMED line 1 is not a 64-hex fingerprint"; return 1; }
  _ship_epoch_ok "$l2" && [ "$l2" -le $((now + 300)) ] || { echo "REVIEW: MALFORMED line 2 is not a plausible epoch"; return 1; }
  [ "$fp" = "$l1" ] || { echo "REVIEW: HASH-MISMATCH the tree changed since the review (reviewed $(printf '%.12s' "$l1"), now $(printf '%.12s' "$fp"))"; return 1; }
  [ $((now - l2)) -le "$ttl" ] || { echo "REVIEW: STALE age=$((now - l2))s ttl=${ttl}s (same bytes as reviewed: a re-attestation prompt, not a code problem)"; return 1; }
  echo "REVIEW: FRESH age=$((now - l2))s"
  return 0
}

ship_verify_e2e() {  # $SHIP_STATE/real-e2e-shipgate-passed: hash form (2 lines) or EXEMPT form (3 lines)
  local f="$SHIP_STATE/real-e2e-shipgate-passed" ttl l1 l2 l3 now n inc fpall fpcrit crc
  if [ "$(ship_cfg REVIEW_GATE sentinel)" = manual ]; then
    # No companion writes an EXEMPT sentinel in manual mode: a diff that touches no critical path is exempt by the
    # categorizer itself (the gate applies to critical-path diffs only); a critical diff needs the user's waiver.
    bash "$SHIP_BIN/ship-sentinel.sh" categorize > /dev/null 2>&1; crc=$?
    case "$crc" in
      10) echo "E2E: EXEMPT no critical path changed (manual mode: the categorizer's verdict, recomputed on every read)"; return 0 ;;
      0) _ship_verify_manual e2e E2E; return $? ;;
      *) echo "E2E: ERROR the critical-path categorizer exited $crc (unreadable diff or globs file)"; return 3 ;;
    esac
  fi
  ttl=$(ship_cfg E2E_TTL_SECONDS 43200)
  [ -f "$f" ] || { echo "E2E: ABSENT no $f (run the review-code skill; its test reviewer writes it)"; return 1; }
  n=$(_ship_lines "$f"); l1=$(sed -n 1p "$f"); l2=$(sed -n 2p "$f" | tr -d '[:space:]'); l3=$(sed -n 3p "$f" | tr -d '[:space:]')
  case "$l1" in *SENTINEL-ERROR*) echo "E2E: ERROR sentinel carries SENTINEL-ERROR; delete it and re-earn"; return 3 ;; esac
  now=$(date +%s)
  _ship_epoch_ok "$l2" && [ "$l2" -le $((now + 300)) ] || { echo "E2E: MALFORMED line 2 is not a plausible epoch"; return 1; }
  [ $((now - l2)) -le "$ttl" ] || { echo "E2E: STALE age=$((now - l2))s ttl=${ttl}s (same bytes as tested: a re-attestation prompt, not a code problem)"; return 1; }
  case "$l1" in
    "EXEMPT: "*)
      [ "$n" -eq 3 ] || { echo "E2E: MALFORMED EXEMPT form needs 3 lines, has $n"; return 1; }
      _ship_hex64 "$l3" || { echo "E2E: MALFORMED line 3 is not a 64-hex fingerprint"; return 1; }
      fpall=$(ship_fp_tree) || { echo "E2E: ERROR $fpall"; return 3; }
      [ "$fpall" = "$l3" ] || { echo "E2E: STALE-EXEMPT the tree changed since the exemption was granted (a later code diff cannot inherit a docs-only exemption)"; return 1; }
      echo "E2E: EXEMPT ${l1#EXEMPT: }"; return 0 ;;
    *)
      [ "$n" -eq 2 ] || { echo "E2E: MALFORMED hash form needs 2 lines, has $n"; return 1; }
      l1=$(printf '%s' "$l1" | tr -d '[:space:]')
      _ship_hex64 "$l1" || { echo "E2E: MALFORMED line 1 is neither EXEMPT: nor a 64-hex fingerprint"; return 1; }
      inc=$(ship_critical_ere_file) || { echo "E2E: ERROR cannot build the critical-path filter (CRITICAL_GLOBS_FILE is unreadable, or holds a glob spelling named above)"; return 3; }
      [ -s "$inc" ] || { rm -f "${inc:?}"; echo "E2E: MALFORMED hash form over an empty critical set (no CRITICAL_GLOBS): the writer must use the EXEMPT form, which is bound to the whole tree"; return 1; }
      fpcrit=$(ship_fingerprint "$(ship_base_ref)" "$inc"); local rc=$?; rm -f "${inc:?}"
      [ "$rc" -eq 0 ] || { echo "E2E: ERROR $fpcrit"; return 3; }
      [ "$fpcrit" = "$l1" ] || { echo "E2E: HASH-MISMATCH a critical-path file changed since E2E ran"; return 1; }
      echo "E2E: FRESH age=$((now - l2))s"; return 0 ;;
  esac
}

# ---------------------------------------------------------------------------------------------------------
# Step markers: `$SHIP_STATE/step-<name>` = <fp all> / <HEAD> / <epoch>. A marker is "ok" only while the tree
# (committed, staged, unstaged, untracked) is exactly what it was when written. ship-status.sh reads them.
# ---------------------------------------------------------------------------------------------------------
# The `phase1` marker is the one marker that is a binding, not a resume hint: it uses the check binding (like the Phase-1
# sentinel it mirrors), so it also goes stale when the base moves. Every other marker uses the review fingerprint.
_ship_step_fp() { if [ "$1" = phase1 ]; then ship_fp_phase1; else ship_fp_tree; fi; }
ship_step_mark() {
  local fp; fp=$(_ship_step_fp "$1") || { ship_log "step-mark $1 skipped: $fp"; return 1; }
  ship_write_atomic "$SHIP_STATE/step-$1" "$fp" "$(git rev-parse HEAD 2>/dev/null)" "$(date +%s)"
}
ship_step_ok() {  # 0 marker valid for the current tree · 1 stale · 2 absent
  local f="$SHIP_STATE/step-$1" fp
  [ -f "$f" ] || return 2
  fp=$(_ship_step_fp "$1") || return 1
  [ "$(sed -n 1p "$f" | tr -d '[:space:]')" = "$fp" ]
}
