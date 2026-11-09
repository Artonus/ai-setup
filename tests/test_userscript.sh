#!/usr/bin/env bash
# Tests for tools/lib/meet.user.js.tpl: template shape, syntax of the served script, pure logic (needs node).
# Uses the _d_* helpers from test_daemon.sh (run.sh sources every test file first).

_u_TPL="$ROOT/tools/lib/meet.user.js.tpl"

test_userscript_template_metadata_and_no_secret() {
  local tpl
  tpl="$(cat "$_u_TPL")"
  assert_contains "$tpl" "@match        https://meet.google.com/*" "matches Meet"
  assert_contains "$tpl" "@connect      127.0.0.1" "connect 127.0.0.1"
  assert_contains "$tpl" "@connect      localhost" "connect localhost"
  assert_contains "$tpl" "@grant        GM_xmlhttpRequest" "grant GM_xmlhttpRequest"
  assert_contains "$tpl" "@grant        GM_notification" "grant GM_notification"
  assert_contains "$tpl" "@grant        GM_registerMenuCommand" "grant GM_registerMenuCommand"
  assert_contains "$tpl" "@updateURL    http://127.0.0.1:@@PORT@@/meet.user.js" "updateURL placeholder"
  assert_contains "$tpl" "@downloadURL  http://127.0.0.1:@@PORT@@/meet.user.js" "downloadURL placeholder"
  assert_contains "$tpl" "const TOKEN = '@@TOKEN@@';" "token is a placeholder"
  assert_contains "$tpl" "NIEZWERYFIKOWANE" "selectors are marked as unverified"
  if grep -Eq '[0-9a-f]{40,}' "$_u_TPL"; then fail "template contains something that looks like a secret"; else ok; fi
}

test_userscript_served_script_has_valid_syntax() {
  if ! command -v node > /dev/null 2>&1; then
    printf '  SKIP: node not found, syntax and logic checks of the userscript not run\n'
    return 0
  fi
  _d_setup
  _d_run
  curl -s -o "$T/served.js" "http://127.0.0.1:$D_PORT/meet.user.js"
  _d_end
  local out
  out="$(node --check "$T/served.js" 2>&1)"
  assert_eq 0 "$?" "served userscript parses ($out)"
  cp "$_u_TPL" "$T/template.js"
  out="$(node --check "$T/template.js" 2>&1)"
  assert_eq 0 "$?" "the raw template parses ($out)"
}

test_userscript_pure_logic() {
  if ! command -v node > /dev/null 2>&1; then
    printf '  SKIP: node not found, userscript logic not tested\n'
    return 0
  fi
  sed -n '/PURE LOGIC START/,/PURE LOGIC END/p' "$_u_TPL" > "$T/pure.js"
  cat > "$T/logic.js" <<'EOF'
const assert = require('assert');
const fs = require('fs');
const vm = require('vm');
const ctx = {};
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8') +
  '\n;this.api = { CONFIG, meetCode, classify, initialState, reduce };', ctx);
const { CONFIG: C, meetCode, classify, initialState, reduce } = ctx.api;
const URL1 = 'https://meet.google.com/abc-defg-hij';
const types = (r) => r.acts.map((a) => a.type).join(',');
let n = 0;
const t = (name, fn) => { try { fn(); n++; } catch (e) { console.log('  FAIL: ' + name + ': ' + e.message); process.exitCode = 1; } };
// feed events, return { state, all actions }
const run = (s, evs) => { const acts = []; for (const ev of evs) { const r = reduce(s, ev, C); s = r.state; acts.push(...r.actions); } return { s, acts }; };
const lobby = () => run(initialState(true), [{ type: 'url', url: URL1 }]).s;

