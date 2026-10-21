# Your host deltas, layered on top of the engine's identity-free
# hosts/generic-darwin.nix (which mkDarwin imports via `hostname = "generic-darwin"`).
# Same module system: anything set here MERGES with the engine's modules; use
# lib.mkForce to replace an engine value outright.
{ loginName, ... }:
{
  # No runner kill-switch is needed: `hostname = "generic-darwin"` never imports the
  # engine's runner module, so `local.macosGithubRunner` does not even exist here.
  # (A `lib.mkForce false` on it — what this file carried until 2026-09-20 — made
  # every consumer eval FAIL with "option does not exist"; ADR-004 §9.9.)

  home-manager.users.${loginName} = {

    # ---- Cloud CLIs and secrets recovery — both OFF until you flip them ---------
    # `local.cloudCli.aws.enable` installs the AWS CLI + aws-sso-util and writes
    # ~/.aws/config.example (placeholders only; the real ~/.aws/config is yours).
    # `local.keychainSecrets.backend.type = "gcp"` makes GCP Secret Manager the
    # durable copy of your Keychain secrets: `gcloud auth login` then
    # `secrets-rehydrate` on a fresh Mac. README § Your secrets on a new machine.
    # local.cloudCli.aws.enable = true;
    # local.keychainSecrets.backend.type = "gcp";
  };

  # Homebrew apps for THIS Mac. generic-darwin declares no casks of its own, so
  # these lists are the whole set.
  homebrew = {
    brews = [
      "gh"
    ];
    casks = [
      "firefox"
      "rectangle"
    ];
  };
}
