#!/usr/bin/env bash
# Install Claude Code + OpenCode config from this repo by symlinking into $HOME.
# Portable to macOS (bash 3.2, BSD userland) and Ubuntu. See README.md.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CLAUDE_DIR="$HOME/.claude"
OPENCODE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ai-setup"
MANIFEST="$STATE_DIR/manifest"
STAMP="$(date +%Y%m%d%H%M%S)"
DRY_RUN=0
UNINSTALL=0
CHANGES=0
NEW_MANIFEST=""

# Deep merge of two JSON documents (slurped as .[0] base, .[1] overlay):
# objects merge recursively, arrays are unioned, other values come from the overlay.
MERGE_JQ='def merge($a; $b):
  if ($a|type) == "object" and ($b|type) == "object" then
    reduce ($b|keys_unsorted[]) as $k ($a;
      .[$k] = (if has($k) then merge(.[$k]; $b[$k]) else $b[$k] end))
  elif ($a|type) == "array" and ($b|type) == "array" then
    reduce $b[] as $x ($a; if index([$x]) == null then . + [$x] else . end)
  elif ($a|type) == "array" or ($a|type) == "object" then
    error("type mismatch: base is \($a|type), overlay is \($b|type)")
  else $b end;
merge(.[0]; .[1])'

usage() {
  cat <<'EOF'
Usage: install.sh [--dry-run] [--uninstall]

Symlinks the shared Claude Code / OpenCode config into ~/.claude and
~/.config/opencode. Existing files are backed up, never deleted.

  --dry-run    Show what would change; touch nothing.
  --uninstall  Remove everything a previous run created (backups are kept).
  -h, --help   Show this help.

Environment:
  AI_SETUP_OVERLAY  Directory with a private overlay (shared/, claude/, opencode/)
                    layered on top of this repo. See overlay.example/.
EOF
}

die() { printf 'ai-setup: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

# act <description> <command...>: run a mutating command (or just report it in dry-run).
act() {
  local desc=$1
  shift
  CHANGES=$((CHANGES + 1))
  if [ "$DRY_RUN" = 1 ]; then
    log "would $desc"
  else
    "$@"
    log "$desc"
  fi
}

# Manifest lines are "<path><TAB><what we put there>": "l:<link target>" or "f:<cksum of file>".
file_sum() { cksum < "$1" | awk '{print $1 "-" $2}'; }

# lookup <path> <manifest-file>: print <path>'s recorded field; fails when <path> is not listed.
lookup() {
  [ -f "$2" ] || return 1
  P="$1" awk -F'\t' '$1 == ENVIRON["P"] { print $2; f = 1; exit } END { exit !f }' "$2"
}

# still_ours <path> <field>: <path> is still exactly what a previous run put there.
still_ours() {
  case $2 in
    l:*) [ -L "$1" ] && [ "$(readlink "$1")" = "${2#l:}" ] ;;
    f:*) [ -f "$1" ] && [ ! -L "$1" ] && [ "$(file_sum "$1")" = "${2#f:}" ] ;;
    *) return 1 ;;
  esac
}

# owned <path>: true when a previous run created <path> and nobody has changed it since.
owned() {
  local field
  field="$(lookup "$1" "$MANIFEST")" || return 1
  still_ours "$1" "$field"
}

# record <path> <field>: remember what this run put at <path> (also in dry-run, so pruning can be planned).
record() { printf '%s\t%s\n' "$1" "$2" >> "$NEW_MANIFEST"; }

# clear_dest <path>: make room at <path>. Our own old output is removed; anything else is backed up.
clear_dest() {
  local dest=$1
  if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then return 0; fi
  if owned "$dest"; then
    act "remove $dest" rm -f "$dest"
  else
    act "back up $dest to $dest.bak.$STAMP" mv "$dest" "$dest.bak.$STAMP"
  fi
}

make_link() { mkdir -p "$(dirname "$2")" && ln -s "$1" "$2"; }

# link <src> <dest>: idempotent symlink with backup of whatever is in the way.
link() {
  local src=$1 dest=$2
  record "$dest" "l:$src"
  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then return 0; fi
  clear_dest "$dest"
  act "link $dest -> $src" make_link "$src" "$dest"
}

# OpenCode directory name for each shared kind. Skills are not listed: OpenCode reads
# ~/.claude/skills itself. Plural names confirmed against docs.opencode.ai (Task 5).
opencode_subdir() {
  case $1 in
    agents) echo agents ;;
    commands) echo commands ;;
    *) die "unknown kind: $1" ;;
  esac
}

# src_for <area> <rel>: the overlay's path when it has one, else the base path.
src_for() {
  if [ -n "${AI_SETUP_OVERLAY:-}" ] && [ -e "$AI_SETUP_OVERLAY/$1/$2" ]; then
    printf '%s\n' "$AI_SETUP_OVERLAY/$1/$2"
  else
    printf '%s\n' "$REPO/$1/$2"
  fi
}

# children <area> <subdir>: union of entry names in the base and the overlay.
children() {
  {
    ls -1 "$REPO/$1/$2" 2>/dev/null || true
    if [ -n "${AI_SETUP_OVERLAY:-}" ]; then ls -1 "$AI_SETUP_OVERLAY/$1/$2" 2>/dev/null || true; fi
  } | grep -v '^\.gitkeep$' | sort -u || true
}

