#!/usr/bin/env bash
# retro-data.sh — the mechanical half of the retro skill: gathers a window's numbers and prints them as stable lines.
# It READS ONLY: git history, read-only `gh` queries, `git ls-remote`, and a download's `hm-lock.sh status`. It never
# fetches, never writes a file, never records a lock. The judgment (what the numbers mean) is the skill's job.
#
#   retro-data.sh [--days N] [--config <file>] [--download <dir>]
#
# Conventions:
#   - bash 3.2 clean; `set -u`; no `set -e`/`pipefail`. Every producer is captured and its exit status checked before
#     anything parses it: a failed read is never a zero.
#   - Configuration: retro.env next to SKILL.md (or --config). KEY=value lines and # comments on their own lines; a
#     value may not begin with #. Parsed, never sourced.
#   - History, findings files and the rules file are read from REF (the base branch: its remote-tracking branch when
#     it exists), never from the working tree. The install record is the one exception: hm-lock.sh reads it from the
#     checkout, as the onboarding wrote it.
#   - Output: one fact per line, keyword first, k=v fields next, free text (a subject, a title, a path) LAST.
#       WINDOW days=<n> since=<iso> until=<iso>
#       REF <ref> <commit> tip=<iso date of the tip commit>
#       REPORT path=<report file to write>
#       COMMITS total=<n> feat=<n> fix=<n> chore=<n> docs=<n> other=<n> style=<conventional|keywords>
#       COMMIT <short id> <type> <subject>
#       FIXCHAIN count=<n> kind=file|dir commits=<id,id,...> <path>        (oldest commit first)
#       ISSUES opened=<n> closed=<n> net=<+n|-n>
#       PRS merged=<n> fix=<n>
#       PR <number> <type> <title>
#       FINDINGS files=<n>  /  FINDINGS-FILE <path>
#       SESSIONS files=<n>  /  SESSIONS-FILE <path>            session summaries written in the window (SESSION_NOTES_DIR)
#       THRESHOLD value=<n> <file it was read from>
#       GUARDS added=<n> budget-per-month=<n|none> days=<n>  /  GUARD-FILE <path>
#       CURRENCY source=download|tag installed=<v[,v]> available=<v> ...  /  CURRENCY-ITEM <state> recorded=<v> <path>
#       NOT-CONFIGURED <section> reason=<token>              a choice in retro.env: the section is skipped, not failed
#       UNAVAILABLE <section> reason=<token> [detail]        a read that failed: the section has NO number
#   - Last line: RETRO-RESULT retro-data PASS complete | PARTIAL unavailable=<sections> | FAIL <reason>
#   - Exit: 0 every configured section was read · 2 usage or configuration · 3 a read failed (PARTIAL: the other
#     sections are still printed; FAIL: nothing could be read at all, e.g. not a git repository).
set -u
LC_ALL=C; export LC_ALL
GIT_TERMINAL_PROMPT=0; export GIT_TERMINAL_PROMPT   # a release URL that wants a password fails, never prompts
GH_PROMPT_DISABLED=1; export GH_PROMPT_DISABLED     # gh never prompts either (e.g. to pick a base repository)

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "$BIN/.." && pwd -P)"
CONFIG=""; DAYS=7; DOWNLOAD=""; UNAV=""; GH_LIMIT=1000
TAB="$(printf '\t')"; RS="$(printf '\036')"
ERRF="$(mktemp "${TMPDIR:-/tmp}/retro-data.XXXXXX")" || { echo "RETRO-RESULT retro-data FAIL tmp-failed"; exit 3; }
ZF="$(mktemp "${TMPDIR:-/tmp}/retro-data.XXXXXX")" || { rm -f "$ERRF"; echo "RETRO-RESULT retro-data FAIL tmp-failed"; exit 3; }
trap 'rm -f "$ERRF" "$ZF"' EXIT

