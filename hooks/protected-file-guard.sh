#!/usr/bin/env bash
# protected-file-guard.sh — PreToolUse hook: an agent edit of a protected file needs the user's approval.
# hooks-pack: 1
#
# Wired as: PreToolUse, matcher "Edit|Write|NotebookEdit|Bash", timeout 10, onFailure "block" (a crash or a timeout
# then blocks the call instead of letting it through).
#
# What it answers (stdout JSON, exit 0):
#   allow, silently   the call names no protected file, or the target repository has no .claude/hooks/hooks.env
#   "ask"             the call would change a protected file: the user sees the approval prompt for that one call,
#                     with the file and the reason. Approving it is the user making the edit.
#   "deny"            only where nobody can be asked: permission mode bypassPermissions (whether a hook's "ask"
#                     prompts there is not documented, so the guard does not rely on it) and dontAsk (which turns
#                     every prompt into a refusal anyway). The reason says how the human makes the edit.
#   warn-only         HOOKS_MODE=warn in the target repository's hooks.env: what would have been "ask" or "deny" is
#                     allowed instead, with one line per reason prefixed "warn-only:" on stderr and as the JSON
#                     systemMessage (no permissionDecision). Still asked in warn mode: .claude/settings.json and
#                     .claude/settings.local.json (a write there is silent self-escalation), and configuration errors.
# Errors never allow silently: a malformed hooks.env, a missing or unreadable protected list, no JSON parser while
# the call mentions a protected name, or a path that cannot be resolved while it mentions one → "ask", with the
# error in the reason. Exit 2 only when the hook cannot even read its input.
#
# Protected = the globs in the list named by PROTECTED_FILES_FILE in <repo>/.claude/hooks/hooks.env (default
# .claude/protected-files.txt), plus built-ins that cannot be configured away: .claude/settings.json and
# .claude/settings.local.json (they can switch the hooks off), .claude/hooks/** and the list
# itself. Configuration is read from the repository the call targets, not from where the session started, with one
# exception: while the session's own repository (the cwd's, or else CLAUDE_PROJECT_DIR's) is governed, a file-tool
# target whose resolved path ends in /.claude/settings.json or /.claude/settings.local.json is asked about wherever it
# is (another worktree's or the main checkout's root, a subfolder's .claude/, the user's ~/.claude/), since any of
# them can switch the hooks off.
#
# How each tool is judged:
#   any tool with tool_input.file_path or .notebook_path: the path is resolved (symlinks followed, `..` folded),
#     taken relative to its repository's top level, and matched; the unresolved spelling is matched too. Case is
#     folded only where the repository's filesystem folds case (probed on its own hooks.env).
#   Bash: the command (backslashes and quotes removed) is "ask" when it is not a provable read and it
#     - names a protected file (a glob's literal part, or a word that is a protected path once normalized), or
#     - names a folder that holds protected entries on its own (`.claude`, `.claude/`, `.claude/*`, `.claude/.`, also as
#       git's -C, --work-tree or --git-dir folder), or the whole repository folder (`.`, `*`, git's `:/` or
#       `:(top)`, its path with or without a trailing slash, `..` from a subfolder) with rm, mv, cp, rsync, ln, tar,
#       chmod, git checkout/restore and the like, or a folder above the repository with rm, rmdir, chmod, chown, shred
#       or find -delete, or
#     - rewrites the tree wholesale, by patch or by archive: git clean, git reset --hard/--merge/--keep, git stash
#       (not list or show), git rm (not --cached) of the tree, find -delete/-exec over the tree
#       (or with no folder named), git apply, git am,
#       patch, tar/bsdtar extraction, unzip (not -l/-v/-t), 7z/7za/7zr x or e, cpio -i, or the pack's own `hooks-install.sh … apply`.
#     Words are normalized before they are judged: a leading ~/ expanded, a relative word joined with the cwd, `.`,
#     `..` and `//` folded as text (`sub/../.claude`, `.claude/./settings.json`), then taken relative to the top.
#     Quoted words count once as written (a quoted path with a space) and once split at blanks (`bash -c "rm …"`).
#     Expected noise, by design: copying a folder that holds a protected file (`cp -r .github /tmp/x`) and a commit
#     command whose message names a protected file are asked about too.
#     A provable read: every pipeline stage one of cat head tail grep wc stat od cut tr column ls diff cmp jq, less
#     (no short-option cluster holding o or O, no long option starting --l/--L: options bundle and abbreviate), rg
#     (no --pre), sort (no cluster holding o, no --o…), find (no -exec/-delete/-fprint), the pack's
#     `bash .claude/hooks/hooks-check.sh` alone and `bash <download>/hooks/bin/hooks-install.sh plan …`, or git
#     diff/show/log/status/blame/add/ls-files/check-ignore (no -c,
#     --ext-diff, --textconv, --output); and no ; & > < tee $( or backtick anywhere.
#   any other tool added to the matcher: its whole tool_input is searched for a literal part → "ask".
#   no jq and no python3: every file-tool call is "ask" (a path cannot be resolved), a command by literal parts only.
#
# What the shell guard can and cannot see. The file tools (Edit, Write, NotebookEdit) are the real guarantee: their
# path is exact. The Bash check is best-effort pattern matching on the command text. It cannot see a path the shell
# builds while the command runs ("$A$B", a glob the shell or git expands, an encoded string), a write done by an
# interpreter one-liner, a
# script the agent writes and then runs (its contents are not in the command), a branch switch, merge, rebase or
# pull that changes a protected file, hardlinks, or write tools not in the matcher (MCP or plugin tools;
# PowerShell). The pre-merge check is the guarantee for those.
#
# If the hooks folder is half deleted (hook-lib.sh gone, a script broken), every call the guard matches fails and,
# with onFailure "block", is blocked. Recovery, by the user in their own terminal: `git checkout -- .claude/hooks`
# (or reinstall from the download), or start a session with --settings '{"disableAllHooks": true}' to repair it.
# This script missing while the folder still has hooks.env or the protected list: the handler itself answers "ask"
# (deny in bypassPermissions/dontAsk) for every call it matches. Only where the pack is absent entirely does the
# handler say the guard is off in that folder.

