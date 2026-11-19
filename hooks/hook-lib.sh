#!/usr/bin/env bash
# hook-lib.sh — shared helpers for the hooks pack. SOURCED by every hook script; never run on its own.
# hooks-pack: 1
#
# Rules every helper keeps (the scripts rely on them):
#   - bash 3.2, BSD and GNU userland, `set -u` only, no pipefail reliance.
#   - No required JSON parser at run time: hk_field uses jq when present, else python3, else returns 3 and the
#     caller takes its documented no-parser path. JSON output is built here with sed escaping, never with jq.
#   - Configuration files are data: hooks.env is parsed line by line (KEY=value, `#` comments on their own lines),
#     never sourced. A malformed file is an error, never "no configuration".
#
#   hk_parser                          prints jq | python3 | none
#   hk_field <json-file> <a.b.c>       prints the value (strings raw, anything else as JSON). 0 found · 1 absent or
#                                      null · 2 the input is not JSON · 3 no parser
#   hk_mode <top>                      prints warn | enforce (HOOKS_MODE of that repository's hooks.env; enforce unless
#                                      it says exactly warn)
#   hk_kv_get <file> <KEY>          value of KEY in a KEY=value file. 0 found · 1 absent · 2 unreadable/malformed
#   hk_globs_to_ere                    stdin: one glob per line; stdout: one anchored ERE per line
#   hk_glob_bad <glob>                 0 when the spelling cannot be honoured (leading ./ or /, trailing /, {a,b}, [ab],
#                                      !x, # in it)
#   hk_glob_token <glob>               the literal part a shell command must contain to name the file
#   hk_toplevel <dir>                  physical top level of the git work tree holding <dir>; 1 when none
#   hk_resolve <path> <base-dir>       absolute physical path (symlinks followed, missing tail kept); 1 on failure
#   hk_case_folds <dir>                0 when the filesystem holding <dir> folds case, probed on the repository's own
#                                      hooks.env (else on <dir>'s last component); HOOKS_CASE_FOLD=0|1 overrides
#   hk_json_escape                     stdin → JSON string body (no quotes); control characters dropped
#   hk_lower                           stdin → lower case (ASCII)

HOOKS_PACK_VERSION=1
HOOKS_ENV_REL=.claude/hooks/hooks.env
HOOKS_DIR_REL=.claude/hooks
HOOKS_LIST_DEFAULT=.claude/protected-files.txt
# Always protected, whatever the list says: the files that can switch the hooks off (disableAllHooks) or rewire them.
HOOKS_BUILTIN_SETTINGS=".claude/settings.json .claude/settings.local.json"
# Every key hooks.env.example documents; hooks-check.sh names any key missing from an installed hooks.env.
HOOKS_ENV_KEYS="PROTECTED_FILES_FILE COMMIT_CHECK_CMD COMMIT_CHECK_TIMEOUT_SECS"

# hk_mode <top> — warn | enforce: the HOOKS_MODE of the repository at <top>. warn only when hooks.env says exactly
# HOOKS_MODE=warn; absent, empty, any other value or a malformed hooks.env → enforce (the existing behaviour).
hk_mode() {
  local v
  v="$(hk_kv_get "$1/$HOOKS_ENV_REL" HOOKS_MODE 2>/dev/null)" || v=""
  if [ "$v" = warn ]; then echo warn; else echo enforce; fi
}

# Windows (Git for Windows' bash is MSYS2; Cygwin likewise): native jq.exe and python.exe write text with CRLF line
# ends, and native python resolves paths to C:\… forms the shell's own paths never compare equal to.
hk_windows() { case "${OSTYPE:-}" in msys*|cygwin*) return 0 ;; esac; return 1; }

# A native jq.exe ends every output line with CRLF: every jq call of the hooks scripts (hooks-install's settings merge,
# hooks-check's reads) goes through this wrapper on Windows, which drops those CRs.
# Only when a jq is installed: the function would otherwise make `command -v jq` answer yes with no jq to run.
if hk_windows && command -v jq >/dev/null 2>&1; then
  jq() { local o rc; o="$(command jq "$@")"; rc=$?; [ -z "$o" ] || printf '%s\n' "$o" | tr -d '\r'; return "$rc"; }
fi

