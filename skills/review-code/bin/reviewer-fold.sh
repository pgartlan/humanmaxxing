#!/usr/bin/env bash
# reviewer-fold.sh — decide how many reviewer agents one review gets and which lenses each carries. MAX_REVIEWERS is a
# HARD TOTAL of agents: every lens reviewer, the general reviewer, the zero-context reader and any intent-fidelity agent
# count; mechanical checks (lint, leak scans) do not, and the second pass reuses the same agents. Read by review-code
# Step 2 and review-plan Step 3. Reads its arguments, stdin and (with --agents-dir) the agent files; writes only into
# --out-dir.
#
#   reviewer-fold.sh --max <n> --total-score <n> [--fixed <n>] [--small <n>] [--step <n>] [--min-score <n>]
#                    [--budget <calls>] [--agents-dir <dir> [--agents-dir <dir>] --out-dir <dir>] < lenses
#
# stdin: one matched lens per line, tab-separated: <agent> <score> <critical 0|1> <domain> <kind> [<check>]
#   score     from lens-score.sh (critical 1 = a file of it is on a critical path)
#   domain    a short word for the area (api, data, frontend, infra, …): lenses of one domain share an agent first
#   kind      test | security | other. The test lens, and the security lens when any lens is critical, are protected:
#             never dropped, ranked first, and they COUNT toward the total (other lenses fold into them)
#   check     result of the lens's mechanical check, run before this script: none (default) | clean | found
# --fixed     agents that are not lens reviewers but count: the zero-context reader (1, the default) plus an intent-
#             fidelity agent when one runs
# --total-score  lens-score.sh's TOTAL. The change earns 1 lens reviewer below --small (default 60), 2 at --small, and
#             one more per further --step (default 150) points; never more than --max minus --fixed
# --min-score a lens below it (default 40) never runs solo, unless protected or its check found something; below it with
#             a clean check, it gets no agent at all (the check covered it)
#
# Order: rank (protected first, then score, then input order) → the top lenses that may run solo take the earned
# places → every other lens folds into the agent of its domain, else the one with the lowest load (fewest profiles,
# then lowest score). No lens may run solo → the general reviewer takes the one place. A hybrid agent's budget is
# budget * (1 + (profiles - 1) / 2), rounded up.
#
# Output — the decision table, printed for the user:
#   LENS <agent> score=<n> solo
#   LENS <agent> score=<n> folded into <host> (by domain|by load)[, below min score]
#   LENS <agent> score=<n> skipped (its check ran clean, below min score)
#   RUN <host> budget=<n> profiles=<a>[,<b>…]
#   AGENTS total=<n> reviewers=<n> fixed=<n> earned=<n> max=<n>
#   SECOND-PASS only-on-critical            (below --small: the second pass runs only after a BLOCK)
#   FOLD-RESULT PASS agents=<n> folded=<n> skipped=<n>
# With --agents-dir, each RUN with two or more profiles gets <out-dir>/<host>.hybrid.md: the "acting as both" frame and
# each profile's FULL agent file (<agents-dir>/<agent>.md, the first --agents-dir that has it: give the project's
# folder first, then the user-level one; "general" is review-code's general reviewer, no file).
# Exit: 0 · 2 usage, a malformed line, or a missing agent file (FOLD-RESULT FAIL <reason>).
set -u
die() { [ -z "${2:-}" ] || echo "$2" >&2; echo "FOLD-RESULT FAIL $1"; exit 2; }
num() { case "$2" in ''|*[!0-9]*) die usage "$1 must be a whole number" ;; esac; }
MAX=""; TOTAL=""; FIXED=1; SMALL=60; STEP=150; MINS=40; BUDGET=30; AD=""; AD2=""; OD=""
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || die usage "$1 needs a value"
  case "$1" in
    --max) MAX="$2" ;; --total-score) TOTAL="$2" ;; --fixed) FIXED="$2" ;; --small) SMALL="$2" ;; --step) STEP="$2" ;;
    --min-score) MINS="$2" ;; --budget) BUDGET="$2" ;; --out-dir) OD="$2" ;;
    --agents-dir) if [ -z "$AD" ]; then AD="$2"; elif [ -z "$AD2" ]; then AD2="$2"; else die usage "at most two --agents-dir"; fi ;;
    *) die usage "unknown argument: $1" ;;
  esac
  shift 2
