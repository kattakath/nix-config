// Tier 1 picker: arm Chrome's OWN inspect mode over CDP and let the operator point.
//
// The agent does not build a picker. Overlay.setInspectMode({mode:'searchForNode'}) works
// from a plain CDP client with no DevTools window, and Overlay.inspectNodeRequested carries
// the clicked backendNodeId [F-INSPECTMODE-WORKS]. $0 is not usable for this
// [F-DOLLAR-ZERO-DEAD].
//
// stdout: exactly one page-lab/pick@1 object. stderr: everything a human reads.

import { execFileSync, spawn } from 'node:child_process';
import { existsSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  HIGHLIGHT_CONFIG,
  attach,
  browserSocket,
  connect,
  disarmTarget,
  enableInOrder,
  pageTargets,
  withCleanup,
} from './lib/cdp.mjs';
import { build, formatErrors, splitClasses, validate } from './lib/envelope.mjs';

const EXIT = { OK: 0, TIMEOUT: 2, ORIGIN: 3, CANCELLED: 4, NO_ROUTE: 5, DISARM_FAILED: 6 };

const STAMP = join(tmpdir(), 'page-lab-pick.arm.json');

// One constant, because promoting it is a one-line change: Escape is UNVERIFIED from a
// non-DevTools client [F-UNMEASURED-ESC], so this promises Ctrl-C only.
const operatorPrompt = (tabs, ms) =>
  `ARMED on ${tabs} tab(s). Click the element you mean in the browser. ` +
  `Ctrl-C here cancels and disarms. ${Math.round(ms / 1000)}s timeout.`;

const HELP = `Usage: pick-element.mjs [options]

  --browser-url <url>     debug browser (default http://127.0.0.1:9222)
  --timeout <ms>          hard deadline for the click (default 45000)
  --expect-origin <o>     refuse a pick from any other origin
  --focus-delay <ms>      pause after raising the browser (default 800)
  --json                  one compact line on stdout instead of pretty JSON
  --no-raise              do not raise the browser before arming
  --no-confirm            skip the 1.2s highlight confirm-back
  --disarm-only           clear inspect mode everywhere and exit
  -h, --help              this text

stdout is exactly one page-lab/pick@1 object; every diagnostic goes to stderr.

Exit: 0 picked · 2 timeout or no usable pick · 3 origin mismatch · 4 cancelled
      5 no route / no page targets · 6 disarm failed or self-invalid envelope
      7 this Node cannot speak WebSocket (use the page-lab-pick wrapper)

An armed picker swallows the next click on EVERY armed tab. If a run is lost, recover with
  pick-element.mjs --disarm-only
`;

