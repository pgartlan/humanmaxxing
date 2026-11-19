#!/usr/bin/env bash
# tests/lib.sh — shared harness for the script tests. SOURCED by every tests/**/*.test.sh.
#
# Each test file builds throwaway git fixtures (a bare origin plus a work clone) under one temp dir, installs the
# skill under test into the fixture the way a user would (.claude/skills/<name>), runs the real scripts, and asserts
# on the two things a caller routes on: the exit code and the last stdout line. Nothing is mocked.
#
#   t_fixture <name> [ship.env lines...]   new fixture; cwd becomes its work clone; sets B (bin dir) and ST (state dir)
#   run <cmd...>                           runs cmd with stdin from T_STDIN (default empty); sets RC, OUT, LAST
#   expect <rc> <ERE> <label>              asserts RC and that LAST matches ERE
#   expect_rc <rc> <label>                 asserts RC only
#   expect_out <ERE> <label>               asserts some line of OUT matches
#   refute_out <ERE> <label>               asserts no line of OUT matches
#   check <label> <cmd...>                 asserts cmd exits 0
#   t_done                                 prints the file's tally; exit status 1 when anything failed

set -u
T_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
T_TMP="$(mktemp -d "${TMPDIR:-/tmp}/skilltests.XXXXXX")" || exit 2
T_PASS=0; T_FAIL=0; T_STDIN=""; RC=0; OUT=""; LAST=""
trap 'rm -rf "$T_TMP"' EXIT

# Isolate from the developer's git configuration (signing, hooks, default branch, a global ignore file).
export HOME="$T_TMP/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_TERMINAL_PROMPT=0
export GIT_DEFAULT_HASH=sha1   # fixtures assert 40-hex values; a SHA-256 fixture asks for it explicitly
unset SHIP_CONTRACT_VERIFIED CLAUDE_CODE_SESSION_ID GH_REPO 2>/dev/null   # GH_REPO: a developer's own must not leak into "unset" cases

t_pass() { T_PASS=$((T_PASS + 1)); [ -n "${T_VERBOSE:-}" ] && echo "  ok    $1"; return 0; }
t_fail() {
  T_FAIL=$((T_FAIL + 1)); echo "  FAIL  $1"
  shift; for l in "$@"; do echo "        $l"; done
  echo "        --- output (last 12 lines) ---"; printf '%s\n' "$OUT" | tail -12 | sed 's/^/        | /'
  return 0
}

run() {
  OUT="$(printf '%s' "$T_STDIN" | "$@" 2>&1)"; RC=$?
  LAST="$(printf '%s\n' "$OUT" | tail -1)"; T_STDIN=""
}
expect() {
  local want_rc="$1" ere="$2" label="$3" hit=0
  printf '%s\n' "$LAST" | grep -Eq -- "$ere" && hit=1
  if [ "$RC" = "$want_rc" ] && [ "$hit" = 1 ]; then t_pass "$label"
  else t_fail "$label" "want rc=$want_rc last~/$ere/" "got  rc=$RC last=$LAST"; fi
}
expect_rc() { if [ "$RC" = "$1" ]; then t_pass "$2"; else t_fail "$2" "want rc=$1" "got  rc=$RC"; fi; }
expect_out() {
  local hit=0; printf '%s\n' "$OUT" | grep -Eq -- "$1" && hit=1
  if [ "$hit" = 1 ]; then t_pass "$2"; else t_fail "$2" "want a line matching /$1/"; fi
}
refute_out() {
  local hit=0; printf '%s\n' "$OUT" | grep -Eq -- "$1" && hit=1
  if [ "$hit" = 0 ]; then t_pass "$2"; else t_fail "$2" "want NO line matching /$1/"; fi
}
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then t_pass "$label"; else OUT="(check command: $*)"; t_fail "$label" "command exited non-zero"; fi
}