done
for v in "--max:$MAX" "--total-score:$TOTAL" "--fixed:$FIXED" "--small:$SMALL" "--step:$STEP" "--min-score:$MINS" "--budget:$BUDGET"; do
  num "${v%%:*}" "${v#*:}"
done
[ "$STEP" -gt 0 ] && [ "$BUDGET" -gt 0 ] || die usage "--step and --budget must be 1 or more"
[ "$MAX" -gt "$FIXED" ] || die usage "--max $MAX leaves no place for a reviewer beside the $FIXED fixed agent(s)"
{ [ -z "$AD" ] && [ -z "$OD" ]; } || { [ -n "$AD" ] && [ -n "$OD" ]; } || die usage "--agents-dir and --out-dir go together"
[ -z "$AD" ] || [ -d "$AD" ] || die usage "--agents-dir $AD is not a folder"
[ -z "$AD2" ] || [ -d "$AD2" ] || AD2=""   # the user-level folder may not exist: nothing to look in
[ -z "$OD" ] || mkdir -p "$OD" || die usage "cannot create --out-dir $OD"

W="$(mktemp -d "${TMPDIR:-/tmp}/fold.XXXXXX")" || die mktemp-failed "cannot create a temporary folder"
trap 'rm -rf "$W"' EXIT
n=0; anycrit=0; : > "$W/in"
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  n=$((n + 1))
  IFS='	' read -r a s c d k ck extra <<EOF
$line
EOF
  [ -n "$a" ] && [ -n "$d" ] && [ -n "${k:-}" ] && [ -z "${extra:-}" ] || die malformed "line $n: want <agent> <score> <critical> <domain> <kind> [<check>], tab-separated"
  [ "$a" != general ] || die malformed "line $n: 'general' is the general reviewer, not a lens"
  case "$a" in .*|*[!A-Za-z0-9._-]*) die malformed "line $n: an agent name is letters, digits, '.', '_' and '-' only (it names a file)" ;; esac
  case " $(cut -f3 "$W/in" | tr '\n' ' ') " in *" $a "*) die malformed "line $n: agent $a is listed twice" ;; esac
  case "$s" in ''|*[!0-9]*) die malformed "line $n: score must be a whole number" ;; esac
  case "$c" in 0|1) ;; *) die malformed "line $n: critical must be 0 or 1" ;; esac
  case "$k" in test|security|other) ;; *) die malformed "line $n: kind must be test, security or other" ;; esac
  case "${ck:-none}" in none|clean|found) ;; *) die malformed "line $n: check must be none, clean or found" ;; esac
  [ "$c" = 1 ] && anycrit=1
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$s" "$n" "$a" "$d" "$k" "${ck:-none}" >> "$W/in"
done

awk -F'\t' -v ac="$anycrit" 'BEGIN{OFS="\t"} { p = ($5 == "test" || ($5 == "security" && ac == 1)) ? 1 : 0; print p, $0 }' "$W/in" \
  | sort -t'	' -k1,1nr -k2,2nr -k3,3n > "$W/ranked"