t('meetCode', () => {
  assert.strictEqual(meetCode(URL1), 'abc-defg-hij');
  assert.strictEqual(meetCode(URL1 + '?authuser=1'), 'abc-defg-hij');
  assert.strictEqual(meetCode('https://meet.google.com/landing'), null);
  assert.strictEqual(meetCode('https://meet.google.com/abc-defg-hijk'), null);
  assert.strictEqual(meetCode('https://evil.com/abc-defg-hij'), null);
  assert.strictEqual(meetCode(''), null);
});
t('classify by text PL/EN and attributes', () => {
  assert.strictEqual(classify({ text: ' Dołącz teraz ' }, C), 'join');
  assert.strictEqual(classify({ text: 'Join\n  now' }, C), 'join');
  assert.strictEqual(classify({ ariaLabel: 'Ask to join' }, C), 'ask');
  assert.strictEqual(classify({ text: 'Poproś o dołączenie' }, C), 'ask');
  assert.strictEqual(classify({ ariaLabel: 'Leave call' }, C), 'leave');
  assert.strictEqual(classify({ ariaLabel: 'Opuść rozmowę' }, C), 'leave');
  assert.strictEqual(classify({ jsname: 'Qx7uuf', text: 'whatever' }, C), 'join');
  assert.strictEqual(classify({ text: 'Present now' }, C), null);
  assert.strictEqual(classify({}, C), null);
});
t('join click starts, ping only after the interval', () => {
  let r = run(lobby(), [{ type: 'click', kind: 'join', t: 1000 }]);
  assert.strictEqual(r.s.phase, 'inCall');
  assert.strictEqual(r.acts.map((a) => a.type).join(), 'start');
  r = run(r.s, [{ type: 'tick', t: 2000 }]);
  assert.strictEqual(r.acts.length, 0);
  r = run(r.s, [{ type: 'tick', t: 1000 + C.pingMs }]);
  assert.strictEqual(r.acts.map((a) => a.type).join(), 'ping');
  assert.strictEqual(r.acts[0].code, 'abc-defg-hij');
});
t('click without a meeting code does nothing', () => {
  const r = run(initialState(true), [{ type: 'click', kind: 'join', t: 1 }]);
  assert.strictEqual(r.acts.length, 0);
});
t('ask to join waits for the hang-up button', () => {
  let r = run(lobby(), [{ type: 'click', kind: 'ask', t: 1000 }]);
  assert.strictEqual(r.s.phase, 'waiting');
  assert.strictEqual(r.acts.length, 0);
  r = run(r.s, [{ type: 'tick', t: 5000 }, { type: 'leaveVisible', visible: false, t: 5000 }]);
  assert.strictEqual(r.acts.length, 0);
  r = run(r.s, [{ type: 'leaveVisible', visible: true, t: 9000 }]);
  assert.strictEqual(r.acts.map((a) => a.type).join(), 'start');
  assert.strictEqual(r.s.phase, 'inCall');
});
t('waiting room times out without recording', () => {
  let r = run(lobby(), [{ type: 'click', kind: 'ask', t: 0 }, { type: 'tick', t: C.waitTimeoutMs }]);
  assert.strictEqual(r.s.phase, 'lobby');
  assert.strictEqual(r.acts.map((a) => a.type).join(), 'notify');
});
t('denied/cancelled ask to join (leave click while waiting) does not record', () => {
  const r = run(lobby(), [{ type: 'click', kind: 'ask', t: 0 }, { type: 'click', kind: 'leave', t: 1 }]);
  assert.strictEqual(r.acts.length, 0);
  assert.strictEqual(r.s.phase, 'lobby');
});
t('leave click stops, rejoin starts again', () => {
  let r = run(lobby(), [{ type: 'click', kind: 'join', t: 0 }, { type: 'click', kind: 'leave', t: 100 }]);
  assert.strictEqual(types(r), 'start,stop');
  assert.strictEqual(r.s.phase, 'ended');
  r = run(r.s, [{ type: 'click', kind: 'join', t: 200 }]);
  assert.strictEqual(types(r), 'start');
});
t('leave button flicker is debounced, real disappearance stops', () => {
  let r = run(lobby(), [{ type: 'click', kind: 'join', t: 0 }, { type: 'leaveVisible', visible: true, t: 100 },
    { type: 'leaveVisible', visible: false, t: 1000 }, { type: 'tick', t: 1500 },
    { type: 'leaveVisible', visible: true, t: 2000 }, { type: 'tick', t: 2000 + C.leaveGoneMs + 1 }]);
  assert.ok(!r.acts.some((a) => a.type === 'stop'), 'flicker must not stop');
  r = run(r.s, [{ type: 'leaveVisible', visible: false, t: 10000 }, { type: 'tick', t: 10000 + C.leaveGoneMs }]);
  assert.strictEqual(types(r), 'stop');
  assert.strictEqual(r.s.phase, 'ended');
});
t('unrecognised hang-up button never ends the recording by itself (degraded mode)', () => {
  const r = run(lobby(), [{ type: 'click', kind: 'join', t: 0 }, { type: 'leaveVisible', visible: false, t: 100 },
    { type: 'tick', t: 100000 }]);
  assert.ok(!r.acts.some((a) => a.type === 'stop'));
});
t('address change to a non-meeting page stops', () => {
  const r = run(lobby(), [{ type: 'click', kind: 'join', t: 0 }, { type: 'url', url: 'https://meet.google.com/landing' }]);
  assert.strictEqual(types(r), 'start,stop');
  assert.strictEqual(r.acts[1].code, 'abc-defg-hij');
  assert.strictEqual(r.s.phase, 'idle');
});
t('address change to another meeting stops and starts a new lobby', () => {
  const r = run(lobby(), [{ type: 'click', kind: 'join', t: 0 }, { type: 'url', url: 'https://meet.google.com/xyz-wxyz-abc' }]);
  assert.strictEqual(types(r), 'start,stop');
  assert.strictEqual(r.s.phase, 'lobby');
  assert.strictEqual(r.s.code, 'xyz-wxyz-abc');
});
t('same address again (query change) is not a new session', () => {
  const r = run(lobby(), [{ type: 'click', kind: 'join', t: 0 }, { type: 'url', url: URL1 + '?x=1' }]);
  assert.strictEqual(types(r), 'start');
  assert.strictEqual(r.s.phase, 'inCall');
});
t('pagehide sends a soft stop', () => {
  const r = run(lobby(), [{ type: 'click', kind: 'join', t: 0 }, { type: 'pagehide' }]);
  assert.strictEqual(types(r), 'start,stop');
  assert.strictEqual(r.acts[1].reason, 'pagehide');
  assert.strictEqual(run(lobby(), [{ type: 'pagehide' }]).acts.length, 0, 'pagehide in the lobby does nothing');
});
t('kill switch: disabled never starts, turning it off mid-call stops', () => {
  let r = run(initialState(false), [{ type: 'url', url: URL1 }, { type: 'click', kind: 'join', t: 0 }]);
  assert.strictEqual(r.acts.length, 0);
  r = run(lobby(), [{ type: 'click', kind: 'join', t: 0 }, { type: 'enabled', value: false }]);
  assert.strictEqual(types(r), 'start,stop');
  r = run(r.s, [{ type: 'click', kind: 'join', t: 5 }]);
  assert.strictEqual(r.acts.length, 0, 'still off after the stop');
  r = run(r.s, [{ type: 'enabled', value: true }, { type: 'click', kind: 'join', t: 9 }]);
  assert.strictEqual(types(r), 'start');
});
t('refused start returns to the lobby', () => {
  const r = run(lobby(), [{ type: 'click', kind: 'join', t: 0 }, { type: 'startRefused' }, { type: 'tick', t: 99999 }]);
  assert.strictEqual(r.s.phase, 'lobby');
  assert.ok(!r.acts.some((a) => a.type === 'ping'));
});
t('reduce does not mutate its input', () => {
  const s = lobby(); const copy = JSON.stringify(s);
  reduce(s, { type: 'click', kind: 'join', t: 1 }, C);
  assert.strictEqual(JSON.stringify(s), copy);
});
console.log('  ' + n + ' userscript logic cases passed');
EOF
  local out
  out="$(node "$T/logic.js" "$T/pure.js" 2>&1)"
  assert_eq 0 "$?" "userscript logic cases ($out)"
}
