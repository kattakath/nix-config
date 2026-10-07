Part of the [repo map](../repo-map.md) — the full fleet architecture.

## `modules/home/`

`modules/home/{default.nix,gmail-mcp.nix,plugin-mcp.nix,chromium.nix,default-browser.nix,ubersicht.nix,next-right-thing.nix,spotlight-actions.nix,terminal-theme.nix,desktop-aesthetics.nix,launchd-launcher.nix,containers.nix,metube.nix,yt-dlp-web-ui.nix,macos-user-agents.nix,wireguard-configs.nix,claude-otel.nix,claude-bedrock-gate.nix,claude-brain.nix,claude-code-settings.nix,claude-plugins.nix,claude-guardrails.nix,claude-desktop.nix,chromium-extensions/,wallpaper/}`
— the Home Manager profile loaded on every host, and **nothing else**: it is 23 `.nix`,
all home-manager, since `nix-cache.nix` and `nix-ld-libraries.nix` left on 2026-10-02
(ADR-009 §9b) and `macos-user-agents.nix` arrived from `modules/darwin/core.nix` the
same day. This manifest also silently omitted `spotlight-actions.nix` and
`chromium-extensions/` until the same pass.

**It was `modules/shared/` until 2026-10-02**, and the entry point was `home.nix`.
Both renamed together (ADR-009 §8): `shared` named a SCOPE while every sibling
(`darwin`, `nixos`, `parts`, `features`) names a CLASS, and once the two
non-home-manager files left there was nothing left for the scope name to cover.
`default.nix` is what lets the one import site be the directory literal
`../home` (`modules/parts/compose.nix:210`). **The `ast-grep` rule moved in the
same commit** — `files: 'modules/home/**'`, rule and fixtures renamed to
`home-must-not-cross-layers` — because a glob left pointing at the old path
matches zero files and the layer boundary stops existing with CI green. Nothing
in the repo can catch that; see that fixture file's header for the measurement.

- **`default.nix`** (the entry point; was `home.nix`) — git/ssh-signing, zsh+starship, direnv, gh, bash, claude-code + nerd-fonts;
  darwin-only ssh/vscode blocks gated `lib.mkIf pkgs.stdenv.isDarwin`. The ssh block owns
  `Host nixpi.<domain>` with the `cloudflared access ssh` `ProxyCommand` (store path, not
  `/opt/homebrew`) — the *only* remote path to the Pi, and what makes both deploy-rs legs work
  (`ssh` for activation + `nix copy` for the closure); see `deploy.nodes` above. Host-gated: RAG
  (ollama/pgvector) only when `networking.hostName == "macos"`. **The public-MCP-tunnel half of
  that gate is gone** — it went with the gateway on 2026-10-02
  ([`claude.md`](claude.md) § MCP after the gateway).
  `home.packages` also carries `pandoc`/`poppler` (nixpkgs, darwin-only) — together with
  macos's `libreoffice` cask, these satisfy the docx/pptx/xlsx/pdf skills' stated runtime deps
  (LibreOffice/poppler/pandoc), a gap flagged inline at that skills block since it was first
  wired. Also declares a Spotlight-visible, focus-or-launch `.app` bundle for the Android
  emulator (`home.file."Applications/Android Emulator.app"`, backed by
  `packages/spotlight-launchers.nix`, macos-only). The nine COMMAND bundles from the same
  package land via `./spotlight-actions.nix` instead — a separate module so the mapping is
  one `mapAttrs'` rather than nine more `home.file` lines here.
  **Claude Code AGENT TEAMS is enabled here, in two halves that must both be set** —
  `teammateMode = "tmux"` in the settings block (a real top-level settings key, so it goes
  through `claude-code-settings.nix`'s layering like any other) and
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1"` in the session environment. The env var is the
  gate and the mode is the backend: with the var unset the feature stays off whatever
  `teammateMode` says, which is why neither half is meaningful alone. Spawned teammates
  therefore run as **tmux panes** rather than in-process, so a session that uses them wants a
  tmux-capable terminal. `EXPERIMENTAL` is upstream's word, not ours — the flag can disappear
  under a `claude-code` bump, and nothing here pins it.
- **`spotlight-actions.nix`** — macos-only: maps `spotlight-launchers`' `commandApps` **and**
  `aliasApps` into `~/Applications/<name>.app`. The one alias is **`Terminal`**, which opens
  Ghostty, and it works on the bundle's own NAME — verified: `mdfind` for an app named
  `*terminal*` returns both `/System/Applications/Utilities/Terminal.app` and this one. It
  shares that name deliberately (one query, both rows); the gold icon tells them apart, and
  Spotlight's ranking learns which gets clicked. The bundle **id** is NOT shared
  (`com.kattakath.ghostty-terminal`) — a duplicate id makes LaunchServices pick one of the two
  at random for every `open -b` and URL handler.
  It is a SIBLING bundle rather than an edit to `/Applications/Ghostty.app` because that is a
  Homebrew cask: an edit is clobbered by the next `brew upgrade` and breaks the bundle's code
  signature.
  **`CFBundleAlternateNames` was tried and REMOVED**, and the finding is worth keeping: Apple's
  alias key (Calendar answers "iCal", System Settings answers "Preferences") does work on a
  plain unsigned third-party bundle, but NOT through `home.file`'s `recursive = true`, which
  symlinks `Info.plist` into `/nix/store`. Measured 2026-09-23, same bundle both ways: a real
  copied directory indexed all four names, the symlinked one indexed none. The display name
  survives either way because it comes from the filename. Recovering the synonyms would mean
  COPYING the bundle — home-manager's `targets.darwin.copyApps` exists for exactly that, at the
  price of an App Management TCC grant and a subfolder. Uses `home.file` with `recursive = true`, **not**
  home-manager's `targets.darwin.copyApps` ("works with Spotlight",
  `modules/targets/darwin/copyapps.nix:14`): that option's default is
  `isDarwin && stateVersion >= 25.11` and this profile is on 24.05, so what is live is the
  older `linkApps` — `~/Applications/Home Manager Apps` is a SYMLINK into `/nix/store`, which
  Spotlight does not index. Both also nest the bundles in a subfolder, and `copyApps` needs
  the App Management TCC grant (a click, per Mac).
