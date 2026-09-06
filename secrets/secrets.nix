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
  # 2026-08-23: upgraded from a static PAT to a GitHub App — every registration
  # mints a fresh ~1hr installation token from this key rather than using a
  # long-lived bearer credential directly. Org-level registration serves every
  # dontsell-ai repo, not just app. Content is the raw .pem.
  #
  # 2026-09-06: the App behind this key changed. It was "dontsell-ai" (4689619,
  # org-owned, Self-hosted-runners RW only); it is now "ismailkattakath-ci"
  # (4849830) — the SAME App as gh-app-fleet-key below. The old one was retired
  # because ismailkattakath-ci was already installed on dontsell-ai with
  # repos=all, so a second narrower credential for the same job protected
  # nothing that was still unprotected.
  #
  # SO THIS FILE AND gh-app-fleet-key.age NOW HOLD IDENTICAL KEY MATERIAL, and
  # that is deliberate, not duplication to clean up: an agenix secret has ONE
  # owner, and the two consumers run as different users — this one is owned by
  # `_github-runner` (the bare-metal launchd DAEMONS), the other by the login
  # user (the Tart USER AGENTS, which need a GUI session for
  # Virtualization.framework). Rotating the App key means re-encrypting BOTH,
  # with `age -R` and a recipient-tag check — never `agenix -e`.
  "gh-app-dontsell-ai-key.age".publicKeys = [
    operator
    macos
  ];
  # The fleet-wide CI GitHub App ("ismailkattakath-ci", appId 4849830, PUBLIC
  # so it installs beyond its owning personal account) — ONE key serves every
  # install: kattakath + silvercreek-ai + dontsell-ai orgs and the personal
  # account. Powers tart.githubRunners.* — the ephemeral Tart-VM-per-job
  # runners (nix-tart-vms darwinModules.github-runner, hosts/macos.nix). Same
  # model as the dontsell key above: HOST-decrypted at activation. Content is
  # the raw .pem.
  #
  # 2026-09-06: this App REPLACED both "kattakath-fleet-ci" (4845230) and the
  # org-owned Actions bot "kattakath-ci" (4243998). Its permissions are the
  # union of those roles — Repository Contents/Pull-requests/Actions RW +
  # Metadata R, Organization Self-hosted-runners RW; Administration was
  # deliberately NOT granted (only repo-scoped runner registration needs it,
  # and every lane is org-scoped).
  #
  # THE SAME PRIVATE KEY IS ALSO THE kattakath ORG SECRET
  # CI_BOT_APP_PRIVATE_KEY, which is what auto-merge.yml and
  # update-flake-lock.yml mint from. That is a deliberate consolidation, and
  # it is the reason this file's key is now a code-push credential rather than
  # a runner-registration one: rotating it means rotating BOTH places. Prefer
  # generating a SECOND App private key for whichever side you rotate, so the
  # two are independently revocable.
  # The name is unchanged from the file's creation ("fleet key") because the
  # role is unchanged; only the App behind it moved.
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
