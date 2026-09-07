/*
 * pick-payload.js — the ONE injected picker source.
 *
 * WHY ONE FILE. Tiers 3 and 4 inject the same overlay for the same reason (neither Kapture
 * nor claude-in-chrome exposes Overlay.setInspectMode, so Chrome's own picker is out of
 * reach), but they inject it differently: Kapture blocks on a Promise, claude-in-chrome
 * cannot. Two copies of a picker would drift the moment one of them is fixed. So there is
 * one body function here and two wrappers that stringify it.
 *
 * CommonJS on purpose: this file is `node --check`ed by checks.<system>.page-lab and read
 * as text by the agent; it is never imported by the .mjs scripts.
 *
 * Three constraints shape the body, and every one of them is a measurement:
 *
 *   1. All state hangs off `window`. claude-in-chrome wraps source in a `{ … }` block with
 *      replMode:true, so a top-level `let`/`const` is gone by the next call [F-CIC-REPLMODE].
 *   2. Capture-phase preventDefault on the click. Clicking an <a> must not navigate: a
 *      same-call navigation makes claude-in-chrome fail the post-execution origin re-check
 *      and return "Security check failed" instead of the pick [F-CIC-ORIGIN-RECHECK].
 *   3. Every emitted string is wrapped in << >> sentinels, and the keys are short and
 *      boring. claude-in-chrome SILENTLY replaces values that look like credentials — and
 *      an unwrapped class chain such as `div.card.active` matches its JWT regex exactly,
 *      while a key named `author` trips its /auth/i key rule [F-CIC-SANITIZER]. The
 *      sentinels break the anchors; pick-normalize.mjs strips them agent-side.
 *
 * RAW output shape (NOT an envelope — pick-normalize.mjs is the only thing that builds one):
 *
 *   hit:       { st:'<<hit>>', sel:'<<html > body:nth-of-type(1) > …>>', tag:'<<div>>',
 *                x:12, y:48, w:320, h:64, txt:'<<Some visible text>>' }
 *   not yet:   { st:'<<armed>>' } | { st:'<<cancelled>>' } | { st:'<<timeout>>' }
 *                                 | { st:'<<absent>>' } | { st:'<<disarmed>>' }
 *   arm call:  { canary: { a, b, c, d } }   — see CANARY below
 */

'use strict';

/*
 * Self-contained by construction: this function is stringified and injected, so it may not
 * close over anything in this module.
 */
