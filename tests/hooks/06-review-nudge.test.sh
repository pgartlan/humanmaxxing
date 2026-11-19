#!/usr/bin/env bash
# review-nudge.sh: the once-per-session reminder to run the review-code skill before stopping. It fires only when the
# session wrote a reviewable file, ship's fingerprint says the change is not docs-only, and ship's `verify review` says
# exactly "not covered" (exit 1); warn mode prints, enforce mode holds the stop once; every failure to measure is quiet.
# Mutations this file must catch: drop the once-per-session marker · ignore stop_hook_active · treat a verify exit
# other than 1 as "not covered" · nudge on a docs-only change · emit a decision in warn mode · nudge with no review skill.
. "$(dirname "$0")/../lib.sh"
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || { echo "  SKIP  jq or python3 is required"; t_done; exit $?; }

t_fixture nudge 'DOCS_ALLOWLIST=(\.md$|\.txt$|^docs/|(^|/)CHANGELOG)'
t_hook_install . HOOKS_MODE=enforce
git add -A && git commit -qm hooks && git push -q origin main || exit 2
git checkout -q -b feat || exit 2
ST="$(cd "$(git rev-parse --git-path ship-state)" 2>/dev/null && pwd -P || echo "$HR/.git/ship-state")"
mkdir -p "$ST"

TR="$T_TMP/transcript.jsonl"
tr_write() {  # tr_write <path>... — a transcript whose tool calls write those files
  : > "$TR"; echo '{"type":"user","message":{"role":"user","content":"go"}}' >> "$TR"
  for p in "$@"; do
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"%s"}}]}}\n' "$p" >> "$TR"
  done
}
stop() {  # stop <session> [stop_hook_active] [transcript]
  t_hook review-nudge "{\"session_id\":\"$1\",\"cwd\":\"$HR\",\"transcript_path\":\"${3:-$TR}\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":${2:-false}}"
}

echo x >> lib/u.ts; tr_write "$HR/lib/u.ts"
stop s0; expect_rc 0 "no review-code skill → exit 0"; check "no review-code skill → nothing printed" test -z "$OUT"

mkdir -p .claude/skills/review-code && echo '# review-code' > .claude/skills/review-code/SKILL.md
git add .claude/skills/review-code && git commit -qm review && git push -q origin feat:main && git branch -q -u origin/main || exit 2
echo y >> lib/u.ts

stop s1 true; check "stop_hook_active → nothing printed" test -z "$OUT"
stop s1; expect_rc 0 "code change, no review → exit 0"
expect_out '"decision":"block"' "enforce mode: code change, no review → the stop is held"
expect_out 'review-code skill' "…and the reason names the review-code skill"
if command -v jq >/dev/null 2>&1; then check "…as one valid JSON object" sh -c 'printf "%s" "$1" | jq -e ".decision == \"block\" and (.reason | length > 0)"' _ "$OUT"; fi
stop s1; check "second stop in the same session → nothing (once per session)" test -z "$OUT"

# Warn mode: printed, never held.
sed -i.bak 's/^HOOKS_MODE=.*/HOOKS_MODE=warn/' .claude/hooks/hooks.env && rm -f .claude/hooks/hooks.env.bak
stop s2; expect_rc 0 "warn mode → exit 0"
refute_out '"decision"' "warn mode → never a decision"
expect_out 'warn-only: .*review-code skill' "warn mode → the reminder is printed, prefixed warn-only:"
sed -i.bak 's/^HOOKS_MODE=.*/HOOKS_MODE=enforce/' .claude/hooks/hooks.env && rm -f .claude/hooks/hooks.env.bak

# This session wrote only docs → quiet, though the tree has code changes (another session's).
tr_write "$HR/docs/x.md" "$HR/CHANGELOG.md"
stop s3; check "the session wrote only docs → nothing" test -z "$OUT"
tr_write "/elsewhere/lib/u.ts"
stop s3; check "the session wrote only outside the repository → nothing" test -z "$OUT"
printf '{"type":"user","message":{"role":"user","content":"hi"}}\n' > "$TR"
stop s3; check "the session wrote nothing → nothing" test -z "$OUT"
stop s3 false "$T_TMP/missing.jsonl"; expect_out '"decision":"block"' "an unreadable transcript cannot prove 'nothing written' → held"
tr_write "$HR/lib/u.ts"; printf '{"type":"assistant","message":{"content":[{"type":"tool_use" BROKEN\n' >> "$TR"
stop s3b; expect_out '"decision":"block"' "a tool-use line no parser can read → held"

# Docs-only change on the branch: ship's fingerprint excludes it → quiet.
git checkout -q -- lib/u.ts; echo more >> docs/x.md
tr_write "$HR/docs/x.md" "$HR/lib/u.ts"
stop s4; check "docs-only change (ship's DOCS_ALLOWLIST) → nothing" test -z "$OUT"
git checkout -q -- docs/x.md

# A review that covers the tree → quiet; a reader error → quiet.
echo z >> lib/n.ts; tr_write "$HR/lib/n.ts"
FP="$(bash .claude/skills/ship/bin/ship-sentinel.sh --contract=2 fingerprint | head -1)"
printf '%s\n%s\n%s\n' "$FP" "$(date +%s)" "$(git rev-parse HEAD)" > "$ST/review-code-ran"
stop s5; check "a fresh review sentinel for this tree → nothing" test -z "$OUT"
printf 'SENTINEL-ERROR: x\n%s\n' "$(date +%s)" > "$ST/review-code-ran"
stop s5; check "verify review cannot decide (exit 3) → nothing" test -z "$OUT"
rm -f "$ST/review-code-ran"
mv .claude/skills/ship/bin/ship-sentinel.sh "$T_TMP/ss.sh"
stop s5; check "ship's sentinel script missing → nothing" test -z "$OUT"
mv "$T_TMP/ss.sh" .claude/skills/ship/bin/ship-sentinel.sh
stop s5; expect_out '"decision":"block"' "…and with it back, the same stop is held"

# Clean tree: a recent unreviewed commit is held; an old HEAD is not this session's work.
git commit -qam "Refs #7 code" || exit 2
tr_write "$HR/lib/n.ts"
stop s6; expect_out '"decision":"block"' "clean tree, recent unreviewed commit → held"
echo w >> lib/n.ts
GIT_COMMITTER_DATE="$(( $(date +%s) - 3 * 3600 )) +0000" git commit -qam "Refs #7 old" || exit 2
stop s7; check "clean tree, HEAD older than the window → nothing" test -z "$OUT"

# Not governed (no hooks.env) → quiet.
echo v >> lib/n.ts; mv .claude/hooks/hooks.env "$T_TMP/he"
stop s8; check "no hooks.env → nothing" test -z "$OUT"
mv "$T_TMP/he" .claude/hooks/hooks.env

t_done