# hk_posix_path <path> — the path in the shell's own form. On Windows, Claude Code hands the hooks Windows paths
# (C:\Users\…\file, cwd included) and git prints C:/…: those become /c/Users/… (cygpath -u), which every path the shell
# makes compares equal to. Anything else, and everything on other systems, is printed unchanged.
hk_posix_path() {
  if hk_windows && command -v cygpath >/dev/null 2>&1; then
    case "$1" in [A-Za-z]:[/\\]*|*\\*) cygpath -u -- "$1" 2>/dev/null && return 0 ;; esac
  fi
  printf '%s\n' "$1"
}

# python3 counts only when it runs: on Windows `python3` is often the Microsoft Store alias, which exists on PATH,
# prints "Python was not found" and exits non-zero.
hk_python_runs() { command -v python3 >/dev/null 2>&1 && python3 -I -c 'import json' >/dev/null 2>&1; }
# On Windows the answer is found once per hook run (the alias is slow to fail, and hk_field and hk_resolve would each
# start it again): HK_PY=1 runs, 0 does not. Elsewhere HK_PY stays empty and python3 on PATH is taken as working
# (hk_field still reads a failure to start from python3's exit status).
HK_PY=""
if hk_windows && command -v python3 >/dev/null 2>&1; then
  if hk_python_runs; then HK_PY=1; else HK_PY=0; fi
fi
hk_has_python() { [ "$HK_PY" != 0 ] && command -v python3 >/dev/null 2>&1; }

hk_parser() {
  if command -v jq >/dev/null 2>&1; then echo jq
  elif hk_python_runs; then echo python3
  else echo none; fi
}

hk_field() {
  local f="$1" key="$2" p rc
  # python3 is not probed first (one more interpreter start per field): its own exit status says whether it ran.
  if command -v jq >/dev/null 2>&1; then p=jq; elif hk_has_python; then p=python3; else p=none; fi
  case "$p" in
    jq)
      p="$(printf '%s' "$key" | sed 's/[^.][^.]*/"&"/g; s/\./,/g')"
      # (On Windows, jq is the wrapper above: no CR from a native jq.exe reaches the value.)
      jq -e -r "getpath([$p]) // empty | if type == \"string\" then . else tojson end" < "$f" 2>/dev/null
      rc=$?
      case "$rc" in 0) return 0 ;; 4) return 1 ;; *) return 2 ;; esac ;;
    python3)
      # Bytes, not text: a native Windows python would write "\r\n" for "\n" in text mode.
      python3 -I -c '
import json, sys
try:
    with open(sys.argv[1], "rb") as fh:
        v = json.loads(fh.read().decode("utf-8"))
except Exception:
    sys.exit(2)
for k in sys.argv[2].split("."):
    if isinstance(v, dict) and k in v:
        v = v[k]
    else:
        sys.exit(1)
if v is None:
    sys.exit(1)
sys.stdout.buffer.write(((v if isinstance(v, str) else json.dumps(v)) + "\n").encode("utf-8"))
' "$f" "$key" 2>/dev/null
      rc=$?
      # 0 1 2 are the script's own answers; anything else is a python3 that did not run (the Store alias exits 49,
      # a missing interpreter 127): no parser, never "the input is not JSON".
      case "$rc" in 0|1|2) return "$rc" ;; *) return 3 ;; esac ;;
    *) return 3 ;;
  esac
}

hk_kv_get() {
  local f="$1" want="$2" line k v found=1 val=""
  [ -r "$f" ] || return 2
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"   # a CRLF line end (Git for Windows' default checkout) is a line end; a CR elsewhere is malformed
    case "$line" in *$'\r'*) return 2 ;; ''|'#'*|*=*) ;; *) return 2 ;; esac
    case "$line" in ''|'#'*) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in ''|*[!A-Za-z0-9_]*) return 2 ;; esac
    # A value that starts with # is a trailing comment, never a value.
    case "$(printf '%s' "$v" | sed 's/^[[:space:]]*//')" in '#'*) return 2 ;; esac
    if [ "$k" = "$want" ]; then val="$v"; found=0; fi
  done < "$f"
  [ "$found" -eq 0 ] || return 1
  printf '%s\n' "$val"
}

# The same conversion the ship skill uses for its critical-path globs, anchored over a plain relative path:
# `**/` → `(.*/)?`, `**` → `.*`, `*` → `[^/]*`, `?` → `[^/]`, every other regex metacharacter escaped.
hk_globs_to_ere() {
  grep -v -E '^[[:space:]]*(#|$)' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    -e 's/[].[()+{}|^$\\]/\\&/g' \
    -e 's#\*\*/#__DSTAR_SLASH__#g' -e 's/\*\*/__DSTAR__/g' -e 's#\*#[^/]*#g' -e 's#?#[^/]#g' \
    -e 's#__DSTAR_SLASH__#(.*/)?#g' -e 's/__DSTAR__/.*/g' \
    -e 's#^#^(#' -e 's#$#)$#'
}

