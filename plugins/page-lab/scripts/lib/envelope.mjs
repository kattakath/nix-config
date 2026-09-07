// THE constructor and validator for `page-lab/pick@1`. Every producer goes through here —
// pick-element.mjs (tier 1) and pick-normalize.mjs (tiers 2-5) — so the two cannot drift.
// Re-implementing either half elsewhere is the drift the schema exists to stop.
//
// Authority is ../../references/pick-envelope.schema.json. This file enforces it; it never
// widens it. Not an entrypoint: pick-validate.mjs is the CLI.
//
// validate() returns { valid, errors[] } where each error is
//   { path: "/target/candidates/0/matches", keyword: "required", message: "..." }
// and formatErrors() renders them one per line.

import { readFileSync } from 'node:fs';

export const SCHEMA_NAME = 'page-lab/pick@1';
export const SCHEMA_PATH = new URL('../../references/pick-envelope.schema.json', import.meta.url);

export const SHIP_BLOCKERS = Object.freeze([
  'kapture-minted-selector',
  'shadow-root-target',
  'cross-frame-target',
  'generated-classname',
  'origin-unconfirmed',
  'sanitizer-drift',
]);

let cachedSchema = null;

/** The schema as an object, read once. */
export function loadSchema() {
  if (!cachedSchema) cachedSchema = JSON.parse(readFileSync(SCHEMA_PATH, 'utf8'));
  return cachedSchema;
}

/** Local date, because measuredAt is the dated WHY block's citation, pre-formatted. */
export function localDate(d = new Date()) {
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/** Origin of a URL, or the literal "null" for opaque origins (file:, data:, sandboxed). */
export function originOf(url) {
  try {
    const o = new URL(url).origin;
    return o && o !== 'null' ? o : 'null';
  } catch {
    return 'null';
  }
}

// Build-generated class names are evidence, never an anchor: they change on the next deploy.
// The heuristic is deliberately conservative — a false GENERATED costs one candidate, a
// false STABLE ships a selector that dies silently.
function looksHashy(token, isTail) {
  if (token.length < 5) return false;
  const hasDigit = /[0-9]/.test(token);
  const mixed = /[a-z]/.test(token) && /[A-Z]/.test(token);
  const vowelless = !/[aeiouAEIOU]/.test(token);
  if (hasDigit && (mixed || vowelless)) return true; // css-1x2y3z, jsx-2937461
  if (isTail && mixed) return true; // sc-bdVaJa, styled-components / emotion tails
  return vowelless && token.length >= 6;
}

/** True when a class fragment looks build-generated rather than authored. */
export function isGeneratedClass(cls) {
  const token = String(cls);
  if (token.length >= 20) return true;
  const cut = Math.max(token.lastIndexOf('-'), token.lastIndexOf('_'));
  return cut > 0 ? looksHashy(token.slice(cut + 1), true) : looksHashy(token, false);
}

/** Split a class list into what may anchor a selector and what may not. */
export function splitClasses(classList = []) {
  const stable = [];
  const generated = [];
  for (const c of classList) (isGeneratedClass(c) ? generated : stable).push(c);
  return { stable, generated };
}

/**
 * Ship blockers are derived, never asserted: the same input always produces the same set,
 * so a producer cannot forget one. Extra blockers a caller passes in (sanitizer-drift, which
 * only the tier-4 canary can observe) are merged.
 */
export function deriveShipBlockers(env, extra = []) {
  const out = new Set(extra.filter((b) => SHIP_BLOCKERS.includes(b)));
  const t = env.target;
  if (t) {
    if (t.selectorSource === 'kapture-minted') out.add('kapture-minted-selector');
    if (t.reachability === 'shadow' || t.reachability === 'shadow-in-frame') {
      out.add('shadow-root-target');
    }
    if (t.reachability === 'frame' || t.reachability === 'shadow-in-frame') {
      out.add('cross-frame-target');
    }
    // Only a candidate that actually leans on a generated class is blocked; a positional
    // path next to a generated class is still shippable.
    const generated = t.classes?.generated ?? [];
    const sels = (t.candidates ?? []).map((c) => String(c?.sel ?? ''));
    if (generated.some((g) => sels.some((s) => s.includes(`.${g}`)))) {
      out.add('generated-classname');
    }
  }
  if (env.status === 'picked' && env.originVerified !== true) out.add('origin-unconfirmed');
  return SHIP_BLOCKERS.filter((b) => out.has(b));
}

function prune(value) {
  if (Array.isArray(value)) return value.map(prune);
  if (value && typeof value === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(value)) if (v !== undefined) out[k] = prune(v);
    return out;
  }
  return value;
}

/**
 * The only place a page-lab/pick@1 object is constructed.
 *
 * Fills schema/measuredAt/origin, derives shipBlockers, and STRIPS the fields the fidelity
 * table forbids. Stripping is safe; inventing is not — build never fabricates a match count,
 * a note or a viewport it was not handed. A missing required field stays missing and
 * validate() says so.
 */
export function build(parts = {}) {
  const env = prune({ ...parts });
  env.schema = SCHEMA_NAME;
  env.status ??= 'picked';
  env.measuredAt ||= localDate();
  if (env.url && !env.origin) env.origin = originOf(env.url);
  env.originVerified = env.originVerified === true;
  env.notes = Array.isArray(env.notes) ? [...env.notes] : [];

  if (env.target) {
    const t = env.target;
    if (Array.isArray(t.classes)) t.classes = splitClasses(t.classes);
    if (Array.isArray(t.candidates)) {
      t.candidates = t.candidates.filter((c) => c && typeof c.sel === 'string' && c.sel.length);
      if (env.fidelity !== 'verified') {
        // A missing matches means UNVERIFIED, never one. Carrying one at a lower fidelity
        // would be a fabricated measurement.
        t.candidates = t.candidates.map(({ matches: _drop, ...rest }) => rest);
      }
    }
    if (env.fidelity === 'asserted') delete t.boxes;
  }

  // status:"picked" needs a checked origin or an explicit admission that it was not checked.
  if (env.status === 'picked' && !env.originVerified && !env.notes.includes('origin-unconfirmed')) {
    env.notes.push('origin-unconfirmed');
  }

  env.shipBlockers = deriveShipBlockers(env, parts.shipBlockers ?? []);
  return prune(env);
}