function pageLabPickerBody(opts) {
  var o = opts || {};
  var TIMEOUT = o.timeoutMs || 45000;
  var KEY = '__pageLabPick';
  var W = window;

  // Re-arming over a live picker would leave two overlays and two click handlers.
  if (W[KEY] && typeof W[KEY].disarm === 'function') W[KEY].disarm();

  function wrap(s) {
    return '<<' + String(s === null || s === undefined ? '' : s) + '>>';
  }

  // = with ; or & is claude-in-chrome's cookie/query-string signature, and page text is
  // full of both [F-CIC-SANITIZER].
  function safeText(el) {
    var t = (el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 80);
    return t.replace(/[=;&]/g, ' ').trim();
  }

  // nth-of-type PATH only: positional, verifiable against the live DOM, and its spaces and
  // > cannot match the sanitizer's anchored regexes the way a class chain can.
  function pathOf(el) {
    var parts = [];
    var n = el;
    while (n && n.nodeType === 1 && n !== document.documentElement) {
      var i = 1;
      var sib = n;
      while ((sib = sib.previousElementSibling)) {
        if (sib.tagName === n.tagName) i++;
      }
      parts.unshift(n.tagName.toLowerCase() + ':nth-of-type(' + i + ')');
      n = n.parentElement;
    }
    parts.unshift('html');
    return parts.join(' > ');
  }

  function measure(el) {
    var r = el.getBoundingClientRect();
    return {
      st: wrap('hit'),
      sel: wrap(pathOf(el)),
      tag: wrap(el.tagName.toLowerCase()),
      x: Math.round(r.left),
      y: Math.round(r.top),
      w: Math.round(r.width),
      h: Math.round(r.height),
      txt: wrap(safeText(el))
    };
  }

  var box = document.createElement('div');
  box.setAttribute(
    'style',
    'position:fixed;left:0;top:0;width:0;height:0;pointer-events:none;' +
      'z-index:2147483647;border:2px solid #e11d48;background:rgba(225,29,72,0.12)'
  );

  var state = { st: 'armed', hit: null, done: null, disarm: null };
  var settle = null;
  state.done = new Promise(function (resolve) {
    settle = resolve;
  });

  var live = true;
  var timer = null;

  function onMove(e) {
    var t = e.target;
    if (!t || t.nodeType !== 1 || t === box) return;
    var r = t.getBoundingClientRect();
    box.style.left = r.left + 'px';
    box.style.top = r.top + 'px';
    box.style.width = r.width + 'px';
    box.style.height = r.height + 'px';
  }

  // mousedown/pointerdown are swallowed too: plenty of SPAs navigate on mousedown, and a
  // navigation ends the call before the pick can be returned.
  function swallow(e) {
    e.preventDefault();
    e.stopPropagation();
    if (e.stopImmediatePropagation) e.stopImmediatePropagation();
  }

  function onClick(e) {
    swallow(e);
    var el = e.target;
    if (!el || el.nodeType !== 1) return;
    state.hit = measure(el);
    state.st = 'hit';
    disarm();
    if (settle) settle(state.hit);
  }

  function onKey(e) {
    if (e.key !== 'Escape') return;
    swallow(e);
    state.st = 'cancelled';
    disarm();
    if (settle) settle({ st: wrap('cancelled') });
  }

  // Idempotent, and reachable from outside as window.__pageLabPick.disarm(). state.hit
  // deliberately SURVIVES it, so a late poll still retrieves the pick.
  function disarm() {
    if (!live) return;
    live = false;
    if (timer) clearTimeout(timer);
    document.removeEventListener('mousemove', onMove, true);
    document.removeEventListener('mousedown', swallow, true);
    document.removeEventListener('pointerdown', swallow, true);
    document.removeEventListener('click', onClick, true);
    document.removeEventListener('keydown', onKey, true);
    if (box.parentNode) box.parentNode.removeChild(box);
  }
  state.disarm = disarm;

  timer = setTimeout(function () {
    if (state.st === 'armed') state.st = 'timeout';
    disarm();
    if (settle) settle({ st: wrap(state.st) });
  }, TIMEOUT);

  document.addEventListener('mousemove', onMove, true);
  document.addEventListener('mousedown', swallow, true);
  document.addEventListener('pointerdown', swallow, true);
  document.addEventListener('click', onClick, true);
  document.addEventListener('keydown', onKey, true);
  (document.body || document.documentElement).appendChild(box);

  W[KEY] = state;
  return state;
}

var BODY = pageLabPickerBody.toString();

/*
 * The drift signal the sanitizer otherwise never gives: it replaces values silently, with
 * no error. Expected back from claude-in-chrome — a: JWT-token block, b: cookie/query-string
 * block, c: intact, d: base64 block. ANY deviation means the rules changed under us:
 * print SANITIZER DRIFT, add sanitizer-drift to shipBlockers, demote to tier 5, re-measure
 * [F-CIC-SANITIZER].
 */
var CANARY = { a: 'div.card.active', b: 'x=1;y=2', c: '<<probe>>', d: 'a'.repeat(40) };

function install(opts) {
  return '(' + BODY + ')(' + JSON.stringify(opts || {}) + ')';
}

/*
 * Wrapper 1 — Kapture (tier 3). evaluate runs with awaitPromise:true, so returning the
 * picker's promise makes ONE call block on the human's click. Guarded by
 * [F-UNMEASURED-KAPTURE-AWAIT]: if that measurement fails, tier 3 uses `armed` below in the
 * same ARM/POLL/DISARM shape as tier 4.
 */
function blocking(opts) {
  return install(opts) + '.done';
}

/*
 * Wrapper 2 — claude-in-chrome (tier 4). Three calls, never one: replMode discards top-level
 * bindings between calls and a single evaluation is capped around 40 s [F-CIC-REPLMODE].
 * ARM returns the canary so drift is caught on the first call, not after a bad pick.
 */
function armed(opts) {
  return {
    arm: install(opts) + ' && ({ canary: ' + JSON.stringify(CANARY) + ' })',
    poll:
      '(function(){var s=window.__pageLabPick;' +
      'return s?(s.hit||{st:"<<"+s.st+">>"}):{st:"<<absent>>"};})()',
    disarm:
      '(function(){var s=window.__pageLabPick;if(s&&s.disarm)s.disarm();' +
      'return {st:"<<disarmed>>"};})()'
  };
}

module.exports = {
  pageLabPickerBody: pageLabPickerBody,
  BODY: BODY,
  CANARY: CANARY,
  install: install,
  blocking: blocking,
  armed: armed
};