hk_glob_bad() {
  # A [...] class is rejected, not converted: the file-tool check would take it literally and the shell check as a
  # wildcard, so the two would disagree about what is protected.
  case "$1" in ./*|*/|*'{'*|*'['*|'!'*|*'#'*|/*) return 0 ;; esac
  return 1
}

# Literal part of a glob: everything before its first wildcard; when the glob starts with a wildcard, the longest
# wildcard-free run after it (`**/secrets.json` → `secrets.json`). Empty when the glob is all wildcards.
hk_glob_token() {
  local g="$1" pre
  pre="${g%%[*?[]*}"
  # A folder is named without its trailing slash too (`find .github/workflows -delete`).
  pre="${pre%/}"
  if [ -n "$pre" ]; then printf '%s\n' "$pre"; return 0; fi
  printf '%s\n' "$g" | tr '*?[' '\n\n\n' | awk 'length($0) > length(best) { best = $0 } END { print best }' | sed 's#^/##'
}

hk_toplevel() {
  local d="$1" t
  [ -d "$d" ] || return 1
  t="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$t" ] || return 1
  (cd "$t" 2>/dev/null && pwd -P) || return 1
}

hk_resolve() {
  local p base out
  p="$(hk_posix_path "$1")"; base="$(hk_posix_path "$2")"
  case "$p" in /*) ;; '~'/*) p="$HOME/${p#\~/}" ;; *) p="$base/$p" ;; esac
  # Not on Windows: a native python there answers C:\…, never a path of the shell's; the walk below is used instead.
  if ! hk_windows && command -v python3 >/dev/null 2>&1; then
    # Only a POSIX answer counts (the same rule, for a python3 on PATH that is not what it seems).
    out="$(python3 -I -c 'import os, sys; sys.stdout.write(os.path.realpath(sys.argv[1]))' "$p" 2>/dev/null)" \
      && case "$out" in /*) true ;; *) false ;; esac && { printf '%s\n' "$out"; return 0; }
  fi
  # Without python3: follow the leaf through up to 40 symlinks, then make the deepest existing parent physical.
  local hops=0 dir leaf tail="" t
  while [ -L "$p" ]; do
    hops=$((hops + 1)); [ "$hops" -le 40 ] || return 1
    t="$(readlink "$p")" || return 1
    case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
  done
  dir="$(dirname "$p")"; leaf="$(basename "$p")"
  while [ ! -d "$dir" ]; do
    tail="$(basename "$dir")/$tail"; t="$(dirname "$dir")"
    [ "$t" != "$dir" ] || return 1
    dir="$t"
  done
  dir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  out="$dir/$tail$leaf"
  # `..` left in a missing tail: fold it textually (nothing below the existing parent can be a symlink yet).
  out="$(printf '%s\n' "$out" | awk -F/ '{ n=0; for (i=2;i<=NF;i++) { if ($i=="" || $i==".") continue; if ($i=="..") { if (n>0) n--; continue } s[++n]=$i } o=""; for (i=1;i<=n;i++) o=o "/" s[i]; print (o=="" ? "/" : o) }')"
  printf '%s\n' "$out"
}

hk_case_folds() {
  case "${HOOKS_CASE_FOLD:-}" in 1) return 0 ;; 0) return 1 ;; esac
  local d="$1" f up
  while [ -n "$d" ] && [ ! -d "$d" ]; do d="${d%/*}"; done
  [ -n "$d" ] || return 1
  # Probe the repository's own filesystem, not the root's: a known file inside it (its hooks.env) when there is one,
  # else the folder itself, each with only its last component upper-cased (a case-folding mount can sit under a
  # case-sensitive root, and the upper-cased root path would never exist).
  if [ -f "$d/$HOOKS_ENV_REL" ]; then f="$d/$HOOKS_ENV_REL"; else f="$d"; fi
  up="${f%/*}/$(printf '%s' "${f##*/}" | tr '[:lower:]' '[:upper:]')"
  # A name already in upper case is probed in lower case instead.
  [ "$up" != "$f" ] || up="${f%/*}/$(printf '%s' "${f##*/}" | tr '[:upper:]' '[:lower:]')"
  [ "$up" != "$f" ] || return 1
  # The same file under both spellings = the filesystem folds case.
  [ -e "$up" ] && [ "$up" -ef "$f" ]
}

hk_json_escape() {
  LC_ALL=C tr -d '\000-\010\013-\037\177' | LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' \
    | LC_ALL=C awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'
}

hk_lower() { LC_ALL=C tr '[:upper:]' '[:lower:]'; }

# hk_load_list <top> — the protected list of the repository at <top>. Sets HK_GLOBS (one glob per line, the
# built-in entries first: the hooks folder, the list, the two settings files), HK_ERES (the same, as anchored EREs), HK_TOKENS (one literal per line) and HK_LIST_REL.
# 0 loaded · 1 not governed (no hooks.env: nothing in this repository is guarded) · 2 configuration error (HK_ERR says
# which file and why; the caller never treats it as "nothing protected").
hk_load_list() {
  local top="$1" env="$1/$HOOKS_ENV_REL" rel rc g bad="" tok
  HK_GLOBS=""; HK_ERES=""; HK_TOKENS=""; HK_LIST_REL=""; HK_ERR=""
  [ -f "$env" ] || return 1
  rel="$(hk_kv_get "$env" PROTECTED_FILES_FILE)"; rc=$?
  case "$rc" in
    0) [ -n "$rel" ] || rel="$HOOKS_LIST_DEFAULT" ;;
    1) rel="$HOOKS_LIST_DEFAULT" ;;
    *) HK_ERR="$HOOKS_ENV_REL is malformed (only KEY=value lines and # comments on their own lines): $env"; return 2 ;;
  esac
  case "$rel" in /*|*..*) HK_ERR="PROTECTED_FILES_FILE must be a path inside the repository (got '$rel'): $env"; return 2 ;; esac
  HK_LIST_REL="$rel"
  [ -f "$top/$rel" ] && [ -r "$top/$rel" ] || { HK_ERR="the protected list $rel is missing or unreadable (named by $env)"; return 2; }
  HK_GLOBS="$(printf '%s\n' "$HOOKS_DIR_REL/**" "$rel" $HOOKS_BUILTIN_SETTINGS; grep -v -E '^[[:space:]]*(#|$)' "$top/$rel" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    if hk_glob_bad "$g"; then bad="$bad '$g'"; continue; fi
    tok="$(hk_glob_token "$g")"
    [ -n "$tok" ] || { bad="$bad '$g'"; continue; }
    HK_TOKENS="$HK_TOKENS$tok
"
  done <<EOF_GLOBS
$HK_GLOBS
EOF_GLOBS
  [ -z "$bad" ] || { HK_ERR="the protected list $rel has spellings the guard cannot honour (no leading ./ or /, no trailing /, no {a,b}, no [ab], no !negation, no inline #, not all wildcards):$bad"; return 2; }
  HK_ERES="$(printf '%s\n' "$HK_GLOBS" | hk_globs_to_ere)"
  return 0
}

# hk_match <relpath> <fold 0|1> — prints the first glob of HK_GLOBS that matches (0), or nothing (1).
hk_match() {
  local p="$1" fold="$2" n=0 e g
  [ "$fold" = 1 ] && p="$(printf '%s' "$p" | hk_lower)"
  while IFS= read -r e; do
    n=$((n + 1)); [ -n "$e" ] || continue
    [ "$fold" = 1 ] && e="$(printf '%s' "$e" | hk_lower)"
    if printf '%s\n' "$p" | grep -Eq -- "$e"; then
      g="$(printf '%s\n' "$HK_GLOBS" | sed -n "${n}p")"; printf '%s\n' "$g"; return 0
    fi
  done <<EOF_ERES
$HK_ERES
EOF_ERES
  return 1
}

# hk_stdin_file — reads the hook's stdin into a temp file (path printed). The caller removes it.
hk_stdin_file() {
  local f
  f="$(mktemp "${TMPDIR:-/tmp}/hookin.XXXXXX")" || return 1
  cat > "$f" || { rm -f "$f"; return 1; }
  printf '%s\n' "$f"
}

# hk_raw_mode <json-file> — without a parser: permission_mode by a fixed-pattern extraction (the value is letters only,
# and an escaped occurrence inside a JSON string cannot match the unescaped quotes this pattern needs).
hk_raw_mode() {
  LC_ALL=C sed -n 's/.*"permission_mode"[[:space:]]*:[[:space:]]*"\([A-Za-z]*\)".*/\1/p' "$1" | head -1
}
