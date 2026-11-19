#!/usr/bin/env bash
# lens-score.sh — how much review a change needs, per matched lens and in total: changed lines weighted by what kind of
# file they are in, plus fixed bonuses for the changes that hurt most when missed. Read by review-code Step 2 (and
# review-plan Step 3 when the plan's branch already has a diff). Read-only: runs git diff, writes nothing.
#
#   lens-score.sh --base <ref> [--critical <file>] [--weights "<key>=<n> …"] < lens-files
#
# stdin: one line per (lens, changed file) the detection table matched, tab-separated: <lens agent> <path>. A file may
# appear under several lenses. Paths are from the repository's top.
# --base      the review's base (the merge-base 0a found); the diff is <base> → the working tree, plus untracked files
#             git does not ignore (each counts as new, all its lines added)
# --critical  the critical-paths file (default .claude/critical-paths.txt when it exists): one glob per line, `#` lines
#             not read (so paths still commented out are not critical); `**/` spans folders, `*` and `?` do not
# --weights   overrides, any of (defaults in brackets): critical [3] code [1] config [1] test [0.5] docs [0.1] per
#             changed line; new_exec [25] permission [25] gate [40] deleted [10] per file
#
# A file's weight is `critical` when a critical glob matches it, else by kind: docs (*.md, *.txt, *.rst, docs/), test
# (a tests/test/spec folder, *_test.*, *.test.*, *.spec.*, test_*), config (*.json, *.yml, *.yaml, *.toml, *.ini,
# *.cfg, *.conf, *.env, Dockerfile), code (anything else). Bonuses, once per file: a new executable file; a changed
# permission or allowlist (a mode change, or a changed line naming allowed-tools, permissions, an allow list, tools:);
# a changed gate, hook or CI step (CI workflow files, git hook folders, .claude/hooks/, .claude/settings*.json,
# .claude/critical-paths.txt, ship.env); a deleted file.
#
# Output: `SCORE <lens> <score> files=<n> critical=<0|1>` per lens (input order), `TOTAL <score> files=<n>` over every
# changed file (matched or not), then `SCORE-RESULT PASS`. Scores are rounded to whole points.
# Exit: 0 · 2 usage, malformed input or an unknown weight · 3 git could not read the diff (never a zero score).
set -u
die() { [ -z "${3:-}" ] || echo "$3" >&2; echo "SCORE-RESULT FAIL $2"; exit "$1"; }
BASE=""; CRIT=""; WEIGHTS=""
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || die 2 usage "$1 needs a value"
  case "$1" in --base) BASE="$2" ;; --critical) CRIT="$2" ;; --weights) WEIGHTS="$2" ;; *) die 2 usage "unknown argument: $1" ;; esac
  shift 2
done
[ -n "$BASE" ] || die 2 usage "--base is required"
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || die 3 not-a-repository
cd "$TOP" || die 3 not-a-repository
git rev-parse -q --verify "$BASE^{commit}" >/dev/null || die 2 usage "--base $BASE is not a commit"
if [ -z "$CRIT" ] && [ -f .claude/critical-paths.txt ]; then CRIT=.claude/critical-paths.txt; fi
[ -z "$CRIT" ] || [ -r "$CRIT" ] || die 3 critical-unreadable "cannot read $CRIT"

W_CRITICAL=3 W_CODE=1 W_CONFIG=1 W_TEST=0.5 W_DOCS=0.1 B_NEW_EXEC=25 B_PERMISSION=25 B_GATE=40 B_DELETED=10
for kv in $WEIGHTS; do
  k="${kv%%=*}"; v="${kv#*=}"
  case "$v" in ''|*[!0-9.]*|*.*.*|.*) die 2 usage "weight $k: '$v' is not a number" ;; esac
  case "$k" in
    critical) W_CRITICAL="$v" ;; code) W_CODE="$v" ;; config) W_CONFIG="$v" ;; test) W_TEST="$v" ;; docs) W_DOCS="$v" ;;
    new_exec) B_NEW_EXEC="$v" ;; permission) B_PERMISSION="$v" ;; gate) B_GATE="$v" ;; deleted) B_DELETED="$v" ;;
    *) die 2 usage "unknown weight: $k" ;;
  esac
done

T="$(mktemp -d "${TMPDIR:-/tmp}/lensscore.XXXXXX")" || die 2 mktemp-failed "cannot create a temporary folder"
trap 'rm -rf "$T"' EXIT
cat > "$T/lens" || die 3 stdin-unreadable
awk -F'\t' 'NF && (NF != 2 || $1 == "" || $2 == "") { bad=1 } END { exit bad }' "$T/lens" || die 2 malformed "want <lens agent> <path>, tab-separated, one per line"

# The diff, read whole: a failed read is exit 3, never an empty (zero-score) diff.
git -c core.quotePath=false diff --numstat --no-renames "$BASE" > "$T/numstat" 2>/dev/null || die 3 diff-failed "git diff --numstat failed"
git -c core.quotePath=false diff --summary --no-renames "$BASE" > "$T/summary" 2>/dev/null || die 3 diff-failed "git diff --summary failed"
git -c core.quotePath=false diff -U0 --no-renames "$BASE" > "$T/patch" 2>/dev/null || die 3 diff-failed "git diff failed"
git ls-files -z --others --exclude-standard > "$T/untracked" 2>/dev/null || die 3 diff-failed "git ls-files failed"
# Untracked files: new, every line added; executable when the file has the x bit.
tr '\0' '\n' < "$T/untracked" | while IFS= read -r f; do
  [ -f "$f" ] || continue
  n="$(wc -l < "$f" | tr -d ' ')"; printf '%s\t0\t%s\n' "$n" "$f" >> "$T/numstat"
  if [ -x "$f" ]; then printf ' create mode 100755 %s\n' "$f"; else printf ' create mode 100644 %s\n' "$f"; fi >> "$T/summary"
