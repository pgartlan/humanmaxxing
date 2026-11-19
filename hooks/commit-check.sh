#!/usr/bin/env bash
# commit-check.sh — PreToolUse hook: a commit the agent makes runs the repository's check first, and is refused when
# the check does not pass.
# hooks-pack: 1
#
# Wired as: PreToolUse, matcher "Bash", timeout COMMIT_CHECK_TIMEOUT_SECS + 10, onFailure "block".
#   bash commit-check.sh              the hook (reads the PreToolUse JSON on stdin)
#   bash commit-check.sh --git-hook   the same check from a git-native pre-commit hook (no stdin; the repository is
#                                     the one git runs in). Exit 1 refuses the commit.
#
# Trigger: a shell segment that runs `git`, its options, then `commit` (git commit, git -C x commit, git -c k=v commit
# --amend, after `cd x &&`, after VAR=value, anywhere in a chain). Detection is broad on purpose: a false trigger only
# runs the check.
# Targets: the session's directory, every literal `cd <path>` and `git -C <path>` before the commit (quoted paths, with
# spaces, are followed). Each distinct repository whose .claude/hooks/hooks.env sets COMMIT_CHECK_CMD gets the check,
# run from its top level with `bash -c`, in its own process group: on a timeout the whole group is stopped, so nothing
# the check started keeps running. A target that is not a literal path (a variable, a substitution) → refused: write
# the path literally. A cd inside a subshell, `( ... )` or `$( ... )`, ends at its `)`. A command that commits and
# also runs a nested shell (`bash -c '...'`, sh/zsh/dash/ksh -c, eval) whose script changes directory (cd, pushd, -C,
# --work-tree, --git-dir, GIT_WORK_TREE=, GIT_DIR=) is refused: that cd is not followed, so run the commit without the
# nested shell. COMMIT_CHECK_TIMEOUT_SECS is a whole number of seconds, 1 or more (read in base 10).
#
# Warn-only (HOOKS_MODE=warn in the repository's hooks.env): the check still runs, but every refusal becomes exit 0
# with "warn-only: would have refused this commit ..." and the same reason on stderr (and as the JSON systemMessage
# in hook mode). Not changed by warn mode: a commit in another repository is still asked about (denied in
# bypassPermissions/dontAsk). A warn-mode target's failing check does not end the call: every later target is still
# checked, and an enforce-mode target's refusal still refuses (one systemMessage carries all the warnings).
# Exit 0 = allowed (no commit, no governed repository, or every check passed; silent). Exit 2 = refused, with the
# reason on stderr: the check failed (its last 40 lines shown), timed out, could not start, or the configuration is
# malformed. A check that could not run has not passed.
#
# Also recognized: `--git-dir X` / `--work-tree X` (separated or with =), `GIT_WORK_TREE=X git …` (GIT_DIR=X alone: the
# work tree is the current folder), `pushd X`/`popd`, and git aliases that
# commit (`ci = commit`, `sv = !git commit -am wip`), read from the git configuration of the session's folder and of
# every literal folder the command names that exists (cd/pushd, -C, --work-tree, GIT_WORK_TREE=), before deciding
# whether the command can be a commit at all.
# Another repository (not a worktree of the session's repository, by git common dir) is never checked: its committed
# COMMIT_CHECK_CMD would be that repository's code, run before anyone approved the command. A commit there gets
# "ask" (deny in bypassPermissions/dontAsk), and the reason says its check was not run.
#
# Known gaps: commits that never say `commit` or an alias for it (merge, rebase --continue, cherry-pick, revert,
# `git -c alias.x=commit x`, an alias defined only in another folder's config reached by a non-literal path, eval),
# a commit inside a script the agent runs, a commit the human makes in their own terminal. A cd in one element of a
# pipeline or a backgrounded list (`cd X | ...`, `... | cd X`, `{ cd X; } | ...`, `cd X && y & ...`) runs in a subshell:
# a later commit in the current folder is checked against both X and the folder before the cd (fail closed: one
# check may be extra; inside a brace group, if, while, for or case, any cd before a later | or & counts).
# A shell with no script word (`... | bash`, `bash <<< '...'`, `sh << EOF`, `... | xargs bash -c`) is not followed: a
# command that commits and changes directory anywhere is refused, like the -c case. Only an unquoted shell word counts:
# a quoted commit message or a heredoc body that names these forms is text.
# With commit-check.sh itself missing, the settings handler asks (deny in bypassPermissions/dontAsk) for any command
# that says `git ... commit` while hooks.env still sets COMMIT_CHECK_CMD; an alias is not recognized then. The git-native pre-commit
# mode closes these for the repository it is installed in. The check sees the working tree, not the index: in that
# mode it runs without git's GIT_DIR, GIT_INDEX_FILE, GIT_WORK_TREE, GIT_PREFIX, GIT_OBJECT_DIRECTORY, GIT_COMMON_DIR.
# The handler's timeout is COMMIT_CHECK_TIMEOUT_SECS + 10 as it was at install: after raising the key, run the
# installer's plan --update (hooks-check.sh reports the mismatch).

