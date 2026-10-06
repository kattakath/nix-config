# XFCE's Xft.dpi — LAYER 3 of nixvm's display, and the one that overrides the
# other two for every GTK app.
#
# WHY THIS EXISTS. `services.xserver.dpi = 192` (modules/nixos/desktop-vm.nix)
# does take: the guest's Xorg log says `(++) modeset(0): DPI set to (192, 192)`.
# It still is not what GTK obeys. Measured in the booted guest 2026-10-06,
# `xrdb -query` reported:
#
#     Xft.dpi:	96
#
# XFCE's xsettings daemon publishes that value and GTK follows it, so every app
# rendered at 96 no matter what the X server was told. Fixing the resolution and
# the server DPI alone leaves a bigger desktop with the same small text.
#
# THE UPSTREAM OPTION, and the reason this is a module rather than a shim:
# grepped the pinned nixpkgs first — `nixos/modules/programs/xfconf.nix` is 32
# lines and declares ONLY `enable`, with no per-key surface, so there is no
# NixOS option for this. The pinned HOME-MANAGER does have one:
# `xfconf.settings` (modules/misc/xfconf.nix:96), applied by `xfconf-query`
# (:138) from a `home.activation` entry, gated
# `mkIf (cfg.enable && cfg.settings != { })` (:132) — and `xfconf.enable`
# already defaults true, so defining `settings` is the whole switch.
# NixOS's `programs.xfconf.enable` is the companion the HM module's own
# description demands; XFCE sets it, and it evaluates TRUE in this guest.
#
# upstream option home-manager xfconf.settings exists -> using it. No xset,
# no autostart file, no hand-written xfce-perchannel-xml.
#
# ---- HOST SCOPE: nixvm ONLY, AND THE GATE IS LOAD-BEARING ------------------
# modules/home/ is the profile EVERY host shares, so an ungated definition here
# would reach `macos`. That is not merely untidy — the HM module asserts its
# platform (`assertPlatform "xfconf" pkgs lib.platforms.linux`,
# modules/misc/xfconf.nix:133), so a non-empty `settings` on darwin is a BUILD
# FAILURE, and on `nixpi` it would install a desktop setting on a headless
# server. The gate is `osConfig.networking.hostName`, the same pattern
# modules/home/{default,macos-user-agents,spotlight-actions}.nix use to reach
# the system layer from here (CLAUDE.md § Configuration: per-host divergence is
# a gate, not a fork).
#
# `osConfig ? { }` with the `or ""` fallback matches those siblings: this module
# must still evaluate where there is no NixOS/darwin parent at all (the
# standalone-HM path in checks), and an unknown host simply gets nothing.
#
# WEAKEST ASSUMPTION, stated rather than buried: the HM activation runs from
# `home-manager-ismail.service` at BOOT, which has no session D-Bus. Upstream
# handles that by wrapping the writes in `dbus-run-session` (:159-163), so they
# land in the xsettings channel's XML for the real session to read at login.
# What is NOT proven is the ordering against `xfsettingsd` — if that daemon is
# already running it may republish 96. The booted `xrdb -query` is the only
# check that settles it; a green build proves nothing here.
{
  lib,
  osConfig ? { },
  ...
}:
let
  # `nixvm` is the XFCE build-vm (hosts/nixvm.nix). It is the ONLY host in this
  # fleet with an X session, so this is the only host where an xsettings value
  # means anything.
  isNixvmHost = (osConfig.networking.hostName or "") == "nixvm";
  # AND the desktop must actually be on. `local.desktopVm.enable` is set only
  # inside nixvm's `virtualisation.vmVariant`, and XFCE is what turns
  # `programs.xfconf.enable` on — measured TRUE in the vmVariant and FALSE in
  # nixvm's base config. Without this second term the setting would also land in
  # the base toplevel, where there is no X session and no xfconf daemon, which
  # is precisely the "systemd error message" the HM module's own description
  # warns about. The base is never booted, so this is belt not brace — but it
  # makes the scope exactly "nixvm, desktop running" rather than "nixvm".
  hasXfconf = osConfig.programs.xfconf.enable or false;
in
{
  # 192 is NOT a resolution-scaled number — see modules/nixos/desktop-vm.nix.
  # It must equal `services.xserver.dpi` there, so the server and the xsettings
  # daemon agree; a mismatch is how fonts and widget metrics disagree.
  xfconf.settings = lib.mkIf (isNixvmHost && hasXfconf) {
    xsettings."Xft/DPI" = 192;
  };
}