function parseArgs(argv) {
  const o = {
    browserUrl: 'http://127.0.0.1:9222',
    timeout: 45000,
    focusDelay: 800,
    expectOrigin: null,
    json: false,
    raise: true,
    confirm: true,
    disarmOnly: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    const next = () => {
      const v = argv[++i];
      if (v === undefined) throw new Error(`${a} needs a value`);
      return v;
    };
    if (a === '-h' || a === '--help') o.help = true;
    else if (a === '--browser-url') o.browserUrl = next();
    else if (a === '--timeout') o.timeout = Number(next());
    else if (a === '--focus-delay') o.focusDelay = Number(next());
    else if (a === '--expect-origin') o.expectOrigin = next();
    else if (a === '--json') o.json = true;
    else if (a === '--no-raise') o.raise = false;
    else if (a === '--no-confirm') o.confirm = false;
    else if (a === '--disarm-only') o.disarmOnly = true;
    else throw new Error(`unknown option ${a}`);
  }
  if (!Number.isFinite(o.timeout) || o.timeout <= 0) throw new Error('--timeout must be ms > 0');
  return o;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const err = (s) => process.stderr.write(`${s}\n`);

class Failure extends Error {
  constructor(message, exitCode) {
    super(message);
    this.exitCode = exitCode;
  }
}

// ---------------------------------------------------------------------------
// browser process helpers — identify by the running process path, never by the
// /json/version Browser string, which carries no vendor on this build [F-UGC-NO-VENDOR].
// ---------------------------------------------------------------------------

function debugBrowserBundle() {
  try {
    const out = execFileSync('/usr/bin/pgrep', ['-fl', '--', '--remote-debugging-port'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    for (const line of out.split('\n')) {
      const m = line.match(/(\/[^\s]*?\.app)\//);
      if (m) return m[1];
    }
  } catch {
    // pgrep exits 1 when nothing matches; that is an answer, not an error
  }
  return null;
}

async function raiseBrowser(delayMs) {
  if (process.platform !== 'darwin') return;
  const bundle = debugBrowserBundle();
  if (!bundle) return;
  try {
    execFileSync('/usr/bin/open', [bundle], { stdio: 'ignore' });
    await sleep(delayMs);
  } catch {
    err('[pick] could not raise the browser; bring it forward yourself before clicking');
  }
}

// ---------------------------------------------------------------------------
// pierced-tree index
// ---------------------------------------------------------------------------

function indexTree(root) {
  const byBackend = new Map();
  const byNode = new Map();
  const parentOf = new Map();
  const scopeOf = new Map();

  const walk = (node, parentId, ctx) => {
    byNode.set(node.nodeId, node);
    if (node.backendNodeId) byBackend.set(node.backendNodeId, node);
    parentOf.set(node.nodeId, parentId);
    scopeOf.set(node.nodeId, ctx);
    for (const child of node.children ?? []) walk(child, node.nodeId, ctx);
    for (const sr of node.shadowRoots ?? []) {
      walk(sr, node.nodeId, { ...ctx, inShadow: true, shadowHost: node.nodeId, scope: sr.nodeId });
    }
    if (node.contentDocument) {
      const cd = node.contentDocument;
      // A frame document is a fresh tree: shadow context does not carry across it.
      walk(cd, node.nodeId, {
        inShadow: false,
        inFrame: true,
        frameUrl: cd.documentURL,
        shadowHost: undefined,
        scope: cd.nodeId,
      });
    }
    if (node.templateContent) walk(node.templateContent, node.nodeId, ctx);
  };

  walk(root, null, { inShadow: false, inFrame: false, scope: root.nodeId });
  return { byBackend, byNode, parentOf, scopeOf };
}

const tagOf = (node) => String(node?.localName || node?.nodeName || '').toLowerCase();

function segmentFor(node, parent) {
  const tag = tagOf(node);
  const sibs = (parent?.children ?? []).filter((n) => n.nodeType === 1 && tagOf(n) === tag);
  if (sibs.length <= 1) return tag;
  const idx = sibs.findIndex((n) => n.nodeId === node.nodeId) + 1;
  return idx > 0 ? `${tag}:nth-of-type(${idx})` : tag;
}

// nth-of-type paths only: positional, verifiable, and immune to the claude-in-chrome
// sanitizer's anchored regexes, which eat a class chain like div.card.active [F-CIC-SANITIZER].
function pathFrom(tree, scopeRootId, nodeId) {
  const parts = [];
  let cur = nodeId;
  while (cur != null && cur !== scopeRootId) {
    const node = tree.byNode.get(cur);
    if (!node || node.nodeType !== 1) break;
    const parentId = tree.parentOf.get(cur);
    parts.unshift(segmentFor(node, parentId != null ? tree.byNode.get(parentId) : null));
    cur = parentId;
  }
  return parts.join(' > ');
}

function attrsOf(node) {
  const flat = node?.attributes ?? [];
  const out = {};
  for (let i = 0; i + 1 < flat.length; i += 2) out[flat[i]] = flat[i + 1];
  return out;
}

const cssQuote = (v) => `"${String(v).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
const isPlainIdent = (v) => /^[A-Za-z_-][A-Za-z0-9_-]*$/.test(v);

function textFromHtml(html) {
  return String(html)
    .replace(/<(script|style)\b[\s\S]*?<\/\1>/gi, ' ')
    .replace(/<[^>]*>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 200);
}

function candidateSelectors(tag, attrs, classes, path) {
  const out = [];
  const id = attrs.id;
  // A kapture-N id is real and unique and evaporates on reload — never mint it into a
  // candidate [F-KAPTURE-MUTATES].
  if (id && !/^kapture-\d+$/.test(id)) {
    out.push(isPlainIdent(id) ? `#${id}` : `${tag}[id=${cssQuote(id)}]`);
  }
  for (const key of ['data-testid', 'data-test-id', 'data-qa', 'data-cy', 'name']) {
    if (attrs[key]) out.push(`${tag}[${key}=${cssQuote(attrs[key])}]`);
  }
  const dataAttr = Object.keys(attrs).find((k) => k.startsWith('data-') && attrs[k]);
  if (dataAttr) out.push(`${tag}[${dataAttr}=${cssQuote(attrs[dataAttr])}]`);
  if (attrs['aria-label']) out.push(`${tag}[aria-label=${cssQuote(attrs['aria-label'])}]`);
  if (attrs.role) out.push(`${tag}[role=${cssQuote(attrs.role)}]`);
  if (path) out.push(path);
  if (classes.stable.length) out.push(`${tag}${classes.stable.slice(0, 2).map((c) => `.${c}`).join('')}`);
  const tail = path.split(' > ').slice(-3).join(' > ');
  if (tail && tail !== path) out.push(tail);
  return [...new Set(out)].slice(0, 8);
}

// ---------------------------------------------------------------------------
// modes
// ---------------------------------------------------------------------------

function readStamp() {
  try {
    return JSON.parse(readFileSync(STAMP, 'utf8'));
  } catch {
    return null;
  }
}

function removeStamp() {
  try {
    unlinkSync(STAMP);
  } catch {
    // already gone
  }
}

async function disarmOnly(opts) {
  const stamp = readStamp();
  const browserUrl = stamp?.browserUrl || opts.browserUrl;
  let client;
  try {
    client = await connect(await browserSocket(browserUrl));
  } catch (e) {
    err(`[disarm] no debug browser at ${browserUrl} (${e.message}) — nothing left armed`);
    removeStamp();
    return EXIT.OK;
  }
  let failed = 0;
  try {
    const targets = await pageTargets(client);
    const wanted = stamp?.targetIds?.length
      ? targets.filter((t) => stamp.targetIds.includes(t.targetId))
      : targets;
    // A blind sweep of every page target is the recovery when the stamp is gone: an armed
    // picker swallows the next click on every armed tab [F-ARMED-SWALLOWS].
    for (const t of wanted.length ? wanted : targets) {
      try {
        const sessionId = await attach(client, t.targetId);
        await enableInOrder(client, sessionId, ['DOM', 'Overlay']);
        await disarmTarget(client, sessionId);
        err(`[disarm] cleared ${t.targetId}`);
      } catch (e) {
        failed += 1;
        err(`[disarm] FAILED ${t.targetId}: ${e.message}`);
      }
    }
  } finally {
    client.close();
  }
  removeStamp();
  return failed ? EXIT.DISARM_FAILED : EXIT.OK;
}

async function pick(opts) {
  let client;
  try {
    client = await connect(await browserSocket(opts.browserUrl));
  } catch (e) {
    // A dead port is a dark gate, not a crash: route-up.sh is the named way to open it.
    throw new Failure(e.message, EXIT.NO_ROUTE);
  }
  const targets = await pageTargets(client);
  if (!targets.length) {
    client.close();
    throw new Failure(`no page targets on ${opts.browserUrl}`, EXIT.NO_ROUTE);
  }

  return withCleanup(
    async (clears) => {
      clears.push({ name: 'close socket', run: () => client.close() });

      // Raise the browser first, or the operator's app-switching click IS the pick.
      if (opts.raise) await raiseBrowser(opts.focusDelay);

      const deadlineAt = Date.now() + opts.timeout;
      writeFileSync(
        STAMP,
        JSON.stringify({
          pid: process.pid,
          browserUrl: opts.browserUrl,
          targetIds: targets.map((t) => t.targetId),
          armedAt: new Date().toISOString(),
          deadlineAt,
        }),
      );
      clears.push({ name: 'remove arm stamp', run: () => removeStamp() });

      // The deadman: the only timeout must not live in the process whose death strands the arm.
      const wsFlag = process.execArgv.includes('--experimental-websocket')
        ? ['--experimental-websocket']
        : [];
      const watchdog = spawn(
        process.execPath,
        [
          ...wsFlag,
          fileURLToPath(new URL('./pick-watchdog.mjs', import.meta.url)),
          '--stamp',
          STAMP,
          '--parent',
          String(process.pid),
          '--deadline',
          String(deadlineAt),
        ],
        { detached: true, stdio: 'ignore' },
      );
      watchdog.unref();
      clears.push({
        name: 'stop watchdog',
        run: () => {
          try {
            process.kill(watchdog.pid, 'SIGTERM');
          } catch {
            // already exited
          }
        },
      });

      const armed = [];
      for (const target of targets) {
        const sessionId = await attach(client, target.targetId);
        await enableInOrder(client, sessionId, ['DOM', 'Overlay']);
        const entry = {
          name: `disarm ${target.targetId}`,
          done: false,
          run: async () => {
            if (entry.done) return;
            await disarmTarget(client, sessionId);
            entry.done = true;
          },
        };
        await client.send(
          'Overlay.setInspectMode',
          { mode: 'searchForNode', highlightConfig: HIGHLIGHT_CONFIG },
          sessionId,
        );
        clears.push(entry); // registered only once armed, so nothing clears what never armed
        armed.push({ target, sessionId, entry });
      }

      err(operatorPrompt(armed.length, opts.timeout));

      const hit = await new Promise((resolve, reject) => {
        let settled = false;
        const timer = setTimeout(
          () => reject(new Failure(`no click within ${opts.timeout}ms`, EXIT.TIMEOUT)),
          opts.timeout,
        );
        for (const a of armed) {
          client.on(
            'Overlay.inspectNodeRequested',
            (params) => {
              if (settled) return;
              settled = true;
              clearTimeout(timer);
              resolve({ ...a, backendNodeId: params.backendNodeId });
            },
            a.sessionId,
          );
        }
      });

      // Disarm every tab the moment the pick arrives, so no second tab eats a click and the
      // armed window does not span the measurement. A failure here is not swallowed: the
      // entry stays undone, the finally retries it, and a second failure exits 6.
      for (const a of armed) {
        try {
          await a.entry.run();
        } catch (e) {
          err(`[pick] disarm failed for ${a.target.targetId}: ${e.message}`);
        }
      }

      const { sessionId } = hit;
      const info = await client
        .send('Target.getTargetInfo', { targetId: hit.target.targetId })
        .then((r) => r.targetInfo)
        .catch(() => hit.target);
      const url = info?.url || hit.target.url || '';

      if (opts.expectOrigin) {
        const seen = safeOrigin(url);
        const want = safeOrigin(opts.expectOrigin);
        if (seen !== want) {
          err(`[pick] ORIGIN MISMATCH: clicked ${seen}, expected ${want} — no selector emitted`);
          emit(
            build({
              status: 'origin-mismatch',
              route: 'cdp-overlay',
              fidelity: 'verified',
              url,
              originVerified: false,
              expectedOrigin: opts.expectOrigin,
              notes: [`clicked origin ${seen} is not ${want}`],
            }),
            opts,
          );
          throw new Failure('origin mismatch', EXIT.ORIGIN);
        }
      }

      // Pierce FIRST, then push: a later DOM.getDocument re-keys the tree, and nodeIds are
      // ephemeral by contract [F-NODEID-EPHEMERAL].
      const { root } = await client.send('DOM.getDocument', { depth: -1, pierce: true }, sessionId);
      const tree = indexTree(root);

      const { nodeIds = [] } = await client.send(
        'DOM.pushNodesByBackendIdsToFrontend',
        { backendNodeIds: [hit.backendNodeId] },
        sessionId,
      );
      const nodeId = nodeIds[0];
      if (!nodeId) throw new Failure('could not resolve the clicked node', EXIT.TIMEOUT);

      const described = await client
        .send('DOM.describeNode', { nodeId }, sessionId)
        .then((r) => r.node)
        .catch(() => null);
      const indexed = tree.byBackend.get(hit.backendNodeId) ?? tree.byNode.get(nodeId) ?? described;
      const node = indexed ?? described;
      if (!node) throw new Failure('the clicked node vanished before it could be read', EXIT.TIMEOUT);

      const ctx = tree.scopeOf.get(node.nodeId) ?? { scope: root.nodeId };
      const reachability = ctx.inShadow
        ? ctx.inFrame
          ? 'shadow-in-frame'
          : 'shadow'
        : ctx.inFrame
          ? 'frame'
          : 'document';
      const scopeRootId = ctx.scope ?? root.nodeId;
      const shadowHostPath = ctx.shadowHost
        ? pathFrom(tree, tree.scopeOf.get(ctx.shadowHost)?.scope ?? root.nodeId, ctx.shadowHost)
        : undefined;
      const rootLabel =
        reachability === 'document'
          ? 'document'
          : [ctx.frameUrl, shadowHostPath].filter(Boolean).join(' :: ') || 'document';

      const attrs = attrsOf(node);
      const classList = String(attrs.class || '').split(/\s+/).filter(Boolean);
      const classes = splitClasses(classList);
      const tag = tagOf(node);
      const path = pathFrom(tree, scopeRootId, node.nodeId);

      const box = await client
        .send('DOM.getBoxModel', { nodeId }, sessionId)
        .then((r) => r.model)
        .catch(() => null);
      const boxes = box ? [box.content, box.padding, box.border, box.margin].filter(Boolean) : [];
      const rect = box
        ? {
            x: Math.min(box.content[0], box.content[2], box.content[4], box.content[6]),
            y: Math.min(box.content[1], box.content[3], box.content[5], box.content[7]),
            w: box.width,
            h: box.height,
          }
        : undefined;

      // Serialized markup is read locally to name the element for the operator and is never
      // emitted: no envelope field carries page markup.
      const text = await client
        .send('DOM.getOuterHTML', { nodeId }, sessionId)
        .then((r) => textFromHtml(r.outerHTML))
        .catch(() => undefined);

      const notes = [];
      const candidates = [];
      for (const sel of candidateSelectors(tag, attrs, classes, path)) {
        try {
          const res = await client.send(
            'DOM.querySelectorAll',
            { nodeId: scopeRootId, selector: sel },
            sessionId,
          );
          candidates.push({ sel, matches: res.nodeIds?.length ?? 0, root: rootLabel });
        } catch (e) {
          notes.push(`candidate rejected by the engine: ${sel} (${e.cdp?.message || e.message})`);
        }
        if (candidates.length >= 6) break;
      }
      if (!candidates.length) {
        err('[pick] no candidate selector survived scoring');
        emit(
          build({
            status: 'no-pick',
            route: 'cdp-overlay',
            fidelity: 'verified',
            url,
            originVerified: Boolean(opts.expectOrigin),
            notes: notes.length ? notes : ['no candidate selector could be scored'],
          }),
          opts,
        );
        throw new Failure('no scorable candidate', EXIT.TIMEOUT);
      }
      candidates.sort((a, b) => Number(a.matches !== 1) - Number(b.matches !== 1));
      if (classes.generated.length) {
        notes.push(`generated-looking classes ignored as anchors: ${classes.generated.join(' ')}`);
      }
      if (reachability !== 'document') {
        notes.push(`target is not reachable by document.querySelector (${reachability})`);
      }

      const viewport = await readViewport(client, sessionId);
      const cascade = await readCascade(client, sessionId, nodeId);

      if (opts.confirm) {
        try {
          await client.send(
            'Overlay.highlightNode',
            { highlightConfig: HIGHLIGHT_CONFIG, nodeId },
            sessionId,
          );
          await sleep(1200);
          await client.send('Overlay.hideHighlight', {}, sessionId);
        } catch (e) {
          err(`[pick] confirm-back highlight failed: ${e.message}`);
        }
      }

      const envelope = build({
        status: 'picked',
        route: 'cdp-overlay',
        fidelity: 'verified',
        url,
        originVerified: Boolean(opts.expectOrigin),
        expectedOrigin: opts.expectOrigin ?? undefined,
        pageMutated: false,
        viewport,
        cascade,
        notes,
        target: {
          tag,
          id: attrs.id ?? '',
          classCount: classList.length,
          classes,
          path,
          rect,
          boxes: boxes.length ? boxes : undefined,
          text,
          reachability,
          frameUrl: ctx.frameUrl,
          shadowHostPath,
          selectorSource: 'cdp-scored',
          candidates,
        },
      });

      const { valid, errors } = validate(envelope);
      if (!valid) {
        err('[pick] BUG: the envelope this picker built does not satisfy its own schema:');
        formatErrors(errors).forEach(err);
        throw new Failure('self-invalid envelope', EXIT.DISARM_FAILED);
      }
      emit(envelope, opts);
      err(
        `[pick] ${tag} · ${candidates.filter((c) => c.matches === 1).length}/${candidates.length} ` +
          `unique candidate(s) · shipBlockers: ${envelope.shipBlockers.join(', ') || 'none'}`,
      );
      return EXIT.OK;
    },
    [],
    { cancelExitCode: EXIT.CANCELLED, errorExitCode: 1, cleanupFailExitCode: EXIT.DISARM_FAILED },
  );
}

function safeOrigin(u) {
  try {
    return new URL(u).origin;
  } catch {
    return String(u);
  }
}

function emit(envelope, opts) {
  process.stdout.write(`${JSON.stringify(envelope, null, opts.json ? 0 : 2)}\n`);
}

async function readViewport(client, sessionId) {
  try {
    const m = await client.send('Page.getLayoutMetrics', {}, sessionId);
    const css = m.cssLayoutViewport;
    const dev = m.layoutViewport;
    if (!css?.clientWidth || !dev?.clientWidth) return undefined;
    // layoutViewport is device pixels, cssLayoutViewport is CSS pixels, so their ratio IS
    // the device pixel ratio — measured, without running a line of page JS.
    const dpr = Math.round((dev.clientWidth / css.clientWidth) * 100) / 100;
    if (!(dpr > 0.4 && dpr < 8)) return undefined;
    return { innerWidth: css.clientWidth, innerHeight: css.clientHeight, dpr };
  } catch {
    return undefined;
  }
}

async function readCascade(client, sessionId, nodeId) {
  try {
    await client.send('CSS.enable', {}, sessionId);
    const styles = await client.send('CSS.getMatchedStylesForNode', { nodeId }, sessionId);
    const rules = styles.matchedCSSRules ?? [];
    if (!rules.length) return undefined;
    const winner = rules[rules.length - 1]?.rule; // CDP returns weakest-first
    let unlayeredWinner;
    if (Array.isArray(winner?.layers)) unlayeredWinner = winner.layers.length === 0;
    return {
      matchedRuleCount: rules.length,
      winningRuleSelector: winner?.selectorList?.text,
      winningSheet: winner?.origin,
      unlayeredWinner,
      // "Some rule already matching this node uses !important" — the measured reason an
      // override may need it, rather than reaching for it by reflex.
      needsImportant: rules.some((r) => String(r.rule?.style?.cssText || '').includes('!important')),
    };
  } catch {
    return undefined; // CSS.getLayersForNode and friends are experimental: probe, never assume
  }
}

async function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (e) {
    err(`pick-element.mjs: ${e.message}`);
    process.stderr.write(HELP);
    process.exit(1);
  }
  if (opts.help) {
    process.stdout.write(HELP);
    process.exit(0);
  }
  if (opts.disarmOnly) {
    process.exit(await disarmOnly(opts));
  }
  if (existsSync(STAMP)) {
    err(`[pick] a stale arm stamp exists at ${STAMP} — sweeping before arming`);
    await disarmOnly(opts);
  }
  process.exit(await pick(opts));
}

main().catch((e) => {
  err(`pick-element.mjs: ${e.message}`);
  process.exit(e instanceof Failure ? e.exitCode : 1);
});