set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
. "$HOOK_DIR/hook-lib.sh" || exit 2

GIT_HOOK=0
case "${1:-}" in --git-hook) GIT_HOOK=1 ;; '') ;; *) echo "commit-check: unknown argument '$1' (usage: commit-check.sh [--git-hook])" >&2; exit 2 ;; esac

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/commitcheck.XXXXXX")" || { echo "commit-check: cannot create a temp folder" >&2; exit 2; }
trap 'rm -rf "$TMPD"' EXIT

CC_WARN=0   # 1 when the repository being judged has HOOKS_MODE=warn: refusals become warnings
refuse() {  # refuse <message lines...>
  local l
  if [ "$CC_WARN" = 1 ]; then
    # Warn-only: the commit goes ahead; what would have refused it is shown (stderr, and the JSON systemMessage).
    local msg="warn-only: would have refused this commit (enforce mode blocks it):"
    for l in "$@"; do msg="$msg
$l"; done
    printf '%s\n' "$msg" >&2
    # Inside the per-target loop (a subshell per target): note the warning and end only this target's check, so a
    # later target in enforce mode is still checked; the loop's end prints one systemMessage for all of them.
    if [ -n "${CC_WARNED:-}" ]; then printf '%s\n' "$msg" >> "$CC_WARNED"; exit 0; fi
    [ "$GIT_HOOK" = 1 ] || printf '{"systemMessage":"%s"}\n' "$(printf '%s' "$msg" | hk_json_escape)"
    exit 0
  fi
  for l in "$@"; do printf '%s\n' "$l" >&2; done
  if [ "$GIT_HOOK" = 1 ]; then exit 1; fi
  exit 2
}

