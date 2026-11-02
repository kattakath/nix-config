# Names DERIVED from an identity — one spelling each, so every site that needs one computes
# it the same way from its own inputs (the fleet identity in the engine, the per-host idArgs
# in home-manager, which mkDarwin lets a host override).
#
# NOT auto-imported — `modules/_lib/` is excluded from import-tree by convention
# (see ./nix-ld-libraries.nix). Consumers `import` it explicitly.
{
  # The Workspace account: how Google mints it from the POSIX login and the domain.
  googleAccount = { loginName, domainName }: "${loginName}@${domainName}";

  # nixpi's SSH ingress hostname — the Cloudflare tunnel's public hostname, the deploy-rs
  # target and the ~/.ssh/config block must all name the same host.
  nixpiSshHostname = domainName: "nixpi.${domainName}";
}
