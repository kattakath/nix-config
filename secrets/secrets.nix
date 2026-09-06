# agenix rules — declares each committed .age secret and who may decrypt it.
# Consumed ONLY by the `agenix` CLI (agenix -e/-r), never imported into a system
# config. Recipients are SSH public keys directly (age's SSH support, no
# ssh-to-age step). Most secrets here are OPERATOR-ONLY (encrypted to the
# operator's key alone, never decrypted on any host); the `gh-app-*-key`
# entries are the exception — HOST-decrypted at activation, so they also carry
# the `macos` host-key recipient below.
#
# Edit a secret:   nix run github:ryantm/agenix -- -e secrets/<name>.age
# Re-key after changing recipients:  … -- -r
let
  # operator (ismail) — ~/.ssh/id_ed25519.pub; backed up off-machine, kept
  # editable. Single-sourced in ./operator-key.nix (also the fleet's authorizedKeys
  # via flake.nix → core.nix), so a key rotation is one edit there, not four.
  operator = import ./operator-key.nix;
  # macos host key (/etc/ssh/ssh_host_ed25519_key.pub) — re-checked 2026-08-23
  # (revived github-runner module) since the last pinned value here predated a
  # host-key rotation; verify against the live file before reusing this again.
  macos = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMh/Us9PkRc8ZegkaoES6/AZNo10Iw8sxGq9uniLpHOK root@macos.local";
in
{
  # nixpi's Cloudflare Tunnel connector token (TUNNEL_TOKEN=…). OPERATOR-ONLY: the
  # operator decrypts it on the Mac to plant on the card's FIRMWARE partition (via
  # `nix run .#nixpi-provision --token`); nixpi never decrypts it on-device (a fresh
  # SD flash rotates the host key — see the firmware-secrets flake).
  "cloudflared-token.age".publicKeys = [
    operator
  ];
  # macos self-hosted GitHub Actions runner's GitHub App private key, for the
  # `dontsell-ai` org (modules/darwin/github-runner.nix, services.macosGithubRunner).
  # 2026-08-23: upgraded from a static PAT to a GitHub App — the App is scoped to
  # ONLY "Organization permissions: Self-hosted runners: Read and write" (not
  # admin:org's much wider bundle), and every registration mints a fresh ~1hr
  # installation token from this key rather than using a long-lived bearer
  # credential directly. Org-level registration — serves every dontsell-ai repo,
  # not just app. Content is the raw .pem downloaded from the App's settings page.
  "gh-app-dontsell-ai-key.age".publicKeys = [
    operator
    macos
  ];
  # The fleet-wide CI GitHub App ("kattakath-fleet-ci", appId 4845230, PUBLIC
  # so it installs beyond its owning account) — ONE key serves every install:
  # kattakath + silvercreek-ai + dontsell-ai orgs (and the personal account,
  # unused until repo-level runners land). Powers tart.githubRunners.* — the
  # ephemeral Tart-VM-per-job runners (nix-tart-vms darwinModules.github-runner,
  # hosts/macos.nix). Same model as the dontsell key above: HOST-decrypted at
  # activation; permissions on the App are Organization/Self-hosted-runners RW
  # + Repository/Administration RW only. Content is the raw .pem.
  "gh-app-fleet-key.age".publicKeys = [
    operator
    macos
  ];
  # The macos GitLab runner's glrt- authentication token (runner
  # "macos-ismail-dev" on gitlab.com), for tart.gitlabRunner (nix-tart-vms
  # darwinModules.gitlab-runner, hosts/macos.nix): HOST-decrypted at
  # activation → the agent renders gitlab-runner's config.toml from it at
  # start, so the token lives only here and in the runner's 0600 runtime
  # config. Minted once via `gitlab-runner register`; rotating = re-register,
  # re-encrypt. Content is the bare token, one line.
  "gitlab-runner-token.age".publicKeys = [
    operator
    macos
  ];
}
