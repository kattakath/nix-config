# macOS host config for "macvm" (Apple Silicon, aarch64-darwin) — a UTM guest VM.
#
# Same shared darwin stack as `macos` (modules/darwin/core.nix + the shared
# home.nix profile, Determinate, agenix, home-manager) but with its OWN, leaner
# Homebrew app set and the localhost MCP gateway turned OFF (see below). Think of
# it as the darwin analogue of `nixvm`: a sandbox host, distinct from the real Mac.
#
# Activate INSIDE the VM (the guest's login account MUST be `ismailkattakath`, or
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
{ userName, ... }:
{
  imports = [
    ../modules/darwin/core.nix
  ];

  nixpkgs.config.allowUnfree = true;

  users.users.${userName} = {
    name = userName;
    home = "/Users/${userName}";
  };

  # ---- Trim the MCP gateway on the VM -----------------------------------------
  # The localhost MCP gateway (modules/shared/mcp.nix) spawns ~14 servers at login
  # and a single startup failure crashes the whole proxy — heavier than a sandbox
  # VM needs, and several servers depend on apps this host doesn't carry. Disabling
  # the option removes the gateway launchd agent AND the claude-code MCP wiring
  # (config = mkIf cfg.enable). The real Mac (macos) keeps it (option default is
  # `pkgs.stdenv.isDarwin`, i.e. on).
  home-manager.users.${userName}.services.mcpGateway.enable = false;

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
