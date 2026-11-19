#!/usr/bin/env bash
# worktree-lib.sh — shared helpers for the worktree `bin/*.sh` scripts. SOURCED, never executed.
#
# Conventions:
#   - bash 3.2 clean (macOS /bin/bash): no associative arrays, no `mapfile`, no case-changing expansions, no namerefs.
#   - `set -u`; no `set -e`; no `pipefail`. A producer is never piped into `grep -q`: capture first, then `case`.
#   - Exit codes: 0 done · 1 refused · 2 usage or configuration · 3 a failed read (fetch, ls-remote, a command slot
#     that must print something) · 5 findings that need the user's answer · 6 created, but a later step failed.
#   - The LAST stdout line of every script is `WORKTREE-RESULT <script> PASS|FAIL <reason> [k=v ...]`. Callers route
#     on the exit code and that line, never on the prose above it.
#   - Arguments are parsed strictly: an unknown option or an extra argument is exit 2, so skill text and scripts that
#     are out of step fail at the call instead of doing something else.
#   - Configuration is `worktree.env` next to SKILL.md (or `--config <file>`): KEY=value lines and # comments on their own lines (a value may not begin with #). It is
#     parsed, never sourced. The *_CMD values are commands these scripts RUN with `bash -c`; the values they need
#     (ISSUE, ISSUES, BRANCH, WORKTREE_PATH, MODEL) are passed as environment variables, never pasted into the string.
#   - Test seam: with WORKTREE_TEST_MODE=1 AND WORKTREE_TEST_STOP_AFTER=<step>, worktree-create.sh exits 99 right
#     after that step with no result line, standing in for a create that was killed there. Both variables are
#     needed, so one stray variable in a user's environment does nothing. Never set them outside the tests.

set -u

WT_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WT_SKILL_DIR="$(cd "$WT_BIN/.." && pwd -P)"
WT_SCRIPT="unknown"
WT_CONFIG=""
WT_TAB="$(printf '\t')"

wt_result() {  # wt_result <PASS|FAIL> <reason> [k=v ...] — always the last stdout line
  local t="$1"; shift
  echo "WORKTREE-RESULT $WT_SCRIPT $t $*" | sed 's/ *$//'
}

wt_die() {  # wt_die <rc> <reason> [message...] — MAIN SHELL ONLY
  local rc="$1" reason="$2"; shift 2
  [ "$#" -gt 0 ] && echo "STOP: $*"
  wt_result FAIL "$reason"
  exit "$rc"
}