awk -F'\t' -v max="$MAX" -v fixed="$FIXED" -v total="$TOTAL" -v small="$SMALL" -v step="$STEP" -v mins="$MINS" -v budget="$BUDGET" '
  { N=NR; prot[N]=$1; sc[N]=$2+0; a[N]=$4; d[N]=$5; k[N]=$6; ck[N]=$7 }
  function host(i,   j, b) {
    for (j=1; j<=G; j++) if (run[j] && j != i && j != G && d[j] == d[i]) { why[i]="by domain"; return j }
    b=0
    for (j=1; j<=G; j++) if (run[j] && j != i && (!b || load[j] < load[b] || (load[j] == load[b] && sum[j] < sum[b]))) b=j
    why[i]="by load"; return b
  }
  END {
    G=N+1; a[G]="general"; sc[G]=0
    earned = (total + 0 < small + 0) ? 1 : 2 + int((total - small) / step)
    places = max - fixed; if (earned < places) places = earned
    used=0
    for (i=1; i<=N; i++) {
      solo_ok = prot[i] || ck[i] == "found" || sc[i] >= mins + 0
      if (!solo_ok && ck[i] == "clean") { skip[i]=1; continue }
      if (solo_ok && used < places) { run[i]=1; used++; load[i]=1; sum[i]=sc[i]; prof[i]=a[i] }
      else if (!solo_ok) below[i]=1
    }
    if (used == 0) { run[G]=1; used=1; load[G]=1; sum[G]=0; prof[G]="general" }
    nf=0; ns=0
    for (i=1; i<=N; i++) if (!run[i] && !skip[i]) {
      h=host(i); into[i]=h; load[h]++; sum[h]+=sc[i]; prof[h]=(prof[h] == "" ? a[i] : prof[h] "," a[i]); nf++
    }
    for (i=1; i<=N; i++) {
      if (run[i]) printf "LENS %s score=%d solo\n", a[i], sc[i]
      else if (skip[i]) { printf "LENS %s score=%d skipped (its check ran clean, below min score)\n", a[i], sc[i]; ns++ }
      else printf "LENS %s score=%d folded into %s (%s)%s\n", a[i], sc[i], a[into[i]], why[i], below[i] ? ", below min score" : ""
    }
    for (i=1; i<=G; i++) if (run[i]) {
      p = load[i] < 1 ? 1 : load[i]
      printf "RUN %s budget=%d profiles=%s\n", a[i], int((budget * (1 + p) + 1) / 2), prof[i]
    }
    printf "AGENTS total=%d reviewers=%d fixed=%d earned=%d max=%d\n", used + fixed, used, fixed, earned, max
    if (total + 0 < small + 0) print "SECOND-PASS only-on-critical"
    printf "FOLD-RESULT PASS agents=%d folded=%d skipped=%d\n", used + fixed, nf, ns
  }' "$W/ranked" > "$W/out"

# Hybrid prompts: the frame, then each profile's full agent file.
if [ -n "$AD" ]; then
  while IFS= read -r l; do
    case "$l" in RUN\ *) ;; *) continue ;; esac
    h="$(printf '%s' "$l" | awk '{print $2}')"; p="${l##*profiles=}"
    case "$p" in *,*) ;; *) continue ;; esac
    case "$p" in *,*,*) names="all of $(printf '%s' "$p" | sed 's/,/, /g')" ;; *) names="both $(printf '%s' "$p" | sed 's/,/ and /')" ;; esac
    {
      echo "You are acting as $names. Each profile below is that agent's full definition: apply each profile's"
      echo "checks to the files its lens matched, as thoroughly as if it ran alone, and label every finding with the"
      echo "profile that produced it: \"[<agent>] ## BLOCK — …\"."
      for g in $(printf '%s' "$p" | tr ',' ' '); do
        echo
        if [ "$g" = general ]; then echo "=== PROFILE general (review-code's general reviewer: the base prompt) ==="; continue; fi
        f="$AD/$g.md"; [ -f "$f" ] || [ -z "$AD2" ] || f="$AD2/$g.md"
        [ -f "$f" ] || { echo "profile-missing $g" > "$W/err"; break; }
        echo "=== PROFILE $g ($f) ==="
        cat "$f"
      done
    } > "$OD/$h.hybrid.md"
    [ ! -f "$W/err" ] || { rm -f "$OD/$h.hybrid.md"; break; }   # never leave a hybrid without its profile
  done < "$W/out"
  [ ! -f "$W/err" ] || die "$(cut -d' ' -f1 "$W/err")" "no agent file for $(cut -d' ' -f2 "$W/err") in $AD${AD2:+ or $AD2}: a lens names an agent that does not exist"
  sed -n 's/^RUN \([^ ]*\) .*profiles=.*,.*/HYBRID \1 '"$(printf '%s' "$OD" | sed 's/[\/&]/\\&/g')"'\/\1.hybrid.md/p' "$W/out" > "$W/hy"
  awk 'FILENAME == ARGV[1] { h[++n]=$0; next } /^FOLD-RESULT/ { for (i=1; i<=n; i++) print h[i] } { print }' "$W/hy" "$W/out"
else
  cat "$W/out"
fi
