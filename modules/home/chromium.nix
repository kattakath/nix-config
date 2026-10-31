# Declarative ungoogled-chromium surface (darwin only).
#
# The .app itself comes from the Homebrew `ungoogled-chromium` cask, NOT from Nix:
# nixpkgs' `chromium`/`ungoogled-chromium` are `*-linux` only — there is no darwin
# build to reference. So `programs.chromium.package = null` here, and Home Manager
# contributes only the config files Chromium reads out of its user-data dir.
#
# Three things are wired — two via upstream `programs.chromium` (no custom shell) and
# one via the browser's own preferences domain. The macOS default-browser claim used to
# be a fourth; it moved to `modules/home/default-browser.nix` (`local.defaultBrowser`)
# when Opera Air became the default and Chromium became the debugging browser:
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
#      One policy rides this: `BookmarkBarEnabled`. It is a narrow tier — see the
#      default-search note below for a policy set that arrives and is then REFUSED.
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
  cfg = config.local.ungoogledChromium;

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

  # ---- CRX for a LOCAL, repo-authored extension (not the Chrome Web Store) ----
  # Same shape as crxExtension's output (an `extensions.*` entry needing only
  # `id`/`version`/`crxPath`), but crxPath is a plain repo path literal instead
  # of a fetchurl: there is no upstream to pin a hash against. `id` is NOT
  # free-form — Chrome derives it from the packing key's public half (first 16
  # bytes of its SHA-256, hex nibbles mapped 0-15 -> a-p), so it MUST match
  # whatever `--pack-extension --pack-extension-key=<key.pem>` produces for
  # THIS extension's own key, or Chromium treats it as a different extension
  # (a fresh un-acknowledged sideload, silently disabled) — verified 2026-09-30
  # by computing the id independently (openssl + the same algorithm) and cross-
  # checking against `chrome.management.getAll()` after a real install.
  localCrxExtension =
    {
      id,
      version,
      crxPath,
    }:
    {
      inherit id version crxPath;
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
  options.local.ungoogledChromium = {
    enable = lib.mkEnableOption ''
      declarative config for the Homebrew-installed ungoogled-chromium (darwin only).
      Installs no browser — declare the `ungoogled-chromium` cask on the host
    '';

    # Every extension below is unconditional: each used to sit behind its own
    # default-true toggle that no host ever set, so the toggles were deleted
    # and the build did not change. `userScripts.enable` is the one that stayed
    # an option. The per-extension WHY is a comment on its entry in
    # `programs.chromium.extensions`.

    userScripts.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Sideload Violentmonkey, the userscript manager. The fleet declares no
        userscripts (they are published to Greasy/Sleazy Fork and installed
        from there), so this installs the manager only.

        Violentmonkey declares the MV3 `userScripts` permission, which Chrome
        138+ gates behind a per-extension "Allow User Scripts" toggle that is
        deliberately not settable by policy. Flip it once in chrome://extensions.
      '';
    };

    debugLauncher = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Install `nix-chromium-debug [port]` — a hand-run command that launches Chromium
        with `--remote-debugging-port` (default 9222, loopback only).

        MOVED HERE from `local.mcpGateway.chromeDevtools.enable` on 2026-09-30, when
        chrome-devtools stopped being a gateway-hosted server and became `page-lab`'s
        plugin-owned one (#657 batch 2). The MCP server left; opening the port did not,
        and it was never an MCP concern — it is a browser concern, which is this module.
        The Kapture extension below is the same shape: this file owns the browser half of a
        browser-automation server whose client lives elsewhere.

        Deliberately a hand-run command and NOT a launchd agent or login item: the port
        is an unauthenticated control channel over a browser holding live logins and the
        Apple Passwords native host. It should exist for a session, on purpose, and die
        with the window — never come back at boot.

        `page-lab`'s attach probe finds the port either way: it tries the HTTP endpoint
        first and falls back to `--autoConnect` reading `DevToolsActivePort`. So without
        this the plugin still works, in the weaker of its two modes.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isDarwin) {
    # `nix-chromium-debug` — the CLASSIC, launch-flag route to the CDP port.
    #
    # NO LONGER THE ONLY ROUTE, and no longer the one the server assumes
    # (that server is page-lab's now — #657 batch 2).
    # A running browser CAN now be switched into debugging mode from
    # `chrome://inspect/#remote-debugging` (Chrome/Chromium M144+),
    # which is how the browser page-lab's chrome-devtools server attaches to is enabled — it
    # picks its own port and writes it to `DevToolsActivePort` [F-NO-JSON-HTTP].
    # This wrapper stays for the flag route, which is still the only way to open a
    # port on a browser whose UI toggle you do not want to use, and the only way to
    # get a debug port on an --isolated throwaway profile.
    #
    # It launches CHROMIUM specifically. Which profile the SERVER attaches to is now
    # page-lab's business, not this module's: its attach probe defaults to the same
    # Chromium profile path and takes CDP_USER_DATA_DIR to override, so the two AGREE
    # out of the box while staying independent knobs.
    # (Until 2026-09-21 the default was Opera Air, which is no longer installed.)
    #
    # Why a wrapper at all, rather than a declared browser flag: the .app is a
    # Homebrew cask, so `programs.chromium.package` is null, and upstream's own
    # assertion then FORBIDS `commandLineArgs` — there is no Nix wrapper to pass
    # them to.
    #
    # Deliberately a hand-run command and NOT a launchd agent or a login item: the
    # port is an unauthenticated control channel over a browser holding live logins
    # and the Apple Passwords native host. It should exist for a session, on
    # purpose, and die with the window — never come back at boot.
    home.packages = lib.mkIf cfg.debugLauncher [
      (pkgs.writeShellApplication {
        name = "nix-chromium-debug";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.curl
          pkgs.gnused
          pkgs.jq
        ];
        text = ''
          # 9222 is the de-facto default every CDP client assumes. Bound to 127.0.0.1
          # only — never expose or forward it; that turns a local-only debugging
          # channel into a remote one.
          port="''${1:-9222}"

          # Relaunching while the same profile is already running silently reuses the
          # existing process and the port never opens — indistinguishable from the
          # flag being ignored, and it cost real debugging time to learn. Refuse
          # instead of producing a browser that looks right and is not.
          if /usr/bin/pgrep -x "Chromium" >/dev/null 2>&1; then
            echo "nix-chromium-debug: Chromium is already running." >&2
            echo "  --remote-debugging-port is a STARTUP flag, so it cannot be added to" >&2
            echo "  this process. Either quit Chromium completely and re-run, or leave it" >&2
            echo "  running and turn debugging on in-browser at chrome://inspect/#remote-debugging" >&2
            echo "  — that needs no relaunch, and the server finds the port it picks." >&2
            exit 1
          fi

          echo "nix-chromium-debug: opening CDP on 127.0.0.1:$port" >&2
          echo "  WARNING: any local process can now drive this browser and read its" >&2
          echo "  pages, cookies and session state. Quit Chromium when you are done." >&2
          # `-g`: launch without stealing focus — the window still opens (unlike
          # `-j`, which hides it outright), it just does not jump to the front.
          # A debug session driven by an agent should not fight the operator for
          # the foreground on every new tab it opens.
          /usr/bin/open -g -na "Chromium" --args "--remote-debugging-port=$port"

          # Rewrite DevToolsActivePort from the live endpoint. Chromium writes that file
          # only in chrome://inspect consent mode, NEVER for --remote-debugging-port
          # (measured 2026-10-21: mtime and browser UUID unchanged across a flag-mode
          # launch). A file left by an earlier consent session therefore names a dead
          # UUID, and any client in `--autoConnect` mode — page-lab's attach probe falls
          # back to it when no browser answered at MCP start — gets a 404 until the
          # file is fixed by hand. Same two-line format Chromium writes.
          active="$HOME/Library/Application Support/Chromium/DevToolsActivePort"
          path=""
          for _ in $(seq 1 30); do
            path="$(curl -fsS --max-time 1 "http://127.0.0.1:$port/json/version" 2>/dev/null \
              | jq -r '.webSocketDebuggerUrl // empty' | sed 's|^ws://[^/]*||')" || path=""
            [ -n "$path" ] && break
            sleep 0.5
          done
          if [ -z "$path" ]; then
            echo "nix-chromium-debug: Chromium launched, but CDP never answered on 127.0.0.1:$port" >&2
            echo "  within 15s — DevToolsActivePort was NOT refreshed." >&2
            exit 1
          fi
          printf '%s\n%s' "$port" "$path" >"$active.tmp"
          mv -f "$active.tmp" "$active"
        '';
      })
    ];

    programs.chromium = {
      enable = true;
      # The .app is the Homebrew cask; nixpkgs has no darwin build to point at.
      # Leaving this null also forbids `commandLineArgs` (upstream assertion) —
      # correct, since a cask-installed browser has no Nix wrapper to pass them to.
      # Consequence worth knowing before looking for it here: a browser LAUNCH flag
      # cannot be declared in this module at all. The one the fleet needs,
      # `--remote-debugging-port` for chrome-devtools-mcp, is therefore a hand-run
      # `nix-chromium-debug` wrapper — declared ABOVE in this file since 2026-09-30.
      # It lived in modules/shared/mcp.nix while chrome-devtools was a gateway server;
      # #657 batch 2 made that server plugin-owned, so only the browser half stayed,
      # and the browser half belongs here — which is also the
      # right shape for it, since that port is an unauthenticated control channel
      # that should live for one session, not persist.
      package = null;

      extensions = [
        # iCloud Passwords, paired with Apple's native-messaging host below
        # (`nativeMessagingHosts`), so macOS Passwords.app autofills here.
        # macOS ships that manifest to Chrome and Firefox only.
        (crxExtension {
          name = "icloud-passwords";
          id = icloudPasswordsId;
          version = "3.3.0";
          hash = "sha256-P+//MFjneHc0XV1cbvbx+4wIXtLB5Oz3bRa/L7ZGZ7A=";
        })
        # uBlock Origin — the real Manifest V2 build, not uBO Lite.
        # ungoogled-chromium's `extensions-manifestv2.patch` makes
        # `ShouldDisableLegacyExtensions()` return false unconditionally, so MV2 and
        # its blocking `webRequest` are fully restored here; upstream Chrome and
        # Brave can only run the declarativeNetRequest-limited MV3 build.
        (crxExtension {
          name = "ublock-origin";
          id = "cjpalhdlnbpafiamejdnhcphjbkeiagm";
          version = "1.74.0";
          hash = "sha256-akht0BrQg6I0Cj8AO63TmQZYE5kodaAgx2EPjuOKyx8=";
        })
        # Claude in Chrome: drives the browser over CDP (its `debugger` permission)
        # and talks to the local CLI over native messaging. Its host manifest
        # (`com.anthropic.claude_code_browser_extension`) is planted by claude-code
        # itself, because its `path` must follow the current CLI install — do NOT
        # re-declare it under `nativeMessagingHosts`.
        (crxExtension {
          name = "claude-in-chrome";
          id = "fcoeoabgfenejglbffodgkkbkcdhcgfn";
          version = "1.0.85";
          hash = "sha256-XBwTGKzxC7Rji+EprjT53+couGenDGAzgvieZqXQi+M=";
        })
        # Kapture MCP Browser Automation: the same capability (`debugger` +
        # `<all_urls>`) reached a different way, which is why both exist.
        # claude-in-chrome is a NATIVE-MESSAGING client keyed to one CLI install;
        # Kapture is a LOCAL-BRIDGE client any MCP client can reach, so it survives
        # a session claude-in-chrome's tools never loaded into.
        #   - A tab is invisible to the bridge until connected from the toolbar
        #     popup toggle (verified against the installed 1.2.1 `popup.js`).
        #     Installing grants nothing; a bridge with zero connected tabs is dark.
        #   - The MCP server half is declared by the `page-lab` plugin's `.mcp.json`
        #     (github:kattakath/skills), `npx -y kapture-mcp@latest bridge` — never
        #     here. The `@latest` stays loose; no pin in this repo can stop it.
        (crxExtension {
          name = "kapture-mcp";
          id = "ejfnegenodbdcodemkibocefmajjjjbn";
          version = "1.2.1";
          hash = "sha256-VqOmeVNbE+Rb0PIsuPg/sQG1kyc1+dpuVeP4SyjwvvI=";
        })
        # "Into The Black Hole" true-AMOLED theme: a code-free MV2 extension (a
        # `theme` key only). Until acknowledged once, Chromium leaves
        # `extensions.theme` unset and still looks stock.
        (crxExtension {
          name = "amoled-black-theme";
          id = "faeadnfmdfamenfhaipofoffijhlnkif";
          version = "1.0.1";
          hash = "sha256-HcajUNEDGhOhxosEOQu/dGQK9m9IGoIz75aKN/UWBMU=";
        })
        # MeTube Downloader: POSTs a URL to the MeTube address saved in the
        # extension's own options (profile state Nix does not own). Point it at
        # `local.meTube`, `http://127.0.0.1:8081`.
        (crxExtension {
          name = "metube-downloader";
          id = "fbmkmdnlhacefjljljlbhkodfmfkijdh";
          version = "1.9";
          hash = "sha256-9xQwpgPf7HEvt7lu+Pd1N2E1TyWbPI/I/W+4ST/cAng=";
        })
        # Repo-authored (~10-line) extension setting Chromium's PER-SCRIPT
        # Malayalam fonts to Noto Sans/Serif Malayalam (`fonts.packages`,
        # hosts/macos.nix). Source: `chromium-extensions/malayalam-font-setter/`.
        # WHY AN EXTENSION — no declarative route exists (verified 2026-09-30):
        #   1. the chrome://settings/fonts pref (`webkit.webprefs.fonts.<generic>.Mlym`)
        #      does not exist until some actor registers it; `setPref` fails with
        #      "Pref not found", and enabling Malayalam as a language did not help.
        #   2. no enterprise policy: the installed Chromium Framework binary has no
        #      `PerScript*` or font-policy string, so the recommended-CFPreferences
        #      route `BookmarkBarEnabled` uses does not apply.
        #   3. `chrome.fontSettings.setFont()` is extension-only and lasts only
        #      while the extension is enabled (measured: it reverted on removal),
        #      so `bg.js` reapplies it on `onInstalled`/`onStartup` + top level.
        (localCrxExtension {
          id = "eaaffdlmgpmjccgdneagbjfckkdehama";
          version = "1.0";
          crxPath = ./chromium-extensions/malayalam-font-setter.crx;
        })
      ]
      ++ lib.optional cfg.userScripts.enable (crxExtension {
        name = "violentmonkey";
        id = "jinjaccalgkegednnccohejagnlnfdag";
        version = "2.48.0";
        hash = "sha256-yRTrkG3wgVKXMLPT+1cOWMHpdhXEat3wAmiSD0Z6lc8=";
      });

      nativeMessagingHosts = [ applePasswordsHost ];
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
    #
    # `BookmarkBarEnabled = false` defaults *View ▸ Always Show Bookmarks Bar* to OFF
    # (it seeds `bookmark_bar.show_on_all_tabs`); the menu item stays live and a manual
    # tick wins for good. Its sibling *Always Show Toolbar in Full Screen* is
    # `browser.show_fullscreen_toolbar`, a profile pref with NO policy behind it (this
    # build's policy table has none touching it), so that one stays a manual click.
    #
    # `PromptForDownloadLocation = false` undoes ungoogled's
    # `prefs-always-prompt-for-download-directory-by-defaul.patch`, which flips
    # "Ask where to save each file" ON (upstream ships it off). Unlike the search set,
    # this one IS honoured at the recommended level: chrome://policy read
    # `Platform | Recommended | OK` on 2026-10-31. Files land in the profile's
    # `savefile.default_directory` (~/Downloads); the settings toggle still wins.
    targets.darwin.defaults."org.chromium.Chromium" = {
      BookmarkBarEnabled = false;
      PromptForDownloadLocation = false;
    };
  };
}