- **`mcp.nix` — DELETED 2026-10-02 (#734); this entry is a RECORD, not a live file.** What it
  was: the fleet MCP gateway, one `mcp-proxy` hosting every server with **no plugin
  owner**, reached by every client as ONE portal connector. See
  [`mcp-gateway.md`](../mcp-gateway.md) for the roster, the counting convention (entries vs
  capabilities) and § Which lane — the 2026-09-30 ownership split that sends a skill's tool half
  into that skill's marketplace plugin instead. **There are NO per-client stdio servers**: the
  `open-design` entry that used to be the exception left the fleet on 2026-09-22 (the APP is still
  a cask — only its stdio MCP server is gone; [`open-design.md`](../open-design.md)).
  **DELETED 2026-10-02 (#734)** — 1,181 lines, gone with the Cloudflare stack. The paragraph
  above is kept as the record of what it did, not as a description of a file that exists. It
  remains the SOURCE OF RECORD for every server's real command, version pins and Keychain
  service id, which is where `gmail-mcp.nix` and `plugin-mcp.nix` read theirs from rather than
  re-deriving them off an upstream README — recover it with
  `git show 4f9ea50^:modules/shared/mcp.nix`, never from an upstream default.
- **`gmail-mcp.nix` + `plugin-mcp.nix`** — the LIVE MCP lane, and the whole pattern in two
  modules. Claude Code spawns a plugin-declared stdio server per session; a plugin's `.mcp.json`
  can set `env` only to literals or `${VAR}` passthroughs, so it **cannot** run a Keychain read.
  So the split is: the launcher BINARY here, the `.mcp.json` naming it by binary name in
  `github:kattakath/skills`. Same arrangement `page-lab` already has with `page-lab-pick`.
  - **THE JOIN IS GATED IN BOTH DIRECTIONS, and the second direction crosses the repo
    boundary.** `plugin-mcp.nix` types `local.pluginMcp.servers` as an **enum**, so naming a
    server this fleet cannot build fails at eval — that is the forward half, and it has always
    been there. `checks.<system>.mcp-launcher-parity` (2026-10-02) is the reverse half: it reads
    every `plugins/*/.mcp.json` out of the pinned `kattakath-skills` input at **eval** time
    (`builtins.readDir`/`readFile` over a realised input — no import-from-derivation, no
    network) and asserts SET EQUALITY between the `nix-mcp-*` commands those plugins name and
    the `nix-mcp-*` derivations `macos` actually composes into `home.packages`. Measured
    2026-10-02 at pin `5ba108f`: **8 = 8**, no drift either way.
    - **The built side is read off the composed package list, not re-derived.** A check that
      re-applied gmail's address sanitisation would agree with a broken rule by sharing it.
      Derivation name == binary name for all three builders (`writeShellScriptBin` in
      `packages/keychain-mcp.nix` + `packages/gmail-mcp.nix`, `writeShellApplication` in
      `packages/mcpfinder-mcp.nix`), each emitting exactly one `$out/bin/<name>`.
    - **Scope is the `nix-mcp-` prefix, and the exclusions are structural.** Of the 16 servers
      the plugins declare, 8 are out of this lane: `memory` and `chrome-devtools` are
      `${CLAUDE_PLUGIN_ROOT}`-relative, which expands **only** inside the owning plugin, so no
      PATH binary can exist for them even in principle; `mcp-nixos` and `terraform-mcp-server`
      are bare nixpkgs binaries installed as ordinary packages; `mobile-mcp`,
      `macos-automator`, `sequential-thinking` and `kapture` are `npx` invocations with no
      fleet binary at all.
    - **Why EQUALITY and not containment — the previous pin is the measurement.** At
      `cc56d06` (two days older) the tree held **zero** `plugins/*/.mcp.json`; the MCP
      ownership split landed after it. A forward-containment gate ("every plugin-named command
      is built") would therefore have been **vacuously green** over an empty left-hand set — a
      gate that passes without testing anything, which is worse than no gate. Set equality
      instead reports `0 declared vs 8 built` and goes **red**, which is what makes the pin
      bump load-bearing rather than cosmetic.
    - **The two non-empty legs are not redundant with that.** Equality alone is degenerate if
      both sides empty at once (host lists cleared *and* layout moved), and — the everyday
      value — a layout regression otherwise reads as "8 orphans", sending the reader to
      `hosts/macos.nix` when the fault is the pinned tree. Verified by pointing the plugin
      directory at one holding no `.mcp.json`: three legs red, the **first** of them naming the
      tree rather than the host.
    - **The cost, stated:** `kattakath-skills` is now load-bearing for a second thing, so an
      MCP server added over there needs this pin bumped here to stay green.
      `.github/workflows/update-flake-lock.yml` bumps every input weekly and arms auto-merge,
      so the join is re-checked on a reviewable PR rather than never — the lag is bounded at
      one week, not unbounded. When a leg goes red, the plugin is **already** broken on this
      Mac (the marketplace tracks HEAD, not this pin); the stuck lockfile PR is the symptom,
      not the fault.
  - `local.gmailMcp.accounts` → `nix-mcp-gmail-<sanitised-address>`, one per Gmail account
    (`packages/gmail-mcp.nix` — its own file because it materialises an OAuth keys FILE with
    `umask 077` set BEFORE creation, and derives a per-account `--tool-prefix`).
  - `local.pluginMcp.servers` → `nix-mcp-{wordpress,apify,postgres}`, the three CREDENTIALED
    servers the purge left homeless. One generic `packages/keychain-mcp.nix` builds all three —
    it is the extracted form of the gateway's own `mkGeneratedStdio`, so there is no second copy
    of "export N variables, exec a pinned interpreter". It writes NO file, so it needs no umask;
    credentials reach the server through its environment, never argv.
  - Secret handles (NAMES only; values stay in the login Keychain): `mcp:apify.com:token`,
    `mcp:silvercreek.ai:wp_url` / `:wp_user` / `:wp_app_password`. `postgres` needs none — its
    `DATABASE_URI` is the local-rag capsule's `local.rag.pgvector.databaseUri`, loopback `trust`
    with no password, and the module ASSERTS `local.rag.pgvector.enable` so it cannot declare a
    server pointing at a store that is switched off.
  - **Baking the absolute `npx` is NOT sufficient, and this is the trap.** `npx` honours its own
    store-path shebang, then execs the DOWNLOADED package's bin, whose shebang is
    `#!/usr/bin/env node` — resolved from the CALLER's PATH. Measured 2026-10-02:
    `@apify/actors-mcp-server` died with *"requires Node.js 22 or later (you have v20.20.2)"*
    under fnm's node, until the launcher PREPENDED the pinned `nodejs`/`uv` bin dir to `PATH`.
    The gateway never hit this because its launchd agent already carried `pkgs.nodejs` on PATH;
    a plugin-spawned launcher has no such PATH control. `gmail-mcp.nix` bakes `npx` the same way
    and does **not** prepend — it works today only because its server tolerates node 20.
  - All three were smoke-tested through a real MCP `initialize` before being declared, not just
    evaluated: wordpress reported `Connection successful` against silvercreek.ai PROD, apify
    registered its Actor tools, postgres logged `Successfully connected to database`.
- **`chromium.nix`** — `local.ungoogledChromium`, real-Mac-only: the declarative surface for
  the Homebrew `ungoogled-chromium` cask. Installs **no** browser (`programs.chromium.package =
  null`) — nixpkgs' `chromium`/`ungoogled-chromium` are `*-linux` only, so the `.app` must be a
  cask; this module contributes only the files Chromium reads out of its user-data dir, via
  upstream HM `programs.chromium` (no custom shell), plus two recommended-level policies. The
  LaunchServices default-browser claim is NOT here any more — it left with `local.defaultBrowser`
  when Chromium stopped being the default (`chromium.nix:10`). Five surfaces, five sideloaded
  extensions:
  - **`External Extensions/<id>.json`** — pinned `fetchurl` CRXes installed as
    `external_crx` + `external_version`. The Web Store `external_update_url` is **dead** here
    (ungoogled's `disable-webstore-urls.patch`), so a local CRX is the only path; the official
    extension ID survives because it derives from the signed CRX3 public key, not the path.
    One option per extension, all defaulting on:

    | Option | Extension | MV | Note |
    |---|---|---|---|
    | `applePasswords` | iCloud Passwords | 3 | also plants the native host below |
    | `adBlock` | uBlock Origin | **2** | the **real** MV2 build, not uBO Lite |
    | `userScripts.enable` | Violentmonkey | 3 | also materialises `userScripts.scripts` |
    | `claudeInChrome` | Claude in Chrome | 3 | native host is claude-code's, not ours |
    | `kaptureMcp` | Kapture MCP Browser Automation | 3 | browser end only; per-tab gate is **DevTools** |
    | `darkTheme` | Into The Black Hole | 2 | code-free theme (a `theme` key, nothing else) |

    `adBlock` gets the **real MV2** uBlock Origin — with blocking `webRequest`, not
    `declarativeNetRequest` — because ungoogled's `extensions-manifestv2.patch` makes
    `ShouldDisableLegacyExtensions()` return false unconditionally. Chrome and Brave cannot.
    **Two browser-automation extensions, on purpose.** Both hold `debugger` +
    `<all_urls>`; they differ in *who can reach them*, which is the whole point:

    | | `claudeInChrome` | `kaptureMcp` |
    |---|---|---|
    | Transport | native messaging | DevTools panel → local bridge |
    | Reachable by | the one CLI its host manifest names | any MCP client that speaks to the bridge |
    | Per-tab gate | none | **must open DevTools + connect** |
    | Fails when | its tools never load into the session | the `npx` bridge isn't running |

    `claudeInChrome`'s `com.anthropic.claude_code_browser_extension` native host is written
    by claude-code itself (its `path` must track the current CLI install), so this module must
    **not** re-declare it — only Apple's host needs replanting. `kaptureMcp` needs no host at
    all, but its **server half is not declared here**: `~/.claude.json` runs
    `npx -y kapture-mcp@latest bridge` at user scope — imperative and unpinned, so it can
    change under a session with no rebuild. Its declarative home is the `page-lab` plugin's
    `.mcp.json` (where `kapture` moved on 2026-09-30), **not** this repo — there is no gateway to
    declare it in since 2026-10-02 ([`claude.md`](claude.md) § MCP after the gateway).
    (Historical note: the kapture *gateway* entry was removed 2026-08-22 along with the whole
    public-MCP-exposure subsystem; that removal was about the gateway and the Cloudflare
    tunnel, not about the tool, and this extension does not resurrect either. It outlived both
    the subsystem's return and its final teardown — which is the point: the extension is a
    browser capability, never a gateway one.)
  - **`NativeMessagingHosts/com.apple.passwordmanager.json`** — Apple's own native-messaging
    manifest, re-pointed at Chromium. macOS ships it to **Chrome and Firefox only**; replanting
    it is what makes Passwords.app autofill here, and it is safe because the manifest gates on
    **extension ID** (`allowed_origins`), not on browser brand.
  - **`userScripts.scripts`** — an `attrsOf (nullOr path)`, attr name → `.user.js` source, each
    materialised to `~/.local/share/userscripts/<name>.user.js` (an **XDG runtime** path;
    deliberately not `~/Documents`/`~/Desktop`, which are TCC-walled and would need Chromium a
    Full Disk Access grant to read a `file://` from) plus a generated `index.html` of install
    links. `null` (e.g. `lib.mkForce null`) keeps a declaration but skips the file.

    **EMPTY since 2026-09-14, and kept on purpose.** No host declares a script any more —
    every one was published to Greasy/Sleazy Fork instead (see [`packages.md`](packages.md)
    § Userscripts for the trade). `xdg.dataFile` is gated on the attrset being non-empty, so an empty one writes
    nothing at all; `enable` still sideloads Violentmonkey itself, which is what the published
    scripts install into. The option stays because it is a free seam and a private script that
    must not reach a public fork is still a real case. It remains the public/private merge
    point, so if both repos ever repopulate it, **keys must be distinct** — the module system
    treats a repeated key as a **conflict**, not an override.

    **Nix owns the files, never Violentmonkey's database**, and that is a Chromium wall rather
    than a shortcut. bitbloxhub's Firefox pattern (enterprise policy → `browser.storage.managed`
    → a Violentmonkey *fork* that parses it at startup) does **not** port: the fork's hook is
    Firefox-gated, Chromium only populates `chrome.storage.managed` for extensions declaring a
    `storage.managed_schema` (Violentmonkey declares none), and the *forced* policy level the
    fork would need lives in MDM-owned `/Library/Managed Preferences/org.chromium.Chromium.plist`,
    unreachable from Home Manager (the **recommended** level is reachable — see
    `hideBookmarkBar` below — but it cannot lock a value, which is what that trick relies on).
    A userscript is installed by **navigating** to it, so a declared script cost one click per
    script off the index page and had **no update channel** — `checks.<system>.userscripts`
    banned `@downloadURL`/`@updateURL`/`@installURL` outright (pointed at this repo they would
    let a push to `main` mutate an installed script with no activation), so every change was a
    `@version` bump plus that same click-through. That gate is gone with the scripts; a
    fork-published copy gets the `@updateURL` the declared one was forbidden, which is exactly
    why the fleet stopped declaring them.
    **Never put a secret in a userscript** — `source` is
    copied into the world-readable store, private flake or not.
  - **`hideBookmarkBar`** — one of two *policy* surfaces, and the place this repo writes
    Chromium's own preferences domain: HM `targets.darwin.defaults."org.chromium.Chromium"` sets
    `BookmarkBarEnabled = false`, so **View ▸ Always Show Bookmarks Bar** starts OFF (it seeds
    the `bookmark_bar.show_on_all_tabs` pref). macOS has **no** policies-JSON directory — that is
    the Linux path; Chromium's platform loader reads CFPreferences and grades every key by
    `CFPreferencesAppValueIsForced`: forced → **mandatory** (greys the menu item out, and only an
    MDM configuration profile in `/Library/Managed Preferences/` can set it), everything else →
    **recommended**. So the plain, unprivileged user domain is precisely the level that means
    "off by default, still toggleable", and a manual tick then wins for good. HM applies it with
    `defaults import`, which **merges**, so Chromium's own state in that domain survives.
    - **No sibling for View ▸ Always Show Toolbar in Full Screen.** That is
      `browser.show_fullscreen_toolbar`, a macOS-only *profile pref* with **no policy behind
      it** — this cask's Chromium 152 carries a 579-name policy table (`AIModeSettings` →
      `XSLTEnabled`) with nothing fullscreen-toolbar-shaped in it. The only remaining lever is
      the profile's `Preferences` JSON, browser-owned mutable state Nix must not seed (same
      class as `extensions.pinned_extensions`), so it stays a one-time manual click.
  - **No default-SEARCH-ENGINE option — tried, shipped, and removed 2026-08-31.** Worth keeping
    the negative result: ungoogled ships **no working prepopulated engine**, because
    `replace-google-search-engine-with-nosearch.patch` rewrites Google's row of
    `prepopulated_engines.json` into a "No Search" stub, so a fresh profile's picker reads *No
    Search (Default)*. A `defaultSearchProvider` option seeding the `DefaultSearchProvider*` set
    looked like the fix and **evaluated, activated, and verified green from Nix's side** — the
    plist was written and `chrome://policy` showed every key arriving with Source `Platform`,
    Level `Recommended`. The browser then **refused it**: `DefaultSearchProviderEnabled` reported
    *"This policy is blocked, its value will be ignored"* and the other four cascaded to `Error`
    behind the dead main switch, while `BookmarkBarEnabled` in the same table read `OK`.
    - **Lesson, and the reason this paragraph exists:** upstream `can_be_recommended: true` is a
      *hint*, not a guarantee — the set carries it and is still mandatory-only in practice.
      **`chrome://policy` is the only real test of a policy's tier**, and a policy can arrive
      correctly and still be ignored. Mandatory would need an MDM-installed
      `/Library/Managed Preferences` plist and would **padlock** Settings ▸ Search engine, which
      is worse than a click. Do not re-attempt.
    - **Manual instead, once per profile:** DuckDuckGo is prepopulated → ⋮ ▸ *Make default*.
      Google is not (its row is stripped) → Settings ▸ Search engine ▸ Site search ▸ **Add**,
      name `Google`, shortcut `google.com`, URL `https://www.google.com/search?q=%s`.
    - **Adding an engine hits the same wall**: `SiteSearchSettings` and
      `EnterpriseSearchAggregatorSettings` are mandatory-only too, and engines they create can
      never be promoted to default (`CreatedByNonDefaultSearchProviderPolicy`).
  - **`makeDefaultBrowser`** — the one surface that is neither a user-data-dir file nor a policy:
    it claims LaunchServices' `http`/`https` handler for Chromium with nixpkgs'
    **`defaultbrowser`** (darwin-only, substitutable from cache), run from a Home Manager
    activation step. The argument is the **short name `chromium`**, not the bundle id —
    `org.chromium.Chromium` is rejected as "not available as an HTTP handler". The `defaultbrowser`
    CLI also lands on PATH as this setting's read-only doctor: **no arguments** prints the handler
    list with the current default starred.
    - **Idempotent by the tool's own guard**, not ours: it reads the current handler first and
      early-returns with "chromium is already set as the default HTTP handler", never touching
      LaunchServices. A settled Mac is a true no-op.
    - **One consent dialog, once**, on the activation that actually changes the handler (a fresh
      or reset Mac) — unavoidable, and the reason the idempotence above matters. `defaultbrowser`
      calls Launch Services' `LSSetDefaultHandlerForURLScheme`, whose SDK-declared replacement
      `-[NSWorkspace setDefaultApplicationAtURL:toOpenURLsWithScheme:completionHandler:]` is
      documented in the macOS 26 `AppKit/NSWorkspace.h` as: *"Some URL schemes require user
      consent before you can change their handlers. If a change requires user consent, the system
      will ask the user asynchronously"*. The browser schemes are exactly those, for every tool
      and every API. The legacy call is still safe to use — that same SDK declares it
      `API_TO_BE_DEPRECATED`, i.e. soft-deprecated with **no** removal version.
    - **`duti` passed over**: it takes bundle ids but has no idempotence guard, so it would
      re-ask on every activation. The step also tolerates its own failure, because the `.app` is
      a Homebrew cask and nothing orders brew's activation before Home Manager's — a first-ever
      rebuild warns and retries next time rather than failing over which browser opens a link.
  - **No policy can tidy the NEW-TAB PAGE** — a settled dead end, not an omission. **Every** NTP
    policy Chromium defines is **mandatory-only**: `NewTabPageLocation`, `NTPCardsVisible`,
    `NTPCustomBackgroundEnabled`, `NTPMiddleSlotAnnouncementVisible`, `NTPOutlookCardVisible`,
    `NTPSharepointCardVisible`, `NTPContentSuggestionsEnabled` and both `NTPFooter*` all **omit**
    `can_be_recommended` in their upstream `policy_definitions/**.yaml`, which defaults it to
    false. Absence is the answer, not a metadata gap — the flag is written explicitly when true,
    and both policies this repo *does* ship (`BookmarkBarEnabled`,
    `DefaultSearchProviderSearchURL`) carry `can_be_recommended: true`. `NewTabPageLocation`'s own
    `desc` says it outright: "configures the default New Tab page URL **and prevents users from
    changing it**". A padlocked new-tab page is worse than a click, so it stays unset. Nor is
    there any policy that hides just the **shortcut tiles**: the one shortcut-shaped policy,
    `NTPShortcuts`, goes the wrong way (it *pre-configures up to 10 organization shortcuts in
    addition to* the user's own) and is mandatory-only too. Hiding the tiles writes a
    profile-JSON pref (`custom_links.*` / `home.module.most_visited.enabled`), browser-owned
    mutable state Nix must not seed → one click in **Customize Chrome ▸ Shortcuts ▸ Hide
    shortcuts**. ungoogled's `--custom-ntp` flag is not a route either: `chromium-flags.conf` is
    Linux-only, so on macOS it needs `chrome://flags`.
  - **Three manual, one-time clicks Nix cannot do:** Chromium parks every *externally* installed
    extension disabled pending acknowledgement on macOS (enable once → `ack_external` sticks;
    `ExtensionInstallForcelist` can't help, it needs the patched-out Web Store), and Chrome 138+
    gates Violentmonkey's `userScripts` permission behind a per-extension "Allow User Scripts"
    toggle that is deliberately not settable by policy, plus its sibling "Allow access to file
    URLs" toggle, without which it refuses a `file://` install off the index page (fallback:
    paste the script into Violentmonkey's own editor). The theme rides the same gate — until
    it is enabled once, Chromium unpacks it but leaves `extensions.theme` unset and the browser
    still looks stock.
- **The media stack is a CAPSULE, not a module in this directory.** `media-queue.nix`, the
  media CLIs and the Finder Services left for
  [`kattakath/nix-media-cli`](https://github.com/kattakath/nix-media-cli) on 2026-09-05 and came
  back in-tree on 2026-09-12 as `modules/features/media-cli/` (ADR-002 wave 5). They reach the
  Mac as one home-manager module: `local.mediaCli.enable`, set from `modules/home/default.nix` on
  `isMacosHost`. Everything that used to be documented here — the three `QueueDirectories`
  tiers, `ProcessType = "Background"`, the `SIGSTOP`/`SIGCONT` pause, the `MAINPID` orphan
  adoption, the deliberate absence of a GUI status surface — lives with the code, in that
  capsule's `packages/media-queue.nix` header and `module.nix`.

  Two things changed in the EXTRACTION and are worth knowing here, because both were invisible
  couplings this repo was supplying by accident — and both survived the absorption unchanged,
  which is the point of bringing the code back rather than the old vendored shape:

  - **The launchd `arg0`.** The agents' `nix-media-queue` basename came from this repo's
    VENDORED `hm-launchd` fork; upstream home-manager emits `/bin/sh -c 'wait4path … && exec …'`
    instead. That is not cosmetic — a `/nix/store` arg0 is what lets the worker read the
    TCC-protected folders it exists to work on. The capsule's module therefore builds its own
    named wrapper, so it needs no fork and works on stock home-manager — and
    `checks.<system>.media-cli-module` asserts the arg0 is both `nix-*` AND a store path.
  - **The vision model** was a hardcoded literal, so no environment variable could have
    overridden it. It is now a `defaultModel` derivation argument, surfaced as
    `local.mediaCli.visionModel`.

  `rclip` stays HERE (`rclipCli` in `modules/home/default.nix`, with its `dontCheckRuntimeDeps` override and
  `RCLIP_USE_ONNX_ON_MACOS`): it is a third-party search tool this repo merely installs, and
  the VECTOR half of retrieval, deliberately independent of the XMP half. It reaches the stack
  through that module's `extraSearchPackages` seam, alongside `exiftool` and `auge`.
- **`default-browser.nix`** — `local.defaultBrowser`, a fleet-level concern rather than a
  Chromium one: the HTTP/HTTPS handler is a LaunchServices property any installed browser can
  hold, so it moved out of `chromium.nix` once Chromium stopped being the daily browser and
  became the debugging one. Takes `defaultbrowser`'s SHORT name — the last dot-component of the
  bundle id, lowercased (`com.google.Chrome` → `chrome`, `org.chromium.Chromium` → `chromium`,
  also `operaair`, `opera`, `safari`); a bundle id itself is rejected, and `null` claims
  nothing. **The fleet holds `chrome`, and the reason is PASSKEYS, not preference.** Reaching a
  macOS Passwords.app passkey needs the RESTRICTED entitlement
  `com.apple.developer.web-browser.public-key-credential`, which Apple grants per-Team-ID to
  registered browser vendors on request. Verified 2026-09-15 with `codesign -d --entitlements`:
  Chrome (`EQHXZ8M8AV`) carries it plus `com.google.common.folsom` (iCloud Keychain) and
  `com.google.Chrome.webauthn{,-uvk}` (Touch ID); Opera and Opera Air carry the same shape;
  Safari has the WebKit equivalent; **ungoogled-chromium carries NEITHER** — seven
  entitlements, all hardware/sandbox, and no `keychain-access-groups` key at all. So no
  Chromium swap fixes it, and the plain (googled) `chromium` cask is worse: DISABLED in
  Homebrew since 2026-09-01 for failing the Gatekeeper check. A community rebuild can never
  obtain the grant — do not re-attempt. The sideloaded iCloud Passwords extension does not
  rescue it either; that does passwords, while a macOS passkey comes from the
  AuthenticationServices API the browser itself calls. Two behaviours worth knowing before
  blaming an activation: the tool early-returns when the handler already matches, so a settled
  Mac is a true no-op; and the activation that actually CHANGES it raises one macOS consent
  dialog, which is Launch Services' documented behaviour for browser schemes, not a bug. `duti`
  was passed over — bundle ids, but no idempotence guard, so it would re-ask every activation.
- **`ubersicht.nix`** — `local.ubersicht`, the fleet's ONE Übersicht widget: `htmlWidget` is
  a runtime shell path (a `$HOME` string, never a store path) to a single HTML file the widget
  `cat`s and renders full-screen with no chrome, re-read every `refreshMinutes` (5). A plain
  `home.file` symlink into Übersicht's watched widgets directory
  (`~/Library/Application Support/Übersicht/widgets/html-fullscreen.jsx`) — hot-loaded, no
  activation shim, no launchd unit. Upstream-first: neither home-manager nor nix-darwin has an
  Übersicht option (grepped 2026-09-15). The app itself is the `ubersicht` cask in
  `hosts/macos.nix`; the file goes into an `<iframe srcDoc>` so a full HTML document keeps its
  own `<head>`/CSS instead of leaking into Übersicht's page. The file lives in
  `~/.local/share/ubersicht/`, NOT `~/Documents`/`~/Desktop`/`~/Downloads`: Übersicht shells out
  via `/bin/sh`, which TCC denies in those three.
- **`next-right-thing.nix`** — `local.nextRightThing`, the generator that decides what the
  Übersicht widget SAYS. Split from `ubersicht.nix` so that module stays "render whatever HTML is
  at this path" and remains reusable; `local.ubersicht.htmlWidget` is single-sourced from
  `outputPath` here so writer and reader cannot drift. A `launchd.agents.next-right-thing`
  (`StartInterval`, default 20 min, `nix-next-right-thing` arg0 via `launchd-launcher.nix`) runs
  six scripts from `packages/next-right-thing/`: `probe.sh` is cheap change-detection that decides
  whether a run earns a model call at all, `gather.sh` collects candidate signal as plain text
  using no MCP and no model, `art.sh` caches a fallback wallpaper, `decide.sh` calls `claude -p`
  under an enumerated read-only tool allowlist (never `tg_send`, and never `tg_read` — despite the
  name it MARKS MESSAGES READ), `render.sh` emits one self-contained Duochrome card, and `run.sh`
  publishes atomically via a same-filesystem rename. The `probe`/`gather` pair is the cost control:
  the expensive step is reached only when something actually changed. It shows exactly ONE
  action: a dashboard forgives a bad ranking because the eye finds the real item among nine, but
  with one card a wrong pick IS the product — hence the art fallback, which lets the generator
  decline to speak. Darwin-gated; a clean no-op on `nixpi`.
- **`terminal-theme.nix`** — `local.terminalTheme`, the ONE place the fleet's 16-slot ANSI
  ring, ground/ink/cursor, and font face + per-surface sizes are stated. Publishes a derived
  view at `config.lib.terminalTheme` (`byName`, `ghosttyPalette`, `toRgb16`) through
  home-manager's own `options.lib` extension point (pinned `modules/misc/lib.nix:5`) — the
  same seam `config.lib.base16` and `config.lib.stylix` use. **Pure options, no packages, no
  activation, no platform gate**, so it evaluates on `aarch64-linux` too; each consumer keeps
  its own gate. Ghostty and VS Code take **16/16** slots, Terminal.app **4/16** (an OS
  ceiling, not a gap — `sdef Terminal.app | grep -ci ansi` is `0`). Before this existed, VS
  Code held **pre-lift Tango in 7 of 16 slots** while Ghostty held the WCAG-corrected values.
  **stylix was rejected on measurement, not taste** — its Ghostty target hardcodes
  `"9=${base08}" … "14=${base0C}"`, so brights collapse onto normals and 8 of 16 values come
  out wrong, for +16 lock nodes. Full reasoning: [`terminal-theme.md`](../terminal-theme.md).
- **Ghostty** (`programs.ghostty` in `modules/home/default.nix`, `macos` only) — GPU-accelerated terminal,
  installed as a **Homebrew cask** because nixpkgs' `ghostty` is **Linux-only** and refuses to
  evaluate on aarch64-darwin. That is precisely the case home-manager documents for
  `package = null` ("set this on platforms where ghostty is not available"), so the cask ships
  the app and Nix owns nothing but `$XDG_CONFIG_HOME/ghostty/config` — the same split already
  used for the ungoogled-chromium cask. Settings deliberately **match the existing terminal**
  rather than introduce a second look. **Colours and type are not stated here at all** —
  they come from `terminal-theme.nix` via `programs.ghostty.themes.fleet`, selected with
  `settings.theme = "fleet"`, which is upstream's own option for exactly this (pinned HM
  `modules/programs/ghostty.nix:67`, written to `$XDG_CONFIG_HOME/ghostty/themes/<name>` at
  `:172-179`). **The inline colours had to be DELETED, not merely supplemented**: an explicit
  `background`/`foreground`/`palette` in `settings` overrides a theme's, so keeping both would
  make the theme file dead weight. System-following stays off deliberately, but is now
  *reachable* — `light:NAME,dark:NAME` applies to `theme`. The palette's derivation lives in
  [`terminal-theme.md`](../terminal-theme.md).

  On the SPLITS specifically, a nine-agent workflow derived four alternatives that improved
  the contrast numbers and each lost the thing worth having — the winner lifted the *unfocused* ground and thereby made the panes you
  are **not** in the loudest thing on screen, which no contrast metric can see.
  **`unfocused-split-fill` is deliberately unset**: it then defaults to `background`, so the
  unfocused ground is unchanged and only the text dims (17.58:1 → 6.80:1). Ground stays
  identical across both panes *and* the titlebar. **`window-titlebar-background` is not used**
  — Ghostty's own docs say it "only takes effect if window-theme is set to ghostty" and is
  "currently only supported in the GTK app", so on macOS it validates but is **inert**; the
  titlebar takes `background`, and `macos-titlebar-style` is the only real lever.
  `enableZshIntegration` is deliberately **off**: it sources the integration script out of the
  Nix `package`, which is null here, so it would point at nothing — the cask's app bundle
  injects shell integration itself.
- **`desktop-aesthetics.nix`** — the macOS desktop look, split in two:
  - **Terminal.app** is UNGATED on every darwin host — type on EVERY profile, and the four
    colours macOS actually exposes (`background`/`normal text`/`bold text`/`cursor`) plus
    `font name` on `Pro`, which this block also forces as default/startup. Values come from
    `terminal-theme.nix`; this module owns **delivery**, never the palette. Driven through
    Terminal's own AppleScript `settings set` API since Terminal owns `com.apple.Terminal`
    and clobbers direct plist writes. Guarded on Terminal already running so a rebuild never
    launches it — with **`pgrep -x Terminal`, never a `ps | grep -q` pipe**. An earlier
    comment claimed the opposite ("`pgrep` can't see it from activation"); that was a
    misdiagnosis. home-manager's generated activate script runs under `set -o pipefail`,
    `grep -q` exits the instant it matches, the closed pipe kills `ps` with SIGPIPE, and the
    pipeline reports 141 on a *successful* match — so the guard skipped forever on a Mac
    where Terminal was running. Measured in the real activation context
    (`launchctl asuser <uid> sudo -u <user>`): the pipe form exits 141, `pgrep` exits 0. Rule:
    no pipe in a guard that runs under `pipefail`. Every property
    is compared before it is written, so a settled Mac is a true no-op. This repo used to
    VENDOR an "Ubuntu" profile + generator here; #319 dropped that, and Apple's scripting
    interface replaced it — which is also why the ANSI ring is unreachable (it lives only in
    the NSKeyedArchiver blobs a `.terminal` profile carries). Writes **unversioned user
    state**: `home-manager rollback` does not revert `com.apple.Terminal`.
  - The **custom wallpaper** stays behind `local.desktopAesthetics.enable` (default true;
    the former `macvm` guest set it false as a visual tell).
- **`wireguard-configs.nix`** — operator-managed WG confs synced to `~/.config/wireguard`, no
  autostart; import-only for the `WireGuard.app` GUI (the `vpn` CLI left with the `macvm`
  guest, 2026-09-05 — [`macvm-readd-runbook.md`](../macvm-readd-runbook.md)).
- **`containers.nix`** — `local.containers`, darwin-only: the **per-user** container runtime,
  Colima declared through home-manager's own `services.colima` (upstream-first — the pinned
  nix-darwin has no `virtualisation.*` namespace at all, so a system-level answer does not
  exist). It replaced the **Docker Desktop cask**, which could not be owned declaratively:
  measured on `macos` 2026-09-16, `/Library/LaunchDaemons/com.docker.socket.plist` hardcodes
  the account that first launched the app and `/var/run/docker.sock` is a symlink *into that
  account's home*, so every other account gets `EACCES` and launching the app as the second
  user re-binds the helper and breaks the first. Colima is per-user by construction — one
  launchd agent in the user's own gui domain, `$COLIMA_HOME` and the docker socket under the
  user's home — so two accounts mean two VMs and no shared helper to fight over. Genuinely
  custom here: nothing but the `enable` switch and the profile's `settings` values.
- **`claude-code-settings.nix`** — makes Claude Code's **user-scope** `settings.json` LAYERED:
  a Nix-owned floor re-asserted every rebuild, merged over a real, writable file the app and
  the operator can change. Exists because of an UPSTREAM design, not a local mistake: the
  pinned home-manager's `programs.claude-code` `install -Dm444`s settings.json into the store
  and symlinks it, so the app cannot persist what its UI writes and a rebuild reverts it — and
  reading `options.nix` in full turns up **no** mutability option. The operator meets this as
  "I cannot change the Bedrock model", with the chicken-and-egg that the agent needed to
  diagnose it is the one that just lost its model. **Why a merge and not
  `mkOutOfStoreSymlink`:** out-of-store hands over the whole file, floor included, and there
  is no second user-scope file to split the floor into (`settings.local.json` is PROJECT
  scope); nor can the floor move up to managed, whose § SCOPE RULE admits only the two
  never-negotiable rules and whose § COVERAGE LIMIT records that managed settings do not
  reach an Anthropic-hosted cloud session.
- **`claude-otel.nix`** — `local.claudeOtel`, real-Mac-only: a local OTel Collector
  receiving Claude Code's native OpenTelemetry `tool_decision`/`tool_result` events over
  localhost OTLP, writing a rotating JSONL for `/routing-review` to mine for
  deterministic-routing hardening candidates. See
  [`claude-code-observability-runbook.md`](../claude-code-observability-runbook.md).
- **`claude-bedrock-gate.nix`** — **Bedrock routing's governance**: a `nix-bedrock-gate` shell
  hook that makes Claude Code's Bedrock routing conditional on an AWS identity actually
  resolving, instead of on `CLAUDE_CODE_USE_BEDROCK` merely existing.
  - **The identity is runtime-owned (2026-09).** `~/.aws/config` belongs to the `aws` CLI
    (`aws configure sso`), like the SSO tokens in `~/.aws/sso/cache` always did — it is in
    no repo. The gate resolves the profile (`AWS_PROFILE`, else `default`) and the region
    (shell → `settings.json` `env` → that profile's `region` key; never `sso_region`), and
    the hook **exports** a file-derived `AWS_REGION`, because Claude Code reads the region
    from the environment only (anthropics/claude-code#18962). Select a non-default profile
    with `secret set AWS_PROFILE <name>`. ADR-003's split: identity is content, the gate is
    governance.
  - **This module declares NO options.** `local.claudeBedrock.{region,profile}` — which wrote
    `AWS_*` into `settings.json`'s `env` — was deprecated when the identity became
    runtime-owned and **deleted 2026-09-15**, once nix-personal (the only thing that ever set
    it) was retired. The settings.json writer and its deprecation warning went with it. Do not
    reintroduce them: a value there overrides the runtime `~/.aws/config` in every session,
    which is the exact failure this module exists to prevent. There is deliberately no
    `enable` option either — `CLAUDE_CODE_USE_BEDROCK` stays in the login Keychain so it
    remains a runtime toggle.
  - **`adoptAwsConfig` — the one-shot migration.** When no `home.file` entry targets
    `.aws/config`, an activation step between `writeBoundary` and `linkGeneration` replaces a
    leftover store symlink with a real `0600` copy. Ran once, when nix-personal's `aws-sso.nix`
    (which store-symlinked the file) stopped being evaluated — home-manager's orphan cleanup
    would otherwise have deleted the symlink and every profile with it.
  - **The trap it closes** is unchanged: the Keychain flag survives every activation, a
    missing identity does not, and a read-only `settings.json` cannot be hand-repaired. It
    degrades to Claude Code's default provider rather than erroring. Offline and CLI-free by
    design (local files only; no `aws sts` call per shell). Companion: the
    `.claude/hooks/pretooluse-bash-guard.js` block, which only covers activations the *agent*
    runs; this covers a switch typed by hand.
- **`claude-guardrails.nix`** — the **global guardrail floor**: user-scope
  `programs.claude-code.settings` (upstream `jsonFormat.type`, so it is freeform and the deny
  list concatenates with any other module's), darwin-gated, no options, no hooks, no scripts.
  Exists because every decision hook in `.claude/` is project-scoped — sessions in any other repo
  had none of them while VS Code starts in `bypassPermissions`, and the globally-wired
  `mcpfinder` exposed its config-writing tool everywhere but here. Two halves:
  - `permissions.deny`. Entry rule: a fleet-wide policy already written down (imperative MCP
    adoption, secret values in the transcript — `secret reveal`, `security find-*-password
    -w/-g`, and since 2026-09-21 `agenix -d` / `age -d` age decryption — `/run/agenix` and
    OpenTofu-state plaintext, `gh pr merge`, force-push) — never repo policy. Deny rules still
    apply in `bypassPermissions` (it skips prompts; a deny is not one), but they match the
    command text Claude writes, not `sh -c` or an absolute binary path — a floor, not a
    boundary. **No catch-all `Read(**)`**: a blanket Read deny disables Bash auto-approve
    everywhere, so the path denies stay narrow on purpose.
  - `attribution = { commit = ""; pr = ""; sessionUrl = false; }` (2026-09-21) — mechanises
    `claude/CLAUDE.md` § Git authorship, which forbids `Co-Authored-By: Claude` trailers and
    "Generated with Claude Code" PR footers but had to be re-won each session against Claude
    Code's own session-start reminder. All three sub-keys are required: setting only `commit`
    makes Claude Code ignore the deprecated `includeCoAuthoredBy` and fall back to its DEFAULT
    PR text, and `sessionUrl` is a separate `Claude-Session` trailer that appears only from
    cloud/Remote Control sessions.
  - **Not the top tier any more.** Since 2026-09-21 `modules/darwin/claude-managed-settings.nix`
    restates the secret-value denies and all three `attribution` keys at **managed** scope on
    `macos`, where a deny cannot be retracted by any lower scope and every per-key precedence
    sentence in claude-code 2.1.260 puts managed first. The two are ADDITIVE, not a
    replacement: this file is the only tier that reaches the devcontainer and machines this
    Home Manager config never touched. See [`modules-darwin.md`](modules-darwin.md)
    § `modules/darwin/`.
- **`claude-desktop.nix`** — `local.claudeDesktop`. It **still runs, and it now renders an EMPTY
  `mcpServers` block** (2026-10-02): the portal it used to dial is destroyed, and Desktop loads
  no plugins, so Desktop genuinely has **no** MCP servers. **The module stays ENABLED on
  purpose** — "Desktop has no MCP servers" is a state something must *write*. Switching the
  writer off leaves whatever is on disk, which is exactly how a stale `kattakath-portal` entry
  pointing at destroyed infrastructure survived for a day after the purge (#732). So
  `enable = false` is the wrong lever here and an empty render is the right one, and
  `checks.claude-desktop-config-shape` asserts BOTH halves — the module is on, and it writes
  nothing.
  The machinery is unchanged and still earns its keep: Desktop accepts ONLY the stdio shape, so
  any `url` becomes a pinned `mcp-remote` shim (`lib.hm.mcp.transformMcpServer` + one
  `extraTransform`, the codex module's pattern); an activation plus the
  `claude-desktop-mcp-sync` watch agent merge ONLY `.mcpServers` and ONLY entries carrying the
  `NIX_CONFIG_MANAGED` env marker, so `preferences`, `coworkUserFilesPath`, `extraServers` and
  anything added in Desktop's UI survive an empty render. Full rationale, including the clobber
  that forced the watch agent: [`docs/claude-desktop-mcp.md`](../claude-desktop-mcp.md).
- **`claude-plugins.nix`** — `local.claudePlugins.marketplaces` **+ `.declared`**, the
  **N-marketplace** Claude Code plugin mechanism. An `attrsOf submodule` keyed by marketplace name, each carrying a
  `source` (a `/nix/store` path or an `https://` git URL — asserted, so an impure
  `toString ../plugins` fails loudly), a `plugins` list of BARE names, and an `autoUpdate`
  flag (https only). Install ids are derived as `<plugin>@<marketplace>`, which is what
  `settings.enabledPlugins` keys on, so a plugin's id can never drift from its marketplace
  through a typo. **A `repin` option existed until 2026-09-30** and is GONE — nothing outside
  the module ever set it, and the teardown it named is deleted (see the two bullets below).
  - **`marketplaces.*.plugins` is a CATALOGUE and enables nothing.** It makes
    `<plugin>@<marketplace>` resolvable; `extraKnownMarketplaces` never reads it. Adding a name
    there merged twice and did nothing both times — #751 (`empire`, reverted in #754) and #753
    (`silent-instruments`).
  - **`local.claudePlugins.declared` is what turns an id on or off** (`attrsOf bool`, added
    2026-10-02, ADR-008's `declared` lane). Full `<plugin>@<marketplace>` ids, user scope,
    re-asserted every activation. Rendered as
    `enabledPlugins = cfg.declared // genAttrs alwaysOnIds (_: true)` — floor last, so the
    always-on three win the merge even without the assertion that already forbids an overlap.
    **The invariant it preserves, which is the real content of #648:** Nix may write an
    `enabledPlugins` key only for an id a human named ON PURPOSE — never one DERIVED from the
    catalogue — so the jq merge in `claude-code-settings.nix` (`.[0] * $nix[0]`, right operand
    wins per key) leaves every unnamed id, `false` included, exactly as `/plugin` wrote it.
    Three assertions, each measured firing via `extendModules`: a malformed key, an overlap with
    the always-on three, and a plugin absent from its own marketplace's catalogue — the last
    skipped when the marketplace is not declared here, because `<plugin>@synced` (claude.ai
    sync) is live and unknowable at eval. **Full ids, not bare names, for that reason.** The
    `assured` (managed-settings) lane of ADR-008 §6 is **NOT built**.
  - **Why it exists.** This was a single-marketplace mechanism inlined in `home.nix`
    (`claudePluginIds` / `localPluginsMarketplace` / `home.activation.claudeCodePlugins`)
    until nix-personal needed a second marketplace and grew a near-verbatim 80-line COPY of
    the activation script, ordered `entryAfter [ "claudeCodePlugins" ]` so the two would not
    race on mutable `~/.claude`. `attrsOf` merges by key, so that second marketplace became
    one more attribute instead, there is exactly one script, and the race has no reason to
    exist. `plugins` being a `listOf` means a layer composed in through `extraHomeModules`
    can also append a plugin to a marketplace THIS repo declares — impossible before.
  - **`source` is a scalar on purpose.** A marketplace has exactly one source, so two
    differing definitions SHOULD be a loud conflict, not a silent pick. It is `mkDefault`
    here so a downstream layer can repoint one (a fork of the official marketplace, say)
    with a plain assignment. Everything a private layer needs to ADD merges.
  - **Path-literal trap.** `source = "${../../plugins}"` is a Nix SOURCE PATH LITERAL,
    resolved relative to the `.nix` file it is written in. The same line moved to another
    flake silently re-points at THAT flake's `plugins/`, so each repo's marketplace entry
    must stay in the repo that owns the tree — which is why nix-personal kept its own
    `plugins/` directory and a 5-line module until it was retired 2026-09-15, rather than
    shipping the tree here. Nothing in this repo can trip the trap today: there is no
    `plugins/` tree here either, so none of the four `source` values in
    `modules/home/default.nix` is a repo-relative path literal — three are `https://` git URLs
    (`kattakath` among them since 2026-09-23), and one is a store path (the patched
    grok-build plugin).
  - **The activation script is now ONE `marketplace add` per store-path marketplace**
    (2026-09-30) — no install loop, no uninstall, no marketplace-remove, no two phases. The
    declarations do the work: `extraKnownMarketplaces` + `enabledPlugins`, and Claude Code's
    **session-start reconcile** fetches and re-points from there. Four measurements, Claude
    Code 2.1.268, isolated `CLAUDE_CONFIG_DIR`:
    1. The session-start reconcile DOES re-point a `directory`-source marketplace when
       settings' `source.path` changes, and it is **not auth-gated** (a logged-OUT TUI printed
       `Not logged in` and `Plugins changed. Run /reload-plugins to activate.` in one frame,
       and `known_marketplaces.json` moved).
    2. `~/.claude/plugins/cache` is **never read at load** for a directory source — the plugin
       loads LIVE from the marketplace directory; one whose recorded `installPath` was absent
       still loaded and ran. **This refutes the module's earlier premise** that `plugin
       install` COPIES into the cache and so a plain guard would serve a stale generation
       forever — that claim was measured FALSE, and the teardown built on it is deleted.
    3. The CLI does not propagate a settings change — neither `plugin update` nor
       `marketplace update`. `known_marketplaces.json` is what a refresh reads, and only an
       explicit `plugin marketplace add` writes it.
    4. `plugin marketplace add <path>` on an already-registered NAME with a DIFFERENT path
       succeeds and re-points, so no remove-first dance is needed.

    What the one call still buys: **it removes the first-session lag.** Without it a fresh
    Mac's first session has the plugin absent, and the first session after each content bump
    serves the previous generation behind a "Plugins changed" notice. Activation runs before
    any session, so the lag becomes zero. `programs.claude-code.marketplaces` (upstream) is
    still unusable for the same two reasons as before: it writes a Nix-managed
    `known_marketplaces.json` symlink where both the CLI and that reconcile need a mutable
    file, and the reserved `claude-plugins-official` rejects directory pins as untrusted.
- **Git SSH signing principals** — no module of its own any more. `git-allowed-signers.nix`
  and its custom `kattakath.git.extraAllowedSignersPrincipals` option were **deleted**
  2026-09-13 in favour of upstream's own `programs.git.signing` (pinned home-manager
  `programs/git.nix:63-116`; impl `:470-506` writes `$XDG_CONFIG_HOME/git/allowed_signers` and
  points `gpg.ssh.allowedSignersFile` at it). `modules/home/default.nix` sets the fleet default
  principal (`userEmail`); because `allowedSigners` is a `lines` option, extra identities
  simply **append** — the persona addresses `izzy@silvercreek.ai` and `hi@izzykatt.ca` are
  listed alongside it, which is how the retired nix-personal layer's principals came across
  with no custom seam.
- **`wallpaper/wallpaper.png`** — the vendored desktop wallpaper `desktop-aesthetics.nix`
  installs. It is copied to `~/.local/share/nix-desktop-wallpaper.png` via `home.file` and
  pointed at from there, **not** referenced as a store path directly: `settings.picture` set
  to a store path leaves the wallpaper out of the generation's closure, so
  `nix-collect-garbage` would delete the file out from under the desktop.
- **`hm-launchd/`** — replaces stock HM launchd so every agent's `ProgramArguments[0]`
  basename is `nix-<activity>` (macOS BTM rule — tags nix-config origin; **never** a bare
  interpreter like `sh`/`python3`). It is upstream's own `waitForNixStore = false` trade
  (pinned HM `modules/launchd/default.nix:47-52`): a named launcher instead of a
  `/bin/sh -c wait4path` arg0, accepting that launchd's exec fails outright if it fires
  before `/nix` is mounted. There is **no** wait4path "inside the wrapper" — a wrapper that
  itself lives in `/nix/store` could never run one. This is **mandatory
  for every launchd unit this repo authors**: HM user agents are auto-wrapped here, and any
  hand-written `launchd.daemons`/`launchd.agents` MUST point `arg0` at a
  `writeShellScriptBin "nix-<activity>"` wrapper (canonical today: `nix-tart-vm-<name>` and
  `nix-tart-runner-<name>` in the `tart-vms` capsule, `nix-file-rotation-<suffix>` in
  `modules/darwin/core.nix` — the trio this line used to name, `telegramMcp`/`wpMcp`/`apifyMcp`,
  lived in `mcp.nix` and went with it on 2026-10-02) — codified as the always-applied
  [`launchd-naming.md`](../../.claude/rules/launchd-naming.md) rule, which also documents the
  three known-upstream `/bin/sh` exceptions that are NOT ours and must never be renamed.
  **The fork is GONE (2026-09-14).** It shrank to one file, then to none: the pinned
  home-manager grew the three options it existed for, so `modules/home/launchd-launcher.nix`
  (53 lines) now just sets them — `waitForNixStore = false`, `launcher.name`, `launcher.shell`
  — and upstream's own `mutateConfig` rewrites both `Program` and `ProgramArguments`. The
  drift check that guarded the fork (`hm-launchd-drift`, which pinned the sha256 of upstream's
  `default.nix`) went with it; there is nothing left to drift against. This is the repo's
  worked example of the [`upstream-first`](../../.claude/rules/upstream-first.md) rule paying
  off: a 560-line vendored copy deleted the moment the input owned the behaviour.

- **`macos-user-agents.nix`** (macos only, gated on `osConfig.networking.hostName`) — the
  Maccy login opener and the two inbox Trash sweeps: **`~/Desktop`**, the capture inbox
  (⇧⌘4/⇧⌘5 land there by macOS's own default; the real Mac sets no
  `screencapture.location`) swept whole after **1 day**; **`~/Downloads`**, the
  browser/AirDrop inbox, swept after **7 days** of disposable types only
  (media/installers/archives allowlist — documents and directories stay for manual
  triage). Paired with `finder.FXRemoveOldTrashItems` so the Trash self-purges, and reading
  `local.folders.{desktop,downloads}` through `osConfig` rather than re-deriving a path.
  **They were `modules/darwin/core.nix`'s `launchd.user.agents` until 2026-10-02** — the
  same move metube and yt-dlp-web-ui made, for the same self-heal. They were three of the
  last five units on the `selfHeals = false; domain = "gui"` row of
  `modules/darwin/launchd-sources.nix`; the `tart-vms` capsule's two CI runners followed in
  the same week and **emptied the row**. Those two did NOT need a home-manager lane added to
  the capsule, which is what the plan here assumed: a nix-darwin module declares straight
  into `home-manager.users.<primaryUser>.launchd.agents` (the shape `logging.nix` was
  already using), and for the runners that is the only correct shape, because their plists
  derive from nix-darwin options. Lane, not layer.

  **Two things this move had to preserve that the download servers did not.** The
  **Labels** are pinned to their live values with an explicit `config.Label`
  (`com.kattakath.file-rotation.trash-{desktop,downloads}`, `org.nixos.open-maccy`): taking
  home-manager's `org.nix-community.home.<attr>` default would make each a DIFFERENT launchd
  unit and drop the operator's Background Task Management approval. That is safe because the
  self-heal probe keys off the Label too — upstream names each plist
  `"${v.config.Label}.plist"` and reads `agentName` back out of that filename. And the
  **arg0** stays a store-resident `nix-*` script, which is what grants the two sweeps read
  access to the TCC-protected folders at all; `launchd-launcher.nix` supplies it from the
  attribute name, so the inner scripts are named `file-rotation-<inbox>-sweep` /
  `open-maccy-run` to avoid one name mapping to two store paths.
  `checks.<system>.launchd-selfheal-lane` gates the lane, the three Labels, the per-agent
  `enable` (a `mkEnableOption` defaulting to **false** — a lane change that forgets it
  renders no plist and throws no error) and the arg0.

- **`metube.nix`** / **`yt-dlp-web-ui.nix`** (macos only) — `local.meTube` (127.0.0.1:8081,
  for the sideloaded Chrome extension) and `local.ytDlpWebUi` (127.0.0.1:3033, replacing the
  Colima container of the same name). Both are loopback-only `KeepAlive` agents whose wrapper
  does the `mkdir -p`, the legacy-layout migration and the env exports that home-manager's
  pure-`exec` launcher structurally cannot.
  **They lived in `modules/darwin/` as `launchd.user.agents` until 2026-09-22.** The move buys
  self-heal: nix-darwin's user-agent activation is diff-gated (`modules/system/launchd.nix:19,36`
  — `if ! diff`, load, else skip) and `modules/darwin/launchd-reconcile.nix` covers
  `launchd.daemons` **only**, so a nix-darwin user agent that has left its launchd domain is
  never re-bootstrapped; Home Manager probes with `launchctl print` and re-bootstraps
  (`modules/launchd/default.nix:411-419`) — which is why 22 HM agents survived the 2026-09-22
  outage and the system tier did not. Cost of the move: the Label changes
  `org.nixos.<n>` → `org.nix-community.home.<n>`, so both plists exist for one activation and
  the loser of the port bind KeepAlive-thrashes briefly. nix-darwin unloads and `rm`s the old
  plist in the same switch (`modules/system/launchd.nix:150-161`) but that removal is
  **single-transition** — run `nix run .#launchd-doctor` right after the first activation; its
  orphaned-plists section exists for exactly this failure.
  The inner wrapper dropped its `nix-` prefix (`metube-run`, not `nix-metube`):
  `launchd-launcher.nix` already renames arg0 to `nix-<agent>`, so the old spelling produced
  two store paths with one name.

## Home-Manager modules that are not in `modules/home/`

Three whole features reach the Mac's Home Manager profile from outside this directory, each
behind **one** `enable`. One is now an in-tree capsule; two are still flake inputs (ADR-002
waves 5-6 absorb them).

- **`modules/features/keychain-secrets/`** (an IN-TREE CAPSULE — it was extracted from this
  repo into the standalone MIT `nix-keychain-secrets` flake, then absorbed back by ADR-002
  wave 4) — `local.keychainSecrets`: the macOS login-Keychain `secret` CLI
  (`secret`/`set-secret`/`remove-secret`/`pb-conceal`) plus `~/.config/secrets/loader.sh`, a
  loader wired into **all four** shell entry points so even the non-interactive bash an agent
  spawns gets the operator's tokens. Darwin-gated internally, a clean no-op on the NixOS
  hosts. Full behaviour: [`secrets-and-keychain.md`](../secrets-and-keychain.md) and the
  capsule's own `README.md`.

  **It is a security surface, so two cross-file contracts are gated rather than trusted.**
  (1) `modules/darwin/core.nix` derives `launchd.user.envVariables.BASH_ENV` from
  `local.keychainSecrets.loaderRelPath` **by reference** — that is the only thing covering
  a bash spawned by a GUI app or a launchd job, which descends from no shell at all; the
  capsule's `checks/module-evaluates.nix` pins that option's DEFAULT as a literal, so a
  rename cannot move one half without the other. (2) `modules/home/claude-bedrock-gate.nix`
  writes the same three shell-init options at `lib.mkOrder 1600` and must run AFTER this
  module's `lib.mkAfter` (= 1500), because it reads a variable this loader exports — run it
  first and it sees an unset variable, does nothing, and Claude Code silently keeps a Bedrock
  route it cannot use. Nothing checked that until wave 4 put both halves in one evaluation;
  `checks.aarch64-darwin.bedrock-gate-after-loader` (`modules/parts/checks.nix`) now asserts
  it against the REAL `macos` config, on all three surfaces.

  Reached through `modules/parts/compose.nix` as the `keychainSecretsModule` specialArg, from
  the `capsuleModules` seam rather than `flake.modules` — see [`engine.md`](engine.md)
  § `modules/features/` for the measurement behind that. Its three darwin CLIs are still `packages`/`apps`
  (`nix run .#secret`), registered by the capsule itself; `pb-conceal` is deliberately
  installed but not published, exactly as before the absorption.

- **`modules/features/local-rag/`** (an IN-TREE CAPSULE — extracted from this repo to
  `kattakath/nix-local-rag` on 2026-08 and absorbed back by ADR-002 wave 6, the last
  satellite) — `local.rag.ollama` + `local.rag.pgvector`, the loopback RAG stack
  (launchd Postgres+pgvector+pgsql-http, a local Ollama embed model, and the in-DB `embed()`
  that makes retrieval plain SQL). Threaded in as `localRagModule` through the RAW
  `capsuleModules` seam. **It measured drv-identical on BOTH seams** — unlike keychain-secrets
  it contributes nothing to `home.packages` directly — and rides the raw one anyway for
  consistency and because order-insensitivity here is a property of today's contents, not of
  the class; the reasoning is in its `flake-module.nix` header.

  The seam that matters is `local.rag.pgvector.databaseUri`, and it has **TWO consumers, both
  in this repo**: `modules/home/plugin-mcp.nix:110` hands it to the plugin-lane `postgres` MCP
  launcher as `plainEnv.DATABASE_URI`, and since 2026-10-02 (#796) the capsule also exports it
  as the `RAGDB_URI` session variable (`modules/features/local-rag/pgvector-local.nix:419`), for
  a plain SHELL consumer that cannot read a Nix option. What changed on 2026-10-02 is **which**
  module consumes it — not that the Nix half went away: `modules/shared/mcp.nix` used to hand it
  to the gateway's `postgres` server as `env.DATABASE_URI`, and that file is deleted (#734).
  `postgres` takes no credential (a loopback **trust-auth** URI with no password), which is why
  it can live in the plugin lane at all — unlike `gmail`, which needed `packages/gmail-mcp.nix`.

  **And a plugin's `.mcp.json` is NOT invisible to this repo** — the claim that it is was the
  reasoning behind calling this a loss of coupling, and it is false.
  `checks.<system>.mcp-launcher-parity` reads every `plugins/*/.mcp.json` out of the pinned
  `kattakath-skills` input at EVAL time and asserts set equality between the `nix-mcp-*`
  commands those plugins name and the launchers `macos` builds (§ `gmail-mcp.nix` +
  `plugin-mcp.nix` above, same file). The `rag` plugin declares `postgres` →
  `nix-mcp-postgres`, so this very server is inside that join, and `plugin-mcp.nix` ALSO asserts
  `local.rag.pgvector.enable` whenever `postgres` is listed. What genuinely no gate can assert
  is that the server ANSWERS at runtime, and the non-`nix-mcp-` lanes
  (`${CLAUDE_PLUGIN_ROOT}`-relative, bare nixpkgs binaries, `npx`) are out of scope by
  construction.
  `checks.<system>.local-rag-module` still pins that URI as a **literal** so a
  port/role/db rename fails there instead of silently returning zero rows, and
  `local-rag-inert` is the kill-switch gate — both switches unset must contribute nothing,
  which is the state `nixpi`/`nixvm` are in since `modules/home/default.nix` imports it
  unconditionally. There is deliberately **no** wrapping `programs.localRag.enable`
  (ADR-002 §4's "two-switch regression"). It registers no packages: everything it installs is
  nixpkgs', reached through `home.packages` from inside the two modules.

  **The Postgres daemon is hand-rolled on purpose, and `local-rag-upstream-seam` is why that
  stays true.** nix-darwin's `services.postgresql` exists and is reachable on `macos`; it was
  read in full and **refuted** — full record in
  [`docs/local-rag-upstream-postgres-evidence.md`](../local-rag-upstream-postgres-evidence.md),
  citation in `pgvector-local.nix`'s header. The check pins the four properties the swap would
  move — the home-manager lane (upstream renders `launchd.user.agents`, `selfHeals = false`),
  a store-path arg0 (upstream's `script` renders `/bin/sh`, which **`ast-grep` cannot catch**:
  the literal is in the pinned input, not this repo), `initdb … --auth=peer` under the login
  user (upstream's `superUser` is `readOnly` `"postgres"`), and a `dataDir` under `$HOME`
  (upstream's default initdb's a fresh cluster over the live store). Each assertion was
  falsified before landing, not merely written.

  It was the only satellite with a SECOND consumer — `ircc-whatsapp-bot` pinned it too, which
  is why that unpin (ircc grew a `botOnly` output) was an ADR-002 wave-0 prerequisite rather
  than part of the absorption diff.
- **`modules/features/media-cli/`** (an IN-TREE CAPSULE — it was extracted from this repo to
  `kattakath/nix-media-cli` on 2026-09-05 and absorbed back by ADR-002 wave 5) —
  `local.mediaCli`, the eleven media CLIs + the launchd work queue + the Finder Services,
  `macos`-only because of closure size. Threaded in as `mediaCliModule` through the RAW
  `capsuleModules` seam rather than `flake.modules` — see [`engine.md`](engine.md)
  § `modules/features/` for the measurement. Its eleven packages are deliberately **not** re-published as flake outputs
  (nix-config never carried one); `checks.<system>.media-cli-packages` builds all of them, so
  the shellcheck coverage the satellite's CI had is kept.