result() { echo "RETRO-RESULT retro-data $*"; }
die() {   # die <rc> <reason> [message]
  local rc="$1" reason="$2"; shift 2
  [ "$#" -gt 0 ] && echo "STOP: $*"
  result FAIL "$reason"; exit "$rc"
}
usage() { die 2 usage "usage: retro-data.sh [--days N] [--config <file>] [--download <dir>]"; }
unavailable() {   # unavailable <section> <reason> [detail]
  local d=""; [ -n "${3:-}" ] && d=" $(printf '%s' "$3" | tr '\n\r\t' '   ' | cut -c1-200)"
  echo "UNAVAILABLE $1 reason=$2$d"
  case ",$UNAV," in *",$1,"*) ;; *) UNAV="${UNAV:+$UNAV,}$1" ;; esac
}
notconf() { echo "NOT-CONFIGURED $1 reason=$2"; }
first_err() { head -1 "$ERRF" 2>/dev/null; }
is_number() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# ---- arguments ------------------------------------------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
  case "$1" in
    --days) [ "$#" -ge 2 ] || usage; DAYS="$2"; shift 2 ;;
    --config) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; CONFIG="$2"; shift 2 ;;
    --download) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; DOWNLOAD="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
is_number "$DAYS" && [ "${#DAYS}" -le 5 ] || die 2 usage "--days must be a whole number from 1 to 3660, got '$DAYS'"
DAYS=$((10#$DAYS))   # decimal, always: a leading zero is not octal
[ "$DAYS" -ge 1 ] && [ "$DAYS" -le 3660 ] || die 2 usage "--days must be a whole number from 1 to 3660, got '$DAYS'"
# --download is resolved now, before the script moves to the repository root.
case "$DOWNLOAD" in ''|/*) ;; *) DOWNLOAD="$PWD/$DOWNLOAD" ;; esac

# ---- configuration --------------------------------------------------------------------------------------------------
kv_get() {   # kv_get <file> <key> — 0 found (value printed, may be empty) · 1 absent · 2 unreadable or malformed
  local f="$1" want="$2" line k v found=1 val=""
  [ -r "$f" ] || return 2
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"   # a CRLF line end (Git for Windows' default checkout) is a line end; a CR elsewhere is malformed
    case "$line" in *$'\r'*) return 2 ;; ''|'#'*|*=*) ;; *) return 2 ;; esac
    case "$line" in ''|'#'*) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in ''|*[!A-Za-z0-9_]*) return 2 ;; esac
    case "$(printf '%s' "$v" | sed 's/^[[:space:]]*//')" in '#'*) return 2 ;; esac   # a trailing comment, not a value
    if [ "$k" = "$want" ]; then val="$v"; found=0; fi
  done < "$f"
  [ "$found" -eq 0 ] || return 1
  printf '%s\n' "$val"
}
cfg() { local v; v=$(kv_get "$CONFIG" "$1") || v=""; if [ -n "$v" ]; then printf '%s\n' "$v"; else printf '%s\n' "${2:-}"; fi; }

[ -n "$CONFIG" ] || CONFIG="$SKILL_DIR/retro.env"
[ -f "$CONFIG" ] || die 2 config-missing "no configuration at $CONFIG: copy retro.env.example to retro.env and fill it, or pass --config <file>"
kv_get "$CONFIG" BASE_BRANCH >/dev/null 2>&1; [ "$?" -ne 2 ] || die 2 config-malformed "$CONFIG is unreadable or malformed (KEY=value lines and # comments on their own lines; a value may not begin with #)"

BASE=$(cfg BASE_BRANCH)
[ -n "$BASE" ] || die 2 config-base-branch "BASE_BRANCH is not set in $CONFIG"
case "$BASE" in -*|*[!A-Za-z0-9._/-]*) die 2 config-base-branch "BASE_BRANCH is not a plain branch name: $BASE" ;; esac
REMOTE=$(kv_get "$CONFIG" BASE_REMOTE); [ "$?" -eq 1 ] && REMOTE=origin   # absent = origin; present and empty = none
case "$REMOTE" in -*|*[!A-Za-z0-9._-]*) die 2 config-malformed "BASE_REMOTE is not a plain remote name: $REMOTE" ;; esac
STYLE=$(cfg COMMIT_STYLE)
case "$STYLE" in conventional|keywords) ;; *) die 2 config-commit-style "COMMIT_STYLE must be conventional or keywords, got '$STYLE'" ;; esac
FIX_WORDS=$(cfg FIX_WORDS "fix,fixes,fixed,bug,bugfix,hotfix,regression,broken,crash")
FEAT_WORDS=$(cfg FEAT_WORDS "feat,feature,add,adds,added,implement,implements,introduce,introduces,new,support")
DOCS_WORDS=$(cfg DOCS_WORDS "docs,doc,documentation,readme,changelog")
CHORE_WORDS=$(cfg CHORE_WORDS "chore,refactor,cleanup,bump,deps,dependencies,rename,ci,build,test,tests,lint,format")
CHAIN_MIN=$(cfg FIX_CHAIN_MIN 3)
is_number "$CHAIN_MIN" && [ "$CHAIN_MIN" -ge 2 ] || die 2 config-malformed "FIX_CHAIN_MIN must be a whole number of 2 or more, got '$CHAIN_MIN'"
TRACKER=$(cfg TRACKER)
case "$TRACKER" in github|none) ;; *) die 2 config-tracker "TRACKER must be github or none, got '$TRACKER'" ;; esac
REPORT_DIR=$(cfg REPORT_DIR)
[ -n "$REPORT_DIR" ] || die 2 config-report-dir "REPORT_DIR is not set in $CONFIG"
FINDINGS_DIR=$(cfg FINDINGS_DIR)
SESSION_NOTES_DIR=$(cfg SESSION_NOTES_DIR)
CLAUDE_MD=$(cfg CLAUDE_MD CLAUDE.md)
GUARD_GLOBS=$(cfg GUARD_GLOBS)
GUARD_BUDGET=$(cfg GUARD_BUDGET_PER_MONTH)
[ -z "$GUARD_BUDGET" ] || is_number "$GUARD_BUDGET" || die 2 config-malformed "GUARD_BUDGET_PER_MONTH must be a whole number or empty, got '$GUARD_BUDGET'"
RELEASE_URL=$(cfg RELEASE_REPO_URL)
case "$RELEASE_URL" in -*) die 2 config-malformed "RELEASE_REPO_URL may not begin with '-'" ;; esac
# GH_REPO=owner/repo: every gh query reads that repository (gh honors the GH_REPO environment variable). Empty or
# absent: the environment is left alone and gh picks the repository its own default way.
GH_REPO_CFG=$(cfg GH_REPO)
if [ -n "$GH_REPO_CFG" ]; then
  case "$GH_REPO_CFG" in */*/*|/*|*/|-*|*[!A-Za-z0-9._/-]*) die 2 config-malformed "GH_REPO must be owner/repo or empty, got '$GH_REPO_CFG'" ;;
    */*) GH_REPO="$GH_REPO_CFG"; export GH_REPO ;;
    *) die 2 config-malformed "GH_REPO must be owner/repo or empty, got '$GH_REPO_CFG'" ;; esac
fi
for p in "$REPORT_DIR" "$FINDINGS_DIR" "$SESSION_NOTES_DIR" "$CLAUDE_MD"; do
  case "$p" in /*|../*|*/../*|*/..|..) die 2 config-malformed "paths in $CONFIG are relative to the repository and stay inside it: '$p'" ;; esac
