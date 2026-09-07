// Raw Chrome DevTools Protocol client, zero npm dependencies.
//
// Custom rather than off-the-shelf because the canonical client is unavailable here:
// chrome-remote-interface means either an unpinned `npx -y` fetch at runtime or a nixpkgs
// attribute that no longer exists [F-CRI-UNAVAILABLE]. Node's built-in WebSocket is the
// standard-library primitive reused instead. Nothing in chrome-devtools-mcp sends an
// arbitrary CDP command at any version, so this side channel is structural, not a stopgap
// [F-NO-CDP-PASSTHROUGH].
//
// Not an entrypoint. Importers: pick-element.mjs, pick-watchdog.mjs, selector-verify.mjs.

import { spawnSync } from 'node:child_process';

/** Exit code for a Node runtime that cannot speak WebSocket even after the re-exec. */
export const EXIT_UNSUPPORTED_NODE = 7;

const REEXEC_ENV = 'PAGE_LAB_CDP_WS_REEXEC';

// The fleet's default Node (v20) has no global WebSocket; --experimental-websocket supplies
// one and Node 22+ has it unflagged [F-NODE-NO-WS]. Re-exec ourselves once so the plugin
// works on both without the caller knowing which Node they have. execArgv carries `-e` and
// its source for `node -e` callers, so replaying it verbatim reconstructs either invocation.
if (typeof WebSocket === 'undefined') {
  const alreadyTried =
    process.env[REEXEC_ENV] === '1' || process.execArgv.includes('--experimental-websocket');
  if (alreadyTried) {
    process.stderr.write(
      'page-lab: this Node has no WebSocket even with --experimental-websocket. ' +
        'Run via the `page-lab-pick` wrapper (pins nodejs_22) or a Node 22+ on PATH.\n',
    );
    process.exit(EXIT_UNSUPPORTED_NODE);
  }
  const child = spawnSync(
    process.execPath,
    ['--experimental-websocket', ...process.execArgv, ...process.argv.slice(1)],
    { stdio: 'inherit', env: { ...process.env, [REEXEC_ENV]: '1' } },
  );
  process.exit(child.status === null ? 1 : child.status);
}

/**
 * The one highlight config. Passed on BOTH arm and disarm: setInspectMode({mode:'none'})
 * rejects without it, and a disarm that throws leaves the tab armed [F-DISARM-HIGHLIGHTCONFIG].
 */
export const HIGHLIGHT_CONFIG = Object.freeze({
  showInfo: true,
  showStyles: false,
  showRulers: false,
  showExtensionLines: false,
  contentColor: { r: 111, g: 168, b: 220, a: 0.66 },
  paddingColor: { r: 147, g: 196, b: 125, a: 0.55 },
  borderColor: { r: 255, g: 229, b: 153, a: 0.66 },
  marginColor: { r: 246, g: 178, b: 107, a: 0.66 },
});

async function httpJson(url, timeoutMs) {
  const res = await fetch(url, { signal: AbortSignal.timeout(timeoutMs) });
  if (!res.ok) throw new Error(`cdp: ${url} answered HTTP ${res.status}`);
  return res.json();
}

/** GET /json/version on a debug browser → its browser-level webSocketDebuggerUrl. */
export async function browserSocket(browserUrl, { timeout = 5000 } = {}) {
  const base = String(browserUrl).replace(/\/+$/, '');
  let json;
  try {
    json = await httpJson(`${base}/json/version`, timeout);
  } catch (err) {
    throw new Error(
      `cdp: nothing answered ${base}/json/version (${err?.message || err}) — ` +
        'open the gate with scripts/route-up.sh --tier 1 --yes',
    );
  }
  if (!json?.webSocketDebuggerUrl) {
    throw new Error(`cdp: ${base}/json/version carries no webSocketDebuggerUrl`);
  }
  return json.webSocketDebuggerUrl;
}

/**
 * Open one browser-level socket. Every target rides it via flat sessions, so a single
 * connection serves every tab.
 *
 * @returns {Promise<{send:Function,on:Function,close:Function,closed:boolean}>}
 */
