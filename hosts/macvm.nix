# macOS host config for "macvm" (Apple Silicon, aarch64-darwin) — a UTM guest VM.
#
# Same shared darwin stack as `macos` (modules/darwin/core.nix + the shared
# home.nix profile, Determinate, agenix, home-manager) but with its OWN, leaner
# Homebrew app set and the localhost MCP gateway turned OFF (see below). Think of
# it as the darwin analogue of `nixvm`: a sandbox host, distinct from the real Mac.
#
# SEPARATE PERSONA: this host runs under the `aloshy` / aloshy.ai account (same
# person, isolated local identity), set via the per-host `identity` override at
# the mkDarwin call in flake.nix — so `userName` here resolves to `aloshy`, NOT the
# global `ismailkattakath`.
#
# Activate INSIDE the VM (the guest's login account MUST be `aloshy`, or
# home-manager builds /Users/<wrong> paths):
#   nix run github:kattakath/nix-config#macvm    # first activation (before darwin-rebuild is on PATH)
#   darwin-rebuild switch --flake .#macvm         # thereafter
#
# Grok Build (the xAI `grok` CLI) is NOT a Homebrew app — install it ONCE in the
# VM with xAI's installer, then authenticate:
#   curl -fsSL https://x.ai/cli/install.sh | bash   # installs into ~/.grok (see https://docs.x.ai/build/overview)
#   grok                                             # first run authenticates
# The shared home.nix already puts ~/.grok/bin on PATH, provides Node, and wires
# the grok-build Claude Code plugin — so no Nix app-list entry is needed.
{ userName, lib, ... }:
{
  imports = [
    ../modules/darwin/core.nix
  ];

  nixpkgs.config.allowUnfree = true;

  # Dock at the BOTTOM on the VM (override core.nix's shared `orientation = "right"`;
  # mkForce because both set the same option). Everything else about the Dock
  # (autohide, tilesize, …) is inherited from core.nix.
  system.defaults.dock.orientation = lib.mkForce "bottom";

  users.users.${userName} = {
    name = userName;
    home = "/Users/${userName}";
  };

  # ---- Per-host home-manager tweaks for the VM --------------------------------
  home-manager.users.${userName} = {
    # Trim the MCP gateway (modules/shared/mcp.nix): it spawns ~14 servers at login
    # and one startup failure crashes the whole proxy — heavier than a sandbox VM
    # needs, and several servers depend on apps this host doesn't carry. Disabling
    # the option removes the gateway launchd agent AND the claude-code MCP wiring
    # (config = mkIf cfg.enable). macos keeps it (default = pkgs.stdenv.isDarwin).
    services.mcpGateway.enable = false;

    # Keep the VM visually DISTINCT from the real Mac: opt out of the operator's
    # custom desktop look (modules/shared/desktop-aesthetics.nix) — no custom
    # wallpaper, no Terminal.app "Ubuntu" profile. The VM falls back to the stock
    # macOS wallpaper + default Terminal, so it's recognisable at a glance as the
    # sandbox (even in fullscreen) instead of looking identical to macos.
    local.desktopAesthetics.enable = false;
  };

  # ---- Homebrew apps for THIS host --------------------------------------------
  # The framework (enable/onActivation/taps) lives in modules/darwin/homebrew.nix;
  # this is macvm's leaner set. onActivation.cleanup = "uninstall" removes anything
  # installed but not listed here. No brews, no masApps — GUI apps only.
  homebrew = {
    brews = [ ];
    casks = [
      "opera" # regular Opera (distinct from macos's opera-gx)
      "whatsapp"
      "capcut" # video editor
      "iina" # macOS-native video player (mpv-based) — plays & thumbnails most formats
    ];
    masApps = { };
  };
}