wt_kv_get() {  # wt_kv_get <file> <key> — 0 found (value printed, may be empty) · 1 absent · 2 unreadable or malformed
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

wt_cfg() {  # wt_cfg <KEY> [default] — the value, or the default when the key is absent or empty
  local v
  v=$(wt_kv_get "$WT_CONFIG" "$1") || v=""
  if [ -n "$v" ]; then printf '%s\n' "$v"; else printf '%s\n' "${2:-}"; fi
}

wt_is_number() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# wt_export_gh_repo — MAIN SHELL ONLY (needs WT_CONFIG). GH_REPO=owner/repo in the config: exported, so every `gh`
# (worktree-issue.sh and any slot command) targets that repository, not the one gh would infer from the remotes.
# Empty or absent: the environment is left alone and gh resolves the repository its own default way.
wt_export_gh_repo() {
  local r; r=$(wt_cfg GH_REPO "")
  [ -n "$r" ] || return 0
  case "$r" in */*/*|/*|*/|-*|*[!A-Za-z0-9._/-]*) wt_die 2 config-malformed "GH_REPO must be owner/repo or empty (got '$r')" ;;
    */*) GH_REPO="$r"; export GH_REPO ;;
    *) wt_die 2 config-malformed "GH_REPO must be owner/repo or empty (got '$r')" ;; esac
}

# wt_load_config — MAIN SHELL ONLY. Validates the file and sets WT_BASE, WT_REMOTE, WT_BASE_REF (what a new branch
# starts from), WT_MAX_LEN, WT_POST_MODE, WT_PUSH. Any problem is exit 2 before anything is created.
wt_load_config() {
  local v rc
  [ -n "$WT_CONFIG" ] || WT_CONFIG="$WT_SKILL_DIR/worktree.env"
  [ -f "$WT_CONFIG" ] || wt_die 2 config-missing "no configuration at $WT_CONFIG: copy worktree.env.example to worktree.env and fill it, or pass --config <file>"
  WT_CONFIG="$(cd "$(dirname "$WT_CONFIG")" && pwd -P)/$(basename "$WT_CONFIG")"   # absolute: slot commands may run elsewhere
  wt_kv_get "$WT_CONFIG" BASE_BRANCH >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 2 ] || wt_die 2 config-malformed "$WT_CONFIG is unreadable or malformed (only KEY=value lines and # comments on their own lines are allowed; a value may not begin with #)"
  WT_BASE=$(wt_cfg BASE_BRANCH "")
  [ -n "$WT_BASE" ] || wt_die 2 config-base-branch "BASE_BRANCH is not set in $WT_CONFIG"
  case "$WT_BASE" in -*|*[!A-Za-z0-9._/-]*) wt_die 2 config-base-branch "BASE_BRANCH is not a plain branch name: $WT_BASE" ;; esac
  # BASE_REMOTE: absent means origin; present and empty means "this repository has no remote".
  v=$(wt_kv_get "$WT_CONFIG" BASE_REMOTE); rc=$?
  if [ "$rc" -eq 1 ]; then WT_REMOTE="origin"; else WT_REMOTE="$v"; fi
  case "$WT_REMOTE" in -*|*[!A-Za-z0-9._-]*) wt_die 2 config-malformed "BASE_REMOTE is not a plain remote name: $WT_REMOTE" ;; esac
  if [ -n "$WT_REMOTE" ]; then WT_BASE_REF="refs/remotes/$WT_REMOTE/$WT_BASE"; else WT_BASE_REF="refs/heads/$WT_BASE"; fi
  WT_MAX_LEN=$(wt_cfg BRANCH_MAX_LEN 50)
  wt_is_number "$WT_MAX_LEN" || wt_die 2 config-malformed "BRANCH_MAX_LEN must be a number from 20 to 200 (got '$WT_MAX_LEN')"
  { [ "$WT_MAX_LEN" -ge 20 ] && [ "$WT_MAX_LEN" -le 200 ]; } || wt_die 2 config-malformed "BRANCH_MAX_LEN must be a number from 20 to 200 (got '$WT_MAX_LEN')"
  WT_POST_MODE=$(wt_cfg POST_CREATE_MODE wait)
  case "$WT_POST_MODE" in wait|background) ;; *) wt_die 2 config-malformed "POST_CREATE_MODE must be wait|background (got '$WT_POST_MODE')" ;; esac
  WT_PUSH=$(wt_cfg PUSH_ON_ISSUE 0)
  case "$WT_PUSH" in 0|1) ;; *) wt_die 2 config-malformed "PUSH_ON_ISSUE must be 0|1 (got '$WT_PUSH')" ;; esac
  wt_export_gh_repo
  # set -f: the entries are names, not patterns; without it a `*` would expand against the caller's directory.
  set -f
  for v in $(wt_cfg COPY_FILES ""); do
    case "$v" in /*|..|../*|*/..|*/../*) set +f; wt_die 2 config-copy-files "COPY_FILES entries are paths inside the repository (got '$v')" ;; esac
  done
  set +f
}

# wt_stop_after <step> — the test seam described in the header.
wt_stop_after() {
  [ "${WORKTREE_TEST_MODE:-}" = "1" ] && [ "${WORKTREE_TEST_STOP_AFTER:-}" = "$1" ]
}

# wt_dirty_count <worktree> [extra git-status args] — number of changed paths; return 3 when git status itself fails
# (an unreadable index is never "clean"). Untracked files are always counted, one by one: a user's
# status.showUntrackedFiles=no would otherwise hide them, and `git worktree remove` would then delete them unasked.
# Untracked files are the one thing in a worktree no ref can bring back.
wt_dirty_count() {
  local wt="$1" out; shift
  out=$(git -C "$wt" -c status.showUntrackedFiles=all status --porcelain --untracked-files=all "$@" 2>/dev/null) || return 3
  if [ -z "$out" ]; then echo 0; else printf '%s\n' "$out" | grep -c .; fi
}

# wt_live_cwds — MAIN SHELL ONLY. Prints the working directory of every live process this account owns (physical
# paths, one per line) and returns 0; returns 3 with a reason on stderr when the list cannot be trusted. A worktree
# that a process sits in (a session, a dev server, a test watcher, a plain shell) is in use: removing it pulls the
# folder out from under that process. Not only agent sessions count. Fails closed when:
#   - the scan does not see this script's own process (the scan is broken, so an empty answer means nothing);
#   - another person's account (not root, not a system account) owns processes and this account is not root:
#     their working directories cannot be read, so the list would be partial;
#   - neither /proc nor lsof can be read, or lsof does not finish in WT_LSOF_WAIT seconds (default 30).
# Returns 4 (unknown, not a failure) under Git Bash / MSYS / Cygwin: their /proc lists only their own processes, so a
# native session, editor or server holding the folder is invisible. Neither "not in use" nor a stop that blocks every
# remove is true there; the caller asks the user (remove) or skips (sweep).
# Test seam (test mode only, like WORKTREE_TEST_STOP_AFTER): WORKTREE_TEST_PROC_ROOT replaces /proc,
# WORKTREE_TEST_PS_USERS replaces the `ps -axo uid=,user=` owner scan, WORKTREE_TEST_UNAME replaces `uname -s`.
wt_live_cwds() {
  local proc="/proc" me self raw="" p c uid owners="" out pid i max minuid line cur os
  os=$(uname -s 2>/dev/null)
  if [ "${WORKTREE_TEST_MODE:-}" = "1" ] && [ -n "${WORKTREE_TEST_UNAME:-}" ]; then os="$WORKTREE_TEST_UNAME"; fi
  case "$os" in MINGW*|MSYS*|CYGWIN*) echo "this shell ($os) cannot see native Windows processes" >&2; return 4 ;; esac
  if [ "${WORKTREE_TEST_MODE:-}" = "1" ] && [ -n "${WORKTREE_TEST_PROC_ROOT:-}" ]; then proc="$WORKTREE_TEST_PROC_ROOT"; fi
  me=$(id -u) || { echo "cannot read this account's uid" >&2; return 3; }
  self="${BASHPID:-$(sh -c 'echo $PPID')}"   # this shell's own pid, also inside a $( ) subshell (bash 3.2 has no BASHPID)
  # Whose processes exist: another person's would be invisible to a non-root scan.
  if [ "$me" -ne 0 ]; then
    if [ "${WORKTREE_TEST_MODE:-}" = "1" ] && [ -n "${WORKTREE_TEST_PS_USERS:-}" ]; then out=$(bash -c "$WORKTREE_TEST_PS_USERS") || out="#failed"
    else out=$(ps -axo uid=,user= 2>/dev/null) || out="#failed"; fi
    [ "$out" != "#failed" ] || { echo "the process-owner scan (ps) failed, so it cannot be told whose processes are invisible" >&2; return 3; }
    minuid=1000; [ "$(uname -s)" = "Darwin" ] && minuid=500
    while read -r uid line; do
      case "$uid" in ''|*[!0-9]*) continue ;; esac
      [ "$uid" -ne "$me" ] && [ "$uid" -ge "$minuid" ] && [ "$uid" -lt 65534 ] && owners="$owners ${line:-uid$uid}"
    done <<EOF_OWNERS
$out
EOF_OWNERS
    if [ -n "$owners" ]; then
      echo "processes owned by other accounts exist ($(printf '%s\n' $owners | sort -u | tr '\n' ' ' | sed 's/ $//')) and this account cannot read their working directories; run as root, or after their sessions end" >&2
      return 3
    fi
  fi
  if [ -d "$proc/self" ] || [ -d "$proc/$self" ]; then
    for p in "$proc"/[0-9]*; do
      c=$(readlink "$p/cwd" 2>/dev/null) || continue   # gone, or not ours (the owner scan above covers other people)
      raw="$raw$c
"
      [ "${p##*/}" != "$self" ] || self="#seen"
    done
  elif command -v lsof >/dev/null 2>&1; then
    out=$(mktemp "${TMPDIR:-/tmp}/wt-lsof.XXXXXX") || { echo "cannot create a temporary file for lsof" >&2; return 3; }
    (exec lsof -a -d cwd -u "$me" -Fn) >"$out" 2>/dev/null &
    pid=$!; i=0; max=$(( ${WT_LSOF_WAIT:-30} * 10 ))
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$i" -ge "$max" ]; then kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -f "$out"; echo "lsof did not finish in ${WT_LSOF_WAIT:-30}s" >&2; return 3; fi
      sleep 0.1; i=$((i + 1))
    done
    wait "$pid" || { rm -f "$out"; echo "lsof failed, so the processes in use cannot be listed" >&2; return 3; }
    cur=""
    while IFS= read -r line; do
      case "$line" in p*) cur="${line#p}" ;; n/*) raw="$raw${line#n}
"; [ "$cur" != "$self" ] || self="#seen" ;; esac
    done < "$out"
    rm -f "$out"
  else
    echo "neither /proc nor lsof is available, so the processes in use cannot be listed" >&2; return 3
  fi
  [ "$self" = "#seen" ] || { echo "the process scan did not see this script's own process, so its answer cannot be trusted" >&2; return 3; }
  printf '%s' "$raw" | sort -u | while IFS= read -r c; do
    [ -n "$c" ] || continue
    (cd "$c" 2>/dev/null && pwd -P) || printf '%s\n' "$c"
  done | sort -u
}

# wt_is_live <path> <live list> — 0 when a directory in the list is <path> or below it (<path>-2 is not below it).
wt_is_live() {
  local wt="$1" c
  while IFS= read -r c; do
    case "$c" in "$wt"|"$wt"/*) return 0 ;; esac
  done <<EOF_LIVE
$2
EOF_LIVE
  return 1
}

# wt_mount_below <path> — 0 when a mount point is at <path> or below it, 1 when none, 2 when the mount table cannot be
# read (the caller treats that as "cannot rule it out"). `git worktree remove --force` deletes recursively and does not
# stop at a mount point, so a volume attached below a worktree would be emptied. Test seam (test mode only):
# WORKTREE_TEST_MOUNTINFO replaces /proc/self/mountinfo.
wt_mount_below() {
  local p="${1%/}" mi="/proc/self/mountinfo" table raw m
  if [ "${WORKTREE_TEST_MODE:-}" = "1" ] && [ -n "${WORKTREE_TEST_MOUNTINFO:-}" ]; then mi="$WORKTREE_TEST_MOUNTINFO"; fi
  if [ -r "$mi" ]; then
    table=$(awk '{ print $5 }' "$mi" 2>/dev/null) || return 2
    table=$(printf '%s\n' "$table" | sed 's/\\040/ /g; s/\\011/	/g; s/\\134/\\/g') || return 2
  elif [ -e "$mi" ] || [ "$mi" != "/proc/self/mountinfo" ]; then
    return 2
  else
    raw=$(mount 2>/dev/null) || return 2
    table=$(printf '%s\n' "$raw" | sed -n 's/^.* on \(\/.*\) ([^()]*)$/\1/p') || return 2
    # A line the parse cannot read would be a mount that reads as "none".
    [ "$(printf '%s\n' "$raw" | grep -c .)" -eq "$(printf '%s\n' "$table" | grep -c .)" ] || return 2
  fi
  [ -n "$table" ] || return 2
  while IFS= read -r m; do
    case "$m" in "$p"|"$p"/*) return 0 ;; esac
  done <<EOF_MOUNTS
$table
EOF_MOUNTS
  return 1
}

# wt_in_use_or_die <worktree> — MAIN SHELL ONLY. Refuses (exit 1) when a process sits in the worktree or a mount point
# is at or below it, and stops (exit 3) when either cannot be ruled out. No flag overrides it: discarding uncommitted
# files is the user's to consent to; deleting into a mounted volume or from under a running session is not.
# Where the platform cannot see the processes at all (wt_live_cwds exit 4), it sets WT_IN_USE_UNKNOWN=1 instead: the
# caller turns that into a finding the user answers.
WT_IN_USE_UNKNOWN=0
wt_in_use_or_die() {
  local live mb=0 rc=0
  live=$(wt_live_cwds) || rc=$?
  case "$rc" in
    0) ;;
    4) WT_IN_USE_UNKNOWN=1 ;;
    *) wt_die 3 live-unknown "the processes using $1 could not be listed (reason above), so it cannot be called unused" ;;
  esac
  if [ "$rc" -eq 0 ] && wt_is_live "$1" "$live"; then
    wt_die 1 in-use "a process is running inside $1 (a session, a server, a shell); end it or wait for it, then run this again"
  fi
  wt_mount_below "$1" || mb=$?
  case "$mb" in
    0) wt_die 1 mount-below "a mount point is at or below $1; unmount it first" ;;
    1) ;;
    *) wt_die 3 mount-unknown "the mount table could not be read, so a mount below $1 cannot be ruled out" ;;
  esac
}

# wt_touched_within <dir> <hours> — 0 when any file under <dir> changed in the last <hours> hours, 1 when none. A
# worktree an isolated subagent is working in is not that process's working directory, so the live check cannot see
# it; recent edits can. Regenerable build folders and .git are skipped. FAILS CLOSED: a find error or a missing folder
# counts as touched. A gitignored scratch file a session just wrote counts: that is exactly what `git status` hides.
wt_touched_within() {
  local dir="$1" mins hit
  mins=$(( $2 * 60 ))
  [ -d "$dir" ] || return 0
  hit=$(find -H "$dir" \( -name node_modules -o -name .next -o -name dist -o -name .turbo -o -name coverage -o -name .git \) -prune \
    -o -type f -mmin -"$mins" -print -quit 2>/dev/null) || return 0
  [ -z "$hit" ] || return 0
  return 1
}

# wt_repo_init — MAIN SHELL ONLY. Sets WT_COMMON (absolute git common dir), WT_TOP (this checkout's top level, empty
# when run from a bare repository's root) and WT_PARENT (where sibling folders live). WT_PARENT is, in order: the
# WORKTREE_PARENT_DIR environment variable, the WORKTREE_PARENT_DIR setting (both must exist), or the default: one
# folder per repository, `<parent of the main checkout>/<its name>-worktrees` (made by the first create; WT_PARENT_NEW=1
# until it exists, and nothing else creates it), so worktrees of
# different repositories never mix in one folder. A bare-repository layout keeps its worktrees in the folder that holds
# the bare repository, which is already per repository.
wt_repo_init() {
  local c t
  c=$(git rev-parse --git-common-dir 2>/dev/null) || wt_die 2 not-a-repo "not inside a git repository: $(pwd)"
  WT_COMMON="$(cd "$c" && pwd -P)" || wt_die 2 not-a-repo "git common dir unreadable: $c"
  t=$(git rev-parse --show-toplevel 2>/dev/null) || t=""
  if [ -n "$t" ]; then WT_TOP="$(cd "$t" && pwd -P)" || WT_TOP=""; else WT_TOP=""; fi
  WT_PARENT_NEW=0
  WT_PARENT="${WORKTREE_PARENT_DIR:-}"
  [ -n "$WT_PARENT" ] || WT_PARENT=$(wt_cfg WORKTREE_PARENT_DIR "")
  if [ -z "$WT_PARENT" ]; then
    local first bare main
    first=$(wt_porcelain | sed -n '1,3p')
    main=$(printf '%s\n' "$first" | sed -n 's/^worktree //p' | head -1)
    case "$first" in *"
bare"*) bare=1 ;; *) bare=0 ;; esac
    if [ "$bare" -eq 1 ] || [ -z "$main" ]; then
      WT_PARENT="$(dirname "$WT_COMMON")"
    else
      WT_PARENT="$(cd "$(dirname "$main")" && pwd -P)/$(basename "$main")-worktrees"
      [ -d "$WT_PARENT" ] || WT_PARENT_NEW=1
    fi
  fi
  [ "$WT_PARENT_NEW" -eq 0 ] || return 0
  [ -d "$WT_PARENT" ] || wt_die 2 config-parent-dir "the worktree parent directory does not exist: $WT_PARENT"
  WT_PARENT="$(cd "$WT_PARENT" && pwd -P)" || wt_die 2 config-parent-dir "the worktree parent directory is unreadable"
}

wt_folder_for_branch() { printf '%s\n' "$1" | tr '/' '-'; }

# wt_porcelain — `git worktree list --porcelain`, with every path in the shell's own form. Git for Windows prints
# C:/Users/…, which never compares equal to (or prints like) the /c/… or /tmp/… paths `pwd -P` gives under its bash:
# there each `worktree` line goes through cygpath -u.
wt_porcelain() {
  case "${OSTYPE:-}" in
    msys*|cygwin*)
      if command -v cygpath >/dev/null 2>&1; then
        git worktree list --porcelain 2>/dev/null | while IFS= read -r l; do
          case "$l" in "worktree "[A-Za-z]:[/\\]*) printf 'worktree %s\n' "$(cygpath -u "${l#worktree }")" ;; *) printf '%s\n' "$l" ;; esac
        done
        return 0
      fi ;;
  esac
  git worktree list --porcelain 2>/dev/null
}

# wt_worktree_for_branch <branch> — the path of the worktree that has <branch> checked out; empty when none.
wt_worktree_for_branch() {
  wt_porcelain | awk -v b="refs/heads/$1" '
    /^worktree /{w=substr($0,10)}
    /^branch /{if (substr($0,8)==b) print w}'
}

# wt_worktrees — every non-bare worktree as `<path><TAB><branch-or-(detached)><TAB><sha>`.
wt_worktrees() {
  wt_porcelain | awk -v T="$WT_TAB" '
    function flush() { if (w != "" && !bare) print w T (b == "" ? "(detached)" : b) T h; w=""; b=""; h=""; bare=0 }
    /^worktree /{flush(); w=substr($0,10)}
    /^HEAD /{h=substr($0,6)}
    /^branch /{b=substr($0,8); sub(/^refs\/heads\//,"",b)}
    /^bare$/{bare=1}
    END{flush()}'
}

# wt_gitpath <worktree> <name> — absolute path of a per-worktree git-dir file. `git rev-parse --git-path` answers
# relative to the directory it runs in for a primary checkout and absolute for a linked one; this always returns absolute.
wt_gitpath() {
  local wt="$1" p d
  p=$(git -C "$wt" rev-parse --git-path "$2" 2>/dev/null) || return 1
  # Absolute is /… or, from Git for Windows, a drive form C:/… (which `cd` accepts as is).
  case "$p" in /*|[A-Za-z]:[/\\]*) ;; *) p="$wt/$p" ;; esac
  d="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "$d" "$(basename "$p")"
}

# wt_issues_of <worktree> — the recorded issue set (`7` or `7-8`); empty when none. Return 3 when a marker exists but cannot be read.
wt_issues_of() {
  local f v
  f=$(wt_gitpath "$1" worktree-issues) || return 0
  [ -e "$f" ] || return 0
  [ -r "$f" ] || return 3
  v=$(sed -n 1p "$f" 2>/dev/null | tr -d '[:space:]') || return 3
  printf '%s\n' "$v"
}

# wt_slot <command> — run a configured command with bash -c. The caller exports what the command may read.
wt_slot() { WT_BIN="$WT_BIN" WT_CONFIG="$WT_CONFIG" bash -c "$1"; }
