// Detached deadman disarmer.
//
// The only timeout must not live in the process whose death strands the arm: a `kill -9` of
// the picker leaves every armed tab swallowing the operator's next click [F-ARMED-SWALLOWS],
// and nothing in Chrome is known to undo that on its own — whether a client disconnect
// resets inspect mode is UNVERIFIED [F-UNMEASURED-DISCONNECT-RESET], so this process assumes
// it does not.
//
// Spawned detached with stdio ignored by pick-element.mjs. Writes nothing anywhere.

import { existsSync, readFileSync, unlinkSync } from 'node:fs';

import { attach, browserSocket, connect, disarmTarget, enableInOrder, pageTargets } from './lib/cdp.mjs';

const HELP = `Usage: pick-watchdog.mjs --stamp <path> --parent <pid> --deadline <epoch-ms>

Polls once a second. Sweeps inspect mode off EVERY page target and exits when the parent is
gone, the deadline has passed, or the arm stamp has vanished. Self-terminates 120s past the
deadline regardless. No stdout: it is spawned detached.
`;

const POLL_MS = 1000;
const GRACE_MS = 5000;
const HARD_STOP_MS = 120000;

function parseArgs(argv) {
  const o = { stamp: null, parent: null, deadline: 0 };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '-h' || a === '--help') o.help = true;
    else if (a === '--stamp') o.stamp = argv[++i];
    else if (a === '--parent') o.parent = Number(argv[++i]);
    else if (a === '--deadline') o.deadline = Number(argv[++i]);
    else throw new Error(`unknown option ${a}`);
  }
  return o;
}

const parentAlive = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

async function sweep(browserUrl) {
  let client;
  try {
    client = await connect(await browserSocket(browserUrl));
  } catch {
    return; // the browser is gone, and inspect mode died with it
  }
  try {
    for (const t of await pageTargets(client)) {
      // Independently guarded: the disarm needs highlightConfig and one throw must not leave
      // the remaining tabs armed [F-DISARM-HIGHLIGHTCONFIG].
      try {
        const sessionId = await attach(client, t.targetId);
        await enableInOrder(client, sessionId, ['DOM', 'Overlay']);
        await disarmTarget(client, sessionId);
      } catch {
        // next target
      }
    }
  } finally {
    client.close();
  }
}

async function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch {
    process.exit(1);
  }
  if (opts.help) {
    process.stdout.write(HELP);
    process.exit(0);
  }
  if (!opts.stamp || !Number.isFinite(opts.parent) || !Number.isFinite(opts.deadline)) {
    process.exit(1);
  }

  // Read the stamp once at startup: the browser URL must survive the stamp being removed,
  // which is one of the three conditions that trigger the sweep.
  let browserUrl = 'http://127.0.0.1:9222';
  try {
    browserUrl = JSON.parse(readFileSync(opts.stamp, 'utf8')).browserUrl || browserUrl;
  } catch {
    // fall back to the default port; a sweep against nothing is a no-op
  }

  const hardStop = opts.deadline + HARD_STOP_MS;
  for (;;) {
    const now = Date.now();
    const parentGone = !parentAlive(opts.parent);
    const expired = now > opts.deadline + GRACE_MS;
    const stampGone = !existsSync(opts.stamp);
    if (parentGone || expired || stampGone) {
      // Sweeping after a clean exit is a harmless duplicate — the disarm is idempotent — and
      // the picker kills this process first in the happy path.
      await sweep(browserUrl);
      try {
        unlinkSync(opts.stamp);
      } catch {
        // already gone
      }
      process.exit(0);
    }
    if (now > hardStop) process.exit(0);
    await new Promise((r) => setTimeout(r, POLL_MS));
  }
}

main().catch(() => process.exit(1));
