# infra/cloudflare/nixpi-ssh.nix — terranix (Nix -> OpenTofu/Terraform JSON) module
# provisioning Cloudflare Access for Infrastructure (ZTIA) SSH for `nixpi`.
#
# This is the CF-side half of the ZTIA cutover: short-lived SSH certificates,
# minted by Cloudflare's hosted SSH CA, replacing the static ed25519 key that
# `modules/nixos/core.nix` used to grant `nixpi` unconditionally. The NixOS
# side (`TrustedUserCAKeys`, `modules/nixos/cloudflare-ssh-ca.pub`) trusts the
# CA public key this stack's SSH CA (§ below) produces; nothing here is a
# replacement for the existing `cloudflared-connector` tunnel — ZTIA layers
# Access + a CA on top of the SAME tunnel connectivity
# (`modules/nixos/cloudflared.nix` is untouched).
#
# Modeled directly on the retired `infra/cloudflare/litellm.nix` (see
# `git show main:infra/cloudflare/litellm.nix`) — same terranix rendering
# pattern, same provider pin, same "CLOUDFLARE_API_TOKEN from env" convention,
# same `nix run .#cf-ssh-apply`/`cf-ssh-destroy` wrapper shape (flake.nix).
#
# Resources declared (verified against the CURRENT Cloudflare Terraform
# provider docs, fetched live — see docs/tunnel-architecture-and-runbook.md
# for the full citation list):
#
#   (a) cloudflare_zero_trust_infrastructure_access_target — the "target"
#       object: a hostname label + IP + virtual network. Doc:
#       https://developers.cloudflare.com/cloudflare-one/access-controls/applications/non-http/infrastructure-apps/
#       and https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-infrastructure-access/
#       ("Configure the cloudflare_zero_trust_infrastructure_access_target
#       resource"). Schema per the docs' own example:
#         hostname, account_id, ip = { ipv4 = { ip_addr, virtual_network_id } }
#       IMPORTANT — live-verify before apply: the target's IP must be a
#       private IP that already routes through a Cloudflare Tunnel CIDR route
#       (Networking -> Routes -> Tunnel CIDR) bound to the SAME tunnel that
#       `cloudflared-connector` runs. That route is NOT declared here (it is a
#       property of the tunnel object, not of the target) — provision it
#       separately (dashboard: Networking > Routes > Create route > Tunnel
#       CIDR) before `nix run .#cf-ssh-apply`, or the target IP will not
#       appear as reachable. `virtual_network_id` below is a PLACEHOLDER.
#
#   (b) cloudflare_zero_trust_access_application (type = "infrastructure") —
#       the Infrastructure Access application, gating SSH (protocol "SSH",
#       port 22) against the target above via `target_criteria`. Doc: same
#       two pages as (a), "Add an infrastructure application" step. Schema:
#         type, target_criteria { port, protocol, target_attributes { name =
#         "hostname", values = [...] } }.
#
#   (c) cloudflare_zero_trust_access_policy — the Allow policy on that
#       application, scoped to the owner's identity (kattakath.com Workspace
#       domain — this repo's existing identity convention, see
#       infra/cloudflare/litellm.nix's `allow_email` policy for the same
#       `email_domain` selector), PLUS the ZTIA-specific
#       `connection_rules.ssh.usernames` block naming which UNIX login(s) the
#       cert may assert (`ismail` — matches `users.users.${userName}` on
#       nixpi). Doc: same pages, "Add an infrastructure policy" — schema:
#         application_id, decision = "allow", include = [{ email_domain =
#         { domain } }], connection_rules { ssh { usernames = [...] } }.
#
# NOT declared here (no terraform resource exists / needed):
#   - The SSH CA itself. Confirmed via live doc fetch: generating the CA is a
#     ONE-TIME dashboard action (Access controls > Service credentials > SSH >
#     Generate SSH CA) or a bare API call
#     (`POST /accounts/$ACCOUNT_ID/access/gateway_ca` — idempotent per docs;
#     `GET` the same endpoint if it already exists). There is no
#     `cloudflare_zero_trust_access_gateway_ca`-style Terraform resource
#     documented anywhere in the fetched pages — this is a real gap in the
#     provider, not an oversight here. `nix run .#cf-ssh-apply` therefore only
#     provisions (a)-(c); the CA public key must be fetched separately
#     (dashboard "Copy CA public key", or `GET` the same gateway_ca endpoint)
#     and committed by hand into `modules/nixos/cloudflare-ssh-ca.pub` — see
#     the rollout order in docs/tunnel-architecture-and-runbook.md.
#   - The Tunnel CIDR route binding nixpi's private IP into the tunnel
#     (Networking > Routes) — a property of the tunnel object, provisioned
#     once, out of band of this per-target module (see note in (a) above).
#   - WARP device-enrollment rule / device profile — governs the macOS CLIENT
#     side, not nixpi; no NixOS or per-host terranix equivalent.
#   - Gateway network policy ("Access Infrastructure Target is Present ->
#     Allow") — optional, dashboard/API only, unrelated to this module.
_:
let
  accountId = "726e0b2aa2bc2c6944f96a042e3c461b";

  # ---- PLACEHOLDERS — fill in with live values before `nix run .#cf-ssh-apply` ----
  # nixpi's private IP as it is (or will be) routed through the Cloudflare
  # Tunnel CIDR route bound to the SAME tunnel `cloudflared-connector` runs.
  # This is NOT nixpi's LAN DHCP address by default — confirm the exact
  # address the Tunnel CIDR route publishes before applying.
  # nixpi's LAN IP (its default-route source), to be published as a /32 Tunnel
  # CIDR route through the nixpi tunnel (ca03b113-…). Confirmed via
  # `ssh nixpi 'ip route get 1.1.1.1'` on 2026-07-08.
  targetIp = "10.0.0.37";
  # The account's only virtual network ("default"), fetched live via the
  # Cloudflare API (GET /accounts/…/teamnet/virtual_networks) 2026-07-08.
  virtualNetworkId = "b6c33d6d-4a9d-47c3-9ec1-d15321469b72";

  targetHostname = "nixpi"; # label only — NOT used for DNS resolution
  sshPort = 22;
  allowEmailDomain = "kattakath.com"; # operator's Google Workspace domain — repo convention (infra/cloudflare/litellm.nix)
  sshUsername = "ismail"; # matches users.users.${userName} on hosts/nixpi.nix

  applicationId = "\${cloudflare_zero_trust_access_application.nixpi_ssh.id}";