done

# ---- repository and window ------------------------------------------------------------------------------------------
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || die 3 not-a-repo "not inside a git repository (run it from your project)"
cd "$TOP" || die 3 not-a-repo "cannot enter $TOP"
REF=""
if [ -n "$REMOTE" ] && git rev-parse -q --verify "refs/remotes/$REMOTE/$BASE^{commit}" >/dev/null 2>&1; then REF="refs/remotes/$REMOTE/$BASE"
elif git rev-parse -q --verify "refs/heads/$BASE^{commit}" >/dev/null 2>&1; then REF="refs/heads/$BASE"
else die 3 base-unreadable "neither ${REMOTE:+refs/remotes/$REMOTE/$BASE nor }refs/heads/$BASE names a commit"; fi
TIP=$(git rev-parse --short "$REF" 2>/dev/null) || die 3 base-unreadable "cannot read $REF"
TIP_DATE=$(git log -1 --format=%cI "$REF" 2>/dev/null) || die 3 base-unreadable "cannot read $REF"

NOW=$(date +%s) || die 3 date-failed "date +%s failed"
is_number "$NOW" || die 3 date-failed "date +%s printed '$NOW'"
SINCE_E=$((NOW - DAYS * 86400))
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; }
SINCE=$(iso "$SINCE_E") && [ -n "$SINCE" ] || die 3 date-failed "cannot format a date (neither GNU nor BSD date)"
UNTIL=$(iso "$NOW") && [ -n "$UNTIL" ] || die 3 date-failed "cannot format a date"
echo "WINDOW days=$DAYS since=$SINCE until=$UNTIL"
echo "REF $REF $TIP tip=$TIP_DATE"
echo "REPORT path=${REPORT_DIR%/}/retro-${UNTIL%%T*}.md"

