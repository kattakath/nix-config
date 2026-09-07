#!/usr/bin/env node
/*
 * pick-validate.mjs — the schema gate, as a CLI and as a CI self-test.
 *
 * WHY THIS EXISTS. Two producers build envelopes (pick-element.mjs for tier 1,
 * pick-normalize.mjs for everything below it) and they cannot be allowed to drift apart,
 * because the whole fidelity contract is what stops a sampled selector being read as a
 * verified one. --self-test is the thing that catches the drift: it asserts the POSITIVE
 * fixtures still validate AND that the NEGATIVE ones still fail. A validator that only ever
 * proves things pass proves nothing.
 *
 *   usage: pick-validate.mjs [file.json | -]        validate one envelope
 *          pick-validate.mjs --self-test <dir>      every *-good.json must PASS,
 *                                                   every pick-bad-*.json must FAIL
 *
 * Exit 0 everything behaved as expected · 1 otherwise, naming the file and the rule.
 */

import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { formatErrors, validate } from './lib/envelope.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const SCHEMA = JSON.parse(
  readFileSync(join(HERE, '..', 'references', 'pick-envelope.schema.json'), 'utf8')
);

function usage(code) {
  process.stderr.write(
    'usage: pick-validate.mjs [file.json | -]\n' +
      '       pick-validate.mjs --self-test <fixtures-dir>\n'
  );
  process.exit(code);
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

function check(path) {
  const text = path === '-' ? readFileSync(0, 'utf8') : readFileSync(path, 'utf8');
  return asErrors(validate(JSON.parse(text), SCHEMA));
}

const argv = process.argv.slice(2);
if (argv.length === 0 || argv[0] === '-h' || argv[0] === '--help') usage(argv.length ? 0 : 1);

if (argv[0] !== '--self-test') {
  let errors;
  try {
    errors = check(argv[0]);
  } catch (err) {
    process.stderr.write(`${argv[0]}: ${err.message}\n`);
    process.exit(1);
  }
  if (errors.length) {
    process.stderr.write(`INVALID ${argv[0]}\n`);
    for (const e of errors) process.stderr.write(`  ${e}\n`);
    process.exit(1);
  }
  process.stdout.write(`valid ${argv[0]}\n`);
  process.exit(0);
}

const dir = argv[1];
if (!dir) usage(1);

const files = readdirSync(dir)
  .filter((f) => f.endsWith('.json'))
  .sort();

// A glob that matched nothing would otherwise pass vacuously — the same trap the userscript
// linter guards against.
if (files.length === 0) {
  process.stderr.write(`no .json fixtures in ${dir} — the path or glob is stale\n`);
  process.exit(1);
}

let rc = 0;
for (const f of files) {
  const path = join(dir, f);
  const expectPass = f.endsWith('-good.json');
  const expectFail = f.startsWith('pick-bad-');
  if (!expectPass && !expectFail) {
    process.stderr.write(`✘ ${f}: unclassified fixture — name it *-good.json or pick-bad-*.json\n`);
    rc = 1;
    continue;
  }

  let errors;
  try {
    errors = check(path);
  } catch (err) {
    process.stderr.write(`✘ ${f}: unreadable — ${err.message}\n`);
    rc = 1;
    continue;
  }

  if (expectPass && errors.length) {
    process.stderr.write(`✘ ${f}: expected to PASS, failed:\n`);
    for (const e of errors) process.stderr.write(`    ${e}\n`);
    rc = 1;
  } else if (expectFail && errors.length === 0) {
    process.stderr.write(`✘ ${f}: expected to FAIL, passed — the rule it exercises is gone\n`);
    rc = 1;
  } else {
    process.stdout.write(`ok  ${f} (${expectPass ? 'passes' : 'rejected'})\n`);
  }
}

// Every problem in one run, then one verdict.
if (rc !== 0) {
  process.stderr.write('envelope fixture self-test FAILED — see ✘ above\n');
  process.exit(1);
}
process.stdout.write(`envelope fixture self-test passed (${files.length} fixtures)\n`);
