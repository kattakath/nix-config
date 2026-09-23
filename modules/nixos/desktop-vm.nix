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
  # (modules/shared/wireguard-configs.nix). Renamed 2026-09-06.
  options.local.desktopVm.enable = lib.mkEnableOption "lightweight XFCE desktop + guest integration for the nixvm sandbox";

  config = lib.mkIf cfg.enable {
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
    services.qemuGuest.enable = true;
    services.spice-vdagentd.enable = true;

    # A couple of niceties so the desktop isn't bare on first boot. Both
    # browsers substitute for aarch64-linux, so neither is ever built on the
    # 1-CPU Linux builder. `chromium` and NOT `ungoogled-chromium`: ungoogled
    # patches out the Chrome Web Store and rewrites the Google search engine
    # into a "No Search" stub (both measured in modules/shared/chromium.nix),
    # and nixpkgs enables Widevine only for plain chromium (common.nix:913) —
    # all three cut against a desktop whose point is signing into Google.
    # `opera` is not a choice at all: nixpkgs removed it 2025-05-19
    # (aliases.nix:1932), so the name throws at eval on every system.
    environment.systemPackages = with pkgs; [
      chromium
      firefox
      xfce4-terminal
    ];
  };
}
