#!/usr/bin/env node
/*
 * pick-normalize.mjs — raw tier-2/3/4/5 tool JSON in, ONE valid page-lab/pick@1 envelope out.
 *
 * WHY THIS EXISTS. Tier 1 produces an envelope directly; every other tier produces whatever
 * its tool happens to return. Without one converter, each consumer would learn each tool's
 * shape, and the fidelity contract — the thing that stops a sampled selector being read as a
 * verified one — would live in four places and drift in three. So: one converter, and it
 * imports lib/envelope.mjs rather than building an object of its own.
 *
 * The one rule it must never break: a field the fidelity table forbids is DROPPED, never
 * invented. A missing candidates[].matches means UNVERIFIED. It never means one.
 *
 *   usage: pick-normalize.mjs --route kapture-focus|kapture-hover|kapture-eval|cic-armed|operator-paste
 *                             [--url <page url>] [--expect-origin <origin>] [--page-mutated]
 *          (raw tool JSON on stdin)
 *
 * Exit 0 a valid envelope was printed · 1 no usable pick came out of it (unparseable input,
 * or a sanitizer drift that makes every value suspect — the envelope IS still printed, so the
 * drift is on the record) · 3 origin-mismatch
 * (a valid envelope IS printed, naming both origins and carrying no selector).
 */

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { build, formatErrors, validate } from './lib/envelope.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const SCHEMA = JSON.parse(
  readFileSync(join(HERE, '..', 'references', 'pick-envelope.schema.json'), 'utf8')
);

const ROUTES = {
  'kapture-focus': { fidelity: 'sampled', source: 'kapture-minted' },
  'kapture-hover': { fidelity: 'sampled', source: 'kapture-minted' },
  // tier 3 injects OUR picker through Kapture's evaluate, so no kapture-N id is minted —
  // Kapture's own getUniqueSelector() is what stamps the DOM [F-KAPTURE-MUTATES], and
  // evaluate does not call it.
  'kapture-eval': { fidelity: 'sampled', source: 'injected-picker' },
  'cic-armed': { fidelity: 'asserted', source: 'injected-picker' },
  'operator-paste': { fidelity: 'asserted', source: 'operator-supplied' }
};

function die(msg, code) {
  process.stderr.write(`pick-normalize: ${msg}\n`);
  process.exit(code);
}

function usage() {
  die(
    'usage: pick-normalize.mjs --route <route> [--url <url>] [--expect-origin <origin>] [--page-mutated]',
    1
  );
}

function parseArgs(argv) {
  const out = { pageMutated: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--page-mutated') out.pageMutated = true;
    else if (a === '--route') out.route = argv[++i];
    else if (a === '--url') out.url = argv[++i];
    else if (a === '--expect-origin') out.expectOrigin = argv[++i];
    else if (a === '-h' || a === '--help') usage();
    else die(`unknown argument: ${a}`, 1);
  }
  if (!out.route || !ROUTES[out.route]) usage();
  return out;
}

function readStdin() {
  try {
    return readFileSync(0, 'utf8');
  } catch {
    return '';
  }
}

const SENTINEL = /^<<([\s\S]*)>>$/;
function unwrap(v) {
  if (typeof v === 'string') {
    const m = SENTINEL.exec(v);
    return m ? m[1] : v;
  }
  if (Array.isArray(v)) return v.map(unwrap);
  if (v && typeof v === 'object') {
    const o = {};
    for (const [k, val] of Object.entries(v)) o[k] = unwrap(val);
    return o;
  }
  return v;
}

/*
 * The sanitizer replaces values silently, so a [BLOCKED: marker anywhere outside the canary
 * is the only signal that its rules moved under us [F-CIC-SANITIZER].
 */
function blockedOutsideCanary(node, inCanary = false) {
  if (typeof node === 'string') return !inCanary && node.includes('[BLOCKED:');
  if (Array.isArray(node)) return node.some((v) => blockedOutsideCanary(v, inCanary));
  if (node && typeof node === 'object') {
    return Object.entries(node).some(([k, v]) =>
      blockedOutsideCanary(v, inCanary || k === 'canary')
    );
  }
  return false;
}

function originOf(url) {
  try {
    const u = new URL(url);
    return u.origin === 'null' || !u.origin ? 'null' : u.origin;
  } catch {
    return 'null';
  }
}

const sameOrigin = (a, b) => a.replace(/\/+$/, '') === b.replace(/\/+$/, '');

