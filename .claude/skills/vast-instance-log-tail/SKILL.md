---
name: vast-instance-log-tail
description: >
  Headlessly tail a Vast.ai instance's log from the cloud.vast.ai console using
  Kapture + a JS `evaluate` snippet — no screenshots, no blind-waiting. Use when
  asked to "tail/watch the Vast instance log", "check provisioning progress",
  "see the last N lines of the instance log", "why is the Open button stuck", or
  "diagnose a Vast instance". Pairs with the vast-* provisioning subsystem
  (packages/vast-provision.nix, packages/vast-bootstrap.sh) and the design doc
  docs/vastai-template-provisioning.md.
---

# Vast.ai instance log tail (headless, JS method)

Reading a Vast instance log the wrong way (screenshots, blind-waiting over timeouts,
polling `disk_usage`) is slow, token-heavy, and misses the error — which is almost
always at the **bottom** of the log. Read it as TEXT via Kapture's `evaluate` tool
against the console's Logs modal. These selectors were verified live on the
cloud.vast.ai console (Chrome + Kapture) — they are real, not guessed.

## The three rules that cost us hours

1. **The Logs modal does NOT auto-tail.** You MUST explicitly fire the fetch button
   (`INSTANCE LOGS` / `EXTRA DEBUG LOGS`) after changing anything — a plain read
   returns a **stale** snapshot. Re-click the fetch button before every read.
2. **Read the TAIL, small.** Set the **Line Count** field to ~30–48 and read the last
   lines. The error is at the bottom.
3. **`provision: provisioning complete.` is NOT proof of success.** That line is
   `provision.sh`'s own echo; it prints even when a **required model download failed**
   (the `|| WARN … (continuing)` non-fatal path). ALWAYS scan the tail for
   `[ERROR]` / `(ERR):error occurred` / `status=403` above it before declaring done.
   `disk_usage` (the API/card field) lags — never use it as a progress signal.

## The two log streams

The modal has two fetch buttons (both inside the dialog):
- **`INSTANCE LOGS`** — the container's stdout: the base-image init + your
  `PROVISIONING_SCRIPT` output (aria2 downloads, checksums, provision.sh). This is
  where model-download failures land.
- **`EXTRA DEBUG LOGS`** — the machine/docker-level log (image pull, `success, running
  vastai/base-image:…`). Rarely has app errors.

Note: even at high Line Count the visible window is a tail — early base-image init
(sshd/caddy launch lines) can be pushed off the TOP by long download output, so the
modal is **not** reliable for confirming service startup; use a shell for that.

## Recipe (Kapture)

1. `list_tabs` → the `cloud.vast.ai` tab (needs `evalAllowed: true`).
2. If the Logs modal isn't open, click the instance card's Logs button:
   `[data-testid="instance-card-view-instance-logs-button"]` (one card ⇒ one button;
   for a specific instance, scope to its card first).
3. Set Line Count, fire the fetch, read the `<pre>` — all via `evaluate`:

```js
// STEP A — set Line Count = 48 and fetch INSTANCE LOGS (modal does NOT auto-tail)
(() => {
  const d = document.querySelector('.MuiDialog-root .MuiPaper-root');
  if (!d) return { err: 'no dialog — click the Logs button first' };
  const lc = Array.from(d.querySelectorAll('input'))
    .find(i => /Line Count/i.test(i.getAttribute('placeholder') || ''));
  if (lc) {
    const set = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
    set.call(lc, '48');                                   // native setter — plain .value= won't update React
    lc.dispatchEvent(new Event('input',  { bubbles: true }));
    lc.dispatchEvent(new Event('change', { bubbles: true }));
  }
  const btn = Array.from(d.querySelectorAll('button'))
    .find(b => /^INSTANCE LOGS$/i.test((b.innerText || '').trim())); // or /^EXTRA DEBUG LOGS$/i
  if (btn) btn.click();                                   // <-- the explicit refresh; nothing tails without it
  return { lineCountSet: lc && lc.value, fetched: !!btn };
})()
```

```js
// STEP B — read the tail as TEXT (re-run STEP A first for fresh lines)
(() => {
  const d = document.querySelector('.MuiDialog-root .MuiPaper-root');
  if (!d) return { err: 'no dialog' };
  const pre = d.querySelector('pre,textarea');
  const t = pre ? (pre.value || pre.innerText) : '';
  const lines = t.split('\n');
  const errs = lines.filter(l => /\[ERROR\]|\(ERR\)|status=403|Traceback|FAIL/i.test(l));
  return { numLines: lines.length, last48: lines.slice(-48).join('\n'), errorLines: errs };
})()
```

Other selectors in the modal: close = `[data-testid="modal-close-button"]`; the
fetch buttons have **no** `data-testid` — match by exact button text as above.

## Headless (no browser) fallback

When there's no Kapture/browser, poll the API instead — same INSTANCE LOG stream:

```
PUT https://console.vast.ai/api/v0/instances/request_logs/<id>   body {"tail":"48"}
→ returns a result_url → curl it → tail
```

Exit on `provision: provisioning complete.` **AND** a clean error-scan (no `[ERROR]`/
`(ERR)`/`403` above it). This is a helper signal — a completion CLAIM should still be
confirmed by reading the tail through the console at least once.

## Known failure signatures

- `[ERROR] … status=403 … b2.civitai.com/…?Authorization=…` → **aria2 cannot fetch
  Civitai's signed-B2 redirect** (its segmented/HEAD/Range probe is rejected by the
  single-use pre-signed URL). `curl -L` on the identical URL returns 200. Fix: route
  Civitai/B2 URLs through curl, not aria2. `provision.sh` marks it non-fatal, so the
  run continues and a REQUIRED LoRA silently goes missing — treat this as a failure.
- **Open button stuck "Connecting…"** (`[data-testid="instance-page-open-instance-button"]`
  disabled) + sshd (:22) unreachable + ~0 RAM/GPU on the card → services aren't
  persisting; nothing is listening on `OPEN_BUTTON_PORT`. The logs won't show this
  (init scrolled off top) — needs a shell to run `ss -tlnp` / `supervisorctl status`.
