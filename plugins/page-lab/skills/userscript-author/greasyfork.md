# Publishing to Greasy Fork — the rulebook, and the two rules that surprise people

Sharing a script is the point of writing one. Everything here is from Greasy Fork's own
[Code rules](https://greasyfork.org/en/help/code-rules) — **fetched 2026-09-06**. Sleazy Fork
runs the same codebase and the same rule set, differing only in the site name and one
adult-content line, so **"publishable" needs no per-site variant**.

Publishing is the **operator's** move — an agent cannot drive the account.

## The metadata contract

`scripts/userscript-meta-lint.sh` mechanises this table. Nothing here is a house style; each
row is a rule Greasy Fork enforces or a failure it causes.

| Key | Why |
|---|---|
| `@name` | Required. |
| `@namespace` | Required, and what keeps two authors' identically-named scripts apart. |
| `@version` | Required, and must be **orderable** — Greasy Fork rejects a version it cannot sort, and **ignores a re-upload that does not increment**. Plain dotted-numeric (`2.0.1`). Violentmonkey's own grammar allows `1.2a.3`; do not copy that example. |
| `@description` | Required by the Functionality rule: *"Users must know what a script will do before installing it."* A script may not do things "unreasonably outside" it. |
| `@license` | How Greasy Fork resolves copyright. Omit it and **OpenUserJS silently implies MIT on your behalf** — a licence you did not choose. |
| `@match` | Required, and **only for sites the script actually serves**: *"Scripts may not include `@include`s or `@match`es for sites they do not provide functionality on."* |
| `@homepageURL` / `@supportURL` | Give a published script somewhere to send a bug that is not your DMs. |
| `@antifeature` | **Mandatory** if the script contains anything for the *author's* benefit — tracking, ads, miners. Allowed, but only if [declared](https://greasyfork.org/en/help/antifeatures). Undeclared is a removal. |

### `@antifeature` — the exact value set

Six values, and only six: **`ads`** · **`membership`** · **`miner`** · **`payment`** ·
**`referral-link`** · **`tracking`**. A value outside the set does not declare anything.

Three carve-outs that stop over-declaring, which is its own kind of wrong label:

- Promoting **your own** repo, Discord or homepage is **not** `ads`.
- A script for a site that **itself** requires payment is not `payment` — the key is about the
  *script* charging, not the site.
- `referral-link` covers **commission coupon codes**, not only URLs.

`membership` and `payment` are for a script gated behind your paid tier or purchase.

### Banned outright

`@downloadURL`, `@updateURL`, `@installURL`. Greasy Fork **strips them on upload** and forbids
"alternate download URLs, with the intent of having users use the alternate sources"; it also
notes that "most user script managers will handle automatic updates, so doing it in the script
is unnecessary". Pointed at your own repo they let a push to the default branch mutate an
installed script with no review.

## The `@require` tension — real, and resolved

This is the one place a careful author collides with the rules, so read it before assuming
either side.

> **Greasy Fork:** *"Libraries that a script uses should be `@require`-d, unless there's a valid
> technical reason not to do so. In the case that a library is included inline, it must include
> information as to the source of the library (e.g. a comment indicating URL and/or name and
> version)."*

So Greasy Fork **prefers** `@require` — while this skill's hard rule 1 **bans** it. Both hold:

- **The ban has a valid technical reason**, which is exactly the exemption the rule grants: a
  `@require` is fetched **at install time**, there is **no SRI or integrity field** in the
  userscript metadata spec, and nothing pins the fetched bytes. That is an unpinnable supply
  chain in a file that runs on every page it matches.
- **The rule's own inline path is the answer.** Vendoring is sanctioned — *provided* the
  vendored block carries **name / version / URL**. The lint enforces that: a `vendored` marker
  or a `/*! … */` banner with no source URL within five lines fails.

Do **not** vendor by minifying. "Code posted to Greasy Fork must not be obfuscated or minified…
If the script is bundled by a tool such as webpack, it must be output in non-minified form,
with whitespace and variable names retained." Greasy Fork's own heuristic is a single line
**over 5000 characters containing `function`**; the bundled lint is stricter (500 chars), so a
file that passes the lint cannot trip the site's check.

### The four legal `@require` routes — know them, then don't use them

Hard rule 1 bans CDN `@require` outright, for a reason Greasy Fork's rules do not address: the
userscript metadata spec has **no integrity field**, so nothing pins the bytes a user installs.
These four exist so a *shelf* script's `@require` line can be read correctly, and so "Greasy
Fork accepted it" is never mistaken for "the bytes are pinned".

1. **An allowlisted CDN** — the list at <https://greasyfork.org/en/help/cdns> (~65 regex
   entries). jsDelivr is conditional: `/gh/` paths must be pinned to a **40-hex commit**, `/npm/`
   paths to an exact **version**.
