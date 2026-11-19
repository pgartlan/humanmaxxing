#!/usr/bin/env bash
# hm-lock.sh — the install record: which HumanMaxxing release each installed item came from.
#
# Run it from inside your project (any folder of the repository). The lock file is
# <repository top level>/.claude/humanmaxxing.lock, committed with the install.
#
#   hm-lock.sh record --from <download> <product path>...
#       After installing or merging an item, record it: its path in the download (`skills/ship`,
#       `templates/CLAUDE.template.md`), a hash of the download's copy, and the download's VERSION.
#       A path already in the lock is replaced. Exit 0 · 2 usage · 3 error.
#   hm-lock.sh status --from <download>
#       Compare the lock with a (newer) download. One line per item:
#         ITEM <path> current|behind|gone recorded=<version> source=<version>
#         NEW <path>          a skill in the download that the lock does not record (informational)
#       `behind` = the download's copy differs from the one recorded: merge it (never copy over), then record it again.
#       `gone`   = the download no longer has it. Exit 0 all current · 1 something behind or gone · 2 usage · 3 error
#       (no lock, an unreadable lock, or a download without a valid VERSION).
#   hm-lock.sh hash <path>
#       Print the hash of a file or folder (folder: every file under it, by relative path and content).
#
# The hash covers the PRODUCT copy in the download, not your installed copy: an installed skill always differs from
# the product (its filled values block, its .env files), so the record says which release you merged from, and
# `status` says whether a newer download changed it since.
set -u
LC_ALL=C; export LC_ALL

die() { echo "hm-lock: $2" >&2; exit "$1"; }
usage() { die 2 "usage: hm-lock.sh record --from <download> <path>... | status --from <download> | hash <path>"; }

hash_path() {   # $1 = file or folder; prints one hash; returns 3 on error
  local p="$1" f h list man=""
  # --no-filters: the hash is of the bytes alone, never of what a repository's eol or clean filters would make of them.
  if [ -f "$p" ]; then git hash-object --no-filters -- "$p" 2>/dev/null || return 3; return 0; fi
  [ -d "$p" ] || return 3
  list="$(cd "$p" && find . -type f)" || return 3   # find's own status: an unreadable subfolder is an error, never a partial hash
  list="$(printf '%s\n' "$list" | sort)" || return 3
  [ -n "$list" ] || return 3
  while IFS= read -r f; do
    h="$(git hash-object --no-filters -- "$p/$f" 2>/dev/null)" || return 3
    man="$man$h ${f#./}
"
  done <<EOF
$list
EOF
  printf '%s' "$man" | git hash-object --stdin 2>/dev/null || return 3
}

read_version() {   # $1 = download; prints its VERSION
  local v
  [ -f "$1/VERSION" ] || return 3
  IFS= read -r v < "$1/VERSION" || [ -n "${v:-}" ] || return 3
  v="${v%$'\r'}"
  printf '%s\n' "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' || return 3
  printf '%s\n' "$v"
}

check_rel() {   # a product path, written one way only: relative, no .., no ./, no trailing or doubled /, no backslash
  case "$1" in ''|/*|./*|*/../*|../*|*/..|..|*' '*|*/|*//*|*/./*|*/.|.|*\\*) return 1 ;; esac
  return 0
}

lock_path() {
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || die 3 "not inside a git repository (run it from your project)"
  printf '%s/.claude/humanmaxxing.lock\n' "$top"
}