set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
. "$HOOK_DIR/hook-lib.sh" || exit 2

IN="$(hk_stdin_file)" || { echo "protected-file-guard: cannot read the hook input" >&2; exit 2; }
trap 'rm -f "$IN"' EXIT

MODE=""; ASKS=""; WARNS=""; FOLD=0; CUR_WARN=0

# ask <reason> — collect; the answer is printed once, at the end. In warn mode (HOOKS_MODE=warn in the repository the
# match was made in) the reason is collected as a warning instead: the call is allowed and the warning shown.
ask() {
  if [ "$CUR_WARN" = 1 ]; then WARNS="${WARNS:+$WARNS
}warn-only: $1 (enforce mode would ask for approval)"; return 0; fi
  ask_always "$1"
}
# ask_always <reason> — asked in either mode: the settings files (a write there is silent self-escalation, not a gate
# on the install's merge) and configuration errors.
ask_always() { ASKS="${ASKS:+$ASKS
}$1"; }

answer() {
  if [ -z "$ASKS" ]; then
    [ -n "$WARNS" ] || exit 0
    printf '%s\n' "$WARNS" >&2
    printf '{"systemMessage":"%s"}\n' "$(printf '%s' "$WARNS" | hk_json_escape)"
    exit 0
  fi
  local decision=ask reason
  reason="Protected file: $ASKS"
  case "$MODE" in
    bypassPermissions|dontAsk)
      decision=deny
      reason="$reason
Refused because the permission mode ($MODE) cannot ask the user. The user makes this change by hand, or switches to a mode that asks and approves it." ;;
    *)
      reason="$reason
Approve only if you asked for this change. Rule: protected files change only with the user's approval (CLAUDE.md, Protected Files)." ;;
  esac
  [ -z "$WARNS" ] || reason="$reason
$WARNS"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' \
    "$decision" "$(printf '%s' "$reason" | hk_json_escape)"
  exit 0
}

# strip_cmd — backslashes and quotes removed, so `.git\ignore` and `'.git'ignore` still name .gitignore.
strip_cmd() { tr -d "\\\\\"'"; }

# mentions <text> — prints the tokens of HK_TOKENS that <text> contains (case-folded when FOLD=1).
mentions() {
  local text="$1" toks="$HK_TOKENS" t hit=""
  if [ "$FOLD" = 1 ]; then
    text="$(printf '%s' "$text" | hk_lower)"; toks="$(printf '%s' "$toks" | hk_lower)"
  fi
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$text" in *"$t"*) hit="$hit $t" ;; esac
  done <<EOF_T
$toks
EOF_T
  [ -n "$hit" ] || return 1
  printf '%s\n' "${hit# }"
}

