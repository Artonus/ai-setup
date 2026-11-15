#!/usr/bin/env bash
# Tests for the agent-guard file, secret and AI-setup path rules.

ag_path_env() { # ag_path_env <cmd...>: run agent-guard with a sandboxed project, home and tmp
  local T="$AG_T"
  ( cd "$T/proj" && AGENT_GUARD_POLICY="$ROOT/shared/agent-guard/policy.json" CLAUDE_PROJECT_DIR="$T/proj" \
      HOME="$T/home" TMPDIR="$T/tmp" python3 "$ROOT/tools/bin/agent-guard" "$@" )
}

ag_pcheck() { ag_path_env check "$1"; }
ag_ppath() { ag_path_env check-path "$1" "$2"; }

ag_path_setup() {
  AG_T="$(mktemp -d)"
  mkdir -p "$AG_T/proj/build" "$AG_T/proj/sub" "$AG_T/proj/src" "$AG_T/home/.ssh" "$AG_T/tmp"
  : >"$AG_T/proj/exists.txt"
  : >"$AG_T/home/existing.txt"
}

test_ag_paths_rm_inside_and_outside() {
  ag_path_setup
  local T="$AG_T"
  assert_eq none "$(ag_pcheck "rm \"$T/proj/build/out.o\"" | cut -f1)" "rm inside project"
  assert_eq ask "$(ag_pcheck 'rm ../x' | cut -f1)" "rm parent path"
  assert_eq ask "$(ag_pcheck 'rm "$HOME/x"' | cut -f1)" "rm under HOME"
  assert_eq ask "$(ag_pcheck 'rm /etc/hosts' | cut -f1)" "rm absolute outside"
  assert_eq none "$(ag_pcheck 'rm "$TMPDIR/x"' | cut -f1)" "rm under TMPDIR"
  assert_eq none "$(ag_pcheck 'rm "${TMPDIR}/x"' | cut -f1)" "rm under braced TMPDIR"
  assert_eq ask "$(ag_pcheck 'rm "$OTHER/x"' | cut -f1)" "rm with unknown variable"
  assert_eq ask "$(ag_pcheck 'rm $(ls)' | cut -f1)" "rm with command substitution"
  assert_eq file-destructive "$(ag_pcheck 'rm /etc/hosts' | cut -f2)" "rule id"
  assert_eq none "$(ag_pcheck 'rm build/out.o' | cut -f1)" "relative inside project"
  rm -rf "$T"
}

test_ag_paths_cd_tracks_cwd() {
  ag_path_setup
  local T="$AG_T"
  assert_eq none "$(ag_pcheck "cd \"$T/proj/sub\" && rm y" | cut -f1)" "cd into project then rm"
  assert_eq ask "$(ag_pcheck 'cd .. && rm y' | cut -f1)" "cd out of project then rm"
  assert_eq ask "$(ag_pcheck 'cd "$X" && rm y' | cut -f1)" "dynamic cd makes relative rm unresolvable"
  assert_eq none "$(ag_pcheck 'cd "$X" && rm /tmp/y' | cut -f1)" "absolute target after dynamic cd"
  rm -rf "$T"
}

test_ag_paths_other_destructive_verbs() {
  ag_path_setup
  local T="$AG_T"
  assert_eq ask "$(ag_pcheck 'rmdir /etc/x' | cut -f1)" "rmdir outside"
  assert_eq ask "$(ag_pcheck 'shred /etc/x' | cut -f1)" "shred outside"
  assert_eq ask "$(ag_pcheck 'truncate -s 0 /etc/x' | cut -f1)" "truncate outside"
  assert_eq none "$(ag_pcheck 'truncate -s 0 build/x' | cut -f1)" "truncate inside"
  assert_eq ask "$(ag_pcheck 'find / -delete' | cut -f1)" "find -delete outside"
  assert_eq ask "$(ag_pcheck 'find /etc -exec rm {} \;' | cut -f1)" "find -exec rm outside"
  assert_eq none "$(ag_pcheck 'find . -name x -delete' | cut -f1)" "find -delete inside"
  assert_eq none "$(ag_pcheck 'find /etc -name x' | cut -f1)" "plain find"
  assert_eq ask "$(ag_pcheck 'dd if=a of=/etc/x' | cut -f1)" "dd of= outside"
  assert_eq ask "$(ag_pcheck 'git ls-files | xargs rm' | cut -f1)" "xargs rm"
  assert_eq ask "$(ag_pcheck "cp a \"$T/home/existing.txt\"" | cut -f1)" "cp onto existing file outside"
  assert_eq none "$(ag_pcheck "cp a \"$T/home/new.txt\"" | cut -f1)" "cp to a new file"
  assert_eq none "$(ag_pcheck 'cp a exists.txt' | cut -f1)" "cp onto existing file inside"
  assert_eq none "$(ag_pcheck "mv a \"$T/home\"" | cut -f1)" "mv into a dir without a clash"
  assert_eq ask "$(ag_pcheck "mv src/existing.txt \"$T/home\"" | cut -f1)" "mv into a dir clobbering a same-named file"
  rm -rf "$T"
}