done
# Paths the permission/allowlist check hits: a changed (+/-) line naming one, in that file's hunks.
awk '/^diff --git /{ f=$0; sub(/^diff --git a\/.* b\//, "", f); next }
     /^[+-]/ && !/^(\+\+\+|---) / && tolower($0) ~ /(allowed-tools|"?permissions"?[[:space:]]*[:=]|"allow"[[:space:]]*:|^[+-][[:space:]]*tools[[:space:]]*:)/ { print f }' "$T/patch" | sort -u > "$T/perm"
# Critical globs as anchored regular expressions.
: > "$T/crit"
if [ -n "$CRIT" ]; then
  awk '{ sub(/\r$/, "") } /^[[:space:]]*(#|$)/ { next } {
         g=$0; sub(/^[[:space:]]+/, "", g); sub(/[[:space:]]+$/, "", g); r=""
         for (i=1; i<=length(g); i++) { c=substr(g,i,1)
           if (substr(g,i,3) == "**/") { r = r "(.*/)?"; i += 2 }
           else if (substr(g,i,2) == "**") { r = r ".*"; i++ }
           else if (c == "*") r = r "[^/]*"
           else if (c == "?") r = r "[^/]"
           else if (index(".+()|^$[]{}\\", c)) r = r "\\" c
           else r = r c }
         print "^" r "$" }' "$CRIT" > "$T/crit"
fi

awk -F'\t' -v wcr="$W_CRITICAL" -v wco="$W_CODE" -v wcf="$W_CONFIG" -v wt="$W_TEST" -v wd="$W_DOCS" \
    -v bx="$B_NEW_EXEC" -v bp="$B_PERMISSION" -v bg="$B_GATE" -v bdl="$B_DELETED" \
    -v crit="$T/crit" -v summ="$T/summary" -v perm="$T/perm" -v lens="$T/lens" '
  function kind(p,   b) {
    b = p; sub(/.*\//, "", b)
    if (p ~ /\.(md|txt|rst)$/ || p ~ /^docs\//) return "docs"
    if (p ~ /(^|\/)(tests?|spec|__tests__)\// || b ~ /(_test\.|\.test\.|\.spec\.|^test_)/) return "test"
    if (b ~ /\.(json|ya?ml|toml|ini|cfg|conf|env)$/ || b ~ /^Dockerfile/) return "config"
    return "code"
  }
  function weight(p,   i) { for (i=1; i<=nc; i++) if (p ~ cr[i]) { iscrit[p]=1; return wcr }
    k = kind(p); return (k=="docs") ? wd : (k=="test") ? wt : (k=="config") ? wcf : wco }
  function gate(p) { return (p ~ /^\.github\/workflows\// || p ~ /^\.gitlab-ci\.yml$/ || p ~ /^\.circleci\// || p ~ /(^|\/)Jenkinsfile$/ \
    || p ~ /^\.husky\// || p ~ /^\.githooks\// || p ~ /^\.pre-commit-config\.ya?ml$/ || p ~ /^\.claude\/hooks\// \
    || p ~ /^\.claude\/settings(\.local)?\.json$/ || p ~ /^\.claude\/critical-paths\.txt$/ || p ~ /(^|\/)ship\.env$/) }
  BEGIN {
    while ((getline l < crit) > 0) cr[++nc] = l
    while ((getline l < perm) > 0) pm[l] = 1
    while ((getline l < summ) > 0) {
      if (l ~ /^ create mode 100755 /) { p=l; sub(/^ create mode 100755 /, "", p); newx[p]=1 }
      else if (l ~ /^ delete mode /) { p=l; sub(/^ delete mode [0-7]+ /, "", p); del[p]=1 }
      else if (l ~ /^ mode change /) { p=l; sub(/^ mode change [0-7]+ => [0-7]+ /, "", p); pm[p]=1 }
    }
  }
  { a = ($1 == "-") ? 0 : $1; d = ($2 == "-") ? 0 : $2; p = $3
    s = (a + d) * weight(p)
    if (p in newx) s += bx
    if (p in pm) s += bp
    if (gate(p)) s += bg
    if (p in del) s += bdl
    sc[p] = s; tot += s; nf++ }
  END {
    while ((getline l < lens) > 0) {
      if (l == "") continue
      split(l, x, "\t"); L = x[1]; p = x[2]
      if (!(L in seen)) { seen[L]=1; order[++no]=L }
      if ((L SUBSEP p) in done) continue
      done[L, p]=1
      if (p in sc) { ls[L] += sc[p]; lf[L]++; if (p in iscrit) lc[L]=1 }
    }
    for (i=1; i<=no; i++) { L=order[i]; printf "SCORE %s %d files=%d critical=%d\n", L, int(ls[L] + 0.5), lf[L], lc[L] + 0 }
    printf "TOTAL %d files=%d\n", int(tot + 0.5), nf
    print "SCORE-RESULT PASS"
  }' "$T/numstat"