export async function connect(wsUrl, { openTimeout = 10000, timeout = 30000 } = {}) {
  const ws = new WebSocket(wsUrl);
  const pending = new Map();
  const handlers = new Set();
  let nextId = 1;
  let closedReason = null;

  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      off();
      try {
        ws.close();
      } catch {
        /* the socket never opened; nothing to close */
      }
      reject(new Error(`cdp: timed out opening ${wsUrl}`));
    }, openTimeout);
    const onOpen = () => {
      off();
      resolve();
    };
    const onError = () => {
      off();
      reject(new Error(`cdp: cannot open ${wsUrl}`));
    };
    function off() {
      clearTimeout(timer);
      ws.removeEventListener('open', onOpen);
      ws.removeEventListener('error', onError);
    }
    ws.addEventListener('open', onOpen);
    ws.addEventListener('error', onError);
  });

  ws.addEventListener('message', (event) => {
    let msg;
    try {
      msg = JSON.parse(typeof event.data === 'string' ? event.data : String(event.data));
    } catch {
      return; // a frame we cannot parse is not a response we can correlate
    }
    if (msg.id !== undefined && pending.has(msg.id)) {
      const slot = pending.get(msg.id);
      pending.delete(msg.id);
      clearTimeout(slot.timer);
      if (msg.error) {
        const err = new Error(`cdp: ${slot.method} → ${msg.error.message}`);
        err.cdp = msg.error;
        err.method = slot.method;
        slot.reject(err);
      } else {
        slot.resolve(msg.result ?? {});
      }
      return;
    }
    if (!msg.method) return;
    for (const h of handlers) {
      if (h.method !== msg.method) continue;
      if (h.sessionId !== undefined && h.sessionId !== msg.sessionId) continue;
      try {
        h.fn(msg.params ?? {}, msg.sessionId);
      } catch (err) {
        process.stderr.write(`[cdp] handler for ${msg.method} threw: ${err?.message || err}\n`);
      }
    }
  });

  const fail = (reason) => {
    closedReason = reason;
    for (const [id, slot] of pending) {
      pending.delete(id);
      clearTimeout(slot.timer);
      slot.reject(new Error(`cdp: ${slot.method} lost — ${reason}`));
    }
  };
  ws.addEventListener('close', () => fail('socket closed'));
  ws.addEventListener('error', () => fail('socket error'));

  return {
    get closed() {
      return closedReason !== null || ws.readyState > 1;
    },
    send(method, params = {}, sessionId, opts = {}) {
      if (closedReason) return Promise.reject(new Error(`cdp: ${method} on a ${closedReason}`));
      const id = nextId++;
      const frame = { id, method, params };
      if (sessionId) frame.sessionId = sessionId;
      return new Promise((resolve, reject) => {
        const ms = opts.timeout ?? timeout;
        const timer = setTimeout(() => {
          pending.delete(id);
          reject(new Error(`cdp: ${method} did not answer in ${ms}ms`));
        }, ms);
        pending.set(id, { resolve, reject, timer, method });
        try {
          ws.send(JSON.stringify(frame));
        } catch (err) {
          pending.delete(id);
          clearTimeout(timer);
          reject(err);
        }
      });
    },
    /** Subscribe to a CDP event; returns an unsubscribe function. */
    on(event, fn, sessionId) {
      const h = { method: event, fn, sessionId };
      handlers.add(h);
      return () => handlers.delete(h);
    },
    close() {
      try {
        ws.close();
      } catch {
        /* already gone */
      }
      fail('socket closed');
    },
  };
}

/**
 * Page targets only, devtools:// dropped. /json/list returned 13 targets of which 3 were
 * pages on the measured machine [F-TARGETS-13-3].
 */
export async function pageTargets(client) {
  const { targetInfos = [] } = await client.send('Target.getTargets');
  return targetInfos.filter(
    (t) => t.type === 'page' && !String(t.url || '').startsWith('devtools://'),
  );
}

/** Flat-session attach: one socket, many targets. */
export async function attach(client, targetId) {
  const { sessionId } = await client.send('Target.attachToTarget', { targetId, flatten: true });
  return sessionId;
}