# link_children <area> <kind> <destdir>: link every entry of <area>/<kind> into <destdir>.
link_children() {
  local name names
  names="$(children "$1" "$2")"
  [ -n "$names" ] || return 0
  # A symlinked target dir would make us write through it into somewhere else.
  if [ -L "$3" ]; then clear_dest "$3"; fi
  while IFS= read -r name; do
    link "$(src_for "$1" "$2/$name")" "$3/$name"
  done <<< "$names"
}

place_copy() { mkdir -p "$(dirname "$2")" && cp "$1" "$2"; }

# write_generated <tmpfile> <dest>: install a generated regular file (idempotent).
write_generated() {
  local tmp=$1 dest=$2
  record "$dest" "f:$(file_sum "$tmp")"
  if [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s "$tmp" "$dest"; then return 0; fi
  clear_dest "$dest"
  act "write $dest (merged with overlay)" place_copy "$tmp" "$dest"
}

# install_json <area> <name> <dest>: symlink the base config, or write base+overlay merged.
install_json() {
  local base="$REPO/$1/$2" over="" tmp
  if [ -n "${AI_SETUP_OVERLAY:-}" ] && [ -f "$AI_SETUP_OVERLAY/$1/$2" ]; then
    over="$AI_SETUP_OVERLAY/$1/$2"
  fi
  if [ -z "$over" ]; then
    link "$base" "$3"
    return 0
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/ai-setup-json.XXXXXX")"
  jq -s "$MERGE_JQ" "$base" "$over" > "$tmp"
  write_generated "$tmp" "$3"
  rm -f "$tmp"
}

# preflight_overlay: fail early, before any change, on a bad overlay.
preflight_overlay() {
  [ -n "${AI_SETUP_OVERLAY:-}" ] || return 0
  [ -d "$AI_SETUP_OVERLAY" ] || die "AI_SETUP_OVERLAY is not a directory: $AI_SETUP_OVERLAY"
  AI_SETUP_OVERLAY="$(cd "$AI_SETUP_OVERLAY" && pwd -P)"
  local f
  for f in claude/settings.json opencode/opencode.json; do
    [ -f "$AI_SETUP_OVERLAY/$f" ] || continue
    command -v jq >/dev/null 2>&1 || die "jq is required to merge $f from the overlay"
    jq -e 'type == "object"' "$AI_SETUP_OVERLAY/$f" >/dev/null 2>&1 \
      || die "invalid JSON in overlay (expected an object): $AI_SETUP_OVERLAY/$f"
    jq -s "$MERGE_JQ" "$REPO/$f" "$AI_SETUP_OVERLAY/$f" >/dev/null 2>&1 \
      || die "cannot merge overlay $f into the base (type mismatch, or invalid base JSON)"
  done
}

install_all() {
  local kind
  link "$(src_for shared AGENTS.md)" "$CLAUDE_DIR/AGENTS.md"
  link "$(src_for claude CLAUDE.md)" "$CLAUDE_DIR/CLAUDE.md"
  install_json claude settings.json "$CLAUDE_DIR/settings.json"
  link "$(src_for shared AGENTS.md)" "$OPENCODE_DIR/AGENTS.md"
  install_json opencode opencode.json "$OPENCODE_DIR/opencode.json"
  link_children shared skills "$CLAUDE_DIR/skills"
  for kind in agents commands; do
    link_children shared "$kind" "$CLAUDE_DIR/$kind"
    link_children shared "$kind" "$OPENCODE_DIR/$(opencode_subdir "$kind")"
  done
}

write_manifest() {
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  mkdir -p "$STATE_DIR"
  sort -u "$NEW_MANIFEST" > "$MANIFEST"
}

# prune_stale: remove links/files a previous run created that this run no longer wants.
prune_stale() {
  [ -f "$MANIFEST" ] || return 0
  local path field
  while IFS=$'\t' read -r path field; do
    if lookup "$path" "$NEW_MANIFEST" >/dev/null; then continue; fi
    if still_ours "$path" "$field"; then
      act "remove stale $path" rm -f "$path"
    elif [ -e "$path" ] || [ -L "$path" ]; then
      log "keeping $path: it is no longer what ai-setup installed"
    fi
  done < "$MANIFEST"
}

# uninstall: remove everything the manifest lists. Backups made earlier are left in place.
uninstall() {
  if [ ! -f "$MANIFEST" ]; then
    log "nothing to uninstall"
    return 0
  fi
  local path field
  while IFS=$'\t' read -r path field; do
    if still_ours "$path" "$field"; then
      act "remove $path" rm -f "$path"
    elif [ -e "$path" ] || [ -L "$path" ]; then
      log "keeping $path: it is no longer what ai-setup installed"
    fi
  done < "$MANIFEST"
  act "remove manifest $MANIFEST" rm -f "$MANIFEST"
}

main() {
  while [ $# -gt 0 ]; do
    case $1 in
      --dry-run) DRY_RUN=1 ;;
      --uninstall) UNINSTALL=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done

  preflight_overlay

  NEW_MANIFEST="$(mktemp "${TMPDIR:-/tmp}/ai-setup.XXXXXX")"
  trap 'rm -f "$NEW_MANIFEST"' EXIT

  if [ "$UNINSTALL" = 1 ]; then
    uninstall
  else
    install_all
    prune_stale
    write_manifest
  fi

  if [ "$DRY_RUN" = 1 ]; then
    log "ai-setup (dry run): $CHANGES change(s) planned"
  else
    log "ai-setup: $CHANGES change(s)"
  fi
}

main "$@"
