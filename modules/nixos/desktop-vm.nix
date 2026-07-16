# Optional lightweight desktop for the nixvm sandbox — X11 + XFCE with
# passwordless autologin and QEMU/SPICE guest integration. Opt-in via
# `services.desktopVm.enable`; the base nixvm stays headless (serial + SSH only)
# unless this is turned on, so the installed headless image and the CI-runner
# path carry no desktop cost. hosts/nixvm.nix enables it ONLY inside
# `virtualisation.vmVariant`, so the desktop materialises for the graphical
# `build-vm` / `nix run .#nixvm-gui` path but NOT for the plain image.
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
  userName,
  ...
}:
let
  cfg = config.services.desktopVm;
in
{
  options.services.desktopVm.enable = lib.mkEnableOption "lightweight XFCE desktop + guest integration for the nixvm sandbox";

  config = lib.mkIf cfg.enable {
    # X11 + XFCE. modesetting binds QEMU's virtio-gpu with no host GPU needed.
    services.xserver = {
      enable = true;
      desktopManager.xfce.enable = true;
      displayManager.lightdm.enable = true;
    };

    # Boot straight into the session with no credential prompt — this is a
    # throwaway sandbox. autoLogin lives at the top level in current nixpkgs
    # (moved out of services.xserver.displayManager). With XFCE as the sole
    # session, nixpkgs auto-selects it, so `defaultSession` is unnecessary.
    services.displayManager.autoLogin = {
      enable = true;
      user = userName;
    };

    # Guest integrations: qemu-guest-agent (host<->guest control) and
    # spice-vdagent (clipboard sharing + auto display-resize when the QEMU
    # window is resized).
    services.qemuGuest.enable = true;
    services.spice-vdagentd.enable = true;

    # A couple of niceties so the desktop isn't bare on first boot.
    environment.systemPackages = with pkgs; [
      firefox
      xfce4-terminal
    ];
  };
}