// ---------------------------------------------------------------------------
// Dependency-free validator. Covers exactly the keyword surface the schema's own
// $comment names, so no pointer is ever resolved and no npm validator is needed.
// ---------------------------------------------------------------------------

const TYPES = {
  object: (v) => v !== null && typeof v === 'object' && !Array.isArray(v),
  array: Array.isArray,
  string: (v) => typeof v === 'string',
  number: (v) => typeof v === 'number' && Number.isFinite(v),
  integer: Number.isInteger,
  boolean: (v) => typeof v === 'boolean',
  null: (v) => v === null,
};

function same(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

function check(schema, data, path, errors) {
  if (schema === true || schema === undefined) return true;
  if (schema === false) {
    errors.push({ path, keyword: 'false', message: 'schema forbids any value here' });
    return false;
  }
  let ok = true;
  const bad = (keyword, message) => {
    ok = false;
    errors.push({ path, keyword, message });
  };

  if (schema.type !== undefined) {
    const types = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (!types.some((t) => TYPES[t]?.(data))) bad('type', `expected ${types.join('|')}`);
  }
  if ('const' in schema && !same(schema.const, data)) {
    bad('const', `must be ${JSON.stringify(schema.const)}`);
  }
  if (schema.enum && !schema.enum.some((e) => same(e, data))) {
    bad('enum', `must be one of ${JSON.stringify(schema.enum)}`);
  }
  if (typeof data === 'string') {
    if (schema.pattern && !new RegExp(schema.pattern, 'u').test(data)) {
      bad('pattern', `must match ${schema.pattern}`);
    }
    if (schema.minLength !== undefined && data.length < schema.minLength) {
      bad('minLength', `shorter than ${schema.minLength}`);
    }
    if (schema.maxLength !== undefined && data.length > schema.maxLength) {
      bad('maxLength', `longer than ${schema.maxLength}`);
    }
  }
  if (typeof data === 'number') {
    if (schema.minimum !== undefined && data < schema.minimum) {
      bad('minimum', `below ${schema.minimum}`);
    }
    if (schema.maximum !== undefined && data > schema.maximum) {
      bad('maximum', `above ${schema.maximum}`);
    }
  }
  if (Array.isArray(data)) {
    if (schema.minItems !== undefined && data.length < schema.minItems) {
      bad('minItems', `fewer than ${schema.minItems} items`);
    }
    if (schema.maxItems !== undefined && data.length > schema.maxItems) {
      bad('maxItems', `more than ${schema.maxItems} items`);
    }
    if (schema.uniqueItems) {
      const seen = new Set();
      for (const item of data) {
        const key = JSON.stringify(item);
        if (seen.has(key)) bad('uniqueItems', `duplicate item ${key}`);
        seen.add(key);
      }
    }
    if (schema.items) {
      data.forEach((item, i) => {
        if (!check(schema.items, item, `${path}/${i}`, errors)) ok = false;
      });
    }
    if (schema.contains) {
      const scratch = [];
      const hit = data.some((item, i) => check(schema.contains, item, `${path}/${i}`, scratch));
      if (!hit) bad('contains', `no item matches ${JSON.stringify(schema.contains)}`);
    }
  }
  if (TYPES.object(data)) {
    for (const key of schema.required ?? []) {
      if (!(key in data)) bad('required', `missing required property "${key}"`);
    }
    for (const [key, sub] of Object.entries(schema.properties ?? {})) {
      if (key in data && !check(sub, data[key], `${path}/${key}`, errors)) ok = false;
    }
    if (schema.additionalProperties === false) {
      const known = new Set(Object.keys(schema.properties ?? {}));
      for (const key of Object.keys(data)) {
        if (!known.has(key)) bad('additionalProperties', `unexpected property "${key}"`);
      }
    }
  }
  for (const sub of schema.allOf ?? []) {
    if (!check(sub, data, path, errors)) ok = false;
  }
  if (schema.anyOf) {
    const scratch = [];
    if (!schema.anyOf.some((sub) => check(sub, data, path, scratch))) {
      bad('anyOf', `matched none of ${schema.anyOf.length} alternatives`);
    }
  }
  if (schema.not) {
    const scratch = [];
    if (check(schema.not, data, path, scratch)) {
      bad('not', `must NOT match ${JSON.stringify(schema.not)}`);
    }
  }
  if (schema.if) {
    const scratch = [];
    const branch = check(schema.if, data, path, scratch) ? schema.then : schema.else;
    if (branch && !check(branch, data, path, errors)) ok = false;
  }
  return ok;
}

/**
 * Validate an envelope. Schema defaults to the frozen contract on disk.
 * @returns {{valid:boolean, errors:Array<{path:string,keyword:string,message:string}>}}
 */
export function validate(obj, schema = loadSchema()) {
  const errors = [];
  check(schema, obj, '', errors);
  return { valid: errors.length === 0, errors };
}

/** One human line per error, for a CLI or a stderr dump. */
export function formatErrors(errors = []) {
  return errors.map((e) => `  ${e.path || '/'}: ${e.keyword} — ${e.message}`);
}