# run_check <top> — 0 passed or not configured; refuses otherwise.
run_check() {
  local top="$1" env="$1/$HOOKS_ENV_REL" cmd secs rc pid w out="$TMPD/out" mark="$TMPD/timedout"
  [ -f "$env" ] || return 0
  CC_WARN=0; [ "$(hk_mode "$top")" = warn ] && CC_WARN=1
  cmd="$(hk_kv_get "$env" COMMIT_CHECK_CMD)"; rc=$?
  case "$rc" in 0|1) ;; *) refuse "Commit refused: $HOOKS_ENV_REL is malformed, so the commit check cannot run: $env" \
    "Rule: a change passes the repository's check before it is committed. The user fixes $HOOKS_ENV_REL (KEY=value lines and # comments on their own lines)." ;; esac
  [ -n "$cmd" ] || return 0
  secs="$(hk_kv_get "$env" COMMIT_CHECK_TIMEOUT_SECS)" || secs=""
  [ -n "$secs" ] || secs=60
  case "$secs" in *[!0-9]*) refuse "Commit refused: COMMIT_CHECK_TIMEOUT_SECS must be a whole number of seconds (got '$secs'): $env" ;; esac
  secs=$((10#$secs))   # base 10: a leading zero (08) is not octal
  [ "$secs" -gt 0 ] || refuse "Commit refused: COMMIT_CHECK_TIMEOUT_SECS must be 1 or more seconds (got 0): $env"
  rm -f "$mark"
  # The check and the watcher each run in their own process group (set -m, for the one launch only), so a timeout
  # stops everything the check started (a test runner's children included) and no stray sleep outlives the hook.
  # In git-hook mode git's own GIT_DIR, GIT_INDEX_FILE, ... are removed: they point at the repository being committed,
  # and a check that runs git in another folder would otherwise act on that repository's index.
  set -m
  ( if [ "$GIT_HOOK" = 1 ]; then unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_COMMON_DIR; fi
    cd "$top" && exec bash -c "$cmd" ) > "$out" 2>&1 < /dev/null &
  pid=$!
  # The mark is written before the TERM: the hook wakes as soon as the check dies, and must already see that it timed
  # out (else it stops the watcher before the KILL and a child that ignores TERM outlives the hook).
  ( sleep "$secs"; : > "$mark"; if kill -TERM -- -"$pid" 2>/dev/null; then sleep 2; kill -KILL -- -"$pid" 2>/dev/null; else rm -f "$mark"; fi ) > /dev/null 2>&1 < /dev/null &
  w=$!
  set +m
  # The check is outside the hook's process group, so a Ctrl-C or TERM sent to the hook would not reach it: pass it on.
  trap 'kill -TERM -- -"$pid" -"$w" 2>/dev/null; echo "commit-check: stopped; the commit check was stopped with it" >&2; if [ "$GIT_HOOK" = 1 ]; then exit 1; fi; exit 2' INT TERM HUP
  wait "$pid"; rc=$?
  trap - INT TERM HUP
  kill -TERM -- -"$w" 2>/dev/null; wait "$w" 2>/dev/null
  if [ -f "$mark" ]; then
    kill -KILL -- -"$pid" 2>/dev/null   # whatever ignored TERM: the watcher was stopped before its own KILL
    refuse "Commit refused: the commit check did not finish within ${secs}s, so it has not passed." \
      "Check: $cmd (in $top)" "Rule: a change passes the repository's check before it is committed. Fix the slow check, or raise COMMIT_CHECK_TIMEOUT_SECS in $HOOKS_ENV_REL (the user's change)."
  fi
  if [ "$rc" -ne 0 ]; then
    refuse "Commit refused: the commit check failed (exit $rc), so the commit was not made." \
      "Check: $cmd (in $top)" "--- last 40 lines of its output ---" "$(tail -40 "$out")" "---" \
      "Rule: a change passes the repository's check before it is committed. Fix what the check reports, then commit again."
  fi
  return 0
}

if [ "$GIT_HOOK" = 1 ]; then
  TOP="$(hk_toplevel "$PWD")" || refuse "commit-check: not inside a git work tree"
  run_check "$TOP"
  exit 0
fi

IN="$TMPD/in"
cat > "$IN" || { echo "commit-check: cannot read the hook input" >&2; exit 2; }

TRIGGER_ERE='(^|[^A-Za-z0-9_.-])git([[:space:]].*)?[[:space:]]commit([[:space:]]|$)'
CMD="$(hk_field "$IN" tool_input.command)"; RC=$?
if [ "$RC" -eq 3 ]; then
  # No JSON parser: the raw input with escaped newlines and tabs turned into spaces.
  RAW="$(sed -e 's/\\[nt]/ /g' "$IN" | tr '\n\t' '  ')"
  printf '%s\n' "$RAW" | grep -Eq "$TRIGGER_ERE" || exit 0
  if ST="$(hk_toplevel "${CLAUDE_PROJECT_DIR:-$PWD}")" || ST="$(hk_toplevel "$PWD")"; then
    [ "$(hk_mode "$ST")" = warn ] && CC_WARN=1
  fi
  if printf '%s\n' "$RAW" | grep -Eq '(^|[^A-Za-z0-9_-])(cd|-C)[[:space:]]'; then
    refuse "Commit refused: this commit names another directory (cd or git -C), and without jq or python3 the check cannot tell which repository it targets." \
      "Install jq or python3, or run the commit from the repository's own folder."
  fi
  TOP="$(hk_toplevel "${CLAUDE_PROJECT_DIR:-$PWD}")" || TOP="$(hk_toplevel "$PWD")" || exit 0
  run_check "$TOP"
  exit 0
fi
case "$RC" in
  0) ;;
  1) exit 0 ;;
  *) echo "commit-check: the hook input is not the JSON a PreToolUse hook receives" >&2; exit 2 ;;
esac
CWD="$(hk_field "$IN" cwd)" && CWD="$(hk_posix_path "$CWD")" || CWD="$PWD"   # Windows: C:\… → /c/…
[ -d "$CWD" ] || CWD="$PWD"

MODE="$(hk_field "$IN" permission_mode)" || MODE=""
# Refusals made before a target repository is known follow the session repository's mode.
if ST="$(hk_toplevel "${CLAUDE_PROJECT_DIR:-$CWD}")" || ST="$(hk_toplevel "$CWD")"; then
  [ "$(hk_mode "$ST")" = warn ] && CC_WARN=1
