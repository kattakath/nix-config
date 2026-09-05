# Starter fleet flake — scaffolded by `nix flake init -t github:kattakath/nix-config`.
#
# Consumes the public nix-config ENGINE (lib.mkDarwin) instead of forking it:
# your identity is overridden here, your host deltas live in hosts/macos.nix,
# and engine updates arrive with a plain `nix flake update`. The three steps to
# a running Mac are in this template's README.md.
{
  description = "A personal nix-darwin fleet built on the kattakath/nix-config engine";

  inputs.nix-config.url = "github:kattakath/nix-config";

  outputs =
    { self, nix-config }:
    let
      system = "aarch64-darwin";
      # Reuse the engine's own nixpkgs pin — no second nixpkgs input to keep in sync.
      pkgs = nix-config.inputs.nixpkgs.legacyPackages.${system};
    in
    {
      darwinConfigurations.macos = nix-config.lib.mkDarwin {
        inherit system;
        # `hostname` selects the ENGINE's hosts/<name>.nix profile (mkDarwin
        # resolves it inside nix-config, not this repo) — local deltas layer on
        # top via extraModules below.
        hostname = "macos";
        # EDIT ME — the identity threaded into every module (specialArgs).
        # loginName MUST equal your macOS login (`id -un`): it becomes
        # /Users/<loginName> and home-manager.users.<loginName>.
        identity = {
          loginName = "yourlogin";
          fullName = "Your Name";
          userEmail = "you@example.com"; # git author email
          domainName = "example.com";
        };
        extraModules = [ ./hosts/macos.nix ];
      };

      # `nix run .#macos` — first activation before darwin-rebuild is on PATH
      # (mirrors the engine's apps.aarch64-darwin.macos). Thereafter:
      #   darwin-rebuild switch --flake .#macos
      apps.${system}.macos = {
        type = "app";
        program = "${pkgs.writeShellScript "activate-macos" ''
          exec ${self.darwinConfigurations.macos.config.system.build.darwin-rebuild}/bin/darwin-rebuild switch --flake "${self}#macos" "$@"
        ''}";
        meta.description = "First activation of this Mac from the flake (after Determinate Nix)";
      };
    };
}