# is_read <command> — 0 when every stage of the command only reads.
is_read() {
  local c="$1" seg w sub
  case "$c" in *'
'*) return 1 ;; esac
  c="$(printf '%s' "$c" | sed -e 's/[0-9]*>[[:space:]]*\/dev\/null//g' -e 's/2>&1//g' -e 's/&&/|/g' -e 's/||/|/g')"
  case "$c" in *';'*|*'&'*|*'>'*|*'<'*|*'`'*|*'$('*) return 1 ;; esac
  while IFS= read -r seg; do
    set -f
    # shellcheck disable=SC2086
    set -- $seg
    set +f
    [ "$#" -gt 0 ] || return 1
    w="$1"; shift
    case "$w" in
      cat|head|tail|grep|wc|stat|od|cut|tr|column|ls|diff|cmp|jq) ;;
      # uniq and xxd are not here: both take an output file as a plain argument.
      # Short options bundle (`-So FILE`) and long options abbreviate (`--log-f`, `--LOG-F`), so any cluster holding
      # o or O and any long option starting --l or --L counts as a possible log file.
      less) for sub in "$@"; do case "$sub" in --[lL]*) return 1 ;; --*) ;; -*[oO]*) return 1 ;; esac; done ;;
      rg) for sub in "$@"; do case "$sub" in --pre*) return 1 ;; esac; done ;;
      bash|sh)
        # The pack's own read-only commands: `bash <...>/.claude/hooks/hooks-check.sh` alone, and the installer's
        # `plan` (it writes nothing; it names the settings file it would change).
        case "$#:${1:-}:${2:-}" in
          1:*/.claude/hooks/hooks-check.sh:|1:.claude/hooks/hooks-check.sh:) ;;
          *:*/hooks/bin/hooks-install.sh:plan|*:hooks/bin/hooks-install.sh:plan) ;;
          *) return 1 ;;
        esac ;;
      # The same for sort: `-uo FILE`, `-ro.claude/settings.json`, and --output abbreviated down to `--o=FILE`.
      sort) for sub in "$@"; do case "$sub" in --o*) return 1 ;; --*) ;; -*o*) return 1 ;; esac; done ;;
      find) for sub in "$@"; do case "$sub" in -exec|-execdir|-ok|-okdir|-delete|-fprint|-fprint0|-fprintf|-fls) return 1 ;; esac; done ;;
      git)
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -c|--config-env*) return 1 ;;
            -C) shift; [ "$#" -gt 0 ] && shift ;;
            -*) shift ;;
            *) break ;;
          esac
        done
        [ "$#" -gt 0 ] || return 1
        sub="$1"; shift
        case "$sub" in diff|show|log|status|blame|add|ls-files|check-ignore) ;; *) return 1 ;; esac
        for w in "$@"; do case "$w" in --output*|-o|--ext-diff|--textconv) return 1 ;; esac; done ;;
      *) return 1 ;;
    esac
  done <<EOF_SEG
$(printf '%s\n' "$c" | tr '|' '\n')
EOF_SEG
  return 0
}

# ancestors — every folder that holds a protected entry (from HK_GLOBS' literal prefixes), one per line.
ancestors() {
  local g pre d
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    pre="${g%%[*?[]*}"
    case "$pre" in
      */) d="${pre%/}" ;;
      */*) d="$(dirname "$pre")" ;;
      *) continue ;;
    esac
    while [ -n "$d" ] && [ "$d" != . ]; do
      printf '%s\n' "$d"
      case "$d" in */*) d="$(dirname "$d")" ;; *) d="" ;; esac
    done
  done <<EOF_G
$HK_GLOBS
EOF_G
}

