// automation-session.js — seed/capture a Playwright `storageState` into/out of the LIVE
// automation browser over CDP (connectOverCDP, so we do NOT launch or kill the browser —
// the `chrome-automation` launcher owns it and the playwright MCP attaches to the same port).
//
//   node automation-session.js seed      # reads storageState JSON on stdin, injects cookies
//                                        #   (+ best-effort localStorage) into the live context
//   node automation-session.js capture   # prints the live context's storageState JSON to stdout
//
// Env: PLAYWRIGHT_CORE = nix store path of playwright-core (required); CDP_URL (default :9222).
// The Keychain read/write is done by the shell wrapper (automation-session.nix) via `security`,
// so no secret value is ever passed on argv from here.
'use strict';
const PC = process.env.PLAYWRIGHT_CORE;
if (!PC) { process.stderr.write('PLAYWRIGHT_CORE unset\n'); process.exit(2); }
const { chromium } = require(PC);
const CDP = process.env.CDP_URL || 'http://127.0.0.1:9222';

(async () => {
  const mode = process.argv[2];
  if (mode !== 'seed' && mode !== 'capture') {
    process.stderr.write('usage: automation-session.js seed|capture\n');
    process.exit(2);
  }

  let browser;
  try {
    browser = await chromium.connectOverCDP(CDP);
  } catch (e) {
    process.stderr.write(`cannot connect to CDP at ${CDP} — is chrome-automation running? (${e.message})\n`);
    process.exit(1);
  }
  // connectOverCDP surfaces the browser's existing default context.
  const ctx = browser.contexts()[0] || (await browser.newContext());

  if (mode === 'seed') {
    const raw = require('fs').readFileSync(0, 'utf8'); // stdin
    let state;
    try { state = JSON.parse(raw); } catch (e) { process.stderr.write('stdin is not valid storageState JSON\n'); process.exit(1); }
    const cookies = Array.isArray(state.cookies) ? state.cookies : [];
    if (cookies.length) await ctx.addCookies(cookies);
    // best-effort localStorage per origin (cookies are what carries WordPress/most auth; this is
    // extra fidelity and must never fail the seed — hence try/catch and a short timeout).
    let originsDone = 0;
    for (const o of (state.origins || [])) {
      if (!o || !o.origin || !Array.isArray(o.localStorage) || !o.localStorage.length) continue;
      const page = await ctx.newPage();
      try {
        await page.goto(o.origin, { waitUntil: 'domcontentloaded', timeout: 15000 });
        await page.evaluate((items) => { for (const it of items) { try { localStorage.setItem(it.name, it.value); } catch (_) {} } }, o.localStorage);
        originsDone++;
      } catch (_) { /* origin unreachable / blocked — skip */ }
      finally { await page.close().catch(() => {}); }
    }
    process.stderr.write(`seeded ${cookies.length} cookie(s), ${originsDone}/${(state.origins || []).length} origin localStorage\n`);
  } else {
    const state = await ctx.storageState();
    process.stdout.write(JSON.stringify(state));
  }

  // connectOverCDP: close() DISCONNECTS our client; it does NOT terminate the real browser,
  // so the window stays up for the playwright MCP.
  await browser.close().catch(() => {});
})().catch((e) => { process.stderr.write('automation-session: ' + (e && e.message) + '\n'); process.exit(1); });
