# Declarative ungoogled-chromium surface (darwin only).
#
# The .app itself comes from the Homebrew `ungoogled-chromium` cask, NOT from Nix:
# nixpkgs' `chromium`/`ungoogled-chromium` are `*-linux` only — there is no darwin
# build to reference. So `programs.chromium.package = null` here, and Home Manager
# contributes only the config files Chromium reads out of its user-data dir.
#
# Two things are wired, both via upstream `programs.chromium` (no custom shell):
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

    userScripts = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Sideload Violentmonkey, the userscript manager. Userscripts themselves are
        NOT declared here — public ones would belong in this repo, the operator's
        private ones come from the nix-personal flake via `extraHomeModules`.

        Violentmonkey declares the MV3 `userScripts` permission, which Chrome 138+
        gates behind a per-extension "Allow User Scripts" toggle that is
        deliberately not settable by policy. Flip it once in chrome://extensions.
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
        ++ lib.optional cfg.userScripts (crxExtension {
          name = "violentmonkey";
          id = "jinjaccalgkegednnccohejagnlnfdag";
          version = "2.48.0";
          hash = "sha256-yRTrkG3wgVKXMLPT+1cOWMHpdhXEat3wAmiSD0Z6lc8=";
        });

      nativeMessagingHosts = lib.optional cfg.applePasswords applePasswordsHost;
    };
  };
}