function first(...vals) {
  for (const v of vals) if (v !== undefined && v !== null && v !== '') return v;
  return undefined;
}

/* Every tier-2..5 producer is tolerated by shape, not by name: an entry is whatever carries
 * a selector. Anything not recognised is a no-pick, never a guess. */
function entries(raw) {
  if (Array.isArray(raw)) return raw;
  for (const k of ['elements', 'result', 'results', 'data']) {
    if (Array.isArray(raw?.[k])) return raw[k];
  }
  return raw && typeof raw === 'object' ? [raw] : [];
}

function readEntry(e) {
  if (!e || typeof e !== 'object') return null;
  const sel = first(e.sel, e.selector, e.cssSelector, e.uniqueSelector);
  const tag = first(e.tag, e.tagName, e.nodeName);
  if (!sel && !tag) return null;
  const box = e.rect || e.boundingBox || e.bbox || e;
  const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : undefined);
  const rect = {
    x: num(first(box.x, box.left)),
    y: num(first(box.y, box.top)),
    w: num(first(box.w, box.width)),
    h: num(first(box.h, box.height))
  };
  return {
    sel: sel ? String(sel) : undefined,
    tag: tag ? String(tag).toLowerCase() : undefined,
    txt: first(e.txt, e.text, e.textContent),
    id: typeof e.id === 'string' ? e.id : undefined,
    classCount: Array.isArray(e.classes) ? e.classes.length : undefined,
    rect: Object.values(rect).every((v) => v !== undefined) ? rect : undefined
  };
}

/* Everything build() cannot know, applied after it and before validation, so this file never
 * re-implements the constructor it imports. */
function ensure(parts, forced) {
  let env;
  try {
    env = build(parts);
  } catch (err) {
    die(`lib/envelope.mjs build() rejected these parts: ${err.message}`, 1);
  }
  const out = { ...env, ...forced };
  out.shipBlockers = [...new Set([...(env.shipBlockers || []), ...(forced.shipBlockers || [])])];
  out.notes = [...new Set([...(env.notes || []), ...(forced.notes || [])])];
  if (out.status !== 'picked') delete out.target;
  return out;
}

function emit(env) {
  const errors = asErrors(validate(env, SCHEMA));
  if (errors.length) {
    process.stderr.write('pick-normalize: produced an INVALID envelope — this is a bug:\n');
    for (const e of errors) process.stderr.write(`  ${e}\n`);
    process.exit(1);
  }
  process.stdout.write(`${JSON.stringify(env, null, 2)}\n`);
}

/* The validator's return shape is lib/envelope.mjs's to choose; normalise rather than couple. */
function asErrors(r) {
  if (r === true || r === undefined || r === null) return [];
  if (r === false) return ['envelope failed validation (validator returned no detail)'];
  const list = (x) => {
    const arr = Array.isArray(x) ? x : [x];
    if (arr.length && typeof arr[0] === 'object') return formatErrors(arr).map((l) => l.trim());
    return arr.map((e) => (typeof e === 'string' ? e : JSON.stringify(e)));
  };
  if (Array.isArray(r)) return list(r);
  if (typeof r === 'object') {
    const ok = r.valid !== undefined ? r.valid : r.ok;
    const errs = r.errors || r.problems || [];
    if (ok === true) return [];
    if (ok === false) {
      const l = list(errs);
      return l.length ? l : ['envelope failed validation (validator returned no detail)'];
    }
    return list(errs);
  }
  return list(r);
}

// --------------------------------------------------------------------------- main

const args = parseArgs(process.argv.slice(2));
const spec = ROUTES[args.route];

let raw;
try {
  const text = readStdin();
  if (!text.trim()) die('no JSON on stdin', 1);
  raw = JSON.parse(text);
} catch (err) {
  die(`stdin is not JSON: ${err.message}`, 1);
}

// The injected picker appends its highlight box while armed, so any HTML diff taken
// mid-pick is contaminated even on routes that mint nothing.
const pageMutated =
  args.pageMutated || spec.fidelity === 'sampled' || spec.source === 'injected-picker';

const notes = [];
const shipBlockers = [];

if (blockedOutsideCanary(raw)) {
  notes.push(
    'SANITIZER DRIFT: a [BLOCKED:] marker appeared outside the canary — the output filter changed, re-measure before trusting any tier-4 pick'
  );
  shipBlockers.push('sanitizer-drift');
}

