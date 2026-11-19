#!/usr/bin/env bash
# worktree-install-launcher.sh — write the per-machine command that starts work on an issue from any directory.
#
#   worktree-install-launcher.sh [--config F] [--name NAME] [--dir DIR]
#
# Writes <DIR>/<NAME> (default: $HOME/bin/maxx-start): a short script that changes into this repository's primary
# working copy (the worktree of BASE_BRANCH) and runs bin/worktree-start.sh there with its arguments (and the
# WORKTREE_PARENT_DIR environment value as --parent, when this machine sets one). Then, from any directory: `maxx-start 123`, `maxx-start fable 12,13`.
# The written file names this script on its second line. A file of that name that this script did not write is never
# overwritten (exit 1); one it wrote is replaced, so re-running after a move updates it. Run it once per machine
# (and again when the repository or its parent folder moves). It writes outside the repository: install only with the
# user's approval.
# Exit codes: 0 written (or already current) · 1 refused · 2 usage or configuration.
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/worktree-lib.sh"
# shellcheck source=skills/worktree/bin/worktree-lib.sh
. "$LIB" || { echo "worktree-lib missing or broken" >&2; exit 2; }
WT_SCRIPT="worktree-install-launcher"

NAME="maxx-start"; DIR=""
[ -z "${HOME:-}" ] || DIR="$HOME/bin"   # no HOME: no default; --dir is then required
usage() { wt_die 2 usage "usage: worktree-install-launcher.sh [--config F] [--name NAME] [--dir DIR]${1:+ ($1)}"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) [ "$#" -ge 2 ] || usage "--config needs a file"; WT_CONFIG="$2"; shift 2 ;;
    --name) [ "$#" -ge 2 ] || usage "--name needs a name"; NAME="$2"; shift 2 ;;
    --dir) [ "$#" -ge 2 ] || usage "--dir needs a directory"; DIR="$2"; shift 2 ;;
    *) usage "unknown argument $1" ;;
  esac
done
case "$NAME" in ''|-*|*[!A-Za-z0-9._-]*) usage "NAME must be a plain command name (got '$NAME')" ;; esac
[ -n "$DIR" ] || usage "no --dir and no HOME"

wt_load_config
wt_repo_init
PRIMARY=$(wt_worktree_for_branch "$WT_BASE")
[ -n "$PRIMARY" ] || wt_die 2 no-primary "no working copy has $WT_BASE checked out: the launcher runs from there"
PRIMARY="$(cd "$PRIMARY" && pwd -P)"
# The skill's path inside the primary copy (the launcher runs the primary copy's scripts, not this worktree's).
REL="${WT_SKILL_DIR#"$WT_TOP"/}"
[ "$REL" != "$WT_SKILL_DIR" ] || wt_die 2 not-installed "this skill is not inside the repository's checkout ($WT_SKILL_DIR)"
[ -f "$PRIMARY/$REL/bin/worktree-start.sh" ] || wt_die 2 not-installed "the primary copy has no $REL/bin/worktree-start.sh: commit and merge the skill first"
CFG_ARG=""
case "$WT_CONFIG" in "$WT_SKILL_DIR/worktree.env") ;; *) CFG_ARG=" --config $(printf '%q' "$WT_CONFIG")" ;; esac

# The parent folder is passed only when this machine overrides it in its environment: a configured value is read by the
# launcher itself, and the default is worked out at each run (it may not exist yet).
PARENT_ARG=""
[ -z "${WORKTREE_PARENT_DIR:-}" ] || PARENT_ARG=" --parent $(printf '%q' "$WT_PARENT")"
mkdir -p "$DIR" 2>/dev/null || wt_die 2 bad-dir "cannot create $DIR"
D="$(cd "$DIR" && pwd -P)" && [ -n "$D" ] || wt_die 2 bad-dir "cannot enter $DIR"
DIR="$D"
TARGET="$DIR/$NAME"
TAG="# Written by worktree-install-launcher.sh; re-run it to update. The logic lives in the repository."
CONTENT="#!/usr/bin/env bash
$TAG
cd $(printf '%q' "$PRIMARY") || exit 2
exec bash $(printf '%q' "$REL/bin/worktree-start.sh")$CFG_ARG$PARENT_ARG \"\$@\""

if [ -e "$TARGET" ]; then
  if [ "$(sed -n 2p "$TARGET" 2>/dev/null)" != "$TAG" ]; then
    echo "STOP: $TARGET exists and was not written by this script. Choose another --name, or move that file yourself."
    wt_result FAIL exists-foreign "path=$TARGET"; exit 1
  fi
  if [ "$(cat "$TARGET")" = "$CONTENT" ]; then
    echo "$TARGET is already current."
    wt_result PASS current "path=$TARGET"; exit 0
  fi
fi
printf '%s\n' "$CONTENT" > "$TARGET.tmp.$$" && chmod 755 "$TARGET.tmp.$$" && mv -f "$TARGET.tmp.$$" "$TARGET" \
  || { rm -f "$TARGET.tmp.$$"; wt_die 2 write-failed "cannot write $TARGET"; }
echo "Wrote $TARGET: from any directory, \`$NAME <issue>\` (or \`$NAME <model> <issue>\`) starts a session."
case ":${PATH:-}:" in
  *":$DIR:"*) ;;
  *) echo "Note: $DIR is not on your PATH. Add it in your shell profile: export PATH=\"$DIR:\$PATH\"" ;;
esac
OTHER=$(command -v "$NAME" 2>/dev/null) || OTHER=""
if [ -n "$OTHER" ] && [ "$OTHER" != "$TARGET" ]; then echo "Note: \`$NAME\` currently runs $OTHER, which comes first on your PATH."; fi
wt_result PASS installed "path=$TARGET"
