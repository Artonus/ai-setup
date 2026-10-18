#!/usr/bin/env bash
# Shared helpers for the plain-bash test suite. Sourced by tests/run.sh.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$*"; }

assert_eq() { # assert_eq <expected> <actual> <message>
  if [ "$1" = "$2" ]; then ok; else fail "$3 (expected '$1', got '$2')"; fi
}

assert_link() { # assert_link <path> <expected-target>
  if [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]; then
    ok
  else
    fail "$1 should be a symlink to $2 (readlink: '$(readlink "$1" 2>/dev/null)')"
  fi
}

assert_missing() { # assert_missing <path>
  if [ -e "$1" ] || [ -L "$1" ]; then fail "$1 should not exist"; else ok; fi
}

assert_file() { # assert_file <path>: regular file, not a symlink
  if [ -f "$1" ] && [ ! -L "$1" ]; then ok; else fail "$1 should be a regular file"; fi
}

assert_contains() { # assert_contains <haystack> <needle> <message>
  case $1 in
    *"$2"*) ok ;;
    *) fail "$3 (output did not contain '$2'; output was: $1)" ;;
  esac
}

count_backups() { # count_backups <path>: how many <path>.bak.* entries exist
  local n=0 f
  for f in "$1".bak.*; do
    if [ -e "$f" ] || [ -L "$f" ]; then n=$((n + 1)); fi
  done
  echo "$n"
}

# Fresh sandbox: temp dir (symlinks resolved, as install.sh uses pwd -P), a HOME
# and a copy of the repo, both with spaces in the path to exercise quoting.
new_env() {
  T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ai-setup-test.XXXXXX")" && pwd -P)"
  export HOME="$T/my home"
  mkdir -p "$HOME"
  unset XDG_CONFIG_HOME XDG_STATE_HOME AI_SETUP_OVERLAY
  REPO="$T/ai setup"
  mkdir -p "$REPO"
  cp -R "$ROOT/install.sh" "$ROOT/shared" "$ROOT/claude" "$ROOT/opencode" "$ROOT/tools" "$REPO/"
  mkdir -p "$REPO/shared/skills/demo"
  printf '# demo skill\n' > "$REPO/shared/skills/demo/SKILL.md"
  printf 'say hello\n' > "$REPO/shared/commands/hello.md"
  mkdir -p "$REPO/vendor/anthropic-skills/skills/pdf" "$REPO/vendor/anthropic-skills/skills/xlsx"
  printf '# pdf skill\n' > "$REPO/vendor/anthropic-skills/skills/pdf/SKILL.md"
  printf '# xlsx skill\n' > "$REPO/vendor/anthropic-skills/skills/xlsx/SKILL.md"
  mkdir -p "$REPO/vendor/mattpocock-skills/skills/engineering/tdd" "$REPO/vendor/mattpocock-skills/skills/in-progress/draft"
  printf '# tdd skill\n' > "$REPO/vendor/mattpocock-skills/skills/engineering/tdd/SKILL.md"
  mkdir -p "$REPO/vendor/mattpocock-skills/skills/engineering/to-tickets"
  printf '# tickets skill\n' > "$REPO/vendor/mattpocock-skills/skills/engineering/to-tickets/SKILL.md"
  printf '# draft skill\n' > "$REPO/vendor/mattpocock-skills/skills/in-progress/draft/SKILL.md"
}

run_install() { # run_install [install.sh args]: sets RC and OUT
  RC=0
  OUT="$(bash "$REPO/install.sh" "$@" 2>&1)" || RC=$?
}
