# `llmstxt` — Claude Code plugin

Author a spec-compliant **`llms.txt`** — and, where it earns its place, the de-facto
**`llms-full.txt`** — from any body of written work: a docs tree, a website, a repo, a
portfolio, or a developer accomplishment document.

In-repo plugin, served from the `kattakath-nix-config` marketplace (`plugins/` at the repo
root) and installed declaratively by `modules/shared/home.nix`. Nothing is fetched from a
third-party marketplace, so it cannot drift.

## What llms.txt is

A proposal by **Jeremy Howard (Answer.AI)**, September 2024, revised to **v2 in August
2026** — <https://llmstxt.org> (markdown: <https://llmstxt.org/index.md>; changelog:
<https://llmstxt.org/changes.md>; repo: <https://github.com/AnswerDotAI/llms-txt>).

A markdown file at `/llms.txt`, or at any subpath covering the URLs beneath it, giving an
agent a **curated index** of a body of work. Web pages are built for people — navigation,
ads, scripts — and converting them back to clean text is lossy and expensive. llms.txt
inverts that: a small file that fits in context, pointing at clean markdown that is fetched
only when needed.

### The format

Markdown, in this exact order:

1. an optional byte-order mark;
2. an **H1** with the project or site name — *the only required element*;
3. a **blockquote** summary carrying the key information needed to understand the rest;
4. zero or more markdown sections **of any type except headings** — the detail region;
5. zero or more sections delimited by **H2** headers, each a "file list" whose items are
   `- [name](url)` with optional `: notes`.

```markdown
# Title

> Optional description goes here

Optional details go here

## Section name

- [Link title](https://link_url): Optional link details

## Optional

- [Link title](https://link_url)
```

The `## Optional` section holds, by convention, secondary information — links an agent can
skip when a shorter context is needed. **v2 removed its mechanical meaning**: it used to tell
the `llms_txt2ctx` context-expansion tool what to omit, and v2 dropped that tooling from the
proposal. The convention survives; the defined behaviour does not.

The second half of the proposal is the companion pages: every page an agent might need should
also serve **clean markdown at the same URL**, with `.md` appended (`page.html.md`) or
replacing the extension (`page.md`) — `index.md` for a URL with no filename. v2 adds
discovery via standard link relations, as `<link>` elements or an HTTP `Link:` header:
`rel="alternate" type="text/markdown"` for the markdown version, `rel="describedby"` for the
llms.txt that covers the page.

### `llms-full.txt`