# ---- commits and fix chains -----------------------------------------------------------------------------------------
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
has_word() {   # has_word <normalized subject padded with spaces> <comma list>
  local w list; list="$(lower "$2" | tr ',' ' ')"
  set -f   # a word is a word: `*` in a list from retro.env must not expand to file names
  for w in $list; do case "$1" in *" $w "*) set +f; return 0 ;; esac; done
  set +f
  return 1
}
CONV_RE='^([A-Za-z]+)(\([^)]*\))?!?:[[:space:]]'   # type, optional (scope), optional !, colon, space
classify() {   # classify <subject> — prints feat|fix|chore|docs|other
  local s="$1" t n
  if [ "$STYLE" = conventional ]; then
    if [[ "$s" =~ $CONV_RE ]]; then
      t="$(lower "${BASH_REMATCH[1]}")"
      case "$t" in
        feat) echo feat ;; fix) echo fix ;; docs) echo docs ;;
        chore|refactor|test|tests|ci|build|perf|style) echo chore ;;
        *) echo other ;;
      esac
    else echo other; fi
    return 0
  fi
  n=" $(lower "$s" | sed 's/[^a-z0-9]/ /g') "   # whole words only: "prefix" is not "fix"
  if has_word "$n" "$FIX_WORDS"; then echo fix
  elif has_word "$n" "$FEAT_WORDS"; then echo feat
  elif has_word "$n" "$DOCS_WORDS"; then echo docs
  elif has_word "$n" "$CHORE_WORDS"; then echo chore
  else echo other; fi
}

# Paths come NUL-separated (-z): git prints them raw, never in its quoted form ("caf\303\251", "a\"b"), which would not
# name a real file. Shape: "<RS><id><TAB><subject>" NUL, then the commit's paths, each NUL-terminated, the first one after a
# newline. A path holding a tab or a newline cannot travel in the line format below: the fix chains say so, never a count.
git -c core.quotePath=false log -z --no-merges --since="$SINCE" --format="${RS}%h${TAB}%s" --name-only "$REF" >"$ZF" 2>"$ERRF" \
  || die 3 git-log-failed "git log failed: $(first_err)"
NL="
"
N_ALL=0; N_feat=0; N_fix=0; N_chore=0; N_docs=0; N_other=0; IDX=0; CUR_T=""; CUR_H=""; PAIRS=""; COMMIT_LINES=""; BADPATH=""
while IFS= read -r -d '' line || [ -n "$line" ]; do
  line="${line#"$NL"}"
  case "$line" in
    "$RS"*)
      line="${line#"$RS"}"; CUR_H="${line%%"$TAB"*}"; subj="${line#*"$TAB"}"
      CUR_T="$(classify "$subj")"; IDX=$((IDX + 1)); N_ALL=$((N_ALL + 1))
      eval "N_$CUR_T=\$((N_$CUR_T + 1))"
      COMMIT_LINES="${COMMIT_LINES}COMMIT $CUR_H $CUR_T $subj
"
      ;;
    '') ;;
    *)
      if [ "$CUR_T" = fix ]; then
        case "$line" in *"$TAB"*|*"$NL"*) BADPATH="$CUR_H"; continue ;; esac
        PAIRS="${PAIRS}file${TAB}${IDX}${TAB}${CUR_H}${TAB}${line}