VERB="${1:-}"; [ -n "$VERB" ] || usage; shift
case "$VERB" in
  hash)
    [ "$#" -eq 1 ] || usage
    hash_path "$1" || die 3 "cannot hash '$1' (missing, empty or unreadable)"
    ;;
  record|status)
    [ "${1:-}" = "--from" ] && [ -n "${2:-}" ] || usage
    SRC="$2"; shift 2
    [ -d "$SRC" ] || die 3 "download folder not found: $SRC"
    V="$(read_version "$SRC")" || die 3 "$SRC/VERSION is missing or not a version (x.y.z)"
    LOCK="$(lock_path)"
    if [ "$VERB" = record ]; then
      [ "$#" -ge 1 ] || usage
      mkdir -p "$(dirname "$LOCK")" || die 3 "cannot create $(dirname "$LOCK")"
      TMP="$LOCK.tmp.$$"
      if [ -f "$LOCK" ]; then cp "$LOCK" "$TMP" || die 3 "cannot read $LOCK"
      else printf '%s\n' "# HumanMaxxing install record, written by tools/hm-lock.sh. Do not edit by hand." "# item <path> <hash of the download's copy> <release version>" > "$TMP" || die 3 "cannot write $TMP"; fi
      DONE=""
      for p in "$@"; do
        check_rel "$p" || { rm -f "$TMP"; die 2 "not a product path: '$p' (relative to the download, written plainly: no spaces, .., ./, backslash, trailing or doubled /)"; }
        H="$(hash_path "$SRC/$p")" || { rm -f "$TMP"; die 3 "cannot hash $SRC/$p (missing or empty)"; }
        awk -v p="$p" '!($1 == "item" && $2 == p)' "$TMP" > "$TMP.2" && mv -f "$TMP.2" "$TMP" || { rm -f "$TMP" "$TMP.2"; die 3 "cannot update the lock"; }
        printf 'item %s %s %s\n' "$p" "$H" "$V" >> "$TMP" || { rm -f "$TMP"; die 3 "cannot update the lock"; }
        DONE="${DONE}RECORDED $p $V
"
      done
      mv -f "$TMP" "$LOCK" || { rm -f "$TMP"; die 3 "cannot write $LOCK"; }
      printf '%s' "$DONE"   # only once the lock holds them
      exit 0
    fi
    [ "$#" -eq 0 ] || usage
    [ -f "$LOCK" ] || die 3 "no install record at $LOCK (installed before records existed: compare by hand, then record each item)"
    [ -r "$LOCK" ] || die 3 "cannot read $LOCK"
    echo "SOURCE version=$V"
    RC=0; SEEN=""; N=0
    while IFS= read -r line || [ -n "$line" ]; do
      # The lock is committed in the user's repository, so Git for Windows may check it out with CRLF line ends: one CR
      # at the end of a line is the line end. A CR elsewhere is malformed. (The hashes compared below are of the
      # download's bytes, never of the lock's lines: nothing hashed is stripped.)
      line="${line%$'\r'}"
      case "$line" in *$'\r'*) die 3 "malformed line in $LOCK (a carriage return inside it)" ;; esac
      IFS=' ' read -r kind p h rv rest <<EOF_LINE
$line
EOF_LINE
      case "$kind" in '#'*|'') continue ;; item) ;; *) die 3 "malformed line in $LOCK: $kind $p" ;; esac
      [ -n "$p" ] && [ -n "$h" ] && [ -n "$rv" ] && [ -z "$rest" ] || die 3 "malformed item line in $LOCK: $p"
      N=$((N + 1)); SEEN="$SEEN|$p|"
      if [ ! -e "$SRC/$p" ]; then echo "ITEM $p gone recorded=$rv source=$V"; RC=1; continue; fi
      NOW="$(hash_path "$SRC/$p")" || die 3 "cannot hash $SRC/$p"
      if [ "$NOW" = "$h" ]; then echo "ITEM $p current recorded=$rv source=$V"
      else echo "ITEM $p behind recorded=$rv source=$V"; RC=1; fi
    done < "$LOCK"
    [ "$N" -gt 0 ] || die 3 "$LOCK records no item"
    for d in "$SRC"/skills/*/; do
      [ -d "$d" ] || continue
      p="skills/$(basename "$d")"
      case "$SEEN" in *"|$p|"*) ;; *) echo "NEW $p" ;; esac
    done
    exit "$RC"
    ;;
  *) usage ;;
esac
