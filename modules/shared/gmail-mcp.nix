# Per-account Gmail MCP launchers on PATH, for the PLUGIN lane.
#
# WHY THIS MODULE EXISTS. The 2026-10-01 purge removed the central MCP gateway from
# macOS (`local.mcpGateway.enable = false`), and these four launchers lived inside it —
# so `gmail` would have gone dark with no replacement. The operator chose to keep the
# capability and give it a plugin home.
#
# THE SPLIT, and it is the pattern the other ownerless servers will follow:
#   HERE          the launcher binaries, because they read the login Keychain and must
#                 not be duplicated into a plugin repo.
#   THE PLUGIN    a `.mcp.json` in github:kattakath/skills naming each launcher by
#                 BINARY NAME, so Claude Code spawns one stdio server per account,
#                 per session, with no proxy and nothing shared between clients.
#
# This is NOT a gateway coming back. There is no long-lived process, no listening
# socket, no tunnel and no portal: Claude Code starts a launcher when a session needs
# it and reaps it afterwards. "Plugin-local, not shared" is exactly what the operator
# asked for, and the binaries being Nix-installed is just how software gets onto this
# machine — the same arrangement `page-lab-pick` already has with the `page-lab`
# plugin, and `mcp-nixos` with `claude-code-nix`.
#
# WHY THE PLUGIN CANNOT CARRY THE LAUNCHER ITSELF: a plugin's `.mcp.json` can set `env`
# to literals or passthroughs, but it cannot run a `security find-generic-password`
# read. Putting the credential logic in the plugin would also mean a second copy of it
# in a second repo — see packages/gmail-mcp.nix's header.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.gmailMcp;
in
{
  options.local.gmailMcp = {
    accounts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "someone@example.com" ];
      description = ''
        Google/Workspace addresses to install a Gmail MCP launcher for, one binary each,
        named `nix-mcp-gmail-<sanitised-address>`.

        PLAIN ADDRESSES, not aliases: the sanitised form is derived inside
        `packages/gmail-mcp.nix` so the tool prefix, the credentials filename and the
        binary name cannot drift apart.

        Empty by default and set PER HOST, because the account list is operator
        identity rather than fleet shape — a template consumer of this repo wants the
        mechanism without inheriting someone else's mailboxes.

        Each account needs a ONE-TIME browser auth before its tools work; the launcher
        prints the exact command. The shared OAuth client id/secret come from the login
        Keychain at launch, so no credential is in the store or in this list.
      '';
    };
  };

  # Darwin-gated because the launcher reads the macOS login Keychain via
  # /usr/bin/security. On Linux the option exists and does nothing, which keeps
  # `hosts/*.nix` free of platform conditionals.
  config = lib.mkIf (cfg.accounts != [ ] && pkgs.stdenv.hostPlatform.isDarwin) {
    home.packages = map (
      email:
      pkgs.callPackage ../../packages/gmail-mcp.nix { } {
        inherit email;
        inherit (config.home) homeDirectory;
      }
    ) cfg.accounts;
  };
}