"
        case "$line" in */*) PAIRS="${PAIRS}dir${TAB}${IDX}${TAB}${CUR_H}${TAB}${line%/*}
" ;; esac   # a file at the top level has no folder area: the repository itself is not an area
      fi
      ;;
  esac
done <"$ZF"
echo "COMMITS total=$N_ALL feat=$N_feat fix=$N_fix chore=$N_chore docs=$N_docs other=$N_other style=$STYLE"
printf '%s' "$COMMIT_LINES"
# One hit per commit per area: a commit touching three files in one folder is one fix of that folder. The log is newest
# first (IDX ascending), so prepending keeps the commit list oldest first.
if [ -n "$BADPATH" ]; then
  unavailable fixchains unparseable-path "commit $BADPATH touched a path with a tab or a newline"
elif [ -n "$PAIRS" ]; then
  CHAINS=$(printf '%s' "$PAIRS" | awk -F'\t' -v min="$CHAIN_MIN" '
    { key = $1 FS $4; if (seen[key, $3]++) next
      if (!(key in n)) order[++k] = key
      n[key]++; ids[key] = (ids[key] == "" ? $3 : $3 "," ids[key]) }
    END { for (i = 1; i <= k; i++) { key = order[i]; if (n[key] < min) continue
            split(key, p, FS); printf "%d\t%s\t%s\t%s\n", n[key], p[1], ids[key], substr(key, length(p[1]) + 2) } }') \
    || die 3 fixchain-failed "could not compute fix chains"
  CHAINS=$(printf '%s' "$CHAINS" | sort -t "$TAB" -k1,1nr -k2,2 -k4,4) || die 3 fixchain-failed "could not sort fix chains"
  while IFS="$TAB" read -r c kind ids path; do
    [ -n "$c" ] || continue
    echo "FIXCHAIN count=$c kind=$kind commits=$ids $path"
  done <<EOF_CH
$CHAINS
EOF_CH
fi

# ---- tracker: issues opened / closed, merged PRs (read-only gh queries) ------------------------------------------------
gh_count() {   # gh_count <out var> <gh args...> — the query's --jq 'length'; returns 0 ok · 1 failed (reason in GH_WHY)
  local __v="$1" o; shift
  : > "$ERRF"
  o=$(gh "$@" --limit "$GH_LIMIT" --json number --jq 'length' 2>"$ERRF") || { GH_WHY="gh-failed"; return 1; }
  is_number "$o" || { GH_WHY="gh-unexpected-output"; return 1; }
  [ "$o" -lt "$GH_LIMIT" ] || { GH_WHY="truncated-at-$GH_LIMIT"; return 1; }
  eval "$__v=\$o"
}
if [ "$TRACKER" = none ]; then
  notconf issues tracker-none; notconf prs tracker-none
elif ! command -v gh >/dev/null 2>&1; then
  unavailable issues gh-missing; unavailable prs gh-missing
else
  OPENED=""; CLOSED=""; GH_WHY=""
  if gh_count OPENED issue list --state all --search "created:>=$SINCE" \
     && gh_count CLOSED issue list --state closed --search "closed:>=$SINCE"; then
    NET=$((OPENED - CLOSED)); [ "$NET" -ge 0 ] && NET="+$NET"
    echo "ISSUES opened=$OPENED closed=$CLOSED net=$NET"
  else
    unavailable issues "$GH_WHY" "$(first_err)"
  fi
  : > "$ERRF"
  if PRL=$(gh pr list --state merged --search "merged:>=$SINCE" --limit "$GH_LIMIT" --json number,title \
             --jq '.[] | "\(.number)\t\(.title)"' 2>"$ERRF"); then
    N_PR=0; N_PRFIX=0; PR_LINES=""; BAD=0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      num="${line%%"$TAB"*}"; title="${line#*"$TAB"}"
      is_number "$num" || { BAD=1; break; }
      t="$(classify "$title")"; N_PR=$((N_PR + 1)); [ "$t" = fix ] && N_PRFIX=$((N_PRFIX + 1))
      PR_LINES="${PR_LINES}PR $num $t $title
"
    done <<EOF_PR
$PRL
EOF_PR
    if [ "$BAD" -eq 1 ]; then unavailable prs gh-unexpected-output
    elif [ "$N_PR" -ge "$GH_LIMIT" ]; then unavailable prs "truncated-at-$GH_LIMIT"
    else echo "PRS merged=$N_PR fix=$N_PRFIX"; printf '%s' "$PR_LINES"; fi
  else
    unavailable prs gh-failed "$(first_err)"
  fi
fi

# ---- review findings written or updated in the window ---------------------------------------------------------------
# Everything below is read from REF, never from the working tree: a run from a feature branch, or a tree behind its
# remote, would otherwise drop files that merged this week.
zlist() {   # the unique paths in $ZF (a -z --name-only log), one per line · 4 a path holds a tab or a newline · else sort's
  local p out=""
  while IFS= read -r -d '' p || [ -n "$p" ]; do
    p="${p#"$NL"}"; [ -n "$p" ] || continue
    case "$p" in *"$TAB"*|*"$NL"*) return 4 ;; esac
    out="$out$p$NL"
  done <"$ZF"
  printf '%s' "$out" | sort -u
}
# window_files <section> <LABEL> <folder> <not-configured reason> — the files under <folder> written or updated in the
# window, as `<LABEL> files=<n>` and one `<LABEL>-FILE <path>` line each.
window_files() {
  local sec="$1" lab="$2" dir="$3" nc="$4" FL RC NF FF f
  if [ -z "$dir" ]; then notconf "$sec" "$nc"
  elif [ "$(git cat-file -t "$REF:$dir" 2>/dev/null)" != tree ]; then unavailable "$sec" folder-missing "$dir at $REF"
  elif ! git -c core.quotePath=false log -z --since="$SINCE" --format= --name-only "$REF" -- "$dir" >"$ZF" 2>"$ERRF"; then
    unavailable "$sec" git-log-failed "$(first_err)"
  else
    FL=$(zlist); RC=$?
    if [ "$RC" -eq 4 ]; then unavailable "$sec" unparseable-path "a file under $dir has a tab or a newline in its name"
    elif [ "$RC" -ne 0 ]; then unavailable "$sec" sort-failed
    else
      NF=0; FF=""
      while IFS= read -r f; do
        [ -n "$f" ] && git cat-file -e "$REF:$f" 2>/dev/null || continue   # deleted since: not a file to read
        NF=$((NF + 1)); FF="${FF}$lab-FILE $f
"
      done <<EOF_F
$FL
EOF_F
      echo "$lab files=$NF"; printf '%s' "$FF"
    fi
  fi
}
FINDINGS_DIR="${FINDINGS_DIR%/}"; CLAUDE_MD="${CLAUDE_MD%/}"; SESSION_NOTES_DIR="${SESSION_NOTES_DIR%/}"
window_files findings FINDINGS "$FINDINGS_DIR" no-findings-folder
window_files sessions SESSIONS "$SESSION_NOTES_DIR" no-session-folder

# ---- the repeat-bug threshold, from the rule text in CLAUDE.md ------------------------------------------------------
# The template's "Count the repeats" step says "this fix included, reaches `<YOUR-CLASS-GUARD-THRESHOLD>`" on one line;
# the onboarding fills the number in place. Never a default: no number found is UNAVAILABLE.
if ! RULES=$(git show "$REF:$CLAUDE_MD" 2>/dev/null); then unavailable threshold claude-md-missing "$CLAUDE_MD at $REF"
else
  TH=$(printf '%s\n' "$RULES" | grep -o 'this fix included, reaches `[0-9][0-9]*`' | sed 's/.*`\([0-9]*\)`/\1/' | sort -u)
  case "$TH" in
    '') unavailable threshold rule-not-found "no 'this fix included, reaches \`N\`' line in $CLAUDE_MD" ;;
    *"
"*) unavailable threshold ambiguous "$CLAUDE_MD states more than one threshold: $(printf '%s' "$TH" | tr '\n' ' ')" ;;
    *) echo "THRESHOLD value=$TH $CLAUDE_MD" ;;
  esac
fi

# ---- guard growth (optional) ----------------------------------------------------------------------------------------
set -f; set -- $GUARD_GLOBS; set +f   # one pathspec per pattern, never expanded here; blank patterns are no patterns
if [ "$#" -eq 0 ]; then notconf guards no-guard-globs
else
  NS=$#; for g in "$@"; do set -- "$@" ":(glob)$g"; done; shift "$NS"
  if ! git -c core.quotePath=false log -z --since="$SINCE" --diff-filter=A --format= --name-only "$REF" -- "$@" >"$ZF" 2>"$ERRF"; then
    unavailable guards git-log-failed "$(first_err)"
  else
    GL=$(zlist); RC=$?
    if [ "$RC" -eq 4 ]; then unavailable guards unparseable-path "a matching file has a tab or a newline in its name"
    elif [ "$RC" -ne 0 ]; then unavailable guards sort-failed
    else
      NG=0; GF=""
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        NG=$((NG + 1)); GF="${GF}GUARD-FILE $f
"
      done <<EOF_G
$GL
EOF_G
      echo "GUARDS added=$NG budget-per-month=${GUARD_BUDGET:-none} days=$DAYS"; printf '%s' "$GF"
    fi
  fi
fi

# ---- framework currency ---------------------------------------------------------------------------------------------
VER_RE='^v?([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9})(-[0-9A-Za-z.]+)?$'   # x.y.z, an optional v, an optional -pre-release suffix
is_version() { [[ "$1" =~ $VER_RE ]]; }
vcore() { [[ "$1" =~ $VER_RE ]] && printf '%s.%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"; }
vcmp() {   # vcmp <a> <b> — prints -1, 0 or 1 (x.y.z numerically; a pre-release is older than its release) · 1 not versions
  local a1 a2 a3 as b1 b2 b3 bs i x y
  [[ "$1" =~ $VER_RE ]] || return 1
  a1=$((10#${BASH_REMATCH[1]})); a2=$((10#${BASH_REMATCH[2]})); a3=$((10#${BASH_REMATCH[3]})); as="${BASH_REMATCH[4]}"
  [[ "$2" =~ $VER_RE ]] || return 1
  b1=$((10#${BASH_REMATCH[1]})); b2=$((10#${BASH_REMATCH[2]})); b3=$((10#${BASH_REMATCH[3]})); bs="${BASH_REMATCH[4]}"
  for i in 1 2 3; do
    eval "x=\$a$i; y=\$b$i"
    [ "$x" -lt "$y" ] && { echo -1; return 0; }
    [ "$x" -gt "$y" ] && { echo 1; return 0; }
  done
  if [ "$as" = "$bs" ]; then echo 0
  elif [ -z "$as" ]; then echo 1
  elif [ -z "$bs" ]; then echo -1
  elif [[ "$as" < "$bs" ]]; then echo -1
  else echo 1; fi
}
LOCK=".claude/humanmaxxing.lock"
if [ -n "$DOWNLOAD" ]; then
  if [ ! -f "$DOWNLOAD/tools/hm-lock.sh" ]; then unavailable currency download-without-hm-lock "$DOWNLOAD"
  else
    : > "$ERRF"
    HM=$(bash "$DOWNLOAD/tools/hm-lock.sh" status --from "$DOWNLOAD" 2>"$ERRF"); HRC=$?
    if [ "$HRC" -ne 0 ] && [ "$HRC" -ne 1 ]; then unavailable currency hm-lock-failed "$(first_err)"
    else
      AV=$(printf '%s\n' "$HM" | sed -n 's/^SOURCE version=//p' | head -1)
      if ! is_version "$AV"; then unavailable currency hm-lock-unexpected-output "no SOURCE version line"
      else
        NB=0; NG2=0; NC=0; NN=0; NIT=0; INST=""; ITEMS=""; BADV=""; AHEAD=""
        while IFS= read -r line; do
          case "$line" in
            "ITEM "*)
              set -f; set -- $line; set +f   # ITEM <path> <state> recorded=<v> source=<v>
              rv="${4#recorded=}"; NIT=$((NIT + 1))
              if ! is_version "$rv"; then BADV="$rv"
              elif [ "$(vcmp "$rv" "$AV")" = 1 ]; then AHEAD="$rv"; fi
              case "$3" in behind) NB=$((NB + 1)) ;; gone) NG2=$((NG2 + 1)) ;; current) NC=$((NC + 1)) ;; esac
              case ",$INST," in *",$rv,"*) ;; *) INST="${INST:+$INST,}$rv" ;; esac
              ITEMS="${ITEMS}CURRENCY-ITEM $3 recorded=$rv $2
" ;;
            "NEW "*) NN=$((NN + 1)); ITEMS="${ITEMS}CURRENCY-ITEM new recorded=none ${line#NEW }
" ;;
          esac
        done <<EOF_HM
$HM
EOF_HM
        # hm-lock exits 1 for "something is behind or gone" -- and bash exits 1 when a script dies. Only an exit that
        # agrees with the items it printed is a status.
        if [ "$NIT" -eq 0 ] || { [ "$HRC" -eq 1 ] && [ $((NB + NG2)) -eq 0 ]; } || { [ "$HRC" -eq 0 ] && [ $((NB + NG2)) -gt 0 ]; }; then
          unavailable currency hm-lock-failed "exit $HRC does not match the items it printed: $(first_err)"
        elif [ -n "$BADV" ]; then unavailable currency lock-malformed "recorded version '$BADV' is not x.y.z"
        elif [ -n "$AHEAD" ]; then
          unavailable currency download-older-than-install "the download is $AV, an item is recorded at $AHEAD: compare against a newer download"
        else
          echo "CURRENCY source=download installed=${INST:-none} available=$AV behind=$NB gone=$NG2 current=$NC new=$NN"
          printf '%s' "$ITEMS"
        fi
      fi
    fi
  fi
elif [ -z "$RELEASE_URL" ]; then
  notconf currency release-source-not-configured
elif [ ! -f "$LOCK" ]; then
  unavailable currency no-install-record "$LOCK"
else
  LOCKED=""; BADLOCK=0
  while IFS= read -r line || [ -n "$line" ]; do
    # The lock is committed in the user's repository, so Git for Windows may check it out with CRLF line ends: strip
    # one CR at the end of the line before splitting it. A CR anywhere else is not this format.
    line="${line%$'\r'}"
    case "$line" in *$'\r'*) BADLOCK=1; break ;; esac
    IFS=' ' read -r kind p h rv rest <<EOF_LINE
$line
EOF_LINE
    case "$kind" in '#'*|'') continue ;; item) ;; *) BADLOCK=1; break ;; esac
    [ -n "$p" ] && [ -n "$h" ] && [ -n "$rv" ] && [ -z "$rest" ] && is_version "$rv" || { BADLOCK=1; break; }
    LOCKED="${LOCKED}${rv} ${p}
"
  done < "$LOCK"
  if [ "$BADLOCK" -eq 1 ] || [ -z "$LOCKED" ]; then unavailable currency lock-malformed "$LOCK"
  else
    : > "$ERRF"
    TAGS=$(git ls-remote --tags --refs "$RELEASE_URL" 2>"$ERRF")
    if [ "$?" -ne 0 ]; then unavailable currency ls-remote-failed "$(first_err)"
    else
      LATEST=""
      while IFS= read -r line; do
        t="${line##*refs/tags/}"
        is_version "$t" && [ "$(vcore "$t")" = "${t#v}" ] || continue   # releases only, never a pre-release
        if [ -z "$LATEST" ] || [ "$(vcmp "$t" "$LATEST")" = 1 ]; then LATEST="$t"; fi
      done <<EOF_T
$TAGS
EOF_T
      if [ -z "$LATEST" ]; then unavailable currency no-release-tags
      else
        AV="$(vcore "$LATEST")"; NO=0; NI=0; INST=""; ITEMS=""
        while IFS=' ' read -r rv p; do
          [ -n "$rv" ] || continue
          NI=$((NI + 1))
          case ",$INST," in *",$rv,"*) ;; *) INST="${INST:+$INST,}$rv" ;; esac
          c=$(vcmp "$rv" "$AV") || die 3 vcmp-failed "cannot compare '$rv' with '$AV'"
          if [ "$c" = -1 ]; then NO=$((NO + 1)); st=older; else st=current; fi
          ITEMS="${ITEMS}CURRENCY-ITEM $st recorded=$rv $p
"
        done <<EOF_L
$LOCKED
EOF_L
        echo "CURRENCY source=tag tag=$LATEST installed=$INST available=$AV older=$NO items=$NI"
        printf '%s' "$ITEMS"
      fi
    fi
  fi
fi

# ---- result ---------------------------------------------------------------------------------------------------------
if [ -z "$UNAV" ]; then result PASS complete; exit 0; fi
result PARTIAL "unavailable=$UNAV"; exit 3
