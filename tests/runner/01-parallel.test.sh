#!/usr/bin/env bash
# tests/run.sh: test files run T_JOBS at a time, output stays in file order, and every failure shape is a red.
# Runs a copy of the real runner over a fixture repository of small test files (never over this repository: that
# would recurse into this file).
. "$(dirname "$0")/../lib.sh"

R="$T_TMP/repo"; mkdir -p "$R/tests" && cd "$R" && git init -q -b main . || exit 2
cp "$T_ROOT/tests/run.sh" tests/run.sh || exit 2
fx() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "tests/$1.test.sh"; }

# Three green files; the first is the slowest, so a parallel run finishes them out of order.
fx a-slow 'sleep 1; echo "out a"'
fx b-fast 'echo "out b"'
fx c-fast 'echo "out c"'

for j in 1 4; do
  T_JOBS=$j run bash tests/run.sh
  expect 0 '^ALL GREEN \(3 test files\)$' "T_JOBS=$j: three green files are green"
  check "T_JOBS=$j: output is in file order, each file's lines under its header" \
    sh -c 'printf "%s\n" "$1" | grep -E "^(-- |out )" | tr "\n" "|" | grep -qx -- "-- tests/a-slow.test.sh|out a|-- tests/b-fast.test.sh|out b|-- tests/c-fast.test.sh|out c|"' _ "$OUT"
done

# T_JOBS=4 runs four files at once. Proven by a rendezvous, not a stopwatch (wall time varies with the machine's
# load): four files each leave a marker, then wait (up to 30 s) until all four markers exist, and print "met" only
# if they did; otherwise "alone", and the file fails. Serially the first of them would wait alone. Each wait ends as
# soon as the last one arrives, so a parallel run does not get slower. xargs -P refills a slot as soon as a job ends
# (GNU and BSD), so the three short files ahead of them free their slots within about a second.
OV="$T_TMP/overlap"; mkdir -p "$OV" || exit 2
for x in d e f g; do
  fx "$x-meet" "touch '$OV/$x'; i=0
while [ \$i -lt 300 ] && ! { [ -e '$OV/d' ] && [ -e '$OV/e' ] && [ -e '$OV/f' ] && [ -e '$OV/g' ]; }; do sleep 0.1; i=\$((i + 1)); done
if [ \$i -lt 300 ]; then echo 'out $x met'; else echo 'out $x alone'; exit 1; fi"
done
T_JOBS=4 run bash tests/run.sh
expect 0 '^ALL GREEN \(7 test files\)$' "T_JOBS=4: seven green files are green"
for x in d e f g; do
  expect_out "^out $x met\$" "T_JOBS=4: $x-meet ran while the other three were running (four at once)"
done
rm -f tests/?-meet.test.sh

# stderr is kept with its file, in order.
fx b-fast 'echo "out b"; echo "err b" >&2'
T_JOBS=4 run bash tests/run.sh
check "stderr is captured under its file's header, in order" \
  sh -c 'printf "%s\n" "$1" | grep -E "^(-- |out |err )" | tr "\n" "|" | grep -qx -- "-- tests/a-slow.test.sh|out a|-- tests/b-fast.test.sh|out b|err b|-- tests/c-fast.test.sh|out c|"' _ "$OUT"
fx b-fast 'echo "out b"'

# A test file reading stdin gets end of input, never the terminal.
fx f-stdin 'read -r x; echo "read rc=$?"'
T_JOBS=4 run bash tests/run.sh f-stdin
expect_out '^read rc=1$' "a test file reading stdin gets end of input"
rm -f tests/f-stdin.test.sh

# A failing file is red, in both modes, and the files after it still run.
fx b-fast 'echo "out b"; exit 1'
for j in 1 4; do
  T_JOBS=$j run bash tests/run.sh
  expect 1 '^RED$' "T_JOBS=$j: a failing file makes the run red"
  expect_out '^out c$' "T_JOBS=$j: the file after the failing one still ran"
  expect_out '^  FAIL  tests/b-fast\.test\.sh exited 1$' "T_JOBS=$j: and the failing file is named"
done
fx b-fast 'echo "out b"'

# A file whose runner process dies (no exit status written) is red and named.
fx b-fast 'kill -9 "$PPID"; sleep 1'
for j in 1 4; do
  T_JOBS=$j run bash tests/run.sh
  expect 1 '^RED$' "T_JOBS=$j: a killed file makes the run red"
  expect_out '^  FAIL  tests/b-fast\.test\.sh did not finish' "T_JOBS=$j: and is reported as not finished"
  # xargs stops at a command killed by a signal; the runner keeps that inside the job, so the others still finish.
  expect_out '^out a$' "T_JOBS=$j: the slow file running beside it still finished and printed"
  expect_out '^out c$' "T_JOBS=$j: the file after it still ran"
  refute_out 'a-slow\.test\.sh did not finish|c-fast\.test\.sh did not finish' "T_JOBS=$j: only the killed file is reported unfinished"
done
fx b-fast 'echo "out b"'

# A filter that matches nothing is red; a filter that matches runs only those files.
run bash tests/run.sh no-such-file
expect 1 '^RED$' "a filter matching no file is red"
expect_out "no test file matched 'no-such-file'" "and says so"
run bash tests/run.sh c-fast
expect 0 '^ALL GREEN \(1 test files\)$' "a filter runs only the matching file"
refute_out '^out a$|^-- tests/a-slow' "and skips the others"

# The job count: an explicit T_JOBS is used as given; unset or not a positive number means the CPU count, at most 8.
cpus="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)"; [ "$cpus" -le 8 ] || cpus=8
T_JOBS=12 run bash tests/run.sh
expect 0 '^ALL GREEN \(3 test files\)$' "T_JOBS=12 is green"
expect_out '^== tests \(jobs=12\)$' "an explicit T_JOBS above 8 is used as given"
for bad in '' abc 0 -3; do
  T_JOBS=$bad run bash tests/run.sh
  expect 0 '^ALL GREEN \(3 test files\)$' "T_JOBS='$bad' is green"
  expect_out "^== tests \\(jobs=$cpus\\)\$" "T_JOBS='$bad' falls back to the CPU count, at most 8 ($cpus)"
done

# A file name with a space or a quote runs like any other (only line numbers pass through xargs, which would split
# or unquote a name).
fx "g sp'q" 'echo "out g"'
T_JOBS=4 run bash tests/run.sh
expect 0 '^ALL GREEN \(4 test files\)$' "a file name with a space and a quote is run"
expect_out '^out g$' "and its output is printed"
rm -f tests/g*.test.sh

# HUP or TERM to the runner alone stops the jobs it started (they run in their own process group).
fx h-hang "echo \$\$ > '$T_TMP/h.started'; sleep 30"
for sig in TERM HUP; do
  rm -f "$T_TMP/h.started"
  T_JOBS=4 bash tests/run.sh h-hang > "$T_TMP/term.out" 2>&1 &
  rp=$!
  i=0; while [ ! -s "$T_TMP/h.started" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  check "$sig: the hanging job started" test -s "$T_TMP/h.started"
  kill -"$sig" "$rp"; wait "$rp"; RC=$?; OUT="$(cat "$T_TMP/term.out")"
  expect_rc 130 "$sig to the runner stops it with 130"
  hp="$(cat "$T_TMP/h.started")"
  i=0; while kill -0 "$hp" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  check "$sig: and the job it started is no longer running" sh -c '! kill -0 "$1" 2>/dev/null' _ "$hp"
done
rm -f tests/h-hang.test.sh

t_done
