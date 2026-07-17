# Declarative BlenderMCP-VSE addon install for the Mac (home-manager, darwin-only).
#
# The companion to the `blender` MCP server in modules/shared/mcp.nix: that server
# (run in the localhost gateway) connects OUT to a socket the Blender ADDON opens
# on 127.0.0.1:9876. This module makes that addon appear in Blender already
# installed, enabled, VSE-on, and listening — no Edit > Preferences > Install
# dance, no sidebar "Connect to Claude" click ("all nix config, no manual").
#
# HOW (two symlinks into Blender's per-user scripts dir, both from the PINNED
# `blenderMcpSrc` rev — single-sourced with the server):
#   1. addon.py            -> <scripts>/addons/blender_mcp_addon.py
#   2. an autostart script -> <scripts>/startup/blendermcp_autostart.py
# Blender runs scripts/startup/*.py on launch; ours enables the addon, flips the
# `blendermcp_use_vse` scene toggle on (the 30+ VSE tools), and starts the socket
# server — so a freshly-launched Blender is immediately drivable from Claude.
#
# The per-user scripts dir is version-namespaced (~/…/Blender/<major.minor>/), and
# the version isn't known to Nix (Blender comes from the imperative Homebrew cask),
# so an activation script discovers it at switch time: from the installed
# Blender.app's Info.plist AND from any version dirs Blender already created. If
# Blender.app isn't present yet (first switch installs the cask; ordering vs. this
# home-manager activation isn't guaranteed), placement simply no-ops and self-heals
# on the next `darwin-rebuild switch`.
{
  pkgs,
  lib,
  # Pinned BlenderMCP-VSE source (flake = false input) — same rev the gateway
  # server runs (modules/shared/mcp.nix), so addon and server never drift.
  blenderMcpSrc,
  ...
}:
let
  # Fixed module name for the symlinked addon (independent of the upstream
  # filename); the autostart script enables exactly this module.
  addonModule = "blender_mcp_addon";

  # Runs on every Blender launch (scripts/startup/*.py). Timer-deferred so it fires
  # after Blender finishes initialising context; each step is independently guarded
  # so a failure (e.g. no start_server context) degrades to the manual sidebar
  # button rather than breaking Blender startup.
  autostartPy = pkgs.writeText "blendermcp_autostart.py" ''
    """Nix-managed (modules/darwin/blender.nix) — DO NOT EDIT.

    Auto-enable BlenderMCP-VSE, turn on VSE tools, and start its socket server so a
    freshly launched Blender is immediately drivable from Claude via the gateway.
    """

    import bpy
    import addon_utils

    ADDON_MODULE = "${addonModule}"


    def _autostart():
        # 1) Enable the addon (idempotent; registers its operators + scene props).
        try:
            if not addon_utils.check(ADDON_MODULE)[1]:
                addon_utils.enable(ADDON_MODULE, default_set=True, persistent=True)
        except Exception as exc:  # noqa: BLE001
            print(f"[blendermcp-autostart] enable failed: {exc}")

        # 2) Turn on the VSE toolset (mirrors the sidebar "Use Video Editing (VSE)").
        try:
            scene = bpy.context.scene
            if scene is not None and hasattr(scene, "blendermcp_use_vse"):
                scene.blendermcp_use_vse = True
        except Exception as exc:  # noqa: BLE001
            print(f"[blendermcp-autostart] vse toggle failed: {exc}")

        # 3) Start the socket server the gateway's blender-mcp connects to (:9876).
        try:
            bpy.ops.blendermcp.start_server()
        except Exception as exc:  # noqa: BLE001
            print(f"[blendermcp-autostart] start_server failed: {exc}")

        return None  # one-shot: don't re-arm the timer


    bpy.app.timers.register(_autostart, first_interval=1.0)
  '';
in
{
  # Darwin-only: Blender + its user-scripts path are macOS-specific here. Inert on
  # the NixOS hosts (the module is imported everywhere via modules/shared/home.nix,
  # like ./mcp.nix, and gated on the config side).
  config = lib.mkIf pkgs.stdenv.isDarwin {
    home.activation.blenderMcpAddon = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      blenderRoot="$HOME/Library/Application Support/Blender"

      # Symlink the addon + autostart script into one version's scripts dir.
      place_blender_addon() {
        mm="$1"
        [ -n "$mm" ] || return 0
        scripts="$blenderRoot/$mm/scripts"
        $DRY_RUN_CMD mkdir -p "$scripts/addons" "$scripts/startup"
        $DRY_RUN_CMD ln -sf ${lib.escapeShellArg "${blenderMcpSrc}/addon.py"} \
          "$scripts/addons/${addonModule}.py"
        $DRY_RUN_CMD ln -sf ${lib.escapeShellArg autostartPy} \
          "$scripts/startup/blendermcp_autostart.py"
      }

      # Target the installed cask's version (if Blender.app is present yet)...
      app="/Applications/Blender.app"
      if [ -d "$app" ]; then
        place_blender_addon "$(/usr/bin/defaults read "$app/Contents/Info" \
          CFBundleShortVersionString 2>/dev/null | cut -d. -f1,2 || true)"
      fi

      # ...plus any version dirs Blender already created (covers upgrades and the
      # case where the cask installs after this activation on the first switch).
      if [ -d "$blenderRoot" ]; then
        for d in "$blenderRoot"/*/; do
          [ -d "$d" ] || continue
          place_blender_addon "$(basename "$d")"
        done
      fi
    '';
  };
}
