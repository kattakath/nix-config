# `GM_*` / `GM.*` portability — Violentmonkey vs Tampermonkey

**Load this file only when a `GM_*` call is actually being written.** Choosing *whether* to
grant at all is [`patterns.md`](patterns.md) § 6; this file is what happens once the answer is
yes, and what silently differs between the two managers.

**Provenance, stated up front.** Rows marked **[VM-verified]** come from
[`patterns.md`](patterns.md) §§ 3/6/7, verified against violentmonkey.github.io + MDN on
**2026-08-30**. Rows marked **[F-…]** cite [`../../references/facts.md`](../../references/facts.md).
Everything else lives in the **Flagged** table at the bottom and is **not** promoted by being
useful — same discipline as `patterns.md`'s flagged rows.

## Portable core — the set to write against

**[VM-verified]** Violentmonkey's complete `@grant` value set is enumerated in
[`patterns.md`](patterns.md) § 6. Tampermonkey accepts every name in it, so **that set is the
portable floor**: a script whose grants all come from it runs under either manager.

Two consequences worth stating once:

- **The set is the allowlist, not a suggestion.** No linter checks grant *values*, so a
  misspelled grant grants **nothing, silently** — the call is `undefined` at runtime and the
  script degrades to a no-op with no error.
- **`@grant unsafeWindow` is not a documented Violentmonkey privilege** **[VM-verified]** —
  `unsafeWindow` is already in the default sandboxed set. Tampermonkey accepts it; writing it
  buys nothing portable.

## Tampermonkey-only — absent from Violentmonkey

Using any of these makes the script **Tampermonkey-exclusive**. If it must run under
Violentmonkey, there is no shim — re-solve the problem.

| API | Violentmonkey answer |
|---|---|
| `GM_log` | `console.log`. **[VM-verified]** — `GM_log` is not documented by VM. |
| `GM_getTab` / `GM_saveTab` / `GM_getTabs` | No per-tab store. Use `GM_setValue` keyed by something stable, or `sessionStorage`. |
| `GM_webRequest` | None. Also **removed in MV3 builds of Tampermonkey 5.2+** *(flagged)*. |
| `GM_audio.*` | None. Platform `Audio` / Web Audio in page context. |
| `window.onurlchange` | The Navigation API — [`patterns.md`](patterns.md) § 1. |

## The two spelling traps

Both are silent: the misspelling is simply not granted, so the call is `undefined`.

| Underscore form | Promise form | Trap |
|---|---|---|
| `GM_xmlhttpRequest` (lowercase `h`) | `GM.xmlHttpRequest` (**capital `H`**) | The casing flips between the two forms |
| `GM_getResourceURL` (`URL`) | `GM.getResourceUrl` (**`Url`**) | **[VM-verified]** — VM's own list uses the lowercase `rl` |

Grant the exact form you call. Granting `GM_xmlhttpRequest` does not make `GM.xmlHttpRequest`
appear.

## `@grant` asymmetry — the one line that changes behaviour most

**Omitting `@grant` is NOT `@grant none`** [F-VM-GRANT-OMIT].

| Metadata | Sandbox | What exists |
|---|---|---|
| `@grant` **omitted entirely** | **on** | `GM_info`, `GM.info`, `unsafeWindow` only (VM ≥ 2.32.0) |
| `@grant none` | **off** — page context | **No `GM_*` at all**; globals are the page's own |
| `@grant <name>` | on | that API, plus the omitted-case minimum |

So `@grant none` is a *deliberate* choice with a real consequence: it puts the script in page
context, which is why the idempotence guard has to be a `documentElement` marker rather than a
`window` flag ([`patterns.md`](patterns.md) § 8).

## Injection context — no key expresses it portably

