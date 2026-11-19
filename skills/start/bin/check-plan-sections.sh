#!/usr/bin/env bash
# check-plan-sections.sh <plan-file> [--bug] [--feature] [--no-tracker]   (start skill, Step 7)
# Fails CLOSED when the plan lacks a section a later step depends on. The template is templates/plan.md; a model that
# writes the plan "from memory" drops sections silently, and this is the detection.
#
# Always required (once each, outside code fences; a heading may carry a trailing " (note)"):
#   ## Root Cause, ## Fix, ## Implementation Steps, ### Data prerequisites, ## PRs, ## Testing,
#   ### Simplest version considered, ## Risks & Adjacencies, ## Out of Scope, ## Close-out
# Ticket type (the Step 2 classification):
#   --bug        requires ### Why wasn't this caught?, ### Prevention, ### Bug class & guard
#   --feature    requires ### E2E Test Plan
#   neither      requires EITHER the whole bug set OR the feature section
# Content later steps read (review-plan's work-unit audit, review-code's close-out and recurrence checks):
#   ## PRs states the count on a line `PRs: <N>`; ## Close-out has a bare `- Closes #<N>` / `- Refs #<N>` line (with
#   --no-tracker: a `- Done at merge: <task>` line); ### Data prerequisites is not empty; a ## Recurrence verdict
#   section carries a bare `Recurrence-Verdict: #<N> <DOWN|FLAT|UP> — <mechanism>` line; no template placeholder is
#   left unfilled.
#
# Exit: 0 every check passed; 3 one or more problems (each printed as `check-plan-sections: <KIND> …`);
#       2 usage; 4 the plan file is missing or unreadable. Anything else is a bug in this script or its environment.
set -euo pipefail

usage() { echo "usage: check-plan-sections.sh <plan-file> [--bug] [--feature] [--no-tracker]" >&2; exit 2; }
PLAN=""
WANT_BUG=0
WANT_FEATURE=0
NO_TRACKER=0
for a in "$@"; do
  case "$a" in
    --bug) WANT_BUG=1 ;;
    --feature) WANT_FEATURE=1 ;;
    --no-tracker) NO_TRACKER=1 ;;
    -*) usage ;;
    *) [ -z "$PLAN" ] || usage; PLAN=$a ;;
  esac
done
[ -n "$PLAN" ] || usage
if [ ! -f "$PLAN" ] || [ ! -r "$PLAN" ]; then
  echo "check-plan-sections: HALT — plan file '$PLAN' is missing or unreadable" >&2
  exit 4
fi