in
{
  # ---- Provider: API token from the CLOUDFLARE_API_TOKEN env var --------------
  provider.cloudflare = { };

  terraform.required_providers.cloudflare = {
    source = "cloudflare/cloudflare";
    version = ">= 5.0.0";
  };

  # ---- (a) Infrastructure Access target: hostname label + IP + VNet ---------
  resource.cloudflare_zero_trust_infrastructure_access_target.nixpi = {
    account_id = accountId;
    hostname = targetHostname;
    ip = {
      ipv4 = {
        ip_addr = targetIp;
        virtual_network_id = virtualNetworkId;
      };
    };
  };

  # ---- (b) Infrastructure Access application: SSH/22 against that target ----
  resource.cloudflare_zero_trust_access_application.nixpi_ssh = {
    account_id = accountId;
    name = "nixpi SSH (ZTIA)";
    type = "infrastructure";
    target_criteria = [
      {
        port = sshPort;
        protocol = "SSH";
        target_attributes = [
          {
            name = "hostname";
            values = [ targetHostname ];
          }
        ];
      }
    ];
  };

  # ---- (c) Access policy: owner's identity + allowed UNIX login -------------
  # decision = "allow"; connection_rules.ssh.usernames is the ZTIA-specific
  # field naming which cert principal(s) this policy permits — sshd then
  # matches the cert principal against the login user with just
  # TrustedUserCAKeys set (no AuthorizedPrincipalsFile/Command needed).
  resource.cloudflare_zero_trust_access_policy.nixpi_ssh_allow = {
    account_id = accountId;
    application_id = applicationId;
    name = "Allow ${allowEmailDomain} as ${sshUsername}";
    decision = "allow";
    precedence = 1;
    include = [
      {
        email_domain = {
          domain = allowEmailDomain;
        };
      }
    ];
    connection_rules = {
      ssh = {
        usernames = [ sshUsername ];
      };
    };
  };

  # ---- Outputs -----------------------------------------------------------------
  output.nixpi_ssh_application_id = {
    value = applicationId;
  };
  output.nixpi_ssh_target_id = {
    value = "\${cloudflare_zero_trust_infrastructure_access_target.nixpi.id}";
  };
}