# The tokenizer, run once per command over two spellings of it: the plain text (quotes and backslashes removed and
# split at every blank, so `bash -c "rm -rf .claude"` shows its inner words) and the raw text (quote-aware, so a
# quoted path with a space stays one word). Segments end at ; | & ( ) and newlines, words at blanks, < and >. For
# each segment it prints four lines, words separated by \037: R the words as written; N each word as an absolute
# path (a leading ~ expanded, a relative word joined with the physical cwd, `.`, `..` and `//` folded as text); X the
# part after the first = of a word, normalized the same way (`--output=FILE`, `VAR=PATH`); D the normalized words that
# can point into another repository (absolute, ~, or holding `..`).
TOK_AWK='
function norm(p,   n, i, k, out, parts, st) {
  if (p == "~") p = home; else if (substr(p, 1, 2) == "~/") p = home substr(p, 2)
  else if (substr(p, 1, 1) != "/") p = cwd "/" p
  n = split(p, parts, "/"); k = 0
  for (i = 1; i <= n; i++) {
    if (parts[i] == "" || parts[i] == ".") continue
    if (parts[i] == "..") { if (k > 0) k--; continue }
    st[++k] = parts[i]
  }
  out = ""; for (i = 1; i <= k; i++) out = out "/" st[i]
  return out == "" ? "/" : out
}
function far(p) { return substr(p, 1, 1) == "/" || substr(p, 1, 1) == "~" || index(p, "..") > 0 }
function add(list, v) { return list (list != "" ? US : "") v }
function endword() { if (w != "") words[++nw] = w; w = "" }
function endseg(   i, r, n, x, d, e, t, v) {
  endword(); if (nw == 0) return
  r = ""; n = ""; x = ""; d = ""
  for (i = 1; i <= nw; i++) {
    v = norm(words[i]); r = add(r, words[i]); n = add(n, v)
    if (far(words[i])) d = add(d, v)
    e = index(words[i], "="); t = substr(words[i], e + 1)
    if (e > 0 && t != "") { x = add(x, norm(t)); if (far(t)) d = add(d, norm(t)) }
  }
  print r; print n; print x; print d; nw = 0
}
BEGIN { US = "\037"; cwd = ENVIRON["HK_CWD"]; home = ENVIRON["HK_HOME"]; q = ""; w = ""; nw = 0 }
{
  L = length($0)
  for (i = 1; i <= L; i++) {
    c = substr($0, i, 1)
    if (q == "\047") { if (c == "\047") q = ""; else w = w c; continue }
    if (q == "\"") { if (c == "\"") q = ""; else if (c == "\\" && i < L) { i++; w = w substr($0, i, 1) } else w = w c; continue }
    if (c == "\047" || c == "\"") { q = c; continue }
    if (c == "\\") { if (i < L) { i++; w = w substr($0, i, 1) }; continue }
    if (c == " " || c == "\t" || c == "<" || c == ">") { endword(); continue }
    if (c == ";" || c == "|" || c == "&" || c == "(" || c == ")") { endseg(); continue }
    w = w c
  }
  if (q != "") w = w " "; else endseg()
}
END { endseg() }'

# tokenize <plain> <raw> <cwd> — sets STREAM (see TOK_AWK).
tokenize() {
  local pcwd phome="${HOME:-/}"
  pcwd="$(cd "$3" 2>/dev/null && pwd -P)" || pcwd="$3"
  [ -d "$phome" ] && phome="$(cd "$phome" 2>/dev/null && pwd -P)"
  STREAM="$(printf '%s\n%s\n' "$1" "$2" | HK_CWD="$pcwd" HK_HOME="$phome" LC_ALL=C awk "$TOK_AWK")"
}

NL='
'
hit() { TH="${TH:+$TH$NL}$1"; }