# The plan outside code fences, CR and trailing whitespace stripped. A fenced `## PRs` example is not a section.
BODY=$(awk '
  { sub(/[ \t\r]+$/, "") }
  /^```/ || /^~~~/ { infence = !infence; next }
  !infence { print }
' "$PLAN")

PROBLEMS=0
problem() {
  echo "check-plan-sections: $*"
  PROBLEMS=$((PROBLEMS + 1))
}

# count_heading <heading> -> how many lines equal it or start with "<heading> (".
count_heading() {
  printf '%s\n' "$BODY" | awk -v h="$1" '$0 == h || index($0, h " (") == 1 { n++ } END { print n + 0 }'
}

# section_body <heading> -> the lines under it until the next heading of the same or a higher level.
section_body() {
  printf '%s\n' "$BODY" | awk -v h="$1" '
    BEGIN { lv = 0; while (substr(h, lv + 1, 1) == "#") lv++ }
    {
      if ($0 == h || index($0, h " (") == 1) { on = 1; next }
      if (on && substr($0, 1, 1) == "#") {
        n = 0; while (substr($0, n + 1, 1) == "#") n++
        if (substr($0, n + 1, 1) == " " && n <= lv) { on = 0 }
      }
      if (on) print
    }'
}

# has_line <ERE> -> 0 when any stdin line matches. Reads ALL of stdin (grep -c, never grep -q): under pipefail an
# early-exiting reader would SIGPIPE the producer and invert the verdict.
has_line() {
  [ "$(grep -Ec -- "$1" || true)" -gt 0 ]
}

# require <heading> -> 0 when present exactly once; prints MISSING / DUPLICATE otherwise.
require() {
  local n
  n=$(count_heading "$1")
  if [ "$n" -eq 0 ]; then
    problem "MISSING section: $1"
    return 1
  elif [ "$n" -gt 1 ]; then
    problem "DUPLICATE section ($n times): $1"
    return 1
  fi
  return 0
}

# have_all <heading>... -> 0 when every heading appears exactly once (silent).
have_all() {
  local h
  for h in "$@"; do
    [ "$(count_heading "$h")" -eq 1 ] || return 1
  done
  return 0
}

FIRST=$(printf '%s\n' "$BODY" | awk 'NF && !seen { print; seen = 1 }')
if [ "$NO_TRACKER" -eq 1 ]; then
  case "$FIRST" in
    '# '?*) ;;
    *) problem "MISSING title: the plan must start with '# <the task in words>' (first line is: ${FIRST:-<empty>})" ;;
  esac
else
  case "$FIRST" in
    '# #'[0-9]*) ;;
    *) problem "MISSING title: the plan must start with '# #<N> — <Ticket Title>' (first line is: ${FIRST:-<empty>})" ;;
  esac
fi

for h in "## Root Cause" "## Fix" "## Implementation Steps" "### Data prerequisites" "## PRs" "## Testing" \
  "### Simplest version considered" "## Risks & Adjacencies" "## Out of Scope" "## Close-out"; do
  require "$h" || true
done

BUG_SET=("### Why wasn't this caught?" "### Prevention" "### Bug class & guard")
FEATURE_SET=("### E2E Test Plan")
if [ "$WANT_BUG" -eq 1 ] || [ "$WANT_FEATURE" -eq 1 ]; then
  if [ "$WANT_BUG" -eq 1 ]; then
    for h in "${BUG_SET[@]}"; do require "$h" || true; done
  fi
  if [ "$WANT_FEATURE" -eq 1 ]; then
    for h in "${FEATURE_SET[@]}"; do require "$h" || true; done
  fi
elif have_all "${BUG_SET[@]}" || have_all "${FEATURE_SET[@]}"; then
  :
else
  problem "MISSING ticket-type sections: need the BUG set (${BUG_SET[0]} / ${BUG_SET[1]} / ${BUG_SET[2]}) or the FEATURE section (${FEATURE_SET[0]}), each once"
fi

# --- content later steps read ---
if [ "$(count_heading '## PRs')" -eq 1 ]; then
  if ! section_body '## PRs' | has_line '^PRs: [0-9]+'; then
    problem "PRS-COUNT: '## PRs' has no line starting 'PRs: <N>'"
  fi
fi
if [ "$(count_heading '## Close-out')" -eq 1 ]; then
  if [ "$NO_TRACKER" -eq 1 ]; then
    if ! section_body '## Close-out' | has_line '^- Done at merge: [^<[:space:]]'; then
      problem "CLOSE-OUT: '## Close-out' has no '- Done at merge: <the task>' line"
    fi
  elif ! section_body '## Close-out' | has_line '^- (Closes|Refs) #[0-9]+'; then
    problem "CLOSE-OUT: '## Close-out' has no bare '- Closes #<N>' (or '- Refs #<N>') line at the start of a line"
  fi
fi
if [ "$(count_heading '### Data prerequisites')" -eq 1 ]; then
  if [ -z "$(section_body '### Data prerequisites' | tr -d '[:space:]')" ]; then
    problem "DATA-PREREQ: '### Data prerequisites' is empty (write the literal 'None' or one bullet per prerequisite)"
  fi
fi
if [ "$(count_heading '## Recurrence verdict')" -ge 1 ]; then
  if ! section_body '## Recurrence verdict' | has_line '^Recurrence-Verdict: #[0-9]+ (DOWN|FLAT|UP) — [^[:space:]<]'; then
    problem "VERDICT: '## Recurrence verdict' has no bare line 'Recurrence-Verdict: #<N> <DOWN|FLAT|UP> — <mechanism>' (no backticks, bullet or indent; em dash)"
  fi
fi

# --- unfilled template placeholders (outside code fences) ---
if printf '%s\n' "$BODY" | has_line '^### Phase [0-9]+: <name>|^# #<N> |^- (Closes|Refs) #<[A-Z]>|^PRs: 1 — this PR covers #<N>'; then
  problem "UNFILLED: a template placeholder is still in the plan ('### Phase N: <name>', '# #<N> …', 'PRs: 1 — … #<N>' or '- Closes #<N>')"
fi

if [ "$PROBLEMS" -gt 0 ]; then
  echo "check-plan-sections: FAIL ($PROBLEMS problem(s)) — $PLAN"
  exit 3
fi
echo "check-plan-sections: PASS — $PLAN"
