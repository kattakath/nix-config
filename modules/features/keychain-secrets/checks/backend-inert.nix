# ADR-004 Phase 2 gate, kept as a check so it cannot regress silently.
#
# Two properties, both about what activation and the loader do NOT do:
#
#   1. Activation never touches a secret backend. For a throwaway home-manager config with
#      the module enabled, under BOTH `backend.type = "none"` and `"gcp"`, no script in
#      `home.activation` mentions gcloud or any secrets-* command. This is the eval-time twin
#      of ast-grep/rules/activation-must-not-touch-secrets.yml (which sees source text, not
#      the assembled activation).
#   2. With `backend.type = "none"` the emitted loader is BYTE-IDENTICAL to a config that
#      sets nothing at all — the pre-ADR-004 loader — and NO secrets-* CLI is installed, so
#      every existing item behaves exactly as before and the host's drv does not move.
#      Under "gcp" the loader carries the SECRETS_BACKEND export + the reference-mode block
#      and the four CLIs are installed.
#
# `module` / `home-manager` are arguments, not `../module.nix` / `inputs`, for the
# capsule-invariant reason module-evaluates.nix states. `homeDir` is one binding for the
# nix-hardcoded-home-path reason stated there too.
{
  home-manager,
  pkgs,
  module,
}:
let
  homeDir = "/Users/tester";
  mkHm =
    extra:
    (home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        module
        {
          home.username = "tester";
          home.homeDirectory = homeDir;
          home.stateVersion = "24.05";
          local.keychainSecrets.enable = true;
        }
        extra
      ];
    }).config;
  plain = mkHm { };
  none = mkHm { local.keychainSecrets.backend.type = "none"; };
  gcp = mkHm { local.keychainSecrets.backend.type = "gcp"; };

  loaderOf = c: c.home.file.".config/secrets/loader.sh".text;
  activationText =
    c: builtins.concatStringsSep "\n" (map (e: e.data) (builtins.attrValues c.home.activation));
  touches = t: builtins.match ".*(gcloud|secrets-(rehydrate|push|resolve|status)).*" t != null;
  hasClis = c: builtins.any (p: pkgs.lib.hasPrefix "secrets-" (pkgs.lib.getName p)) c.home.packages;

  problems =
    pkgs.lib.optional (
      loaderOf none != loaderOf plain
    ) "backend.type = none changes the loader (must be byte-identical to a config that sets nothing)"
    ++ pkgs.lib.optional (
      !(pkgs.lib.hasInfix "SECRETS_BACKEND=gcp" (loaderOf gcp))
    ) "backend.type = gcp does not export SECRETS_BACKEND in the loader"
    ++ pkgs.lib.optional (
      !(pkgs.lib.hasInfix "_REF=" (loaderOf gcp))
    ) "backend.type = gcp loader lacks the reference-mode export block"
    ++ pkgs.lib.optional (hasClis none) "backend.type = none installs the secrets-* CLIs (declaring ≠ installing)"
    ++ pkgs.lib.optional (!(hasClis gcp)) "backend.type = gcp does not install the secrets-* CLIs"
    ++ pkgs.lib.optional (touches (activationText none)) "home.activation mentions a secret backend with backend.type = none"
    ++ pkgs.lib.optional (touches (activationText gcp)) "home.activation mentions a secret backend with backend.type = gcp";
in
pkgs.runCommand "keychain-secrets-backend-inert" { } (
  if problems == [ ] then
    ''
      echo "backend none: no CLIs, loader byte-identical; backend gcp: CLIs + exports; activation touches no backend either way" > "$out"
    ''
  else
    ''
      echo "keychain-secrets-backend-inert: ADR-004's baseline-unchanged guarantee broke." >&2
      ${pkgs.lib.concatStringsSep "\n" (map (p: ''echo "  ✘ ${p}" >&2'') problems)}
      exit 1
    ''
)