**Not in the spec** — not v1, not v2, and not by accident: a pull request proposing it as an
additional file definition ([AnswerDotAI/llms-txt#70](https://github.com/AnswerDotAI/llms-txt/pull/70))
was closed unmerged in June 2025. It is a vendor/community convention popularised by Mintlify:
one file holding the whole corpus concatenated, for agents that would rather take a single
large fetch than follow N links. Adoption is genuinely split — Anthropic, Cloudflare, OpenAI
and Vercel publish one; Stripe, Gemini and the spec author's own FastHTML docs do not.

Publish it *in addition to* `llms.txt`, never instead, and do not lint it as one. Watch the
size: real ones run to tens of megabytes, which defeats the purpose for most readers.

## What this plugin provides

| Component | Path | What it does |
|---|---|---|
| Skill | `skills/llmstxt/SKILL.md` | The authoring procedure: scope → triage → write → companion markdown → lint → test. Also covers reviewing an existing file. |
| Reference | `skills/llmstxt/reference/spec.md` | Working restatement of the v2 spec with the v1→v2 delta, the `llms-full.txt` caveat, and links to the primary source. |
| Command | `commands/llmstxt.md` | `/llmstxt [path\|url] [--lint] [--full]` |
| Linter | `scripts/llms_txt_lint.py` | Deterministic, **stdlib-only** validator. Errors = spec violations; warnings = the spec's own authoring guidance. |

## Using it

Ask in prose — "generate an llms.txt for my docs", "make this LLM-friendly", "lint this
llms.txt" — or drive it explicitly:

```
/llmstxt ./docs                      # index a docs tree
/llmstxt ./llms.txt --lint           # validate an existing file
/llmstxt ~/notes/impact.md --full    # index one document + build llms-full.txt
```

The linter runs standalone too:

```bash
python3 plugins/llmstxt/scripts/llms_txt_lint.py llms.txt
python3 plugins/llmstxt/scripts/llms_txt_lint.py --strict llms.txt   # warnings fail too
```

Requires only `python3` — **stdlib, no packages**, verified on Python 3.9 (macOS's own
`/usr/bin/python3`) through 3.14, which is what lets it run straight out of a read-only Nix
store path with nothing to install.

Exit `0` clean, `1` findings, `2` usage error. Checks: H1 present and first; single H1; no
headings in the detail region; blockquote present and non-empty; file-list items are real
markdown links; links absolute and pointing at markdown rather than HTML; link notes present;
`## Optional` last; no duplicate sections or URLs; file small enough to sit in context.

## Prior art, and what this reuses

The spec's own [Integrations list](https://llmstxt.org) is the honest starting point: if the
corpus is published by a platform that already emits llms.txt and `.md` page versions —
**Mintlify, GitBook, Wix, Yoast SEO, AIOSEO, `vitepress-plugin-llms`, `docusaurus-plugin-llms`,
Drupal LLM Support, nbdev** — use what it emits and do not hand-write files that will go
stale. The skill says so explicitly.

What *does not* exist upstream is an authoring tool for this job. The ecosystem splits into
two camps, and neither is it:

- **Site/docs-build generators** — the platform plugins above, plus crawlers
  (`dotenvx/llmstxt` is sitemap-only; Firecrawl's generator is deprecated). They take a built
  site or docs tree and mechanically emit an index. They cannot triage a body of writing, and
  they do not apply to a corpus that is not a website.
- **Consumers/parsers** — Answer.AI's own `llms-txt` Python package and its `llms_txt2ctx`
  CLI *expand an existing llms.txt into an LLM context*; MCP servers
  ([langchain-ai/mcpdoc](https://github.com/langchain-ai/mcpdoc),
  [`server-llm-txt`](https://github.com/mcp-get/community-servers/tree/main/src/server-llm-txt),
  now archived) let an agent *fetch and search* llms.txt files. All read the format; none
  writes it — and v2 removed the context-expansion tooling from the proposal outright.

The closest prior art for the part that is actually hard — writing link descriptions worth
reading — is [`llmstxt_architect`](https://github.com/rlancemartin/llmstxt_architect), which
crawls URLs and has an LLM write them. It has been unmaintained since March 2025. No Claude
Code skill or plugin authors llms.txt in `anthropics/skills`,
`anthropics/claude-plugins-official`, `obra/superpowers` or `vercel-labs/agent-skills`; the
community skills that mention it (`Front-End-Checklist`, various SEO packs) *audit* a
published file rather than author one.

**On not reusing a parser.** Off-the-shelf validators do exist —
`turva-llms-txt-validator` and `@25xcodes/llmstxt-parser` (npm),
[`llms-txt-php`](https://github.com/raphaelstolt/llms-txt-php), and `parse_llms_file()` in
Answer.AI's own package. None is in nixpkgs: the only llms.txt-related package there is
`python3Packages.sphinx-llms-txt` (0.7.1), a Sphinx build plugin, not a validator. Reusing
one would mean either a runtime `npx`/`pip` fetch or a new derivation, for a grammar with
exactly one required element. Dependency-free stdlib Python won on determinism — it runs
straight from a read-only store path with nothing to install and no network at check time.
If you would rather lint with an upstream tool, the spec is small enough that swapping is
easy; that is the trade-off, made deliberately.

A linter is not redundant with `claude plugin validate`, and it is not theoretical.
`docs.anthropic.com/llms.txt` uses plain-text list items instead of markdown links and has no
blockquote; `vercel.com/docs/llms.txt` opens with a blockquote and **no H1**, omitting the one
element the spec requires. Both fail this linter. Copying a big name is not a conformance
strategy.

**When it is worth doing at all.** Be honest with users about this: Google Search
[explicitly states it ignores llms.txt](https://developers.google.com/search/docs/fundamentals/ai-optimization-guide),
and Ahrefs' May 2026 crawl of 137k domains found most published files never fetched, with SEO
audit tools the largest single category of requests. llms.txt is not an SEO play. Where it
does earn its keep is the case v2 now leads with — a **coding agent fetching documentation** —
and Claude Code is among the heaviest named agent fetchers of these files. Recommend it for a
corpus agents actually read; do not sell it as a ranking signal.

Related but out of scope: the **ThinkRank** WordPress plugin on this operator's stack exposes
`generate-llms-txt`, `publish-llms-txt`, `get-llms-txt-settings` and `get-llms-txt-status` MCP
tools — evidence of real adoption, and the right tool for a WordPress *site*. It is
site-side publishing, not content authoring, and this plugin depends on none of it.

## Installing / changing it

Installed by `home.activation.claudeCodePlugins` (`modules/shared/home.nix`) as
`llmstxt@kattakath-nix-config`, from a Nix **source path** — `plugins/` is copied into the
store and the marketplace is pinned to that store path.

Editing anything under `plugins/` changes the store path, so activation re-pins the
marketplace and reinstalls the plugin on the next switch. Bump `version` in **both**
`.claude-plugin/plugin.json` and `plugins/.claude-plugin/marketplace.json` when you change
behaviour — `claude plugin tag` validates that the two agree.

```bash
git add -A                                        # flakes ignore untracked files
claude plugin validate --strict plugins/llmstxt   # manifest + component check
claude plugin validate --strict plugins           # marketplace check
nix flake check                                   # fleet-wide evaluation gate
nrs                                               # activate (operator's call)
```