2. **Any URL carrying a Tampermonkey-format SRI fragment** — `#sha256=…` or `#md5=…`, `,`- or
   `;`-separated, `=` or `-` as the separator. This is an **allowlist bypass**, not a guarantee:
   the hash is enforced by **Tampermonkey only** ([`gm-api.md`](gm-api.md) § SRI).
3. **A Greasy Fork Library** — hosted on the site itself, so it is reviewable like any script.
4. **A host that equals, or is a subdomain of, every one of the script's `@match` domains** —
   the undocumented origin-host allowance. It is narrow by construction: one non-matching
   `@match` disqualifies the whole `@require`.

Hard blocks regardless of route: a `data:` `@require` containing `;base64,` is **rejected
outright**. `@resource` is protocol-checked only (`http`, `https`, `data`, protocol-relative
`//`) — no allowlist, no hash, which is why hard rule 1 covers it too.

## Other rules worth knowing before upload

| Rule | Practical effect |
|---|---|
| **2 MB limit**, and you may **not** minify to fit | Move data URIs / JSON out of the script; `@require` a genuine library or vendor it readably. |
| **Primary functionality must be in the code on Greasy Fork** | A stub that loads the real script from elsewhere is not allowed. |
| **No self-update checks more than once/day** | The manager already does this; don't write it. |
| **Adult content must be marked** | Scripts for adult sites — or containing adult content — must be flagged so others can opt out. In practice these land on **Sleazy Fork**. |
| **No unrelated keywords** in name/description | Keyword-stuffing for search placement is a removal. |
| **No reposts** of a script already on Greasy Fork | Unless yours genuinely improves on the original — another reason step 0's shelf check comes first. |
| **Respect copyright** | Vendored code keeps its own licence; check it against your `@license`. |

## Make `git push` the release — without `@updateURL`

Greasy Fork can pull from a raw URL on its own admin page. This is **not** the banned keys:
those live *inside the file* and let a push mutate an installed copy with no review. Sync is a
**site-side setting** — the file stays clean, and users still update *from Greasy Fork*, which
is exactly the norm the ban protects.

| Field | Value |
|---|---|
| Sync source | the **raw** URL — `https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>.user.js` |
| Not | the GitHub *file page* URL — Greasy Fork fetches it verbatim |
| Filename | must end `.user.js` — a plain `.js` is rejected as "not a user script" |

**`@version` is the release trigger.** Sync pulls, but a re-upload that does not increment is
ignored — the same rule as a local re-install.

**Point `sync_identifier` at a raw *branch* URL, never a commit.** Greasy Fork's own wording for
a commit-pinned source: it "will never get updated". A branch URL is what makes the sync a sync.

**One webhook secret per user**, not per script — it authenticates you, and every synced script
of yours rides the same one. Treat it as a credential: never in a file, never in a commit,
never echoed.

Without a webhook, Greasy Fork polls roughly every **12 hours**, and **three consecutive
failures park the script for a month**. So a sync that quietly stopped is not always visible as
an error — a script that has not moved in weeks is the symptom.

### The leniency trap — bump `@version` in the same commit, always

The webhook path saves **leniently**: it auto-confirms **every** warning, *including "version
not incremented"* [F-GF-WEBHOOK-LENIENT]. A push that changes code without bumping `@version` is
therefore **accepted** — no error, no rejected upload — and **silently never reaches installed
users**, because the manager has nothing new to update to.

This is the one failure in the publishing path that reports success on both ends. The habit
that defeats it is mechanical: the `@version` bump and the code change are **one commit**.

## The shelf check

Before authoring anything, both hosts answer "has someone already solved this for this domain"
with one no-auth fetch:

```
https://greasyfork.org/en/scripts/by-site/<domain>
https://sleazyfork.org/en/scripts/by-site/<domain>
```

- Use the **bare** domain — `civitai.com`, not `www.civitai.com`.
- **Check Sleazy Fork too** for an adult-adjacent site. The two run **one codebase** and one
  rule set, but a given site's scripts land on **only one** of them, so a Greasy-Fork-only check
  can read as "nothing exists" when a script does.
- A hit is **evidence, not a dependency**: you still cannot `@require` it, and it is the
  script's **measured selectors and its condition** that are worth having — vendor those with
  attribution, or re-derive them.
- This is also the **no-reposts** rule's practical face: an equivalent script already listed is
  a reason to install it, not to ship a rival.

## Before the first upload

- [ ] Search the by-site index for the domain (§ The shelf check). If an equivalent script exists,
      **install it instead of shipping a rival** — that is both the reuse principle and the
      no-reposts rule.
- [ ] Run the lint clean.
- [ ] Check the listing name does not collide.
- [ ] Decide adult-content marking honestly.
- [ ] Confirm `@description` matches what the script actually does — that is a rule, not a nicety.