fi

# Git aliases that commit (`ci = commit`, `sv = !git commit -am wip`), from the configuration git reads in <dir>.
commit_aliases() {
  git -C "$1" config --get-regexp '^alias\.' 2>/dev/null | while read -r k v; do
    n="${k#alias.}"
    case "$n" in ''|*[!A-Za-z0-9_-]*) continue ;; esac
    case "$v" in commit|'commit '*) echo "$n" ;; '!'*) printf '%s\n' "$v" | grep -Eq "$TRIGGER_ERE" && echo "$n" ;; esac
  done
}
literal() {  # literal <word> — 0 when the word is a plain path the shell will not rewrite
  case "$1" in ''|*'$'*|*'`'*|*'*'*|*'?'*|*'['*|*'{'*) return 1 ;; esac
  return 0
}
absdir() {  # absdir <path> <base> — the directory a cd/-C lands in (not required to exist)
  case "$1" in [A-Za-z]:[/\\]*) hk_posix_path "$1"; return 0 ;; esac   # Windows: git -C C:/repo
  case "$1" in /*) printf '%s\n' "$1" ;; \~) printf '%s\n' "$HOME" ;; \~/*) printf '%s\n' "$HOME/${1#\~/}" ;; *) printf '%s\n' "$2/$1" ;; esac
}

# split_words <segment> — one word per line, the way the shell groups them: '...' and "..." keep spaces (the quotes
# are dropped), a backslash escapes the next character, an unterminated quote runs to the end of the segment.
split_words() {
  printf '%s\n' "$1" | LC_ALL=C awk '{
    n = length($0); w = ""; have = 0; q = ""
    for (i = 1; i <= n; i++) {
      c = substr($0, i, 1)
      if (q != "") {
        if (c == q) q = ""
        else if (q == "\"" && c == "\\" && i < n && index("$`\"\\", substr($0, i + 1, 1)) > 0) { i++; w = w substr($0, i, 1) }
        else w = w c
      } else if (c == "\"" || c == "\047") { q = c; have = 1 }
      else if (c == "\\" && i < n) { i++; w = w substr($0, i, 1); have = 1 }
      else if (c == " " || c == "\t") { if (have) print w; w = ""; have = 0 }
      else { w = w c; have = 1 }
    }
    if (have) print w
  }'
}

# cmd_tokens — the whole command (stdin) as shell tokens, each ended by \036 and led by a kind letter: U a plain word,
# Q a word with quoted parts (quotes dropped; a quoted string runs across lines), O an operator (; | & ( ) or a
# newline), H a heredoc body (the lines after `<<WORD` up to WORD). A # at the start of a word starts a comment.
cmd_tokens() {
  LC_ALL=C awk 'BEGIN { RS = "\001" }
  function flush() { if (have) printf "%s%s\036", (quoted ? "Q" : "U"), w; w = ""; have = 0; quoted = 0 }
  { s = s $0 }
  END {
    n = length(s); w = ""; have = 0; quoted = 0; q = ""; np = 0
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (q == "\047") { if (c == q) q = ""; else w = w c; continue }
      if (q == "\"") {
        if (c == "\"") q = ""
        else if (c == "\\" && i < n && index("$`\"\\", substr(s, i + 1, 1)) > 0) { i++; w = w substr(s, i, 1) }
        else w = w c
        continue
      }
      if (c == "\"" || c == "\047") { q = c; have = 1; quoted = 1; continue }
      if (c == "\\" && i < n) { i++; if (substr(s, i, 1) != "\n") { w = w substr(s, i, 1); have = 1; quoted = 1 }; continue }
      if (c == "#" && !have) { while (i < n && substr(s, i + 1, 1) != "\n") i++; continue }
      if (c == " " || c == "\t") { flush(); continue }
      if (c == "<" && substr(s, i + 1, 1) == "<" && substr(s, i + 2, 1) == "<") { w = w "<<<"; have = 1; i += 2; continue }
      if (c == "<" && substr(s, i + 1, 1) == "<") {
        flush(); printf "U<<\036"; i += 2
        if (substr(s, i, 1) == "-") i++
        while (i <= n && (substr(s, i, 1) == " " || substr(s, i, 1) == "\t")) i++
        d = ""
        while (i <= n) {
          e = substr(s, i, 1)
          if (e ~ /[ \t\n;|&()<>]/) break
          if (e != "\"" && e != "\047" && e != "\\") d = d e
          i++
        }
        i--; pend[++np] = d; continue
      }
      if ((c == "&" && (substr(s, i - 1, 1) ~ /[<>]/ || substr(s, i + 1, 1) == ">"))) { w = w c; have = 1; continue }
      if (c ~ /[;|&()]/) { flush(); printf "O%s\036", c; continue }
      if (c == "\n") {
        flush(); printf "O\n\036"
        for (k = 1; k <= np; k++) {
          body = ""
          while (i < n) {
            e = index(substr(s, i + 1), "\n"); if (e == 0) e = n - i + 1
            line = substr(s, i + 1, e - 1); i += e
            sub(/^\t+/, "", line)
            if (line == pend[k]) break
            body = body line "\n"
          }
          printf "H%s\036", body
        }
        np = 0; continue
      }
      w = w c; have = 1
    }
    flush()
  }'
}

# One pass over the whole command's tokens (cmd_tokens), before the cheap exit:
#  - the literal folders it names (cd/pushd X, -C X, --work-tree X, GIT_WORK_TREE=X; a relative one resolved against
#    the session's folder and each folder named before it): their git aliases that commit count too;
#  - a nested shell (bash/sh/zsh/dash/ksh -c '<script>', eval) whose script changes directory: not followed.
DIRCHG_ERE='(^|[^A-Za-z0-9_.-])(cd|pushd)([[:space:]]|$)|(^|[[:space:]])(-C|--work-tree|--git-dir)([[:space:]=]|$)|(^|[^A-Za-z0-9_])(GIT_WORK_TREE|GIT_DIR)='
ADIRS="$CWD
"
add_adir() { [ -d "$1" ] || return 0; case "
$ADIRS" in *"
$1
"*) ;; *) ADIRS="$ADIRS$1
" ;; esac; }
NEST_DIR=""; STDIN_SH=""
WALL=(); WK=()
while IFS= read -r -d $'\036' x; do WK+=("${x:0:1}"); WALL+=("${x:1}"); done < <(printf '%s\n' "$CMD" | cmd_tokens)
NW=${#WALL[@]}; i=0
while [ "$i" -lt "$NW" ]; do
  w="${WALL[$i]}"; nx=""; [ $((i + 1)) -lt "$NW" ] && nx="${WALL[$((i + 1))]}"
  # A shell or eval word counts only as a plain word (U) or a word that is exactly the name ("bash"); a quoted message
  # or a heredoc body that mentions them is one Q or H token, never a command.
  case "${WK[$i]}" in U) b="${w##*\`}" ;; Q) b="$w" ;; *) b="" ;; esac; t=""
  case "$w" in GIT_WORK_TREE=*) t="${w#GIT_WORK_TREE=}" ;; --work-tree=*) t="${w#--work-tree=}" ;; esac
  case "$b" in
    cd|pushd|-C|--work-tree) t="$nx" ;;
    eval) j=$((i + 1)); sc=""; while [ "$j" -lt "$NW" ]; do sc="$sc ${WALL[$j]}"; j=$((j + 1)); done
          printf '%s\n' "$sc" | grep -Eq "$DIRCHG_ERE" && NEST_DIR=1 ;;
    */bash|*/sh|*/zsh|*/dash|*/ksh|bash|sh|zsh|dash|ksh)
      j=$((i + 1)); hasc=0
      while [ "$j" -lt "$NW" ]; do
        a="${WALL[$j]}"
        case "$a" in
          --) j=$((j + 1)); break ;;
          -o|+o|-O|+O|--rcfile|--init-file) j=$((j + 2)) ;;
          --*) j=$((j + 1)) ;;
          -*c*) hasc=1; j=$((j + 1)) ;;
          -*|+*) j=$((j + 1)) ;;
          *) break ;;
        esac
      done
      # No script word (nothing after it, an operator, a redirection): the script comes from stdin (a pipe, a heredoc,
      # <<<) or from xargs: not followed. With -c, the next word is the script.
      if [ "$j" -ge "$NW" ] || [ "${WK[$j]}" = O ]; then STDIN_SH=1
      elif [ "$hasc" = 1 ]; then
        if printf '%s\n' "${WALL[$j]}" | grep -Eq "$DIRCHG_ERE"; then NEST_DIR=1; fi
      else case "${WALL[$j]}" in '<'*) STDIN_SH=1 ;; esac
      fi ;;
  esac
  if [ -n "$t" ]; then
    t="${t%%[;&|()]*}"
    if literal "$t"; then
      case "$t" in
        /*|\~|\~/*) add_adir "$(absdir "$t" "$CWD")" ;;
        *) while IFS= read -r d; do [ -n "$d" ] && add_adir "$d/$t"; done <<EOF_AD
$ADIRS
EOF_AD
           ;;
      esac
    fi
  fi
  i=$((i + 1))
done
ALIASES="$(while IFS= read -r d; do [ -n "$d" ] && commit_aliases "$d"; done <<EOF_AD
$ADIRS
EOF_AD
)"
ALIASES="$(printf '%s\n' "$ALIASES" | grep . | sort -u)"
WORDS="commit$(printf '%s\n' "$ALIASES" | grep . | sed 's/^/|/' | tr -d '\n')"
TRIGGER_ERE='(^|[^A-Za-z0-9_.-])git([[:space:]].*)?[[:space:]]('"$WORDS"')([[:space:]]|$)'

# Cheap exit: no segment can be a commit. A literal \n or \t counts as a space here (printf 'cd x\ngit commit' | sh).
printf '%s\n' "$CMD" | sed -e 's/\\[nt]/ /g' | grep -Eq "$TRIGGER_ERE" || exit 0

[ -z "$NEST_DIR" ] || refuse "Commit refused: this command commits and runs a nested shell (bash -c, sh -c, eval, ...) whose script changes directory, so the commit check cannot tell which repository the commit targets." \
  "Run the commit without the nested shell (cd <path> && git commit ..., or git -C <path> commit ...), then commit again."
# A shell that reads its script from stdin (`... | bash`, `bash <<< '...'`, `sh << EOF`): its script is not followed
# either, so a command that commits and changes directory anywhere is refused the same way.
if [ -n "$STDIN_SH" ] && printf '%s\n' "$CMD" | grep -Eq "$DIRCHG_ERE"; then
  refuse "Commit refused: this command commits and feeds a nested shell its script on stdin (| bash, bash <<<, sh << EOF) while changing directory, so the commit check cannot tell which repository the commit targets." \
    "Run the commit without the nested shell (cd <path> && git commit ..., or git -C <path> commit ...), then commit again."
fi

TARGETS=""
add_target() { TARGETS="$TARGETS$1
"; }
DIR="$CWD"; STACK=""; SD=0; EXTRA=""
# Segments: split on && || ; | & newlines and parentheses (also inside quotes: a message is not a path). Words honour
# quotes, so `cd "/a b"` and `git -C "/a b"` follow the quoted path. A subshell, ( ... ) or $( ... ), becomes a "("
# line and a ")" line: the folder (and pushd stack) is saved at "(" and restored at ")", so a cd inside a subshell
# ends with it. A parenthesis inside '...' (or a bare one inside "...") is only a split; a ")" with nothing open is
# ignored. The separators stay as their own lines: ";" (also each newline), "&&" (also ||), "|" (also |&) and "&" (a
# lone one: not >&, &>, <&). A cd runs in a subshell when its pipeline element is joined by "|" (a cd after a "|",
# or any cd in the element before one) or its list is ended by "&"; then the folder before it stays a target (EXTRA)
# for every later commit that runs in the current folder: both are checked. Inside { }, if, while, until, for, case
# the whole group is one element (the lists are only reset at the top level), so this can only add targets.
SEGS="$(printf '%s\n' "$CMD" | LC_ALL=C awk '{
    n = length($0); o = ""
    for (i = 1; i <= n; i++) {
      c = substr($0, i, 1); nx = substr($0, i + 1, 1)
      if (q == "\047") { if (c == "\047") q = ""; else if (c == "(" || c == ")") c = "\n" }
      else if (c == "\\" && i < n) { o = o c nx; i++; continue }
      else if (q == "\"") {
        if (c == "\"") q = ""
        else if (c == "$" && nx == "(") { o = o "$\n(\n"; i++; d++; continue }
        else if (c == ")" && d > 0) { d--; c = "\n)\n" }
        else if (c == "(" || c == ")") c = "\n"
      }
      else if (c == "\"" || c == "\047") q = c
      else if (c == "(") c = "\n(\n"
      else if (c == ")") c = "\n)\n"
      o = o c
    }
    print o; print ";"
  }' | LC_ALL=C awk '{
    gsub(/\|&/, "|"); gsub(/[<>]&/, ">"); gsub(/&>/, ">"); gsub(/&&|\|\|/, "\035")
    gsub(/\|/, "\n|\n"); gsub(/&/, "\n\\&\n"); gsub(/\035/, "\n\\&\\&\n"); gsub(/;/, "\n;\n"); print
  }')"
SEGA=()
while IFS= read -r x; do SEGA+=("$x"); done <<EOF_SEGS
$SEGS
EOF_SEGS
NS=${#SEGA[@]}
PIPE_CDS=""; LIST_CDS=""; INPIPE=0; GDEPTH=0   # folders before a cd: in this pipeline element / this and-or list
add_dir_target() {  # add_dir_target <dir> — a commit in the current folder: also every folder a subshelled cd left
  add_target "$1"
  [ -z "$EXTRA" ] || while IFS= read -r e; do [ -n "$e" ] && add_target "$e"; done <<EOF_EX
$EXTRA
EOF_EX
}
si=-1
while [ $((si += 1)) -lt "$NS" ]; do
  seg="${SEGA[$si]}"
  case "$seg" in
    '|') EXTRA="$EXTRA$PIPE_CDS"; INPIPE=1; continue ;;
    '&') EXTRA="$EXTRA$LIST_CDS"; [ "$GDEPTH" -gt 0 ] || { PIPE_CDS=""; LIST_CDS=""; INPIPE=0; }; continue ;;
    '&&') [ "$GDEPTH" -gt 0 ] || { PIPE_CDS=""; INPIPE=0; }; continue ;;
    ';') [ "$GDEPTH" -gt 0 ] || { PIPE_CDS=""; LIST_CDS=""; INPIPE=0; }; continue ;;
    '(') SUBD[SD]="$DIR"; SUBS[SD]="$STACK"; SD=$((SD + 1)); continue ;;
    ')') if [ "$SD" -gt 0 ]; then SD=$((SD - 1)); DIR="${SUBD[$SD]}"; STACK="${SUBS[$SD]}"; fi; continue ;;
  esac
  WL=()
  while IFS= read -r x; do WL+=("$x"); done < <(split_words "$seg")
  set -- ${WL[@]+"${WL[@]}"}
  case "${1:-}" in
    '{'|if|while|until|for|case|select) GDEPTH=$((GDEPTH + 1)) ;;
    '}'|fi|done|'esac') [ "$GDEPTH" -gt 0 ] && GDEPTH=$((GDEPTH - 1)) ;;
  esac
  ENVWT=""; ENVBAD=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      GIT_WORK_TREE=*) if literal "${1#GIT_WORK_TREE=}"; then ENVWT="${1#GIT_WORK_TREE=}"; else ENVBAD="${1#GIT_WORK_TREE=}"; fi; shift ;;
      *=*) case "${1%%=*}" in *[!A-Za-z0-9_]*) break ;; esac; shift ;;
      command|env|exec|time|nohup|sudo|then|do|else|'{') shift ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] || continue
  case "$1" in
    cd|pushd|popd)
      PIPE_CDS="$PIPE_CDS$DIR
"; LIST_CDS="$LIST_CDS$DIR
"
      [ "$INPIPE" = 0 ] || EXTRA="$EXTRA$DIR
"
      ;;
  esac
  case "$1" in
    cd|pushd)
      if [ "$#" -lt 2 ]; then [ "$1" = cd ] && DIR="$HOME"; continue; fi
      literal "$2" || refuse "Commit refused: this command changes directory with '$2', which is not a literal path, so the commit check cannot tell which repository the commit targets." "Write the path literally, then commit again."
      [ "$1" = pushd ] && STACK="$DIR
$STACK"
      DIR="$(absdir "$2" "$DIR")"; continue ;;
    popd)
      if [ -n "$STACK" ]; then DIR="$(printf '%s' "$STACK" | head -1)"; STACK="$(printf '%s' "$STACK" | sed 1d)"; fi
      continue ;;
    git|*/git) ;;
    *)
      # Not a plain git invocation (bash -c "...", xargs, a wrapper): still broad: a commit-looking segment is checked
      # against the current directory.
      if printf '%s\n' "$seg" | grep -Eq "$TRIGGER_ERE"; then add_dir_target "$DIR"; fi
      continue ;;
  esac
  shift
  GD="$DIR"; BAD="$ENVBAD"; FROMDIR=1
  [ -n "$ENVWT" ] && FROMDIR=0
  [ -n "$ENVWT" ] && GD="$(absdir "$ENVWT" "$DIR")"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C) if [ "$#" -lt 2 ]; then break; fi
          FROMDIR=0; if literal "$2"; then GD="$(absdir "$2" "$GD")"; else BAD="$2"; fi; shift 2 ;;
      -c|--git-dir|--namespace|--exec-path|--config-env) shift; [ "$#" -gt 0 ] && shift ;;
      --work-tree) if [ "$#" -lt 2 ]; then break; fi
          FROMDIR=0; if literal "$2"; then GD="$(absdir "$2" "$GD")"; else BAD="$2"; fi; shift 2 ;;
      --work-tree=*) FROMDIR=0; if literal "${1#--work-tree=}"; then GD="$(absdir "${1#--work-tree=}" "$GD")"; else BAD="${1#--work-tree=}"; fi; shift ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  IS=0
  if [ "${1:-}" = commit ]; then IS=1
  elif [ -n "${1:-}" ] && [ -d "$GD" ] && commit_aliases "$GD" | grep -qxF -- "$1"; then IS=1; fi
  if [ "$IS" = 1 ]; then
    [ -z "$BAD" ] || refuse "Commit refused: 'git -C $BAD' is not a literal path, so the commit check cannot tell which repository the commit targets." "Write the path literally, then commit again."
    if [ "$FROMDIR" = 1 ]; then add_dir_target "$GD"; else add_target "$GD"; fi
  elif printf '%s\n' "$seg" | grep -Eq "$TRIGGER_ERE"; then
    if [ "$FROMDIR" = 1 ]; then add_dir_target "$GD"; else add_target "$GD"; fi
  fi
done

[ -n "$TARGETS" ] || exit 0
common_dir() { (cd "$1" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P); }
SESS_TOP="$(hk_toplevel "${CLAUDE_PROJECT_DIR:-$CWD}")" || SESS_TOP="$(hk_toplevel "$CWD")" || SESS_TOP=""
SESS_COMMON=""; [ -n "$SESS_TOP" ] && SESS_COMMON="$(common_dir "$SESS_TOP")"
FOREIGN=""
TOPS=""
while IFS= read -r d; do
  [ -n "$d" ] || continue
  if [ ! -d "$d" ]; then
    refuse "Commit refused: the commit targets $d, which does not exist (or its path could not be read from the command), so its repository's check cannot be found." \
      "Create the folder first and run the commit as its own command, or write the path plainly (one quoted or unquoted word)."
  fi
  t="$(hk_toplevel "$d")" || continue
  case "
$TOPS" in *"
$t
"*) continue ;; esac
  TOPS="$TOPS
$t
"
  # Another repository (not a worktree of the session's): its committed check would be code from that repository,
  # run before anyone approved the command. Ask instead of running it.
  if [ -z "$SESS_COMMON" ] || [ "$(common_dir "$t")" != "$SESS_COMMON" ]; then
    if [ -f "$t/$HOOKS_ENV_REL" ]; then FOREIGN="$FOREIGN $t"; fi
    continue
  fi
  # A subshell per target: a warn-mode target's would-be refusal ends only its own check (refuse, CC_WARNED); an
  # enforce refusal (exit 2) still ends the hook.
  ( CC_WARNED="$TMPD/warned"; run_check "$t" ) || exit $?
done <<EOF_T
$TARGETS
EOF_T
WARNED=""; [ ! -s "$TMPD/warned" ] || WARNED="$(cat "$TMPD/warned")"
if [ -n "$FOREIGN" ]; then
  decision=ask
  reason="Commit check: this commit targets another repository ($(printf '%s' "${FOREIGN# }")), not this session's. Its commit check was NOT run: running it would execute that repository's own command before you approved anything. Approve only if you meant to commit there; then run its check yourself."
  [ -z "$WARNED" ] || reason="$reason
$WARNED"
  case "$MODE" in bypassPermissions|dontAsk) decision=deny; reason="$reason
Refused because the permission mode ($MODE) cannot ask you." ;; esac
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' \
    "$decision" "$(printf '%s' "$reason" | hk_json_escape)"
elif [ -n "$WARNED" ]; then
  printf '{"systemMessage":"%s"}\n' "$(printf '%s' "$WARNED" | hk_json_escape)"
fi
exit 0
