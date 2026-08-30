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
# Why the local-crx install keeps the required ID: the iCloud Passwords CRX carries a
# `key` in its manifest, so its extension ID is derived from that key rather than from
# the install path. A sideloaded copy therefore still registers as
# `pejdijmoenmkgeppbflobdenhhabjlaj` — exactly the origin Apple's helper allowlists.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.ungoogledChromium;

  # ---- iCloud Passwords (Chrome Web Store, fetched once and pinned) -----------
  # Bumping `version` REQUIRES a new `hash` — the CWS endpoint serves whatever the
  # current build is, so a stale hash is the expected failure mode of an upstream
  # release, not a bug. `prodversion` is pinned to the cask's Chromium major so the
  # endpoint hands back a build that browser will actually load.
  icloudPasswordsId = "pejdijmoenmkgeppbflobdenhhabjlaj";
  icloudPasswordsVersion = "3.3.0";
  icloudPasswordsCrx = pkgs.fetchurl {
    name = "icloud-passwords-${icloudPasswordsVersion}.crx";
    url =
      "https://clients2.google.com/service/update2/crx"
      + "?response=redirect&acceptformat=crx2,crx3&prodversion=152"
      + "&x=id%3D${icloudPasswordsId}%26installsource%3Dondemand%26uc";
    hash = "sha256-P+//MFjneHc0XV1cbvbx+4wIXtLB5Oz3bRa/L7ZGZ7A=";
  };

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
  };

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isDarwin) {
    programs.chromium = {
      enable = true;
      # The .app is the Homebrew cask; nixpkgs has no darwin build to point at.
      # Leaving this null also forbids `commandLineArgs` (upstream assertion) —
      # correct, since a cask-installed browser has no Nix wrapper to pass them to.
      package = null;

      extensions = lib.optionals cfg.applePasswords [
        {
          id = icloudPasswordsId;
          crxPath = "${icloudPasswordsCrx}";
          version = icloudPasswordsVersion;
        }
      ];

      nativeMessagingHosts = lib.optional cfg.applePasswords applePasswordsHost;
    };
  };
}
