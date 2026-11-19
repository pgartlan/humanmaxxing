# Sentinel contracts — the exact writer side

Two files, both under `SHIP_STATE`, both written in Step 14 after every source-editing step. A companion ship skill is the reader. **Writer and reader must agree byte for byte**; a drift looks like "the cache never hits" and silently doubles every ship's wall time, or worse, a reader that accepts a stale green.

## The content fingerprint (shared by both sentinels)

Inputs: the diff's changed paths from merge-base to **working tree** (committed, staged, unstaged, and untracked), each with its status and the sha256 of its current content. Deleted files hash as the literal `DELETED`. An untracked file is recorded with status `A`, exactly as `git diff` reports it once it is staged or committed, so committing the reviewed bytes does not change the fingerprint (a review runs before the ship commits; a status of its own for untracked files made every sentinel stale at the commit). Renames are expanded to a delete plus an add (`--no-renames`) so every record has exactly three fields. Records are sorted bytewise and hashed together.

Two filters, both part of the contract. The **tree** fingerprint (review sentinel line 1, EXEMPT form line 3) EXCLUDES paths matching `DOCS_ALLOWLIST` (an ERE over the path; worked default `(\.md$|\.txt$|^docs/|(^|/)CHANGELOG)`) except those matching `DOCS_KEEP_BOUND` (an ERE naming docs that a check or test reads as input: a baseline, a registry, an invariants file; empty when none). Why: a ship's documentation subagent writes new files after the review ran; without the exclusion every ship would fail its merge gate with "the tree changed since the review". A file that cannot change runtime behavior is not a review input; one a check reads IS, hence the keep list. The **critical** fingerprint (E2E hash form line 1) INCLUDES only paths matching `CRITICAL_GLOBS` (conversion below).

```bash
# fingerprint <base-ref> [<include-ere-file>] [<exclude-ere>] [<keep-ere>]   — prints 64 hex chars on stdout, or prints SENTINEL-ERROR and exits 1
#   tree fingerprint:     fingerprint origin/<base> "" "$DOCS_ALLOWLIST" "$DOCS_KEEP_BOUND"
#   critical fingerprint: fingerprint origin/<base> <file made by the glob conversion below>
# Every producer is checked on its own and records are built in a file: NO error path can reach the final hash, and a failing
# git never hides behind a successful sort (no pipefail needed). Never collapse this into one pipeline.
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -c1-64; }   # GNU or BSD, same 64 hex
BASE=$(git merge-base HEAD "$1") || { echo "SENTINEL-ERROR: merge-base unresolved"; exit 1; }
RAW=$(mktemp "${TMPDIR:-/tmp}/fp.XXXXXX") && LIST=$(mktemp "${TMPDIR:-/tmp}/fp.XXXXXX") && RECORDS=$(mktemp "${TMPDIR:-/tmp}/fp.XXXXXX") || { echo "SENTINEL-ERROR: mktemp failed"; exit 1; }
git -c core.quotePath=false diff --name-status --no-renames "$BASE" > "$RAW" || { echo "SENTINEL-ERROR: diff unreadable"; exit 1; }
git -c core.quotePath=false ls-files --others --exclude-standard > "$RAW.u" || { echo "SENTINEL-ERROR: untracked list unreadable"; exit 1; }
sed "s/^/A$(printf '\t')/" "$RAW.u" >> "$RAW" || { echo "SENTINEL-ERROR: untracked list unreadable"; exit 1; }
LC_ALL=C sort -u "$RAW" > "$LIST" || { echo "SENTINEL-ERROR: sort failed"; exit 1; }   # literal tab: BSD sed has no \t
if [ -n "${2:-}" ]; then grep -E -f "$2" "$LIST" > "$LIST.f"; rc=$?; [ "$rc" -le 1 ] || { echo "SENTINEL-ERROR: filter invalid"; exit 1; }; mv -f "$LIST.f" "$LIST"; fi
if [ -n "${3:-}" ]; then   # exclude by PATH field; ENVIRON, not awk -v, which would eat the backslashes in `\.md$`
  FP_EXC="$3" FP_KEEP="${4:-}" awk -F"$(printf '\t')" '$2 !~ ENVIRON["FP_EXC"] || (ENVIRON["FP_KEEP"] != "" && $2 ~ ENVIRON["FP_KEEP"])' "$LIST" > "$LIST.f" || { echo "SENTINEL-ERROR: exclude invalid"; exit 1; }
  mv -f "$LIST.f" "$LIST"
fi
: > "$RECORDS"
while IFS="$(printf '\t')" read -r status path; do
  [ -n "$path" ] || { echo "SENTINEL-ERROR: empty path in diff"; exit 1; }
  if [ -f "$path" ]; then h=$(sha256 < "$path"); case "$h" in *[!0-9a-f]*|'') echo "SENTINEL-ERROR: unreadable $path"; exit 1 ;; esac
  else h=DELETED; fi
  printf '%s\t%s\t%s\n' "$status" "$path" "$h" >> "$RECORDS"
done < "$LIST"
h=$(sha256 < "$RECORDS"); case "$h" in *[!0-9a-f]*|'') echo "SENTINEL-ERROR: hash failed"; exit 1 ;; esac
rm -f "$RAW" "$RAW.u" "$LIST" "$RECORDS"; printf '%s\n' "$h"
```