| Key | Manager | Values |
|---|---|---|
| `@inject-into` | Violentmonkey **[VM-verified]** | `page` · `content` · `auto` (default) |
| `@sandbox` | Tampermonkey *(flagged)* | `raw` · `JavaScript` · `DOM` |
| `@run-in` | Tampermonkey *(flagged)* | — |

**Rule:** leave injection context unset unless CSP forces your hand. A script that needs a
specific context is a script that will behave differently under the other manager, and no key
says the same thing to both.

## `@run-at` — never rely on the default

**[VM-verified]** Violentmonkey's default is `document-end`. Tampermonkey's is
`document-idle` *(flagged)*. The values and their guarantees are in
[`patterns.md`](patterns.md) § 3.

**Rule:** state `@run-at` explicitly in every script. The cost is one line; the alternative is
timing that changes with the manager and cannot be reproduced from the file.

## `@connect` — declare it even where it is not enforced

Tampermonkey checks `@connect` against **both** the initial and the final URL of a
`GM_xmlhttpRequest`. Violentmonkey parses the key but does not enforce it *(flagged)*.

**Rule:** declare `@connect` for every cross-origin host anyway. It is the only place the
file states its own network reach, it is required for portability, and a reader auditing the
script gets the truth from the header instead of from a grep of the body.

## `@unwrap` and `@top-level-await`

`@unwrap` ignores `@grant` entirely and cannot be combined with `@top-level-await` (VM-only)
*(flagged)*. Neither belongs in a script this skill ships: `@unwrap` discards the sandbox
decision the `@grant` line just made.

## Metadata parsing is stricter than it looks

- **The first value of a single-value key wins; later duplicates are silently discarded**
  *(flagged)*. A second `@version` or `@run-at` added during an edit does nothing — and reads
  as if it does.
- Exactly **one space after `//`**, and the first line is exactly `// ==UserScript==`.
- A blank line after `// ==/UserScript==` before code.

## SRI on `@require` — two different things

A `#sha256=` fragment on a `@require` URL is a **Tampermonkey** feature *(flagged)*; it gives
**no** integrity guarantee under Violentmonkey. Greasy Fork nevertheless accepts that fragment
as a route past its CDN allowlist ([`greasyfork.md`](greasyfork.md) § The four legal `@require`
routes) — **"Greasy Fork will accept it" and "the bytes are pinned for your users" are
unrelated claims.** Hard rule 1 bans CDN `@require` for exactly this gap.

## `chrome.userScripts` is the MANAGER's API, never the author's

A `.user.js` containing `chrome.userScripts.*` is a category error: that API is what
Violentmonkey itself calls to inject, and it is unavailable in page or content context.

The Chrome **138+** *Allow User Scripts* per-extension toggle is the operator's, one time per
profile, at `chrome://extensions/?id=<id>`. **Policy cannot set it and an agent cannot flip
it.** A script that "did not run" is this toggle far more often than it is a bug — Probe 4 in
[`probes.md`](probes.md) is what tells the two apart.

## Flagged — NOT re-verified from primary docs

**Do not cite a row here as settled.** Each names the safe action that holds either way, which
is why the file is usable without them being resolved. Promote a row by reading the manager's
own documentation or source and rewriting it with the date — never by tidying the table.

| Claim | Safe action regardless |
|---|---|
| Tampermonkey's `@run-at` default is `document-idle` | State `@run-at` explicitly, always |
| `@sandbox` values `raw`/`JavaScript`/`DOM`; `@run-in` exists | Leave injection context unset |
| Violentmonkey parses but does not enforce `@connect` | Declare `@connect` anyway |
| `GM_webRequest` removed in MV3 Tampermonkey 5.2+ | Do not use it; it is VM-absent regardless |
| `@unwrap` ignores `@grant`; cannot combine with `@top-level-await` | Ship neither key |
| VM's parser keeps the first value of a duplicated single-value key | Never write a key twice |
| `#sha256=` SRI on `@require` is Tampermonkey-only | Hard rule 1 bans CDN `@require` outright |
