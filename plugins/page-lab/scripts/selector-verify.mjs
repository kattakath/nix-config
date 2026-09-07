// Score candidate selectors against the live DOM, with no page JS and no CSP exposure:
// DOM.querySelectorAll asks the engine, so a selector is proven, not plausible.
//
// Two modes, one scorer:
//   list      selectors as arguments or one per line on stdin  → a JSON array of verdicts
//   envelope  a page-lab/pick@1 object on stdin                → the same object with
//             candidates[].matches and candidates[].root filled in
//
// Envelope mode refuses anything but fidelity:"verified": a match count on a sampled or
// asserted envelope is forbidden by the schema, because a missing matches means UNVERIFIED
// and never one.

import { readFileSync } from 'node:fs';

import { attach, browserSocket, connect, enableInOrder, pageTargets } from './lib/cdp.mjs';
import { formatErrors, isGeneratedClass, validate } from './lib/envelope.mjs';

const HELP = `Usage: selector-verify.mjs [options] <selector...>
       selector-verify.mjs [options] -          # selectors on stdin, one per line,
                                                # or one page-lab/pick@1 envelope

  --browser-url <url>     debug browser (default http://127.0.0.1:9222)
  --target-id <id>        page target to query (default: the first page target)
  --root <nodeId>         scoring root, as a nodeId
  --root-selector <css>   scoring root, resolved in this session (nodeIds are ephemeral
                          across processes, so this is usually what you want)
  -h, --help              this text

Verdicts: UNIQUE (1 match) · AMBIGUOUS (>1) · DEAD (0) · GENERATED (leans on a
build-generated class) · INVALID (the engine rejected it) · REJECTED (a \${ template or a
kapture-N selector, neither of which may reach a .user.js).

Exit: 0 at least one UNIQUE · 1 otherwise · 7 this Node cannot speak WebSocket.
`;

function parseArgs(argv) {
  const o = {
    browserUrl: 'http://127.0.0.1:9222',
    targetId: null,
    root: null,
    rootSelector: null,
    stdin: false,
    selectors: [],
  };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '-h' || a === '--help') o.help = true;
    else if (a === '--browser-url') o.browserUrl = argv[++i];
    else if (a === '--target-id') o.targetId = argv[++i];
    else if (a === '--root') o.root = Number(argv[++i]);
    else if (a === '--root-selector') o.rootSelector = argv[++i];
    else if (a === '-') o.stdin = true;
    else if (a.startsWith('--')) throw new Error(`unknown option ${a}`);
    else o.selectors.push(a);
  }
  return o;
}

const err = (s) => process.stderr.write(`${s}\n`);

function readStdin() {
  try {
    return readFileSync(0, 'utf8');
  } catch {
    return '';
  }
}

/** Selectors that must never be scored, because they must never ship. */
function rejectionReason(sel) {
  if (sel.includes('${')) return 'a ${ template selector is untraceable to a measurement';
  if (/kapture-\d/.test(sel)) return 'minted by Kapture — it evaporates on reload';
  return null;
}

function usesGeneratedClass(sel) {
  const classes = [...sel.matchAll(/\.([A-Za-z_-][A-Za-z0-9_-]*)/g)].map((m) => m[1]);
  return classes.filter((c) => isGeneratedClass(c));
}

async function score(client, sessionId, rootNodeId, rootLabel, sel) {
  const rejected = rejectionReason(sel);
  if (rejected) return { sel, root: rootLabel, status: 'REJECTED', reason: rejected };
  let matches;
  try {
    const res = await client.send(
      'DOM.querySelectorAll',
      { nodeId: rootNodeId, selector: sel },
      sessionId,
    );
    matches = res.nodeIds?.length ?? 0;
  } catch (e) {
    return { sel, root: rootLabel, status: 'INVALID', reason: e.cdp?.message || e.message };
  }
  const generated = usesGeneratedClass(sel);
  if (generated.length) {
    return {
      sel,
      matches,
      root: rootLabel,
      status: 'GENERATED',
      reason: `leans on build-generated class(es): ${generated.join(' ')}`,
    };
  }
  const status = matches === 1 ? 'UNIQUE' : matches === 0 ? 'DEAD' : 'AMBIGUOUS';
  return { sel, matches, root: rootLabel, status };
}

