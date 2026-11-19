#!/usr/bin/env bash
# tests/run.sh — the whole local gate: syntax, lint, then every tests/**/*.test.sh. Exit 0 only when all are green.
#   bash tests/run.sh            everything
#   bash tests/run.sh sync       only test files whose path contains "sync" (static checks still run)
#   T_VERBOSE=1 bash tests/run.sh   print every passing assertion too
#   T_JOBS=1 bash tests/run.sh      run the test files one at a time (default: as many at once as CPUs, at most 8)
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
cd "$ROOT" || exit 2
FILTER="${1:-}"; RED=0

SCRIPTS="$(git ls-files --cached --others --exclude-standard -- '*.sh')" || { echo "run: git ls-files failed"; exit 2; }
[ -n "$SCRIPTS" ] || { echo "run: no shell scripts found (wrong directory?)"; exit 2; }

echo "== bash -n"
while IFS= read -r f; do
  bash -n "$f" || { echo "  FAIL  syntax: $f"; RED=1; }
done <<EOF_LIST
$SCRIPTS
EOF_LIST

echo "== shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  if ! printf '%s\n' "$SCRIPTS" | tr '\n' '\0' | xargs -0 shellcheck -S warning; then echo "  FAIL  shellcheck"; RED=1; fi
else
  echo "  FAIL  shellcheck is not installed (a missing linter is a red, not a skip)"; RED=1
fi

# Test files are independent (each makes its own temporary folder), so they run in parallel: T_JOBS at a time
# (default: the CPU count, at most 8; T_JOBS=1 runs them one by one). Each file's output is kept and printed in
# file order once all have finished, so the log reads the same as a serial run.
case "${T_JOBS:-}" in
  ''|*[!0-9]*|0) JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)"   # unset or not a positive count
                 case "$JOBS" in ''|*[!0-9]*|0) JOBS=4 ;; esac
                 [ "$JOBS" -le 8 ] || JOBS=8 ;;
  *)             JOBS="$T_JOBS" ;;
esac
echo "== tests (jobs=$JOBS)"
OUTDIR="$(mktemp -d "${TMPDIR:-/tmp}/runlogs.XXXXXX")" || { echo "run: mktemp failed"; exit 2; }
trap 'rm -rf "$OUTDIR"' EXIT
LIST="$OUTDIR/list"
find tests -name '*.test.sh' | LC_ALL=C sort | while IFS= read -r t; do
  case "$t" in *"$FILTER"*) printf '%s\n' "$t" ;; esac
done > "$LIST"
FOUND="$(grep -c . "$LIST")" || FOUND=0
if [ "$FOUND" -gt 0 ]; then
  # Job <n> runs line <n> of the list and writes <n>.log, then <n>.rc; a missing .rc means it never finished (a red).
  # Only the line numbers pass through xargs, so no file name is ever split or unquoted by it. Each job runs in a
  # subshell and the xargs command always exits 0: xargs (GNU and BSD) stops at once, without waiting for the jobs
  # still running, when a command it started dies by a signal, so a death must stay inside the job.
  # xargs runs in its own process group, so a HUP, INT or TERM to this runner also stops every job it started (the
  # trap is set before the fork, leaving only the instant before XPID is recorded; CONT wakes a job stopped by
  # reading the terminal).
  awk '{print NR}' "$LIST" > "$OUTDIR/idx"
  XPID=""
  trap '[ -z "$XPID" ] || { kill -TERM -- "-$XPID"; kill -CONT -- "-$XPID"; } 2>/dev/null; exit 130' HUP INT TERM
  set -m
  xargs -P "$JOBS" -n 1 bash -c \
    '( bash "$(sed -n "${2}p" "$1/list")" > "$1/$2.log" 2>&1 < /dev/null; echo $? > "$1/$2.rc" ); exit 0' \
    _ "$OUTDIR" < "$OUTDIR/idx" &
  XPID=$!
  set +m
  wait "$XPID"
  trap - HUP INT TERM
  n=0
  while IFS= read -r t; do
    n=$((n + 1)); echo "-- $t"
    cat "$OUTDIR/$n.log" 2>/dev/null
    rc="$(cat "$OUTDIR/$n.rc" 2>/dev/null)"
    if [ -z "$rc" ]; then echo "  FAIL  $t did not finish (no exit status)"; RED=1
    elif [ "$rc" != 0 ]; then echo "  FAIL  $t exited $rc"; RED=1; fi
  done < "$LIST"
else
  echo "  FAIL  no test file matched '${FILTER}'"; RED=1
fi

if [ "$RED" -eq 0 ]; then echo "ALL GREEN ($FOUND test files)"; else echo "RED"; fi
exit "$RED"
