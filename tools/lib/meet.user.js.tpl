// ==UserScript==
// @name         Meet -> meeting-daemon recorder
// @namespace    https://github.com/Artonus/ai-setup/meeting-daemon
// @version      @@VERSION@@
// @description  Starts meeting-rec on the local meeting-daemon when you click "Join now" in Google Meet, stops it when you leave.
// @match        https://meet.google.com/*
// @connect      127.0.0.1
// @connect      localhost
// @grant        GM_xmlhttpRequest
// @grant        GM_notification
// @grant        GM_registerMenuCommand
// @grant        GM_getValue
// @grant        GM_setValue
// @run-at       document-idle
// @noframes
// @updateURL    http://127.0.0.1:@@PORT@@/meet.user.js
// @downloadURL  http://127.0.0.1:@@PORT@@/meet.user.js
// ==/UserScript==

// Served by `meeting-daemon` from tools/lib/meet.user.js.tpl with the placeholders filled in.
// The served script contains the daemon token: never commit or share it.

(function () {
  'use strict';

  // ==== PURE LOGIC START (extracted and tested by tests/test_userscript.sh; no DOM, no GM_* in here) ====

  // NIEZWERYFIKOWANE: every selector below is a guess. Nobody has checked it against the live
  // Google Meet DOM in Zen/Firefox, and Meet changes it without notice. Attributes come first
  // (jsname, data-tooltip, aria-label), PL/EN text is the fallback. Use the menu item
  // "Debug: log buttons" on a real Meet page to see what the candidates look like, then fix this object.
  const CONFIG = {
    buttons: {
      // NIEZWERYFIKOWANE: jsname values come from memory and may be wrong or stale.
      join:  { jsname: ['Qx7uuf'], text: /^(dołącz teraz|join now)$/i },
      ask:   { jsname: [],         text: /^(poproś o dołączenie|ask to join)$/i },
      // NIEZWERYFIKOWANE: the in-call hang-up button; its visibility means "we are in the call".
      leave: { jsname: [],         text: /^(leave call|opuść rozmowę|opuść połączenie|zakończ połączenie)$/i },
    },
    pingMs: 5000,          // ping interval while in a call (daemon timeout is 20 s by default)
    leaveGoneMs: 4000,     // leave button must stay gone this long before we treat it as hang-up
    waitTimeoutMs: 15 * 60 * 1000, // give up waiting in the "Ask to join" waiting room
  };

  const CODE_RE = /^https:\/\/meet\.google\.com\/([a-z]{3}-[a-z]{4}-[a-z]{3})(?:[/?#]|$)/;

  function meetCode(url) {
    const m = CODE_RE.exec(url || '');
    return m ? m[1] : null;
  }

  // desc = { jsname, ariaLabel, tooltip, text } of one button -> 'join' | 'ask' | 'leave' | null
  function classify(desc, cfg) {
    const labels = [desc.ariaLabel, desc.tooltip, desc.text]
      .filter(Boolean)
      .map((s) => String(s).replace(/\s+/g, ' ').trim());
    for (const kind of ['join', 'ask', 'leave']) {
      const rule = cfg.buttons[kind];
      if (desc.jsname && rule.jsname.indexOf(desc.jsname) !== -1) return kind;
      if (labels.some((l) => rule.text.test(l))) return kind;
    }
    return null;
  }

  // phases: idle (not on a meeting page) | lobby | waiting (asked to join) | inCall | ended
  function initialState(enabled) {
    return { phase: 'idle', code: null, enabled: enabled !== false,
             leaveSeen: false, leaveGoneSince: null, waitingSince: null, lastPing: 0 };
  }

  // Pure state machine: (state, event) -> { state, actions }.
  // events:  enabled{value} url{url} click{kind,t} leaveVisible{visible,t} tick{t} pagehide startRefused
  // actions: start | stop{code,reason?} | ping{code} | notify{text}
  function reduce(s, ev, cfg) {
    cfg = cfg || CONFIG;
    const n = Object.assign({}, s);
    const actions = [];
    const resetCall = () => { n.leaveSeen = false; n.leaveGoneSince = null; n.waitingSince = null; };
    const enterCall = (t) => {
      resetCall();
      if (n.enabled) {
        n.phase = 'inCall';
        n.lastPing = t || 0;
        actions.push({ type: 'start' });
      } else {
        n.phase = 'lobby'; // switched off: do not record, do not nag
      }
    };
    const stopCall = (reason) => {
      const a = { type: 'stop', code: s.code };
      if (reason) a.reason = reason;
      actions.push(a);
      resetCall();
    };

    switch (ev.type) {
      case 'enabled':
        n.enabled = !!ev.value;
        if (!n.enabled && s.phase === 'inCall') { stopCall(); n.phase = 'lobby'; }
        break;

      case 'url': {
        const code = meetCode(ev.url);
        if (code === s.code) break;
        if (s.phase === 'inCall') stopCall(); // left the meeting page or moved to another meeting
        resetCall();
        n.code = code;
        n.phase = code ? 'lobby' : 'idle';
        break;
      }

      case 'click':
        if (ev.kind === 'join' && s.phase !== 'inCall' && s.code) {
          enterCall(ev.t); // decision: recording starts at the click on "Join now"
        } else if (ev.kind === 'ask' && (s.phase === 'lobby' || s.phase === 'ended') && s.code) {
          n.phase = 'waiting';
          n.waitingSince = ev.t;
        } else if (ev.kind === 'leave') {
          if (s.phase === 'inCall') { stopCall(); n.phase = 'ended'; }
          else if (s.phase === 'waiting') { resetCall(); n.phase = 'lobby'; }
        }
        break;

      case 'leaveVisible':
        if (s.phase === 'waiting' && ev.visible) {
          enterCall(ev.t); // admitted: the hang-up button appeared
        } else if (s.phase === 'inCall') {
          if (ev.visible) { n.leaveSeen = true; n.leaveGoneSince = null; }
          else if (s.leaveSeen && s.leaveGoneSince === null) n.leaveGoneSince = ev.t;
        }
        break;

      case 'tick':
        if (s.phase === 'inCall') {
          if (s.leaveGoneSince !== null && ev.t - s.leaveGoneSince >= cfg.leaveGoneMs) {
            stopCall(); n.phase = 'ended';
          } else if (ev.t - s.lastPing >= cfg.pingMs) {
            n.lastPing = ev.t;
            actions.push({ type: 'ping', code: s.code });
          }
        } else if (s.phase === 'waiting' && ev.t - s.waitingSince >= cfg.waitTimeoutMs) {
          resetCall();
          n.phase = 'lobby';
          actions.push({ type: 'notify', text: 'Nie wpuszczono do spotkania, nagrywanie nie wystartowało.' });
        }
        break;

      case 'pagehide': // tab closed or reloaded; the daemon waits a few seconds before it stops
        if (s.phase === 'inCall') { stopCall('pagehide'); n.phase = 'ended'; }
        break;

      case 'startRefused': // daemon said busy/disabled/error
        if (s.phase === 'inCall') { resetCall(); n.phase = 'lobby'; }
        break;
    }
    return { state: n, actions };
  }

  // ==== PURE LOGIC END ====

  const BASE = 'http://127.0.0.1:' + Number('@@PORT@@');
  const TOKEN = '@@TOKEN@@';

  let state = initialState(readFlag('enabled', true));
  let lastErrorNote = 0;

  function readFlag(key, dflt) {
    try { return !!GM_getValue(key, dflt); } catch (e) { return dflt; }
  }

  function notify(text) {
    try { GM_notification({ title: 'Meet recorder', text: text, timeout: 5000 }); } catch (e) { /* ignore */ }
  }

  function post(path, body, onResult) {
    GM_xmlhttpRequest({ // GM_xmlhttpRequest avoids mixed-content blocking (https page -> http daemon)
      method: 'POST',
      url: BASE + path,
      headers: { 'Content-Type': 'application/json', 'X-Meeting-Token': TOKEN },
      data: JSON.stringify(body),
      timeout: 5000,
      onload: (r) => {
        let j = {};
        try { j = JSON.parse(r.responseText); } catch (e) { /* ignore */ }
        if (onResult) onResult(r.status, j);
      },
      onerror: () => daemonDown(),
      ontimeout: () => daemonDown(),
    });
  }

  function daemonDown() {
    const now = Date.now();
    if (now - lastErrorNote > 60000) {
      lastErrorNote = now;
      notify('meeting-daemon nie odpowiada. Nagranie może się nie uruchomić lub zatrzymać.');
    }
  }

  function run(a) {
    if (a.type === 'start') {
      post('/start', { title: document.title, url: location.href }, (status, j) => {
        if (status === 200) { notify(j.result === 'already' ? 'Nagrywanie trwa.' : 'Nagrywanie rozpoczęte.'); return; }
        dispatch({ type: 'startRefused' });
        if (j.result === 'busy') notify('Inne spotkanie jest już nagrywane.');
        else if (j.result === 'disabled') notify('Nagrywanie wyłączone w demonie.');
        else notify('Nie udało się wystartować nagrywania (HTTP ' + status + ').');
      });
    } else if (a.type === 'ping') {
      post('/ping', { code: a.code });
    } else if (a.type === 'stop') {
      post('/stop', { code: a.code, reason: a.reason }, (status, j) => {
        if (a.reason !== 'pagehide' && status === 200) notify('Nagrywanie zatrzymane.');
      });
    } else if (a.type === 'notify') {
      notify(a.text);
    }
  }

  function dispatch(ev) {
    if (debug() && ev.type !== 'tick') console.log('[meet-rec] event', ev.type, ev.kind || '', 'phase=' + state.phase);
    const r = reduce(state, ev, CONFIG);
    state = r.state;
    r.actions.forEach(run);
  }

  // ---- DOM glue (NIEZWERYFIKOWANE: depends on the live Meet DOM)

  const BTN = 'button, [role="button"]';

  function describe(el) {
    return {
      jsname: el.getAttribute('jsname'),
      ariaLabel: el.getAttribute('aria-label'),
      tooltip: el.getAttribute('data-tooltip'),
      text: el.textContent,
    };
  }

  function visible(el) {
    return !!(el.offsetParent || (el.getClientRects && el.getClientRects().length));
  }

  function leaveVisible() {
    const els = document.querySelectorAll(BTN);
    for (let i = 0; i < els.length; i++) {
      if (visible(els[i]) && classify(describe(els[i]), CONFIG) === 'leave') return true;
    }
    return false;
  }

  function debug() { return readFlag('debug', false); }

  function dumpButtons(why) {
    const rows = [];
    document.querySelectorAll(BTN).forEach((el) => {
      const d = describe(el);
      rows.push({ kind: classify(d, CONFIG), visible: visible(el), jsname: d.jsname, aria: d.ariaLabel,
                  tooltip: d.tooltip, text: (d.text || '').replace(/\s+/g, ' ').trim().slice(0, 60) });
    });
    console.log('[meet-rec] buttons (' + why + '), phase=' + state.phase + ', code=' + state.code);
    console.table(rows);
  }

  // Capture phase: runs before Meet's own handlers, even if they stop propagation.
  document.addEventListener('click', (e) => {
    const el = e.target && e.target.closest ? e.target.closest(BTN) : null;
    if (!el) return;
    const d = describe(el);
    const kind = classify(d, CONFIG);
    if (debug()) { console.log('[meet-rec] click on', d, '->', kind); dumpButtons('click'); }
    if (kind) dispatch({ type: 'click', kind: kind, t: Date.now() });
  }, true);

  window.addEventListener('pagehide', () => dispatch({ type: 'pagehide' }));

  let lastUrl = null;
  let lastVisible = null;
  function poll() {
    const t = Date.now();
    if (location.href !== lastUrl) { lastUrl = location.href; dispatch({ type: 'url', url: lastUrl }); }
    if (state.phase === 'waiting' || state.phase === 'inCall') {
      const v = leaveVisible();
      if (v !== lastVisible) { lastVisible = v; dispatch({ type: 'leaveVisible', visible: v, t: t }); }
      else if (state.phase === 'inCall' && !v && state.leaveSeen) dispatch({ type: 'leaveVisible', visible: v, t: t });
    } else {
      lastVisible = null;
    }
    dispatch({ type: 'tick', t: t });
  }

  // ---- menu

  GM_registerMenuCommand('Recording on/off (now: ' + (state.enabled ? 'on' : 'off') + ')', () => {
    const next = !readFlag('enabled', true);
    GM_setValue('enabled', next);
    notify(next ? 'Nagrywanie włączone (od następnego dołączenia).' : 'Nagrywanie wyłączone.');
    dispatch({ type: 'enabled', value: next });
  });
  GM_registerMenuCommand('Stop recording now', () => post('/stop', { code: state.code }, () => notify('Wysłano stop.')));
  GM_registerMenuCommand('Debug: toggle logging', () => {
    const next = !debug();
    GM_setValue('debug', next);
    notify('Debug ' + (next ? 'on' : 'off') + ' (konsola przeglądarki, prefiks [meet-rec]).');
    if (next) dumpButtons('debug on');
  });
  GM_registerMenuCommand('Debug: log buttons', () => dumpButtons('menu'));

  setInterval(poll, 1000);
  poll();
})();
