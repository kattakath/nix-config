# Declarative ungoogled-chromium surface (darwin only).
#
# The .app itself comes from the Homebrew `ungoogled-chromium` cask, NOT from Nix:
# nixpkgs' `chromium`/`ungoogled-chromium` are `*-linux` only — there is no darwin
# build to reference. So `programs.chromium.package = null` here, and Home Manager
# contributes only the config files Chromium reads out of its user-data dir.
#
# Three things are wired — two via upstream `programs.chromium` (no custom shell), one
# via the browser's own preferences domain:
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

  # ---- Userscripts -------------------------------------------------------------
  # Nix owns the FILES; Violentmonkey owns the database, and there is no bridge
  # between them on Chromium (see the `scripts` option for why bitbloxhub's
  # Firefox policy trick cannot be copied). So the most a module can do is
  # materialise every declared script into one directory and generate a page of
  # links, because installing a userscript means NAVIGATING to it.
  userScriptFiles = lib.filterAttrs (_: src: src != null) cfg.userScripts.scripts;

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
      map (name: ''<li><a href="${name}.user.js">${name}</a></li>'') (lib.attrNames userScriptFiles)
    )}
    </ol>
    <p>Click one to hand it to Violentmonkey, which needs its "Allow access to
    file URLs" toggle for that. Failing that, paste the file into Violentmonkey's
    own editor. This page is generated by Home Manager — edit the Nix
    declaration, never the page.</p>
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

          A public script can also carry an `https` `@updateURL` pointing at this
          repo, so after the first install it updates itself with no activation. A
          private one has no such URL and is re-installed from this directory after
          a `@version` bump.

          Never put a secret in a userscript: `source` is copied into the
          world-readable Nix store, private flake or not.
        '';
      };
    };

    claudeInChrome = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Sideload Claude in Chrome — the fleet's sole browser-automation tool. It
        drives the browser over CDP (hence its `debugger` permission) and talks to
        the local CLI over native messaging.

        Its native-messaging host manifest
        (`com.anthropic.claude_code_browser_extension`) is planted by claude-code
        itself, NOT by this module — deliberately, since the manifest's `path` must
        point at whichever claude-code install is current. Do not re-declare it
        under `nativeMessagingHosts` here; unlike Apple's Passwords host, nothing
        needs replanting because the CLI already writes it into Chromium's dir.
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
    targets.darwin.defaults."org.chromium.Chromium" = lib.mkIf cfg.hideBookmarkBar {
      BookmarkBarEnabled = false;
    };

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