test_ag_paths_redirects() {
  ag_path_setup
  local T="$AG_T"
  assert_eq none "$(ag_pcheck "echo hi > \"$T/proj/new.txt\"" | cut -f1)" "redirect to new file inside"
  assert_eq ask "$(ag_pcheck 'echo hi > ~/.zshrc' | cut -f1)" "redirect to protected path"
  assert_eq ask "$(ag_pcheck "echo hi >> \"$T/home/existing.txt\"" | cut -f1)" "append to existing file outside"
  assert_eq none "$(ag_pcheck "echo hi > \"$T/home/new.txt\"" | cut -f1)" "redirect to new file outside"
  assert_eq none "$(ag_pcheck 'ls > /dev/null 2>&1' | cut -f1)" "redirect to /dev/null"
  assert_eq ask "$(ag_pcheck 'echo hi > "$X"' | cut -f1)" "dynamic redirect target"
  assert_eq ai-setup "$(ag_pcheck 'echo hi > ~/.claude/x' | cut -f2)" "redirect into ~/.claude"
  rm -rf "$T"
}

test_ag_paths_secret_reads() {
  ag_path_setup
  local T="$AG_T"
  assert_eq deny "$(ag_pcheck 'cat ~/.ssh/id_ed25519' | cut -f1)" "private key"
  assert_eq secret-read "$(ag_pcheck 'cat ~/.ssh/id_ed25519' | cut -f2)" "secret rule id"
  assert_eq none "$(ag_pcheck 'cat ~/.ssh/id_ed25519.pub' | cut -f1)" "public key"
  assert_eq deny "$(ag_pcheck 'cat ~/.aws/credentials' | cut -f1)" "aws credentials"
  assert_eq deny "$(ag_pcheck 'cat .env' | cut -f1)" ".env in cwd"
  assert_eq deny "$(ag_pcheck 'grep KEY src/.env.local' | cut -f1)" ".env.* variant"
  assert_eq deny "$(ag_pcheck 'cat < ~/.ssh/id_rsa' | cut -f1)" "input redirect"
  assert_eq deny "$(ag_pcheck 'cp ~/.ssh/id_rsa /tmp/x' | cut -f1)" "cp of a key"
  assert_eq deny "$(ag_pcheck 'cat .env.example' | cut -f1)" ".env.* includes .env.example"
  assert_eq none "$(ag_pcheck 'ls ~/.ssh/id_rsa' | cut -f1)" "ls is not a read tool"
  assert_eq deny "$(ag_ppath Read "$T/home/.aws/credentials" | cut -f1)" "Read tool on credentials"
  rm -rf "$T"
}

test_ag_paths_check_path() {
  ag_path_setup
  local T="$AG_T"
  assert_eq ask "$(ag_ppath Write '~/.zshrc' | cut -f1)" "Write to .zshrc"
  assert_eq protected-path "$(ag_ppath Write '~/.zshrc' | cut -f2)" ".zshrc rule"
  assert_eq ask "$(ag_ppath Write '~/.claude/settings.json' | cut -f1)" "Write to ~/.claude"
  assert_eq ai-setup "$(ag_ppath Write '~/.claude/settings.json' | cut -f2)" "~/.claude rule"
  assert_contains "$(ag_ppath Write '~/.claude/settings.json' | cut -f3)" "change the AI setup in the ai-setup repo" "ai-setup reason"
  assert_eq ai-setup "$(ag_ppath Edit '~/.config/opencode/opencode.json' | cut -f2)" "~/.config/opencode rule"
  assert_eq protected-path "$(ag_ppath Edit '~/.config/other/x' | cut -f2)" "~/.config is protected"
  assert_eq none "$(ag_ppath Edit "$T/proj/src/a.py")" "Edit inside project"
  assert_eq none "$(ag_ppath MultiEdit "$T/proj/src/a.py")" "MultiEdit inside project"
  assert_eq ask "$(ag_ppath NotebookEdit "$T/home/x.ipynb" | cut -f1)" "NotebookEdit outside project"
  assert_eq ask "$(ag_ppath write '~/.zshrc' | cut -f1)" "tool names are case-insensitive"
  assert_eq ask "$(ag_ppath Write "$T/proj/../outside.txt" | cut -f1)" "dotdot escapes the project"
  assert_eq none "$(ag_ppath Write "$T/tmp/x")" "Write under tmp root"
  assert_eq none "$(ag_ppath Bogus '~/.zshrc')" "unknown tool has no opinion"
  rm -rf "$T"
}