const url = first(args.url, raw?.url, raw?.pageUrl, raw?.href);
if (!url) die('no --url and none in the input — an envelope with no url cannot be traced to a page', 1);
const origin = originOf(url);

const originVerified = Boolean(args.expectOrigin);
if (!originVerified) {
  notes.push('origin-unconfirmed');
  shipBlockers.push('origin-unconfirmed');
}

if (args.expectOrigin && !sameOrigin(origin, args.expectOrigin)) {
  emit(
    ensure(
      {
        status: 'origin-mismatch',
        route: args.route,
        fidelity: spec.fidelity,
        url,
        origin,
        expectedOrigin: args.expectOrigin,
        originVerified: false,
        pageMutated,
        notes,
        shipBlockers
      },
      {
        status: 'origin-mismatch',
        origin,
        expectedOrigin: args.expectOrigin,
        originVerified: false,
        notes: [
          ...notes,
          `measured origin ${origin} is not the expected ${args.expectOrigin} — no selector emitted`
        ],
        shipBlockers
      }
    )
  );
  process.exit(3);
}

const list = entries(unwrap(raw));
const parsed = list.map(readEntry).filter(Boolean);
const deepest = args.route === 'kapture-hover' ? parsed[parsed.length - 1] : parsed[0];

// A :hover stack that terminates at html/body did not reach a real target. Reporting <body>
// as the pick is worse than reporting nothing.
const stackDead =
  args.route === 'kapture-hover' && deepest && ['html', 'body'].includes(deepest.tag || '');
const stateWord = typeof raw?.st === 'string' ? unwrap(raw.st) : '';
// Drift means the output filter no longer matches what the payload was written against, so
// EVERY value in this input is suspect — including the selector. Record it, refuse the pick.
const drifted = shipBlockers.includes('sanitizer-drift');
const noPick =
  drifted ||
  !deepest ||
  !deepest.sel ||
  stackDead ||
  ['armed', 'cancelled', 'timeout', 'absent', 'disarmed'].includes(stateWord);

if (noPick) {
  const why = drifted
    ? 'refusing the pick: the sanitizer blocked a value outside the canary, so no string in this input can be trusted'
    : stackDead
    ? 'the :hover stack terminated at html/body — nothing was actually under the pointer'
    : stateWord
      ? `the picker returned status "${stateWord}" — no element was clicked`
      : 'no entry in the input carried a selector';
  emit(
    ensure(
      {
        status: 'no-pick',
        route: args.route,
        fidelity: spec.fidelity,
        url,
        origin,
        originVerified,
        pageMutated,
        notes: [...notes, why],
        shipBlockers
      },
      { status: 'no-pick', origin, originVerified, notes: [...notes, why], shipBlockers }
    )
  );
  process.exit(drifted ? 1 : 0);
}

if (spec.source === 'kapture-minted') {
  shipBlockers.push('kapture-minted-selector');
  notes.push(
    'selector was minted by Kapture: it is real and unique but evaporates on reload, and stamping it dirtied the DOM — re-measure state A before any HTML diff'
  );
}
// reachability is a CDP measurement (one pierced DOM.getDocument); no tier below 1 can see
// a shadow root or a frame boundary, so say so rather than imply "document" was checked.
notes.push('reachability was not measured on this route — assumed document');
if (spec.fidelity === 'asserted') {
  notes.push(
    'values passed through a sanitizer or a human before reaching this envelope — no match count and no box quads exist'
  );
}

const target = {
  tag: /^[a-z][a-z0-9-]*$/.test(deepest.tag || '') ? deepest.tag : 'div',
  path: deepest.sel,
  reachability: 'document',
  selectorSource: spec.source,
  candidates: [{ sel: deepest.sel, root: 'document' }]
};
if (deepest.id !== undefined) target.id = deepest.id;
if (deepest.classCount !== undefined) target.classCount = deepest.classCount;
if (deepest.rect) target.rect = deepest.rect;
if (typeof deepest.txt === 'string' && deepest.txt) target.text = deepest.txt.slice(0, 200);

emit(
  ensure(
    {
      status: 'picked',
      route: args.route,
      fidelity: spec.fidelity,
      url,
      origin,
      originVerified,
      pageMutated,
      notes,
      shipBlockers,
      target
    },
    { status: 'picked', origin, originVerified, notes, shipBlockers, target }
  )
);