# t_fixture <name> [ship.env lines...] — origin.git + work clone on main with app/api, lib, docs, CHANGELOG; the ship
# skill installed and committed; ship.env written from the arguments (BASE_BRANCH=main is always present).
t_fixture() {
  local name="$1"; shift
  local d="$T_TMP/$name"; mkdir -p "$d" && cd "$d" || exit 2
  git init -q --bare -b main origin.git && git init -q -b main work && cd work || exit 2
  mkdir -p app/api docs lib .claude/skills
  echo a > app/api/r.ts; echo l > lib/u.ts; echo n > lib/n.ts; echo d > docs/x.md; echo c > CHANGELOG.md
  cp -R "$T_ROOT/skills/ship" .claude/skills/ship || exit 2
  printf 'app/api/**\nlib/**\n' > .claude/critical-paths.txt
  { echo "BASE_BRANCH=main"; for l in "$@"; do echo "$l"; done; } > .claude/skills/ship/ship.env
  git add -A && git commit -qm init && git remote add origin ../origin.git && git push -q -u origin main || exit 2
  B=.claude/skills/ship/bin; SKILL="$PWD/.claude/skills/ship"; ST="$(git rev-parse --git-path ship-state)"
  FIX="$d"
}
t_branch() { git checkout -q -b "$1" && echo "$1" >> app/api/r.ts && git commit -qam "Refs #7 $1" || exit 2; }
t_init() { T_STDIN="${1:-}"; run bash "$B/ship-init.sh" --contract=2 --skill-dir "$SKILL"; }
# t_base_commit <file> <content> — advance origin/main by one commit that sets <file> to <content>.
t_base_commit() {
  local cur; cur="$(git rev-parse --abbrev-ref HEAD)"
  git checkout -q main && echo "$2" > "$1" && git add -A && git commit -qm "base: $1" && git push -q origin main \
    && git checkout -q "$cur" || exit 2
}
# ---- worktree skill fixtures and helpers (tests/worktree/*) ---------------------------------------------------------
#   t_wt_fixture <name> [worktree.env lines...]       origin.git + primary clone on main, skill installed and pushed;
#                                                      cwd = primary; sets B, FIX (parent dir: siblings land here), FIXP
#                                                      (FIX, physical), ORIGIN, PRIMARY
#   t_wt_bare_fixture <name> [worktree.env lines...]  same, but a `git clone --bare` at $FIX/.bare (no fetch refspec)
#                                                      and a worktree $FIX/main; cwd = $FIX/main
#   t_wt_cfg <file> [lines...]                         writes $FIX/<file> (BASE_BRANCH=main first); sets CFG
t_wt_seed_origin() {
  local d="$1"
  git init -q --bare -b main "$d/origin.git" && git init -q -b main "$d/seed" || exit 2
  ( cd "$d/seed" && echo base > README && git add -A && git commit -qm init \
    && git remote add origin ../origin.git && git push -q origin main ) || exit 2
  rm -rf "$d/seed"
}
# Installs the skill into the checkout in cwd, writes its worktree.env from the arguments, commits and pushes main.
t_wt_install() {
  local dest=".claude/skills/worktree" l
  mkdir -p .claude/skills || exit 2
  if [ -d "$T_ROOT/skills/worktree" ]; then cp -R "$T_ROOT/skills/worktree" "$dest" || exit 2; else mkdir -p "$dest"; fi
  # The tests' worktrees go beside the checkout (pinned here; a later WORKTREE_PARENT_DIR line in "$@" wins). The
  # default folder (<repo>-worktrees) has its own test.
  { echo "BASE_BRANCH=main"; echo "WORKTREE_PARENT_DIR=$(dirname "$(pwd -P)")"; for l in "$@"; do echo "$l"; done; } > "$dest/worktree.env"
  git add -A && git commit -qm "install worktree skill" && git push -q origin main || exit 2
}
t_wt_fixture() {
  local name="$1"; shift
  local d="$T_TMP/$name"; mkdir -p "$d" || exit 2
  t_wt_seed_origin "$d"
  git clone -q "$d/origin.git" "$d/primary" 2>/dev/null || exit 2
  cd "$d/primary" || exit 2
  t_wt_install "$@"
  B=.claude/skills/worktree/bin; FIX="$d"; FIXP="$(cd "$d" && pwd -P)"; ORIGIN="$d/origin.git"; PRIMARY="$d/primary"
}
t_wt_bare_fixture() {
  local name="$1"; shift
  local d="$T_TMP/$name"; mkdir -p "$d" || exit 2
  t_wt_seed_origin "$d"
  git clone -q --bare "$d/origin.git" "$d/.bare" 2>/dev/null || exit 2
  git -C "$d/.bare" worktree add -q "$d/main" main || exit 2
  cd "$d/main" || exit 2
  git config branch.main.remote origin && git config branch.main.merge refs/heads/main || exit 2
  t_wt_install "$@"
  B=.claude/skills/worktree/bin; FIX="$d"; FIXP="$(cd "$d" && pwd -P)"; ORIGIN="$d/origin.git"; PRIMARY="$d/main"
}
t_wt_cfg() {
  local f="$1" l; shift
  CFG="$FIX/$f"
  { echo "BASE_BRANCH=main"; echo "WORKTREE_PARENT_DIR=$FIXP"; for l in "$@"; do echo "$l"; done; } > "$CFG"
}
# t_wt_run_in <dir> <cmd...> — like run, from another working directory (sets RC, OUT, LAST)
t_wt_run_in() { local d="$1"; shift; OUT="$(cd "$d" && "$@" 2>&1 </dev/null)"; RC=$?; LAST="$(printf '%s\n' "$OUT" | tail -1)"; }
t_wt_tip() { git -C "$ORIGIN" rev-parse "$1"; }
t_wt_count() { git worktree list --porcelain | grep -c '^worktree '; }
t_wt_listed() { git worktree list --porcelain | grep -qx "branch refs/heads/$1"; }
# Git for Windows lists C:/… paths; the fixtures hold the shell's /c/… or /tmp/… form (cygpath -u maps one to the other).
t_wt_has_path() {
  case "${OSTYPE:-}" in
    msys*|cygwin*) git worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r p; do cygpath -u "$p"; done | grep -qxF "$1" ;;
    *) git worktree list --porcelain | grep -qxF "worktree $1" ;;
  esac
}
t_wt_branches() { git for-each-ref refs/heads | wc -l | tr -d ' '; }
t_wt_gitdir() { git -C "$1" rev-parse --absolute-git-dir; }
# t_wt_gitfile <worktree dir> <log|status|pid> — the first file in that worktree's git dir whose name mentions the kind
t_wt_gitfile() {
  local g; g="$(t_wt_gitdir "$1")" || return 1
  local pat="$2"; [ "$2" = status ] && pat='(status|\.rc$|exit)'
  find "$g" -mindepth 1 -maxdepth 1 2>/dev/null | sed 's|.*/||' | grep -E "(post-create|setup).*$pat" | head -1 | sed "s|^|$g/|"
}
t_wt_wait_gitfile() {
  local n="${3:-100}" i=0
  while [ -z "$(t_wt_gitfile "$1" "$2")" ] && [ "$i" -lt "$n" ]; do sleep 0.1; i=$((i + 1)); done
  [ -n "$(t_wt_gitfile "$1" "$2")" ]
}
# t_wt_wait_file <path> [tenths-of-seconds]  polls until the file exists
t_wt_wait_file() {
  local n="${2:-100}" i=0
  while [ ! -e "$1" ] && [ "$i" -lt "$n" ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$1" ]
}
# t_wt_pristine <label> — nothing was created: one worktree, one local branch, no extra directory next to the clones.
t_wt_pristine() {
  local extra; extra="$(find "$FIX" -mindepth 1 -maxdepth 1 -type d ! -name origin.git ! -name primary ! -name other ! -name home ! -name origin.gone | wc -l | tr -d ' ')"
  if [ "$(t_wt_count)" = 1 ] && [ "$(t_wt_branches)" = 1 ] && [ "$extra" = 0 ]; then t_pass "$1"
  else OUT="worktrees=$(t_wt_count) branches=$(t_wt_branches) extra-dirs=$extra"; t_fail "$1" "want one worktree, one branch, no sibling folder"; fi
}
# t_wt_remote_commit <branch> <file> <content> — a commit on origin's <branch> (created from main when absent) made from
# a second clone, so the primary's own refs stay as they were.
t_wt_remote_commit() {
  [ -d "$FIX/other" ] || git clone -q "$ORIGIN" "$FIX/other" 2>/dev/null || exit 2
  ( cd "$FIX/other" && git fetch -q origin \
    && { if git rev-parse -q --verify "refs/remotes/origin/$1" >/dev/null; then git checkout -q -B "$1" "origin/$1"; else git checkout -q -B "$1" origin/main; fi; } \
    && echo "$3" > "$2" && git add -A && git commit -qm "remote: $1 $2" && git push -q origin "$1" ) || exit 2
}
# t_wt_hold_install — a post-checkout hook in the repo in cwd (git runs it inside `worktree add`) that, while $FIX/hold
# exists, announces itself in $FIX/hold.reached and then waits for $FIX/go (at most 10s). It freezes a create in the
# window between the add and the marker, with real git and no stand-in for the script.
t_wt_hold_install() {
  local c; c="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"; mkdir -p "$c/hooks" || exit 2
  cat > "$c/hooks/post-checkout" <<EOF_HOOK
#!/bin/sh
[ -f "$FIX/hold" ] || exit 0
echo reached > "$FIX/hold.reached"
i=0
while [ ! -f "$FIX/go" ] && [ \$i -lt 50 ]; do sleep 0.2; i=\$((i + 1)); done
exit 0
EOF_HOOK
  chmod +x "$c/hooks/post-checkout"
}
t_wt_hold_on() { rm -f "$FIX/go" "$FIX/hold.reached"; : > "$FIX/hold"; }
t_wt_hold_off() { : > "$FIX/go"; rm -f "$FIX/hold"; }
# ---- retro skill fixtures and helpers (tests/retro/*) ---------------------------------------------------------------
#   t_retro_fixture <name> [retro.env lines...]   origin.git + work clone on main, an old first commit (outside every
#                                                  window), the skill installed; retro.env = defaults, then the
#                                                  arguments (a later line for the same key wins). cwd = the clone;
#                                                  sets FIX, ORIGIN, R (the script), CFG (its retro.env)
#   t_retro_cfg [lines...]                         rewrites CFG: the defaults, then the lines
#   t_retro_commit <days ago> <message> [file...]  appends a line to each file (default: a file named after the message
#                                                  count) and commits, dated that many days ago (plus an hour)
#   t_retro_push                                   pushes main, so origin/main (what the script reads) moves
t_retro_cfg() {
  local l
  { echo "BASE_BRANCH=main"; echo "COMMIT_STYLE=conventional"; echo "TRACKER=none"; echo "REPORT_DIR=docs/retros"
    for l in "$@"; do echo "$l"; done; } > "$CFG"
}
t_retro_commit() {
  local days="$1" msg="$2" f when; shift 2
  [ "$#" -gt 0 ] || set -- "misc-$RANDOM.txt"
  for f in "$@"; do mkdir -p "$(dirname "$f")" && echo "$msg" >> "$f" || exit 2; done
  when="@$(( $(date +%s) - days * 86400 - 3600 )) +0000"
  git add -A && GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git commit -qm "$msg" || exit 2
}
t_retro_push() { git push -q origin main || exit 2; }
t_retro_fixture() {
  local name="$1"; shift
  FIX="$T_TMP/$name"; mkdir -p "$FIX" || exit 2
  git init -q --bare -b main "$FIX/origin.git" && git init -q -b main "$FIX/work" && cd "$FIX/work" || exit 2
  mkdir -p .claude/skills && cp -R "$T_ROOT/skills/retro" .claude/skills/retro || exit 2
  CFG="$FIX/work/.claude/skills/retro/retro.env"; t_retro_cfg "$@"
  # A rules file with the template's own "Count the repeats" sentence, filled with 3 the way the onboarding fills it.
  grep -F 'this fix included, reaches `<YOUR-CLASS-GUARD-THRESHOLD>`' "$T_ROOT/templates/CLAUDE.template.md" \
    | sed 's/<YOUR-CLASS-GUARD-THRESHOLD>/3/' > CLAUDE.md
  t_retro_commit 400 "init" README.md
  git remote add origin ../origin.git && t_retro_push
  git branch -q -u origin/main main 2>/dev/null
  ORIGIN="$FIX/origin.git"; R=.claude/skills/retro/bin/retro-data.sh
}
# ---- hooks pack fixtures and helpers (tests/hooks/*) ----------------------------------------------------------------
#   t_hook_fixture <name> [hooks.env lines...]   a git repo with the pack copied into .claude/hooks (from
#                                                 $HOOKS_UNDER_TEST when set, for mutation checks; else hooks/), a
#                                                 protected list from $T_HOOK_LIST, hooks.env from the arguments; cwd =
#                                                 the repo; sets HR (its physical path) and HD (its hooks folder)
#   t_hook_install <dir>                          the same pack, list and hooks.env written into an existing folder
#                                                 (a linked worktree, say); sets HR and HD to it
#   t_hook <script> <json>                        runs the installed hook with that stdin (sets RC, OUT, LAST)
#   t_tool_json <tool> <key> <value> [mode] [cwd] the PreToolUse input for one call, cwd = $HR unless given
#   t_path_without <names...>                     prints a PATH of symlinked tools without the named commands
#   expect_decision <ask|deny|none> <label>       rc 0 and that answer (none = no output at all)
T_HOOK_LIST="${T_HOOK_LIST:-.gitignore
.github/workflows/*
**/secrets.json
config/*.lock
.claude/settings.json}"
t_hook_fixture() {
  local name="$1"; shift
  mkdir -p "$T_TMP/$name" && cd "$T_TMP/$name" || exit 2
  git init -q -b main . || exit 2
  t_hook_install . "$@"
}
t_hook_install() {
  local src="${HOOKS_UNDER_TEST:-$T_ROOT/hooks}" l
  cd "$1" && shift && mkdir -p .claude/hooks || exit 2
  cp "$src"/*.sh .claude/hooks/ || exit 2
  printf '%s\n' "$T_HOOK_LIST" > .claude/protected-files.txt
  { echo "PROTECTED_FILES_FILE=.claude/protected-files.txt"; for l in "$@"; do echo "$l"; done; } > .claude/hooks/hooks.env
  echo ignored > .gitignore
  HR="$(pwd -P)"; HD="$HR/.claude/hooks"
}
t_hook() { T_STDIN="$2"; run bash "$HD/$1.sh"; }
t_tool_json() {
  local tool="$1" key="$2" val="$3" mode="${4:-default}" cwd="${5:-$HR}"
  val="$(printf '%s' "$val" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  cwd="$(printf '%s' "$cwd" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  printf '{"session_id":"t1","cwd":"%s","permission_mode":"%s","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"%s":"%s"}}' \
    "$cwd" "$mode" "$tool" "$key" "$val"
}
# Only a PATH folder that holds one of the named commands is replaced by links to its other tools; every other folder
# stays on the PATH as is. (Git for Windows' `ln -s` copies a file, and a copied bash.exe or git.exe without the DLLs
# beside it does not run: its /usr/bin must stay a real folder, and there jq and python3 live elsewhere.)
t_path_without() {
  local farm d f n hit rest=""
  farm="$T_TMP/path-without-$(printf '%s' "$*" | tr ' ' '-')"
  [ -d "$farm" ] || { mkdir -p "$farm" || exit 2; }
  for d in $(printf '%s' "$PATH" | tr ':' ' '); do
    [ -d "$d" ] || continue
    hit=0
    for n in "$@"; do { [ -x "$d/$n" ] || [ -x "$d/$n.exe" ]; } && hit=1; done
    if [ "$hit" -eq 0 ]; then rest="$rest:$d"; continue; fi
    for f in "$d"/*; do
      n="$(basename "$f")"
      case " $* " in *" $n "*|*" ${n%.exe} "*) continue ;; esac
      [ -x "$f" ] && [ ! -e "$farm/$n" ] && ln -s "$f" "$farm/$n" 2>/dev/null
    done
  done
  printf '%s%s\n' "$farm" "$rest"
}
expect_decision() {
  local want="$1" label="$2" got=none
  case "$OUT" in *'"permissionDecision":"ask"'*) got=ask ;; *'"permissionDecision":"deny"'*) got=deny ;; '') got=none ;; *) got=other ;; esac
  if [ "$RC" = 0 ] && [ "$got" = "$want" ]; then
    if [ "$got" != none ] && command -v jq >/dev/null 2>&1 && ! printf '%s' "$OUT" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null 2>&1; then
      t_fail "$label" "the answer is not valid hook JSON"; return 0
    fi
    t_pass "$label"
  else t_fail "$label" "want rc=0 decision=$want" "got  rc=$RC decision=$got"; fi
}
# ---- what this platform can build (Windows under Git Bash cannot build everything Linux and macOS can) ---------------
#   t_can_name <name>   0 when a file of that name can be made and git lists it under exactly that name (NTFS forbids
#                       " \ : * ? < > | and control characters: MSYS swaps them for other characters git then sees)
#   t_skip <label>      prints a visible SKIP line (never counted as a pass)
t_can_name() {
  local d="$T_TMP/name-probe.$$" got
  rm -rf "$d"; git init -q "$d" 2>/dev/null || return 1
  ( : > "$d/$1" ) 2>/dev/null || { rm -rf "$d"; return 1; }
  got="$(git -C "$d" -c core.quotePath=false ls-files -z --others 2>/dev/null | tr '\0' '\n')"
  rm -rf "$d"
  [ "$got" = "$1" ]
}
t_skip() { echo "  SKIP  $1"; }
#   t_can_unreadable    0 when chmod 000 makes a file unreadable here (not as root; not on Windows, where chmod
#                       cannot take read access away)
#   t_can_symlink       0 when ln -s makes a real symbolic link (Git for Windows' ln copies the file instead)
#   t_tracks_mode       0 when git in the current repository records the executable bit (core.fileMode is false
#                       on Windows)
t_can_unreadable() {
  local f="$T_TMP/unreadable-probe"
  rm -f "$f"; echo x > "$f" && chmod 000 "$f" || return 1
  if [ -r "$f" ]; then chmod 644 "$f"; rm -f "$f"; return 1; fi
  chmod 644 "$f"; rm -f "$f"; return 0
}
t_can_symlink() {
  local d="$T_TMP/symlink-probe"
  rm -rf "$d"; mkdir -p "$d" && echo x > "$d/t" || return 1
  ln -s t "$d/l" 2>/dev/null && [ -L "$d/l" ]; local rc=$?
  rm -rf "$d"; return "$rc"
}
#   t_is_windows        0 under Git for Windows' bash (MSYS2) or Cygwin: for what no capability probe can show, such as
#                       signals to process groups, which MSYS only emulates
t_is_windows() { case "${OSTYPE:-}" in msys*|cygwin*) return 0 ;; esac; return 1; }
t_tracks_mode() { [ "$(git config --get core.fileMode 2>/dev/null)" != false ]; }

# ---- CRLF configuration (what Git for Windows' default core.autocrlf=true checks out) --------------------------------
#   t_crlf <src> <dst>                                    <dst> = <src> with CRLF line ends
#   t_kv_crlf_agree <lib> <getter> <example> <label>      every KEY=value key of <example> reads the same, with the same
#                                                         status, from a CRLF copy as from the LF original (the getter
#                                                         sourced from <lib>), and no value read from the CRLF copy holds a CR
t_crlf() { awk '{ printf "%s\r\n", $0 }' "$1" > "$2" || exit 2; }
t_kv_crlf_agree() {
  local lib="$1" get="$2" ex="$3" label="$4" keys a b
  keys="$(sed -n 's/^\([A-Za-z0-9_][A-Za-z0-9_]*\)=.*/\1/p' "$ex")"
  t_crlf "$ex" "$T_TMP/kv-crlf"
  # shellcheck disable=SC2016  # the dumper's text is literal
  local dump='. "$1" >/dev/null 2>&1 || exit 9; get="$2"; f="$3"; shift 3; for k in "$@"; do v="$("$get" "$f" "$k")"; printf "%s rc=%s [%s]\n" "$k" "$?" "$v"; done'
  # shellcheck disable=SC2086  # one argument per key
  a="$(bash -c "$dump" _ "$lib" "$get" "$ex" $keys)"
  # shellcheck disable=SC2086
  b="$(bash -c "$dump" _ "$lib" "$get" "$T_TMP/kv-crlf" $keys)"
  OUT="LF:
$a
CRLF:
$b"
  if [ -z "$keys" ]; then t_fail "$label" "no KEY=value line found in $ex"
  elif [ "$a" != "$b" ]; then t_fail "$label" "the CRLF copy reads differently"
  elif printf '%s' "$b" | grep -q "$(printf '\r')"; then t_fail "$label" "a value read from the CRLF copy holds a CR"
  elif printf '%s\n' "$a" | grep -v ' rc=0 ' | grep -q .; then t_fail "$label" "a key did not read as present"
  else t_pass "$label"; fi
}
t_done() {
  echo "  $(basename "$0"): $T_PASS passed, $T_FAIL failed"
  [ "$T_FAIL" -eq 0 ]
}