/**
 * Enable domains in the only order that works: a method that "returns nothing" is almost
 * always a missing enable, and CSS and Overlay both depend on DOM having a document.
 */
export async function enableInOrder(client, sessionId, domains = ['DOM']) {
  const want = new Set(domains);
  await client.send('DOM.enable', {}, sessionId);
  const { root } = await client.send('DOM.getDocument', { depth: 0 }, sessionId);
  if (want.has('CSS')) await client.send('CSS.enable', {}, sessionId);
  if (want.has('Overlay')) await client.send('Overlay.enable', {}, sessionId);
  return { rootNodeId: root?.nodeId, documentURL: root?.documentURL, baseURL: root?.baseURL };
}

async function runClears(clears) {
  let failed = 0;
  // Reverse order so sockets registered first are closed last, and EVERY clear is guarded
  // on its own — one try/catch around the loop is the bug that leaves every tab armed
  // [F-DISARM-HIGHLIGHTCONFIG].
  for (const entry of [...clears].reverse()) {
    const name = typeof entry === 'function' ? 'clear' : entry?.name || 'clear';
    const run = typeof entry === 'function' ? entry : entry?.run;
    if (typeof run !== 'function') continue;
    try {
      await run();
    } catch (err) {
      failed += 1;
      process.stderr.write(`[cleanup] FAILED ${name}: ${err?.message || err}\n`);
    }
  }
  clears.length = 0; // idempotent: a second settle must not re-run what already ran
  return failed;
}

/**
 * Run fn with a teardown that is guaranteed on return, throw, SIGINT, SIGTERM and
 * uncaughtException. `clears` is passed to fn so it can register each clear the moment the
 * thing needing it exists, not after the whole loop.
 *
 * @param {(clears:Array)=>Promise<any>} fn
 * @param {Array<{name:string,run:Function}|Function>} clears
 * @param {{cancelExitCode?:number,errorExitCode?:number,cleanupFailExitCode?:number|null}} opts
 */
export async function withCleanup(fn, clears = [], opts = {}) {
  const { cancelExitCode = 130, errorExitCode = 1, cleanupFailExitCode = null } = opts;
  let settling = false;

  const settleAndExit = async (code, why) => {
    if (settling) return;
    settling = true;
    if (why) process.stderr.write(`\n[cleanup] ${why} — tearing down\n`);
    const failed = await runClears(clears);
    process.exit(failed > 0 && cleanupFailExitCode != null ? cleanupFailExitCode : code);
  };

  const onSigint = () => void settleAndExit(cancelExitCode, 'SIGINT');
  const onSigterm = () => void settleAndExit(cancelExitCode, 'SIGTERM');
  const onFatal = (err) => {
    process.stderr.write(`[cleanup] fatal: ${err?.stack || err}\n`);
    void settleAndExit(errorExitCode, 'uncaught error');
  };

  process.on('SIGINT', onSigint);
  process.on('SIGTERM', onSigterm);
  process.on('uncaughtException', onFatal);
  process.on('unhandledRejection', onFatal);

  try {
    const value = await fn(clears);
    const failed = await runClears(clears);
    if (failed > 0 && cleanupFailExitCode != null) {
      process.stderr.write(`[cleanup] ${failed} clear(s) failed — tabs may still be armed\n`);
      process.exit(cleanupFailExitCode);
    }
    return value;
  } catch (err) {
    await runClears(clears);
    throw err;
  } finally {
    process.off('SIGINT', onSigint);
    process.off('SIGTERM', onSigterm);
    process.off('uncaughtException', onFatal);
    process.off('unhandledRejection', onFatal);
  }
}

/**
 * Disarm one target, both halves, each awaited. Overlay state is sticky and shared with
 * every CDP client including the operator's own DevTools [F-STICKY-STATE], so every override
 * ships paired with its clear. Idempotent: the watchdog and the picker may both run it.
 */
export async function disarmTarget(client, sessionId) {
  await client.send('Overlay.setInspectMode', {
    mode: 'none',
    highlightConfig: HIGHLIGHT_CONFIG,
  }, sessionId);
  await client.send('Overlay.hideHighlight', {}, sessionId);
}