async function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (e) {
    err(`selector-verify.mjs: ${e.message}`);
    process.stderr.write(HELP);
    process.exit(1);
  }
  if (opts.help || (!opts.stdin && !opts.selectors.length)) {
    process.stdout.write(HELP);
    process.exit(opts.help ? 0 : 1);
  }

  let envelope = null;
  let selectors = [...opts.selectors];
  if (opts.stdin) {
    const raw = readStdin().trim();
    if (raw.startsWith('{')) {
      let parsed;
      try {
        parsed = JSON.parse(raw);
      } catch (e) {
        err(`selector-verify.mjs: stdin is not JSON (${e.message})`);
        process.exit(1);
      }
      if (parsed.schema !== 'page-lab/pick@1') {
        err('selector-verify.mjs: stdin is JSON but not a page-lab/pick@1 envelope');
        process.exit(1);
      }
      if (parsed.fidelity !== 'verified') {
        err(
          `selector-verify.mjs: refusing to write match counts onto a fidelity:"${parsed.fidelity}" ` +
            'envelope — the schema forbids matches there. Re-pick on the cdp-overlay route.',
        );
        process.exit(1);
      }
      if (
        parsed.target?.reachability &&
        parsed.target.reachability !== 'document' &&
        !opts.rootSelector &&
        !Number.isFinite(opts.root)
      ) {
        // A count taken against the wrong root is worse than no count.
        err(
          `selector-verify.mjs: this envelope's target is reachability:"${parsed.target.reachability}" — ` +
            'name the scoring root with --root-selector (or --root) before re-scoring it.',
        );
        process.exit(1);
      }
      envelope = parsed;
      selectors = (envelope.target?.candidates ?? []).map((c) => c.sel);
    } else {
      selectors.push(...raw.split('\n').map((l) => l.trim()).filter(Boolean));
    }
  }
  if (!selectors.length) {
    err('selector-verify.mjs: nothing to score');
    process.exit(1);
  }

  const client = await connect(await browserSocket(opts.browserUrl));
  let results;
  try {
    const targets = await pageTargets(client);
    const target = opts.targetId
      ? targets.find((t) => t.targetId === opts.targetId)
      : targets[0];
    if (!target) {
      err(`selector-verify.mjs: no page target${opts.targetId ? ` ${opts.targetId}` : ''}`);
      process.exit(1);
    }
    const sessionId = await attach(client, target.targetId);
    const { rootNodeId } = await enableInOrder(client, sessionId, ['DOM']);

    let root = Number.isFinite(opts.root) ? opts.root : rootNodeId;
    let rootLabel = Number.isFinite(opts.root) ? `nodeId ${opts.root}` : 'document';
    if (opts.rootSelector) {
      const res = await client.send(
        'DOM.querySelector',
        { nodeId: rootNodeId, selector: opts.rootSelector },
        sessionId,
      );
      if (!res.nodeId) {
        err(`selector-verify.mjs: --root-selector ${opts.rootSelector} matched nothing`);
        process.exit(1);
      }
      root = res.nodeId;
      rootLabel = opts.rootSelector;
    }

    results = [];
    for (const sel of selectors) {
      results.push(await score(client, sessionId, root, rootLabel, sel));
    }
  } finally {
    client.close();
  }

  const unique = results.filter((r) => r.status === 'UNIQUE').length;

  if (envelope) {
    const bySel = new Map(results.map((r) => [r.sel, r]));
    envelope.target.candidates = envelope.target.candidates.map((c) => {
      const r = bySel.get(c.sel);
      return r && typeof r.matches === 'number'
        ? { ...c, matches: r.matches, root: r.root }
        : { ...c };
    });
    const { valid, errors } = validate(envelope);
    if (!valid) {
      err('selector-verify.mjs: the scored envelope no longer satisfies the schema:');
      formatErrors(errors).forEach((line) => err(line));
      process.exit(1);
    }
    process.stdout.write(`${JSON.stringify(envelope, null, 2)}\n`);
  } else {
    process.stdout.write(`${JSON.stringify(results, null, 2)}\n`);
  }
  process.exit(unique > 0 ? 0 : 1);
}

main().catch((e) => {
  err(`selector-verify.mjs: ${e.message}`);
  process.exit(1);
});
