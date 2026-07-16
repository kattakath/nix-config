# infra/cloudflare/nixpi-tunnel.nix — terranix (Nix -> OpenTofu/Terraform JSON)
# module provisioning nixpi's REMOTELY-MANAGED Cloudflare Tunnel itself.
#
# It provisions four things as Terraform state (declaratively, no imperative
# `curl` calls):
#
#   (a) a remotely-managed tunnel named "nixpi"
#       (cloudflare_zero_trust_tunnel_cloudflared, config_src = "cloudflare");
#   (b) the tunnel's ingress config
#       (cloudflare_zero_trust_tunnel_cloudflared_config): the public-hostname
#       SSH route, the kattakath.com -> local Caddy route, and the required
#       catch-all 404 rule;
#   (c) proxied CNAMEs -> <tunnel-id>.cfargotunnel.com (cloudflare_dns_record):
#       nixpi.kattakath.com (the SSH ingress host) AND the apex kattakath.com
#       (so the Caddy landing-page ingress rule is publicly reachable);
#   (d) the connector token, surfaced as a SENSITIVE `output` via the
#       cloudflare_zero_trust_tunnel_cloudflared_token data source, so
#       `nix run .#cf-tunnel-apply` prints it for the operator to store in the
#       vault (`nix run .#nixpi-vault-token` → secrets/cloudflared-token.age) and
#       plant on the FIRMWARE partition — NEVER written to git or the store.
#
# The runtime connector unit (`modules/nixos/cloudflared.nix`) is UNTOUCHED: it
# reads the token at /run/cloudflared-token, which services.firmwareProvisioning
# copies off the FAT FIRMWARE partition at boot (host-key-independent, so a fresh
# SD flash does not lock out the tunnel — see hosts/nixpi.nix).
#
# Schemas verified against the current Cloudflare Terraform provider v5 docs
# (cloudflare/terraform-provider-cloudflare, docs/resources + docs/data-sources):
#   - cloudflare_zero_trust_tunnel_cloudflared: required { account_id, name };
#     config_src = "cloudflare" selects a remotely-managed tunnel. tunnel_secret
#     is ONLY for locally-managed tunnels — omitted here on purpose.
#   - cloudflare_zero_trust_tunnel_cloudflared_config: required { account_id,
#     tunnel_id }; config.ingress is a list of { hostname?, service } with a
#     trailing catch-all { service = "http_status:404" }.
#   - cloudflare_dns_record: required { zone_id, name, type, ttl }; proxied
#     CNAME uses content = "<tunnel-id>.cfargotunnel.com", proxied = true,
#     ttl = 1 (automatic).
#   - data.cloudflare_zero_trust_tunnel_cloudflared_token: required { account_id,
#     tunnel_id }; the token is the sensitive `.token` attribute.
# accountId / zoneId / domainName are threaded from flake.nix's single sources of
# truth (via _module.args in cfTunnelConfig), so there is no per-file duplicate to drift.
{
  domainName,
  accountId,
  zoneId,
  ...
}:
let
  # nixpi is the only tunnelled host: macos is a client only, nixvm has no
  # public ingress.
  tunnelName = "nixpi";
  publicHostname = "${tunnelName}.${domainName}"; # nixpi.kattakath.com — the SSH ingress host
  apexHostname = domainName; # kattakath.com — the Caddy landing-page host (the zone apex)

  tunnelId = "\${cloudflare_zero_trust_tunnel_cloudflared.nixpi.id}";
in
{
  # ---- Provider: API token from the CLOUDFLARE_API_TOKEN env var --------------
  provider.cloudflare = { };

  terraform.required_providers.cloudflare = {
    source = "cloudflare/cloudflare";
    version = ">= 5.0.0";
  };

  # ---- (a) The remotely-managed tunnel --------------------------------------
  # config_src = "cloudflare" => ingress/config live in the Cloudflare account
  # (declared in (b) below), NOT in an on-origin YAML. No tunnel_secret: that is
  # a locally-managed-only field.
  resource.cloudflare_zero_trust_tunnel_cloudflared.nixpi = {
    account_id = accountId;
    name = tunnelName;
    config_src = "cloudflare";
  };

  # ---- (b) The tunnel ingress ------------------------------------------------
  # Equivalent to the script's PUT .../configurations, extended to the current
  # topology: SSH to the public hostname, the apex kattakath.com to the local
  # Caddy (packages/landing served on :80), and the mandatory catch-all 404.
  resource.cloudflare_zero_trust_tunnel_cloudflared_config.nixpi = {
    account_id = accountId;
    tunnel_id = tunnelId;
    config = {
      ingress = [
        # SSH ingress — nixpi.kattakath.com -> local sshd. Reached client-side with
        # `cloudflared access ssh --hostname nixpi.kattakath.com` (keys-only, the
        # operator's static key in modules/nixos/core.nix). No Access/identity layer.
        {
          hostname = publicHostname;
          service = "ssh://localhost:22";
        }
        # Caddy landing page — kattakath.com -> local Caddy on :80
        # (hosts/nixpi.nix's services.caddy serves packages/landing here).
        {
          hostname = apexHostname;
          service = "http://localhost:80";
        }
        # Required catch-all: any unmatched request returns 404.
        {
          service = "http_status:404";
        }
      ];
    };
  };

  # ---- (c) Proxied CNAME  <hostname> -> <tunnel-id>.cfargotunnel.com ----------
  # ttl = 1 is "automatic" (required for a proxied record). Matches the UPSERTed
  # CNAME the script created for the SSH public hostname.
  resource.cloudflare_dns_record.nixpi = {
    zone_id = zoneId;
    name = publicHostname;
    type = "CNAME";
    content = "${tunnelId}.cfargotunnel.com";
    proxied = true;
    ttl = 1;
  };

  # ---- (c2) Proxied CNAME  kattakath.com (apex) -> the same tunnel -----------
  # Without this the apex ingress rule (b) is unreachable — the tunnel maps
  # kattakath.com -> local Caddy, but nothing resolves kattakath.com to the
  # tunnel. Cloudflare CNAME-flattens the apex, so a proxied CNAME at the zone
  # root is valid here. This is what makes the public landing page live.
  resource.cloudflare_dns_record.nixpi_apex = {
    zone_id = zoneId;
    name = apexHostname;
    type = "CNAME";
    content = "${tunnelId}.cfargotunnel.com";
    proxied = true;
    ttl = 1;
  };

  # ---- (d) Connector token (data source) -------------------------------------
  # The token authenticates the `cloudflared` connector unit. It is a SECRET:
  # surfaced only as a sensitive output so `cf-tunnel-apply` prints it to the
  # operator's terminal for storage in the vault (secrets/cloudflared-token.age)
  # and planting on the FIRMWARE partition. It is NEVER written into git or a store path.
  data.cloudflare_zero_trust_tunnel_cloudflared_token.nixpi = {
    account_id = accountId;
    tunnel_id = tunnelId;
  };

  # ---- Outputs ---------------------------------------------------------------
  output.nixpi_tunnel_id = {
    value = tunnelId;
  };
  # SECRET — printed by cf-tunnel-apply for storage in the vault + FIRMWARE plant.
  # `tofu output -raw nixpi_connector_token` yields the bare token.
  output.nixpi_connector_token = {
    value = "\${data.cloudflare_zero_trust_tunnel_cloudflared_token.nixpi.token}";
    sensitive = true;
  };
}