# scan <top> — judges STREAM for one repository (all in the shell: no process per word). Sets TH, one reason per
# line: a folder that holds protected entries named on its own (`dir`, `dir/`, `dir/*`, `dir/.`, `sub/../dir`), the
# whole repository folder (`.`, `*`, its path with or without a trailing slash, `..` from a subfolder, ~/ spellings)
# with a deleting or moving verb, a folder above the repository with a deleting verb, a git command that rewrites the
# working tree wholesale, a patch, an extraction, the installer's apply. Sets PH: the protected paths the words name
# once normalized (`.claude/./settings.json`, `x//.gitignore`, a relative name in a subfolder session).
scan() {
  local top="$1" S="$STREAM" anc R N X D w n r verb sub total off j rels="" ere gi=""
  local NW XW
  TH=""; PH=""
  anc="$(ancestors | sort -u)"
  if [ "$FOLD" = 1 ]; then
    gi=-i
    anc="$(printf '%s\n' "$anc" | hk_lower)"; S="$(printf '%s\n' "$S" | hk_lower)"; top="$(printf '%s' "$top" | hk_lower)"
  fi
  anc="$NL$anc$NL"
  while IFS= read -r R && IFS= read -r N && IFS= read -r X && IFS= read -r D; do
    IFS=$'\037'; set -f
    # shellcheck disable=SC2086,SC2206
    { set -- $R; NW=( $N ); XW=( $X ); }
    set +f; IFS=$' \t\n'
    total=$#
    while [ "$#" -gt 0 ]; do
      case "$1" in *=*) case "${1%%=*}" in *[!A-Za-z0-9_]*) break ;; esac; shift ;; sudo|command|env|exec|nohup|time) shift ;; *) break ;; esac
    done
    [ "$#" -gt 0 ] || continue
    verb="${1##*/}"; sub=
    if [ "$verb" = git ]; then
      shift
      # The folder git is pointed at (-C, --work-tree, --git-dir) is judged like a word: `git -C .claude checkout --
      # settings.json` names the folder that holds the protected file.
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -C|--git-dir|--work-tree) [ "$#" -gt 1 ] && gitdir "$2" "$((total - $# + 1))"; shift; [ "$#" -gt 0 ] && shift ;;
          --git-dir=*|--work-tree=*) gitdir "${1#*=}" ""; shift ;;
          # Where the filesystem folds case the words arrive lowercased, so `-C` reads as `-c`: judge its value too
          # (a `-c key=value` never names a protected folder).
          -c) [ "$#" -gt 1 ] && [ "$FOLD" = 1 ] && gitdir "$2" "$((total - $# + 1))"; shift; [ "$#" -gt 0 ] && shift ;;
          -*) shift ;;
          *) break ;;
        esac
      done
      sub="${1:-}"; [ "$#" -gt 0 ] && shift
      case "$sub" in
        clean) hit "git clean deletes untracked files anywhere in the tree" ;;
        reset) for w in "$@"; do case "$w" in --hard|--merge|--keep) hit "git reset $w rewrites the whole working tree" ;; esac; done ;;
        stash) case "${1:-}" in list|show) ;; *) hit "git stash rewrites the working tree" ;; esac ;;
        apply|am) hit "git $sub writes whatever files the patch names" ;;
      esac
      verb="git-$sub"
      # git rm --cached leaves the files alone; without it, a pathspec over the tree deletes them.
      [ "$sub" = rm ] && for w in "$@"; do [ "$w" = --cached ] && verb=git-rm-cached; done
    elif [ "$verb" = patch ]; then
      hit "patch writes whatever files the patch names"
    elif [ "$verb" = 7z ] || [ "$verb" = 7za ] || [ "$verb" = 7zr ]; then
      case "${2:-}" in x|e) hit "$verb extracts an archive, which can overwrite any file under its target folder" ;; esac
    elif [ "$verb" = cpio ]; then
      for w in "$@"; do case "$w" in --extract) hit "cpio extracts an archive, which can overwrite any file under its target folder" ;; --*) ;; -*i*) hit "cpio extracts an archive, which can overwrite any file under its target folder" ;; esac; done
    elif [ "$verb" = tar ] || [ "$verb" = bsdtar ]; then
      # Extraction writes whatever the archive holds, under the current folder or -C.
      for w in "$@"; do
        case "$w" in
          --extract|--get) hit "tar extracts an archive, which can overwrite any file under its target folder" ;;
          --*) ;;
          -*x*) hit "tar extracts an archive, which can overwrite any file under its target folder" ;;
        esac
      done
      case "${2:-}" in -*) ;; *x*) hit "tar extracts an archive, which can overwrite any file under its target folder" ;; esac
    elif [ "$verb" = unzip ]; then
      case " $* " in *" -l "*|*" -v "*|*" -t "*|*" -Z"*) ;; *) hit "unzip extracts an archive, which can overwrite any file under its target folder" ;; esac
    elif [ "$verb" = find ]; then
      for w in "$@"; do case "$w" in -delete|-exec|-execdir|-ok|-okdir) verb=find-write ;; esac; done
      # GNU find with no folder named searches the current folder.
      if [ "$verb" = find-write ]; then
        case "${2:-}" in ''|-*|'!'|'(') hit "find names no folder, so it deletes or runs commands over the current folder" ;; esac
      fi
    fi
    case "$R" in *hooks-install.sh*) for w in "$@"; do [ "$w" = apply ] && hit "hooks-install.sh apply writes the guard's own files and the settings file"; done ;; esac
    off=$((total - $#)); j=0
    for w in "$@"; do
      # The word as written (relative words judged as if from the top: `rm -rf .claude` from a subfolder is asked).
      r="$w"
      # git pathspec magic: `:/` and `:(top)` are the top of the tree, `:/x` and `:(top)x` are x from the top. The
      # tokenizer ends a segment at `(`, so any long-form magic (`:(top)`, `:(glob)…`) arrives as a bare `:`.
      case "$verb" in
        git-*) case "$r" in ':'|':/'|':(top)'|':(top)/'|':!'*|':^'*) r=. ;; ':/'*) r="${r#:/}" ;; ':(top)'*) r="${r#:(top)}" ;; esac ;;
      esac
      case "$r" in "$top") r=. ;; "$top"/*) r="${r#"$top"/}" ;; esac
      while :; do
        case "$r" in ./?*) r="${r#./}" ;; */.|*/\*) r="${r%/*}" ;; ?*/) r="${r%/}" ;; *) break ;; esac
      done
      case "$r" in ./|'./*') r=. ;; esac
      judge "$r"
      # The same word normalized against the cwd, then taken relative to the top.
      n="${NW[$((off + j))]:-}"; j=$((j + 1))
      case "$n" in
        '') continue ;;
        "$top") r=. ;;
        "$top"/*) r="${n#"$top"/}" ;;
        *)
          if [ "$n" = / ] || case "$top" in "$n"/*) true ;; *) false ;; esac; then
            case "$verb" in
              rm|rmdir|chmod|chown|shred|find-write) hit "it names $n, a folder that holds the whole repository, with $verb" ;;
            esac
          fi
          continue ;;
      esac
      while :; do case "$r" in */\*) r="${r%/*}" ;; *) break ;; esac; done
      [ "$r" = '*' ] && r=.
      rels="$rels$r$NL"
      judge "$r"
    done
    for n in ${XW[@]+"${XW[@]}"}; do
      case "$n" in "$top"/*) rels="$rels${n#"$top"/}$NL" ;; esac
    done
  done <<EOF_SEG
$S
EOF_SEG
  if [ -n "$rels" ] && [ -n "$HK_ERES" ]; then
    ere="$(printf '%s\n' "$HK_ERES" | paste -sd '|' -)"
    PH="$(printf '%s' "$rels" | grep -E $gi -- "$ere" | sort -u | paste -sd ' ' -)"
  fi
  return 0
}

# judge <relative name> — (scan's helper) a folder holding protected entries, or the whole repository with a deleting
# or moving verb.
judge() {
  if [ -n "$1" ] && case "$anc" in *"$NL$1$NL"*) true ;; *) false ;; esac; then
    hit "it names the folder $1, which holds protected files"
  elif [ "$1" = . ] || [ "$1" = '*' ]; then
    case "$verb" in
      rm|rmdir|mv|cp|rsync|ln|install|tar|unzip|chmod|chown|truncate|dd|shred|git-checkout|git-restore|git-rm|find-write)
        hit "it names the whole repository folder with $verb" ;;
    esac
  fi
}

# gitdir <word> <index in NW, or empty> — (scan's helper) the folder a git option points at, judged as written (from
# the top) and as normalized against the cwd.
gitdir() {
  local r="$1" n
  case "$r" in "$top") r=. ;; "$top"/*) r="${r#"$top"/}" ;; esac
  while :; do case "$r" in ./?*) r="${r#./}" ;; */.) r="${r%/*}" ;; ?*/) r="${r%/}" ;; *) break ;; esac; done
  judge "$r"
  [ -n "$2" ] || return 0
  n="${NW[$2]:-}"
  case "$n" in "$top"/*) judge "${n#"$top"/}" ;; esac
  return 0
}

# load <top> — config for one repository into HK_*; sets FOLD. 0 governed · 1 not governed · 2 error (already asked).
load() {
  local top="$1" rc
  hk_load_list "$top"; rc=$?
  case "$rc" in
    1) return 1 ;;
    2) ask_always "the guard's configuration is broken, so it cannot tell which files are protected: $HK_ERR. The user fixes it by hand."; return 2 ;;
  esac
  FOLD=0; hk_case_folds "$top" && FOLD=1
  CUR_WARN=0; [ "$(hk_mode "$top")" = warn ] && CUR_WARN=1
  return 0
}

# settings_file <cwd> <path...> — while the session's repository (the one <cwd> is in) is governed, a Claude Code
# settings file anywhere is asked about: another worktree's or the main checkout's root, a subfolder's .claude/, the
# user's ~/.claude/. Any of them can switch the hooks off, and none of them may be governed itself.
settings_file() {
  local cwd="$1" stop="" c s; shift
  # The session's repository: where the shell is now, or where the session started (the shell may have left it).
  for s in "$cwd" "${CLAUDE_PROJECT_DIR:-}"; do
    [ -n "$s" ] || continue
    c="$(hk_toplevel "$s")" || continue
    if [ -f "$c/$HOOKS_ENV_REL" ]; then stop="$c"; break; fi
  done
  [ -n "$stop" ] || return 1
  for c in "$@"; do
    case "$c" in
      */.claude/settings.json|*/.claude/settings.local.json) ;;
      */.[cC][lL][aA][uU][dD][eE]/[sS][eE][tT][tT][iI][nN][gG][sS].[jJ][sS][oO][nN]|*/.[cC][lL][aA][uU][dD][eE]/[sS][eE][tT][tT][iI][nN][gG][sS].[lL][oO][cC][aA][lL].[jJ][sS][oO][nN])
        hk_case_folds "${c%/*}" || continue ;;
      *) continue ;;
    esac
    ask_always "$c is a Claude Code settings file, which can switch the hooks off: always protected while this session's repository is governed ($stop)."
    return 0
  done
  return 1
}