- `$1` is `origin/BASE_BRANCH`. `$2`, when given, is a file of extended-regex patterns (one per line) built from `CRITICAL_GLOBS` by the conversion below; only matching paths are hashed.
- An unresolvable merge-base, an unreadable file, or an empty path is `SENTINEL-ERROR`, never a hash. **Never substitute a default.** An empty changed set (nothing matched) hashes the empty input — that is a legitimate, stable value and the reader treats it like any other. A `CRITICAL_GLOBS` file that is configured but missing is an error, never "no globs": only an explicitly empty slot means every diff is exempt.
- Wrap the fence in a function or a script of your own; the shape above is the contract, the packaging is yours. **If the companion ship skill is installed, call its reader instead of re-implementing:** `bash .claude/skills/ship/bin/ship-sentinel.sh --contract=<its contract> fingerprint [--critical]` prints the same hash (its `bin/ship-lib.sh` is the reference implementation of this fence and of the glob conversion below). One implementation, zero drift.

## Glob filter (the `$2` file) — part of the contract

`CRITICAL_GLOBS` is one glob per line (the same file ship reads as `CRITICAL_GLOBS_FILE`). Writer and reader convert it to the regex file identically, or the critical-path hashes never match. The conversion, applied per line after dropping blank lines and `#` comments and trimming whitespace: escape every regex metacharacter (`. [ ] ( ) + { } | ^ $ \`), then `**/` → `(.*/)?`, `**` → `.*`, `*` → `[^/]*`, `?` → `[^/]`, and anchor the result to match a `<status><TAB><path>` line: `^[^<TAB>]*<TAB>(<converted>)$` with a literal tab character. As a sed program (`tab` holds a literal tab):

```bash
grep -v -E '^[[:space:]]*(#|$)' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
  -e 's/[].[()+{}|^$\\]/\\&/g' \
  -e 's#\*\*/#__DSTAR_SLASH__#g' -e 's/\*\*/__DSTAR__/g' -e 's#\*#[^/]*#g' -e 's#?#[^/]#g' \
  -e 's#__DSTAR_SLASH__#(.*/)?#g' -e 's/__DSTAR__/.*/g' \
  -e "s#^#^[^${tab}]*${tab}(#" -e 's#$#)$#'
```

So `app/api/**` becomes `^[^\t]*\t(app/api/.*)$` and `lib/**/*.ts` becomes `^[^\t]*\t(lib/(.*/)?[^/]*\.ts)$`. An empty globs file converts to an empty regex file, which matches nothing: every diff is E2E-exempt (Step 10 says so in bold) and the E2E sentinel takes the EXEMPT form.

## `SHIP_STATE/review-code-ran` — "a full review ran on exactly this tree"

```
<tree fingerprint (all changed paths minus DOCS_ALLOWLIST, plus DOCS_KEEP_BOUND)>   line 1
<epoch seconds>                            line 2
<git rev-parse HEAD>                       line 3
```

Reader rule (ship): valid only if line 1 equals its own fresh tree fingerprint AND line 2 is under the TTL (worked default 12 h; an expired TTL over a matching fingerprint is a re-attestation prompt, not a code problem), checked independently; a line-2 epoch in the future is MALFORMED. Line 3 is informational (which commit the review saw); a reader must not use it as the freshness test, because a rebase changes HEAD without changing content.

## `SHIP_STATE/real-e2e-shipgate-passed` — "real E2E ran green against this diff's critical paths"

Non-exempt diff:
```
<fingerprint over paths matching CRITICAL_GLOBS>   line 1
<epoch seconds>                                     line 2
```
Entirely exempt diff (also the ONLY form when `CRITICAL_GLOBS` is empty: a hash form over an empty critical set would validate any tree):
```
EXEMPT: <category> — <reason>                       line 1
<epoch seconds>                                     line 2
<tree fingerprint>                                  line 3
```

Reader rule: a hash sentinel is valid only if line 1 matches the reader's own computation over the current tree's critical paths AND age is under the TTL (worked default 12 h). An EXEMPT sentinel is valid only if line 3 matches the reader's tree fingerprint (so a docs-only run's exemption can never be inherited by a later code diff) AND age is under the TTL. `SENTINEL-ERROR` on any line → the reader HALTs.

## Writing

Write to a temp file in `SHIP_STATE`, then `mv -f` over the target: a reader never sees a half-written sentinel. If the fingerprint fence printed `SENTINEL-ERROR`, write nothing, print the error, and HALT the skill — a garbage sentinel surfaces later as a confusing HALT in ship; no sentinel surfaces now as a clear one.

## Expected markers — the one matching rule

`run.env` holds `EXPECT=` as a comma-separated list of entries. An entry is `<name>` (peer and isolated modes) or `<name>:R1` / `<name>:R2` (mediated mode: domain and test reviewers get both; the zero-context reviewer gets `:R1` only, since it does not take part in round 2). An entry is satisfied when `SCRATCH_DIR/findings/<name>.md` exists and its **last non-empty line** is exactly

```
<!-- REVIEW-COMPLETE <name> <RUN_ID> -->            for an entry with no round
<!-- REVIEW-COMPLETE <name> <RUN_ID> R2 -->         for an entry <name>:R2 (R1 likewise)
```

An `<name>:R1` entry is also satisfied by `SCRATCH_DIR/findings/round1/<name>.md` (mediated mode copies round 1 there before round 2 rewrites the file). The watcher and the Step 14 hold both use this rule and nothing looser (not "file exists", not "contains the string somewhere"), through one implementation: `bin/wait-for-findings.sh` (`--check` looks once; without it, it waits).

## Hold conditions (nothing is written if any holds)

- A reviewer in the expected list (`run.env`) has no completion marker, checked by `bin/wait-for-findings.sh --check --run-env <SCRATCH_DIR>/run.env --dir <SCRATCH_DIR>/findings` in the same call that writes the sentinel. This includes a review that continued without a reviewer after the Step 5 failure path. The ship reader does not re-check markers (it checks the fingerprint), so this command is the only enforcement of the hold.
- A `[UNVERIFIED:external-tool]` finding is still open and the user has not given a spot-check decision on it.
- Step 10b is not green (non-exempt diff) — the E2E sentinel is withheld; the review sentinel may still be written.
