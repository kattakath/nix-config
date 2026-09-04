# Declarative ungoogled-chromium surface (darwin only).
#
# The .app itself comes from the Homebrew `ungoogled-chromium` cask, NOT from Nix:
# nixpkgs' `chromium`/`ungoogled-chromium` are `*-linux` only — there is no darwin
# build to reference. So `programs.chromium.package = null` here, and Home Manager
# contributes only the config files Chromium reads out of its user-data dir.
#
# Four things are wired — two via upstream `programs.chromium` (no custom shell), one
# via the browser's own preferences domain, one via LaunchServices:
#
#   1. `extensions` → `~/Library/Application Support/Chromium/External Extensions/<id>.json`.
#      ungoogled-chromium patches out the Chrome Web Store (`disable-webstore-urls.patch`),
#      so `external_update_url` is dead there — extensions MUST be installed as a local
#      `external_crx` + `external_version`. Upstream's own option docs say the same.
#   2. `nativeMessagingHosts` → `~/Library/Application Support/Chromium/NativeMessagingHosts/`.
#      This is what makes macOS Passwords.app work: the OS ships its native-messaging
#      manifest ONLY to `/Library/Google/Chrome/...` (Chrome) and
#      `/Library/Application Support/Mozilla/...` (Firefox) — never to Chromium or Brave.
#      Replanting it under Chromium is the whole trick, and it is safe because the
#      manifest gates on EXTENSION ID (`allowed_origins`), not on browser brand.
#   3. `targets.darwin.defaults."org.chromium.Chromium"` → *recommended* enterprise policy.
#      There is no policies-JSON directory on macOS (that is the Linux path); Chromium's
#      platform loader reads the browser's own CFPreferences domain instead, and
#      `policy_loader_mac.mm` grades each key by `CFPreferencesAppValueIsForced`: forced →
#      POLICY_LEVEL_MANDATORY, everything else → POLICY_LEVEL_RECOMMENDED. Only an MDM
#      configuration profile landing in `/Library/Managed Preferences/` is *forced*, and
#      mandatory is the level that GREYS THE MENU ITEM OUT. A plain user-domain write —
#      the one Home Manager can do, unprivileged — is therefore exactly the right level
#      for "off by default, still toggleable": it seeds the pref and a manual override
#      wins for good. (Verified against this cask's build: `nm -u` on Chromium
#      Framework 152 imports `_CFPreferencesAppValueIsForced` + `_CFPreferencesCopyAppValue`,
#      and none of ungoogled's ~111 patches touch policy loading.) Home Manager applies it
#      with `defaults import`, which MERGES, so Chromium's own state in that domain survives.
#      One policy rides this: `hideBookmarkBar`. It is a narrow tier — see the
#      default-search note below for a policy set that arrives and is then REFUSED.
#   4. LaunchServices' `http`/`https` handler → `makeDefaultBrowser`, the one surface here
#      that is neither a file in the user-data dir nor a policy. nixpkgs' `defaultbrowser`
#      claims the scheme on activation and no-ops once Chromium already owns it.
#
# Why a local-crx install keeps each extension's official ID: the ID is derived from
# the public key in the signed CRX3 header, not from the install path. A sideloaded
# copy of the store build therefore registers under exactly the same ID — which is
# what lets Apple's helper allowlist `pejdijmoenmkgeppbflobdenhhabjlaj` keep matching.
#
# ONE MANUAL STEP REMAINS, and it is not a bug: Chromium parks every externally
# installed extension *disabled pending acknowledgement* on macOS. First launch shows
# an "extension added" prompt per extension; enabling it once writes `ack_external`
# into the profile and it stays enabled forever. There is no policy that skips this on
# ungoogled-chromium (`ExtensionInstallForcelist` needs the Web Store, which is patched
# out). Violentmonkey additionally needs its per-extension "Allow User Scripts" toggle
# flipped in chrome://extensions — Chrome 138+ deliberately refuses to let policy set it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.ungoogledChromium;

  # ---- CRX fetching (Chrome Web Store, fetched once and pinned) ---------------
  # Bumping `version` REQUIRES a new `hash` — the CWS endpoint serves whatever the
  # current build is, so a stale hash is the expected failure mode of an upstream
  # release, not a bug. `prodversion` is pinned to the cask's Chromium major so the
  # endpoint hands back a build that browser will actually load.
  chromiumMajor = "152";

  # Emits the `programs.chromium.extensions` entry directly, so a new extension is a
  # one-line spec plus its option — nothing else to keep in sync.
  crxExtension =
    {
      name,
      id,
      version,
      hash,
    }:
    {
      inherit id version;
      crxPath = "${pkgs.fetchurl {
        name = "${name}-${version}.crx";
        url =
          "https://clients2.google.com/service/update2/crx"
          + "?response=redirect&acceptformat=crx2,crx3&prodversion=${chromiumMajor}"
          + "&x=id%3D${id}%26installsource%3Dondemand%26uc";
        inherit hash;
      }}";
    };

  icloudPasswordsId = "pejdijmoenmkgeppbflobdenhhabjlaj";

  # ---- Default search engine: NOT declarable — settled, do not retry -----------
  # ungoogled's `replace-google-search-engine-with-nosearch.patch` rewrites the
  # `google` row of `prepopulated_engines.json` into a "No Search" stub, which is why
  # a fresh profile's picker opens on *No Search (Default)*. Tempting to fix with the
  # `DefaultSearchProvider*` policy set — and it was tried here (2026-08-30). It does
  # NOT work, and the failure is invisible from Nix: the plist is written correctly and
  # `chrome://policy` shows the keys arriving (Source `Platform`, Level `Recommended`,
  # same as `BookmarkBarEnabled` right above them reading OK) yet
  # `DefaultSearchProviderEnabled` reports **"This policy is blocked, its value will be
  # ignored"** and the other four cascade to `Error` behind that dead main switch.
  #
  # So the set is MANDATORY-ONLY in practice, whatever the upstream metadata implies.
  # Mandatory needs `/Library/Managed Preferences` from an MDM profile, and it would
  # PADLOCK Settings ▸ Search engine — worse than the alternative, which is one click:
  # DuckDuckGo is already in the prepopulated list, so ⋮ ▸ Make default sets it for good.
  #
  # ADDING an engine is the same wall, not a softer one: the only two policies that add
  # one *without* forcing it default — `SiteSearchSettings` and
  # `EnterpriseSearchAggregatorSettings` — are mandatory-only too, and the engines they
  # create can never be promoted to default anyway. Google in particular has no
  # in-binary row left to seed (ungoogled strips it), so it is a manual add:
  # Settings ▸ Search engine ▸ Site search ▸ Add — name `Google`, shortcut `google.com`,
  # URL `https://www.google.com/search?q=%s` — then ⋮ ▸ Make default if wanted.
  # Recorded in docs/macos-settings-surface.md as a manual step; do not re-attempt in Nix.

  # ---- Userscripts -------------------------------------------------------------
  # Nix owns the FILES; Violentmonkey owns the database, and there is no bridge
  # between them on Chromium (see the `scripts` option for why bitbloxhub's
  # Firefox policy trick cannot be copied). So the most a module can do is
  # materialise every declared script into one directory and generate a page of
  # links, because installing a userscript means NAVIGATING to it.
  userScriptFiles = lib.filterAttrs (_: src: src != null) cfg.userScripts.scripts;

  # Links are ABSOLUTE `file://` URLs under $HOME, not relative names. Measured
  # 2026-09-04: every relative link 404s, because Home Manager materialises each
  # script as its own `/nix/store/<hash>-hm_<name>.user.js` and Chromium
  # canonicalises the symlinked index, so the page's base resolves to
  # `file:///nix/store/` and `name.user.js` lands beside it instead of inside a
  # directory. The $HOME path is also the STABLE one: it survives every rebuild,
  # so a re-install after a `@version` bump is the same URL rather than a new
  # store hash to go hunting for — and it is what Violentmonkey remembers as
  # `lastInstallURL`.
  userScriptIndex = ''
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8" />
    <title>Nix-declared userscripts</title>
    <style>
      :root { color-scheme: dark }
      body { background: #000; color: #fff; margin: 3rem auto; max-width: 46rem;
             padding: 0 1.5rem; font: 14px/1.7 ui-monospace, SFMono-Regular, monospace }
      h1 { font-size: .9rem; letter-spacing: .18em; text-transform: uppercase;
           border-bottom: 1px solid #fff; padding-bottom: .6rem }
      a { color: #fff }
      p { color: #8a8a8a }
    </style>
    </head>
    <body>
    <h1>Nix-declared userscripts</h1>
    <ol>
    ${lib.concatStringsSep "\n" (
      map (
        name:
        ''<li><a href="file://${config.home.homeDirectory}/.local/share/userscripts/${name}.user.js">${name}</a></li>''
      ) (lib.attrNames userScriptFiles)
    )}
    </ol>
    <p>Click one to hand it to Violentmonkey, which needs its "Allow access to
    file URLs" toggle for that. No toggle? Drag the repo's
    <code>userscripts/&lt;name&gt;.user.js</code> onto Violentmonkey's Dashboard
    instead — drag-and-drop needs no permission, and its installer is where
    "Track external edits" lives, which is the fast authoring loop. Failing both,
    paste the file into Violentmonkey's own editor. This page is generated by
    Home Manager — edit the Nix declaration, never the page.</p>
    </body>
    </html>
  '';

  # ---- Apple's Passwords.app native-messaging host, re-pointed at Chromium ----
  # `path` is a macOS *system* Cryptex location — a runtime OS path, not a per-user
  # one, so it is a legitimate absolute literal here (nothing $HOME-relative to use).
  # The layout ($out/etc/chromium/native-messaging-hosts) is the directory upstream's
  # `programs.chromium.nativeMessagingHosts` symlinkJoins from.
  applePasswordsHost = pkgs.writeTextFile {
    name = "apple-passwords-chromium-native-messaging-host";
    destination = "/etc/chromium/native-messaging-hosts/com.apple.passwordmanager.json";
    text = builtins.toJSON {
      name = "com.apple.passwordmanager";
      description = "PasswordManagerBrowserExtensionHelper";
      path =
        "/System/Cryptexes/App/System/Library/CoreServices"
        + "/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS"
        + "/PasswordManagerBrowserExtensionHelper";
      type = "stdio";
      allowed_origins = [ "chrome-extension://${icloudPasswordsId}/" ];
    };
  };
in
{
  options.programs.ungoogledChromium = {
    enable = lib.mkEnableOption ''
      declarative config for the Homebrew-installed ungoogled-chromium (darwin only).
      Installs no browser — declare the `ungoogled-chromium` cask on the host
    '';

    applePasswords = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Sideload the iCloud Passwords extension and replant Apple's
        native-messaging host manifest under Chromium, so macOS Passwords.app
        autofills there. Without this, Passwords.app reaches Chrome and Firefox
        only — macOS ships the manifest to no other browser.
      '';
    };

    adBlock = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Sideload uBlock Origin — the real Manifest V2 build, not uBO Lite.
        ungoogled-chromium's `extensions-manifestv2.patch` makes
        `ShouldDisableLegacyExtensions()` return false unconditionally, so MV2 and
        its blocking `webRequest` are fully restored here; upstream Chrome and
        Brave can only run the declarativeNetRequest-limited MV3 build. This is
        what makes YouTube ad-free without a browser that bundles its own blocker.
      '';
    };

    userScripts = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Sideload Violentmonkey, the userscript manager, and materialise
          `userScripts.scripts` next to it.

          Violentmonkey declares the MV3 `userScripts` permission, which Chrome
          138+ gates behind a per-extension "Allow User Scripts" toggle that is
          deliberately not settable by policy. Flip it once in chrome://extensions.
        '';
      };

      scripts = lib.mkOption {
        type = with lib.types; attrsOf (nullOr path);
        default = { };
        example = lib.literalExpression ''
          { google-photos-icon-nav = ../../userscripts/google-photos-icon-nav.user.js; }
        '';
        description = ''
          Userscripts to materialise into
          `$XDG_DATA_HOME/userscripts/<name>.user.js`, keyed by basename, plus a
          generated `index.html` linking each one. Set an entry to `null` (e.g.
          `lib.mkForce null`) to keep a declaration but skip the file.

          This attrset is the public/private seam: this repo declares the public
          scripts, the private nix-personal flake adds its own through
          `extraHomeModules`, and the two merge. Keys must be distinct — the module
          system treats a repeated key as a conflict, not an override.

          **Nix owns the files, not Violentmonkey's database**, and that is a
          Chromium limitation rather than a shortcut. bitbloxhub's Firefox pattern
          (enterprise policy → `browser.storage.managed` → a Violentmonkey fork
          that parses it at startup) does not port: the fork's hook is
          Firefox-gated, Chromium only populates `chrome.storage.managed` for
          extensions declaring a `storage.managed_schema` (Violentmonkey declares
          none), and Chromium policy on macOS lives in MDM-owned
          `/Library/Managed Preferences`, which Home Manager cannot write. Since a
          userscript is installed by NAVIGATING to it, installing stays one click
          per script from the generated index — Violentmonkey needs "Allow access
          to file URLs" (a sibling of the "Allow User Scripts" toggle) to accept a
          `file://` install.

          **No script carries `@updateURL`/`@downloadURL`** — not a limitation, the
          community norm: Greasy Fork *strips* both on upload ("any script installed
          from Greasy Fork only update[s] from Greasy Fork"), so they are inert the
          moment a script is shared, and bitbloxhub's Nix-declared Violentmonkey
          goes further still (`options.autoUpdate = 0`). Pointing one at this repo's
          `main` would also let a push mutate the running script with no activation
          and no review — the opposite of declarative. Every script is re-installed
          from this directory after a `@version` bump; Violentmonkey's own fallback
          for a script with no update key is `lastInstallURL`, i.e. the `file://`
          path Nix wrote.

          Do carry the keys that make a script *publishable*, since a userscript is
          worth sharing: `@name` + `@namespace` + `@version` are required by Greasy
          Fork, and `@license` is what stops OpenUserJS silently implying MIT.

          Never put a secret in a userscript: `source` is copied into the
          world-readable Nix store, private flake or not.
        '';
      };
    };

    claudeInChrome = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Sideload Claude in Chrome. It drives the browser over CDP (hence its
        `debugger` permission) and talks to the local CLI over native messaging.

        Its native-messaging host manifest
        (`com.anthropic.claude_code_browser_extension`) is planted by claude-code
        itself, NOT by this module — deliberately, since the manifest's `path` must
        point at whichever claude-code install is current. Do not re-declare it
        under `nativeMessagingHosts` here; unlike Apple's Passwords host, nothing
        needs replanting because the CLI already writes it into Chromium's dir.

        **Not the only browser-automation extension any more** — see `kaptureMcp`,
        and the reason the two coexist rather than one winning.
      '';
    };

    kaptureMcp = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Sideload Kapture MCP Browser Automation. Same capability shape as
        `claudeInChrome` — `debugger` + `<all_urls>`, i.e. CDP over the whole
        profile — reached a different way, which is the entire reason both exist:

        - **claude-in-chrome** is a *native-messaging* client. Its host manifest is
          keyed to one CLI install, so whichever client that manifest points at is
          the only one that can drive it. A session where those tools are simply
          absent has no way to ask for them.
        - **Kapture** is a *DevTools-panel + local-bridge* client. Any MCP client
          that speaks to the bridge gets the tabs, so it survives a session that
          claude-in-chrome's tools never loaded into.

        Two consequences worth knowing before relying on it:

        1. **Its per-tab gate is DevTools, not the extension list.** A tab is
           invisible to the bridge until you open DevTools on it and connect from
           the Kapture panel. Installing this extension grants *nothing* on its
           own — which is also why the broad `debugger` permission is less alarming
           here than it reads.
        2. **The MCP server half is NOT declared by this repo.** It lives in
           `~/.claude.json` at user scope as `npx -y kapture-mcp@latest bridge` —
           imperative and unpinned, so the bridge can change under a session
           without a rebuild. This module owns only the browser end. Declaring the
           server in `mcp.nix` (per CLAUDE.md § Using Subagents) is a real
           follow-up, not a finished job.
      '';
    };

    hideBookmarkBar = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Default *View ▸ Always Show Bookmarks Bar* to OFF, by recommending
        `BookmarkBarEnabled = false` in Chromium's preferences domain (the policy
        seeds the `bookmark_bar.show_on_all_tabs` pref). **Recommended, not
        forced** — the menu item stays live, and once the operator ticks it their
        value wins permanently. Forcing it, which would grey the item out, needs a
        `/Library/Managed Preferences` plist from an MDM profile.

        Its obvious sibling is deliberately absent: *View ▸ Always Show Toolbar in
        Full Screen* is `browser.show_fullscreen_toolbar`, a macOS-only **profile
        pref with no policy behind it** — this build's policy table carries 579
        names and none of them touches the fullscreen toolbar. The only lever left
        is the profile's `Preferences` JSON, browser-owned mutable state that Nix
        must not seed, so that one stays a one-time manual click.
      '';
    };

    makeDefaultBrowser = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Claim `http`/`https` (and so `public.html`) for Chromium in
        LaunchServices, making it the macOS default browser, via nixpkgs'
        `defaultbrowser` on each activation. Note the argument is the SHORT name
        `chromium`, not the bundle id — `org.chromium.Chromium` is rejected as
        "not available as an HTTP handler".

        **Idempotent, and that is the tool's own doing, not ours:** it reads the
        current handler first and early-returns with "chromium is already set as
        the default HTTP handler", never touching LaunchServices. So a settled Mac
        is a true no-op and there is nothing to re-confirm on a routine
        `activate`. That matters because of the next point.

        **Expect one consent dialog, once, on the activation that actually
        changes the handler** — a fresh or reset Mac. It is not avoidable and not
        a bug: `defaultbrowser` calls Launch Services'
        `LSSetDefaultHandlerForURLScheme`, whose SDK-declared replacement,
        `-[NSWorkspace setDefaultApplicationAtURL:toOpenURLsWithScheme:completionHandler:]`,
        is documented in `AppKit/NSWorkspace.h` as: *"Some URL schemes require
        user consent before you can change their handlers. If a change requires
        user consent, the system will ask the user asynchronously"*. The browser
        schemes are exactly those, for every tool and every API — so this joins
        the module's other one-time clicks rather than escaping them.

        The legacy API is safe to keep using: the macOS 26 SDK still declares it
        `API_TO_BE_DEPRECATED`, i.e. soft-deprecated with no removal version.
        `duti` is the obvious alternative and is passed over — it takes bundle ids
        but has no idempotence guard, so it would re-ask every activation.

        `defaultbrowser` also lands on PATH: run it with **no arguments** for a
        read-only list of HTTP handlers with the current default starred.
      '';
    };

    darkTheme = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Sideload the "Into The Black Hole" true-AMOLED black browser theme, so
        Chromium's own frame matches this fleet's black/white aesthetic rather
        than sitting in the default grey.

        A theme is a code-free MV2 extension (a `theme` key and nothing else), and
        it is subject to the same acknowledgement gate as the rest: until it is
        enabled once, Chromium unpacks it but leaves `extensions.theme` unset, so
        the browser still looks stock. Distinct from
        `local.desktopAesthetics.enable`, which owns the macOS *desktop* look —
        this is Chromium's chrome, installed through the same CRX path as every
        other extension here.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isDarwin) {
    programs.chromium = {
      enable = true;
      # The .app is the Homebrew cask; nixpkgs has no darwin build to point at.
      # Leaving this null also forbids `commandLineArgs` (upstream assertion) —
      # correct, since a cask-installed browser has no Nix wrapper to pass them to.
      package = null;

      extensions =
        lib.optional cfg.applePasswords (crxExtension {
          name = "icloud-passwords";
          id = icloudPasswordsId;
          version = "3.3.0";
          hash = "sha256-P+//MFjneHc0XV1cbvbx+4wIXtLB5Oz3bRa/L7ZGZ7A=";
        })
        ++ lib.optional cfg.adBlock (crxExtension {
          name = "ublock-origin";
          id = "cjpalhdlnbpafiamejdnhcphjbkeiagm";
          version = "1.74.0";
          hash = "sha256-akht0BrQg6I0Cj8AO63TmQZYE5kodaAgx2EPjuOKyx8=";
        })
        ++ lib.optional cfg.userScripts.enable (crxExtension {
          name = "violentmonkey";
          id = "jinjaccalgkegednnccohejagnlnfdag";
          version = "2.48.0";
          hash = "sha256-yRTrkG3wgVKXMLPT+1cOWMHpdhXEat3wAmiSD0Z6lc8=";
        })
        ++ lib.optional cfg.claudeInChrome (crxExtension {
          name = "claude-in-chrome";
          id = "fcoeoabgfenejglbffodgkkbkcdhcgfn";
          version = "1.0.85";
          hash = "sha256-XBwTGKzxC7Rji+EprjT53+couGenDGAzgvieZqXQi+M=";
        })
        ++ lib.optional cfg.kaptureMcp (crxExtension {
          name = "kapture-mcp";
          id = "ejfnegenodbdcodemkibocefmajjjjbn";
          version = "1.2.1";
          hash = "sha256-VqOmeVNbE+Rb0PIsuPg/sQG1kyc1+dpuVeP4SyjwvvI=";
        })
        ++ lib.optional cfg.darkTheme (crxExtension {
          name = "amoled-black-theme";
          id = "faeadnfmdfamenfhaipofoffijhlnkif";
          version = "1.0.1";
          hash = "sha256-HcajUNEDGhOhxosEOQu/dGQK9m9IGoIz75aKN/UWBMU=";
        });

      nativeMessagingHosts = lib.optional cfg.applePasswords applePasswordsHost;
    };

    # Recommended-level platform policy — see item 3 of the header for why the plain
    # user domain (not `/Library/Managed Preferences`) is the correct place for a
    # DEFAULT rather than a lock. Takes effect on Chromium's next launch.
    #
    # NOTHING here can tidy the NEW-TAB PAGE, and that is a settled dead end rather
    # than an omission — don't re-derive it. Every NTP policy Chromium defines is
    # MANDATORY-ONLY: `NewTabPageLocation`, `NTPCardsVisible`,
    # `NTPCustomBackgroundEnabled`, `NTPMiddleSlotAnnouncementVisible`,
    # `NTPOutlookCardVisible`, `NTPSharepointCardVisible`, `NTPContentSuggestionsEnabled`
    # and both `NTPFooter*` all omit `can_be_recommended` in their upstream
    # `policy_definitions/**.yaml`, which defaults it to false. `BookmarkBarEnabled`
    # carries it explicitly and works here, so absence is the answer rather than a gap
    # in the metadata — but treat that as a HINT, not a guarantee: the
    # `DefaultSearchProvider*` set carries `can_be_recommended: true` upstream and this
    # build still refuses it at the recommended level (see the note near the top). The
    # only proof is `chrome://policy`. `NewTabPageLocation`'s own `desc` says
    # it outright: "configures the default New Tab page URL AND PREVENTS USERS FROM
    # CHANGING IT". A padlocked new-tab page is worse than a click, so it stays unset.
    #
    # There is also no policy that hides only the SHORTCUT TILES. The one
    # shortcut-shaped policy, `NTPShortcuts` (in this build's table), goes the wrong
    # way — it *pre-configures up to 10 organization shortcuts in addition to* the
    # user's own — and is mandatory-only too. Hiding the tiles writes a profile-JSON
    # pref (`custom_links.*` / `home.module.most_visited.enabled`), browser-owned
    # mutable state Nix must not seed, so it is one click in Customize Chrome ▸
    # Shortcuts ▸ Hide shortcuts. ungoogled's `--custom-ntp` flag is not a route
    # either: `chromium-flags.conf` is Linux-only, so on macOS it needs chrome://flags.
    targets.darwin.defaults."org.chromium.Chromium" = lib.mkIf cfg.hideBookmarkBar {
      BookmarkBarEnabled = false;
    };

    # The `defaultbrowser` CLI doubles as this setting's read-only doctor (no args
    # → the handler list, current default starred), so it is worth a PATH entry.
    home.packages = lib.mkIf cfg.makeDefaultBrowser [ pkgs.defaultbrowser ];

    # Not a launchd unit — a plain activation step, so launchd-naming.md's
    # `nix-<kebab>` arg0 rule does not apply (nothing lands in BTM).
    #
    # Tolerates its own failure on purpose: the `.app` is a Homebrew cask, and
    # nothing orders brew's activation before Home Manager's, so on a first-ever
    # rebuild Chromium may not be registered with LaunchServices yet. Warn and
    # move on; the next activation picks it up. Never fail a rebuild over which
    # browser opens a link.
    home.activation.chromiumDefaultBrowser = lib.mkIf cfg.makeDefaultBrowser (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        $DRY_RUN_CMD ${lib.getExe pkgs.defaultbrowser} chromium \
          || /usr/bin/printf '%s\n' "warning: could not make Chromium the default browser (cask not registered yet?) — retried next activation"
      ''
    );

    # `~/.local/share/userscripts/` — a *runtime* location, so it is XDG-relative
    # (the sources above are repo-relative Nix path literals; two different axes).
    # Deliberately not under ~/Documents or ~/Desktop: those are TCC-protected, and
    # Chromium would need a Full Disk Access grant to read a `file://` from them.
    xdg.dataFile = lib.mkIf (cfg.userScripts.enable && userScriptFiles != { }) (
      lib.mapAttrs' (
        name: src: lib.nameValuePair "userscripts/${name}.user.js" { source = src; }
      ) userScriptFiles
      // {
        "userscripts/index.html".text = userScriptIndex;
      }
    );
  };
}