# check_path <raw path> <cwd> — one file-tool target.
check_path() {
  local raw cwd="$2" abs res top rel g seen="" cand
  raw="$(hk_posix_path "$1")"   # Claude Code on Windows sends C:\…\file
  case "$raw" in /*) abs="$raw" ;; *) abs="$cwd/$raw" ;; esac
  res="$(hk_resolve "$raw" "$cwd")" || res=""
  if [ -z "$res" ]; then
    # Cannot resolve: judge the raw spelling against the repository the session is in.
    settings_file "$cwd" "$abs" && return 0
    top="$(hk_toplevel "$cwd")" || return 0
    load "$top" || return 0
    if g="$(mentions "$raw")"; then ask "$raw could not be resolved and names protected $g."; fi
    return 0
  fi
  # The resolved path, and the spelling as given (a symlink's own path may be listed too).
  for cand in "$res" "$abs"; do
    local d; d="$(dirname "$cand")"
    while [ ! -d "$d" ]; do d="$(dirname "$d")"; done
    top="$(hk_toplevel "$d")" || continue
    case " $seen " in *" $top|$cand "*) continue ;; esac
    seen="$seen $top|$cand"
    load "$top"; case $? in 1|2) continue ;; esac
    case "$cand" in
      "$top"/*) rel="${cand#"$top"/}" ;;
      *)
        # The unresolved spelling may sit under a symlinked parent: make its parent physical first.
        local pd; pd="$(cd "$(dirname "$cand")" 2>/dev/null && pwd -P)" || continue
        case "$pd/$(basename "$cand")" in "$top"/*) rel="${pd#"$top"}/$(basename "$cand")"; rel="${rel#/}" ;; *) continue ;; esac ;;
    esac
    if g="$(hk_match "$rel" "$FOLD")"; then
      if [ "$g" = .claude/settings.json ] || [ "$g" = .claude/settings.local.json ]; then
        ask_always "$rel is a Claude Code settings file, always protected, also in warn mode (repository $top)."
      elif [ "$g" = "$HOOKS_DIR_REL/**" ] || [ "$g" = "$HK_LIST_REL" ]; then
        ask "$rel is one of the guard's own files, always protected (repository $top)."
      else
        ask "$rel matches \"$g\" in $HK_LIST_REL (repository $top)."
      fi
      return 0
    fi
  done
  settings_file "$cwd" "$res" "$abs"
  return 0
}

# check_text <text> <kind> <cwd> — Bash commands and other tools: search for literal parts in every governed
# repository the text can reach (the session's, and any whose path the text spells out, quoted spaces included).
check_text() {
  local text="$1" kind="$2" cwd="$3" plain tops="" stop top n d g th probed=""
  plain="$(printf '%s' "$text" | strip_cmd)"
  tokenize "$plain" "$text" "$cwd"
  if stop="$(hk_toplevel "$cwd")"; then tops="$stop"; fi
  # Every word that can point elsewhere, normalized: its deepest existing folder, probed once per folder. The words
  # come from the tokenizer, never from an unquoted expansion, so a glob in the command is not expanded here.
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    d="$n"; while [ -n "$d" ] && [ ! -d "$d" ]; do d="${d%/*}"; done
    [ -n "$d" ] || d=/
    case "$NL$probed$NL" in *"$NL$d$NL"*) continue ;; esac
    probed="$probed$NL$d"
    top="$(hk_toplevel "$d")" || continue
    case "$NL$tops$NL" in *"$NL$top$NL"*) ;; *) tops="$tops$NL$top" ;; esac
  done <<EOF_W
$(printf '%s\n' "$STREAM" | awk 'NR % 4 == 0' | tr '\037' '\n' | sort -u)
EOF_W
  while IFS= read -r top; do
    [ -n "$top" ] || continue
    load "$top"; case $? in 1|2) continue ;; esac
    g="$(mentions "$plain")" || g=""
    th=""
    if [ "$kind" = Bash ]; then
      scan "$top"
      [ -n "$TH" ] && th="$(printf '%s\n' "$TH" | sort -u)"
      [ -n "$g" ] || g="$PH"
    fi
    [ -n "$g" ] || [ -n "$th" ] || continue
    if [ "$kind" = Bash ] && is_read "$plain"; then continue; fi
    # A settings file named by the call is asked about in either mode (warn mode included).
    case " $g ${PH:-} " in
      *" .claude/settings.json "*|*" .claude/settings.local.json "*)
        ask_always "this $kind call names a Claude Code settings file ($g), always protected, also in warn mode (repository $top)."
        return 0 ;;
    esac
    if [ "$kind" = Bash ] && [ -n "$th" ]; then
      ask "this command may change protected files (repository $top): $(printf '%s\n' "$th" | paste -sd ';' - | sed 's/;/; /g')."
    elif [ "$kind" = Bash ]; then
      ask "this command names $g (protected in $HK_LIST_REL, repository $top) and is not a plain read."
    else
      ask "this $kind call names $g (protected in $HK_LIST_REL, repository $top)."
    fi
    return 0
  done <<EOF_TOPS
$tops
EOF_TOPS
  return 0
}

TOOL="$(hk_field "$IN" tool_name)"; RC=$?
if [ "$RC" -eq 3 ]; then
  # No JSON parser: search the raw input for any literal part of the session repository's list.
  MODE="$(hk_raw_mode "$IN")"
  TOP="$(hk_toplevel "${CLAUDE_PROJECT_DIR:-$PWD}")" || TOP="$(hk_toplevel "$PWD")" || exit 0
  load "$TOP"; [ $? -eq 1 ] && exit 0
  if grep -Eiq 'settings(\.local)?\.json' "$IN"; then
    # A settings file is asked about in either mode (warn included); without a parser, any mention of one.
    ask_always "this call names a Claude Code settings file and the guard has no JSON parser to tell a read from a write (install jq or python3 for a precise answer)."
  elif grep -Eq '"(file_path|notebook_path)"' "$IN"; then
    ask "a file edit, and without jq or python3 the guard cannot read its path or follow a symlink (install jq or python3 for a precise answer)."
  elif g="$(mentions "$(strip_cmd < "$IN")")"; then
    ask "this call names $g and the guard has no JSON parser to tell a read from a write (install jq or python3 for a precise answer)."
  fi
  answer
fi
if [ "$RC" -ne 0 ]; then
  echo "protected-file-guard: the hook input is not the JSON a PreToolUse hook receives" >&2
  exit 2
fi
MODE="$(hk_field "$IN" permission_mode)" || MODE=""
CWD="$(hk_field "$IN" cwd)" && CWD="$(hk_posix_path "$CWD")" || CWD="$PWD"
[ -d "$CWD" ] || CWD="$PWD"

FP="$(hk_field "$IN" tool_input.file_path)" || FP=""
NP="$(hk_field "$IN" tool_input.notebook_path)" || NP=""
if [ -n "$FP" ] || [ -n "$NP" ]; then
  [ -n "$FP" ] && check_path "$FP" "$CWD"
  [ -n "$NP" ] && check_path "$NP" "$CWD"
elif [ "$TOOL" = Bash ]; then
  CMD="$(hk_field "$IN" tool_input.command)" || CMD=""
  [ -n "$CMD" ] && check_text "$CMD" Bash "$CWD"
else
  TI="$(hk_field "$IN" tool_input)" || TI=""
  [ -n "$TI" ] && check_text "$TI" "$TOOL" "$CWD"
fi
answer
