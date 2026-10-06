# Optional lightweight desktop for the nixvm dev VM — X11 + XFCE with passwordless
# autologin and QEMU/SPICE guest integration. Opt-in via `local.desktopVm.enable`;
# hosts/nixvm.nix enables it ONLY inside `virtualisation.vmVariant`, so the XFCE
# desktop materialises for the graphical `build-vm` / `nix run .#nixvm` path,
# while the base nixvm toplevel (which exists only as the build-vm eval substrate,
# see hosts/nixvm.nix) stays headless/minimal.
#
# XFCE is the VM-friendliest DE: it runs on X11 (renders on QEMU's virtio-gpu
# via the `modesetting` driver with no host GPU passthrough) and is light enough
# to stay responsive under emulation. Wayland is deliberately avoided — its
# QEMU display-driver story is fussier. Swap the DE by editing the two xfce lines
# below (e.g. `desktopManager.plasma6.enable`); as the sole enabled session it is
# auto-selected for autologin, so no `defaultSession` is needed.
{
  config,
  lib,
  pkgs,
  loginName,
  ...
}:
let
  cfg = config.local.desktopVm;
in
{
  # `local.*`, not `services.*`: this is a fleet-private aggregate, not an
  # upstream service. NixOS owns the `services.*` namespace, and a future
  # upstream `services.desktopVm` would collide with this declaration. Matches
  # the in-fleet convention already set by `local.folders`
  # (modules/darwin/user-folders.nix) and `local.wireguardConfigs`
  # (modules/home/wireguard-configs.nix). Renamed 2026-09-06.
  options.local.desktopVm.enable = lib.mkEnableOption "lightweight XFCE desktop + guest integration for the nixvm sandbox";

  config = lib.mkIf cfg.enable {
    # ---- tor-browser on aarch64-linux, from the ALPHA channel --------------
    # SCOPED ON PURPOSE: this overlay sits inside `mkIf cfg.enable`, and
    # `local.desktopVm.enable` is set ONLY inside hosts/nixvm.nix's
    # `virtualisation.vmVariant`. So it reaches neither `nixpi` (the live Pi,
    # whose closure must stay lean) nor `macos`, nor even nixvm's base toplevel.
    #
    # WHY an overlay at all: the pinned nixpkgs' tor-browser THROWS at eval on
    # aarch64-linux — `src = sources.${stdenv.hostPlatform.system} or (throw
    # "unsupported system: ...")` — because upstream STABLE (15.0.23 here) ships
    # no aarch64 Linux tarball. `tor-browser-bundle-bin` is a hard alias throw,
    # not an alternative. nixpkgs will not package the aarch64 build until
    # 16.0 goes stable (NixOS/nixpkgs#491286, still open), so there is no
    # upstream option, package or flake to prefer — this is the one lane.
    #
    # WHY overrideAttrs and NOT `.override { sources = ...; }`: `sources` is a
    # `let` binding inside package.nix, not a function argument, so it is not
    # overridable. Replacing `src` directly is the only reachable surface — and
    # it means `meta.platforms` (`lib.attrNames sources`) must be widened by
    # hand or nixpkgs refuses the host platform.
    #
    # THE ALPHA MOVED torrc-defaults. 16.0a13's tarball has
    # `TorBrowser/Tor/torrc-defaults` and `TorBrowser/Tor/geoip{,6}` where 15.x
    # had `TorBrowser/Data/Tor/...` (verified by `tar tf` on the fetched
    # tarball). The stock buildPhase's `--replace-fail` would abort on the
    # missing file, so the path prefix is rewritten in the phase text — one
    # substitution covers all four uses (substituteInPlace, the
    # torrc-defaults_path lockPref, and both GeoIP lines).
    #
    # Everything else in that derivation is arch-generic (autoPatchelfHook +
    # a makeWrapper LD_LIBRARY_PATH), which is why this works at all.
    #
    # KNOWN COSMETIC ROT: `meta.changelog` is baked from the let-bound 15.0.x
    # version and still points at the maint-15.0 branch.
    #
    # BUMPING: alpha releases are short-lived and dist.torproject.org keeps only
    # the current one, so a stale pin here becomes a 404 fetch. Re-point version
    # + hash from https://dist.torproject.org/torbrowser/ when that happens, and
    # DELETE this whole block once nixpkgs ships 16.0 stable with aarch64.
    nixpkgs.overlays = [
      (_final: prev: {
        tor-browser = prev.tor-browser.overrideAttrs (old: {
          version = "16.0a13";
          src = prev.fetchurl {
            urls = [
              "https://dist.torproject.org/torbrowser/16.0a13/tor-browser-linux-aarch64-16.0a13.tar.xz"
              "https://archive.torproject.org/tor-package-archive/torbrowser/16.0a13/tor-browser-linux-aarch64-16.0a13.tar.xz"
            ];
            hash = "sha256-TboDPnxfsA+NI/tUEqCCXNE67lZdMfyEsynQknrGzPc=";
          };
          buildPhase =
            builtins.replaceStrings [ "TorBrowser/Data/Tor/" ] [ "TorBrowser/Tor/" ]
              old.buildPhase;
          meta = old.meta // {
            platforms = old.meta.platforms ++ [ "aarch64-linux" ];
          };
        });
      })
    ];

    # X11 + XFCE. modesetting binds QEMU's virtio-gpu with no host GPU needed.
    services.xserver = {
      enable = true;
      desktopManager.xfce.enable = true;
      displayManager.lightdm.enable = true;
    };

    # Boot straight into the session with no credential prompt — this VM is
    # hand-booted from a local QEMU window and is reachable from no network.
    # It is NOT a stateless sandbox: /home lives on the root qcow2, which is
    # created once and reused (see hosts/nixvm.nix), so that image is durable
    # unencrypted local state rather than a scratch buffer. autoLogin lives at
    # the top level in current nixpkgs (moved out of
    # services.xserver.displayManager). With XFCE as the sole session, nixpkgs
    # auto-selects it, so `defaultSession` is unnecessary.
    services.displayManager.autoLogin = {
      enable = true;
      user = loginName;
    };

    # Guest integrations: qemu-guest-agent (host<->guest control) and
    # spice-vdagent (clipboard sharing + auto display-resize when the QEMU
    # window is resized).
    #
    # The per-session CLIENT (`spice-vdagent`, no trailing d) needs no wiring
    # here: the pinned services.spice-vdagentd module puts `pkgs.spice-vdagent`
    # in environment.systemPackages, that package ships
    # `etc/xdg/autostart/spice-vdagent.desktop`, config/system-path.nix links
    # `/etc/xdg` into the system profile unconditionally, and `xdg.autostart`
    # defaults to true — so xfce4-session starts it from XDG_CONFIG_DIRS.
    # Operator's tell inside the guest: `ps aux | grep spice-vdagent` shows BOTH
    # processes. Only one means the client did not start.
    services.qemuGuest.enable = true;
    services.spice-vdagentd.enable = true;

    # A couple of niceties so the desktop isn't bare on first boot. Both
    # browsers substitute for aarch64-linux, so neither is ever built on the
    # 1-CPU Linux builder. `chromium` and NOT `ungoogled-chromium`: ungoogled
    # patches out the Chrome Web Store and rewrites the Google search engine
    # into a "No Search" stub (both measured in modules/home/chromium.nix),
    # and nixpkgs enables Widevine only for plain chromium (common.nix:913) —
    # all three cut against a desktop whose point is signing into Google.
    # `opera` is not a choice at all: nixpkgs removed it 2025-05-19
    # (aliases.nix:1932), so the name throws at eval on every system.
    environment.systemPackages = with pkgs; [
      chromium
      firefox
      xfce4-terminal
      # Alpha-channel aarch64 build, supplied by the overlay at the top of this
      # module. Unlike the other two it does NOT substitute — the derivation
      # sets preferLocalBuild/allowSubstitutes=false — so it is built on
      # Determinate's native Linux builder on every store-image rebuild.
      tor-browser
    ];
  };
}
