# infra/cloudflare/landing.nix — terranix (Nix → OpenTofu/Terraform JSON) module
# provisioning the DEDICATED, remotely-managed (token) Cloudflare Tunnel + DNS in
# front of the public landing page (Caddy on a host, modules/nixos/landing.nix).
#
# Mirrors infra/cloudflare/litellm.nix, with two deliberate differences:
#   • NO Cloudflare Access — this is a PUBLIC page (no allow/service-token policies,
#     no Access application).
#   • Routes the apex + www of the zone to the loopback Caddy origin.
#
# Topology it declares:
#   (a) a remotely-managed named tunnel "landing" (config_src = cloudflare);
#   (b) its connector token, surfaced as a SENSITIVE `tunnel_token` output;
#   (c) HTTP ingress  {apex, www} -> http://localhost:8787  + 404 catch-all
#       (localhost = the connector's own host, where Caddy serves the static site);
#   (d) proxied CNAMEs  kattakath.com and www.kattakath.com -> <tunnel-id>.cfargotunnel.com
#       (apex uses Cloudflare CNAME flattening).
#
# Apply / retrieve the connector token (then feed it to the host — see the runbook
# at the bottom of this file):
#   CLOUDFLARE_API_TOKEN=<scoped> nix run .#cf-landing-apply
#   tofu output -raw tunnel_token          # -> agenix landing-tunnel-token (TUNNEL_TOKEN=…)
#
# Provider v5 schema (verified, same as litellm.nix): cloudflare_zero_trust_tunnel_*
# and cloudflare_dns_record (content field; ttl=1 = auto).
_:
let
  accountId = "726e0b2aa2bc2c6944f96a042e3c461b";
  zoneId = "6e28971881e488941d052bbbf50d69cd"; # kattakath.com
  apex = "kattakath.com";
  www = "www.kattakath.com";
  # MUST match services.landing-page.port in modules/nixos/landing.nix. Caddy binds
  # this on loopback of the connector's host; cloudflared reaches it via localhost.
  originService = "http://localhost:8787";

  tunnelId = "\${cloudflare_zero_trust_tunnel_cloudflared.landing.id}";
  cnameTarget = "\${cloudflare_zero_trust_tunnel_cloudflared.landing.id}.cfargotunnel.com";
in
{
  # Provider reads CLOUDFLARE_API_TOKEN from the environment (see the apply app).
  provider.cloudflare = { };

  terraform.required_providers.cloudflare = {
    source = "cloudflare/cloudflare";
    version = ">= 5.0.0";
  };

  # ---- (a) remotely-managed named tunnel "landing" ---------------------------
  resource.cloudflare_zero_trust_tunnel_cloudflared.landing = {
    account_id = accountId;
    name = "landing";
    config_src = "cloudflare";
  };

  # ---- (b) connector token (data source) -------------------------------------
  data.cloudflare_zero_trust_tunnel_cloudflared_token.landing = {
    account_id = accountId;
    tunnel_id = tunnelId;
  };

  # ---- (c) HTTP ingress: apex + www -> loopback Caddy; final catch-all 404 ----
  resource.cloudflare_zero_trust_tunnel_cloudflared_config.landing = {
    account_id = accountId;
    tunnel_id = tunnelId;
    config.ingress = [
      {
        hostname = apex;
        service = originService;
      }
      {
        hostname = www;
        service = originService;
      }
      { service = "http_status:404"; }
    ];
  };

  # ---- (d) proxied CNAMEs -> <tunnel-id>.cfargotunnel.com --------------------
  # Apex relies on Cloudflare CNAME flattening (proxied). ttl=1 = auto.
  resource.cloudflare_dns_record.landing_apex = {
    zone_id = zoneId;
    name = apex;
    type = "CNAME";
    content = cnameTarget;
    proxied = true;
    ttl = 1;
  };
  resource.cloudflare_dns_record.landing_www = {
    zone_id = zoneId;
    name = www;
    type = "CNAME";
    content = cnameTarget;
    proxied = true;
    ttl = 1;
  };

  # ---- (e) Output — retrieve with `tofu output -raw tunnel_token` -------------
  output.tunnel_token = {
    value = "\${data.cloudflare_zero_trust_tunnel_cloudflared_token.landing.token}";
    sensitive = true;
  };

  # ---- RUNBOOK ----------------------------------------------------------------
  # 1. Provision the tunnel + DNS and read the connector token:
  #      CLOUDFLARE_API_TOKEN=<Account Cloudflare Tunnel:Edit + Zone DNS:Edit> \
  #        nix run .#cf-landing-apply
  #      tofu output -raw tunnel_token
  # 2. Store it as the dedicated agenix secret (content: TUNNEL_TOKEN=<token>):
  #      echo "TUNNEL_TOKEN=<token>" | agenix -e secrets/landing-tunnel-token.age
  #    add it to secrets/secrets.nix (recipients: the landing host's SSH key), and
  #    declare it on that host:
  #      age.secrets."landing-tunnel-token".file = "${secretsDir}/landing-tunnel-token.age";
  # 3. Enable the page on that host: services.landing-page.enable = true;
  #    then nixos-rebuild. Caddy serves locally immediately; the connector comes up
  #    once the secret is present (haveToken guard in modules/nixos/landing.nix).
}
