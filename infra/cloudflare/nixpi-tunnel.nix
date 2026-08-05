# infra/cloudflare/nixpi-tunnel.nix — terranix (Nix -> OpenTofu/Terraform JSON)
# module provisioning nixpi's REMOTELY-MANAGED Cloudflare Tunnel itself.
#
# It provisions declaratively (no imperative `curl`):
#   (a) a remotely-managed tunnel named "nixpi"
#       (cloudflare_zero_trust_tunnel_cloudflared, config_src = "cloudflare");
#   (b) the tunnel ingress: the SSH route (nixpi.<domain> -> local sshd), ONE
#       web route per hosted site (<domain> -> local Caddy on :80), and the
#       mandatory catch-all 404;
#   (c) per hosted site: a proxied apex CNAME -> <tunnel-id>.cfargotunnel.com
#       (so the ingress rule is reachable), and — when the site opts into www
#       (`www ? true`, false for a subdomain) — a proxied www CNAME -> apex plus a
#       www->apex 301 edge Single Redirect (cloudflare_ruleset,
#       http_request_dynamic_redirect); PLUS the SSH host's own proxied CNAME;
#   (d) the connector token, surfaced as a SENSITIVE `output` via the
#       cloudflare_zero_trust_tunnel_cloudflared_token data source, so
#       `nix run .#cf-tunnel-apply` prints it for the operator to store in the
#       vault (`nix run .#nixpi-vault-token` -> secrets/cloudflared-token.age) and
#       plant on the FIRMWARE partition — NEVER written to git or the store.
#
# The SITES it serves are single-sourced as `hostedSites` in flake.nix
# ([ { domain; zoneId; root; www ? true } ]) and threaded here via _module.args, so
# adding a site is ONE list entry — the ingress rule, apex CNAME, and (when www) the
# www CNAME + redirect are all generated below. hosts/nixpi.nix generates the
# matching Caddy vhost from the same list. accountId / zoneId (the SSH host's zone) / domainName also come from
# flake.nix's single sources (via _module.args in cfTunnelConfig).
#
# The runtime connector unit (the `nix-cloudflared-connector` flake) is UNTOUCHED: it
# reads the token at /run/cloudflared-token, which services.firmwareProvisioning
# copies off the FAT FIRMWARE partition at boot (host-key-independent, so a fresh
# SD flash does not lock out the tunnel — see hosts/nixpi.nix).
#
# Schemas verified against the current Cloudflare Terraform provider v5 docs
# (cloudflare/terraform-provider-cloudflare, docs/resources + docs/data-sources).
{
  domainName,
  accountId,
  zoneId,
  hostedSites,
  ...
}:
let
  # nixpi is the only tunnelled host: macos is a client only, nixvm has no
  # public ingress.
  tunnelName = "nixpi";
  publicHostname = "${tunnelName}.${domainName}"; # nixpi.kattakath.com — the SSH ingress host

  tunnelId = "\${cloudflare_zero_trust_tunnel_cloudflared.nixpi.id}";

  # A stable Terraform resource key from a domain: kattakath.com -> kattakath_com.
  siteKey = domain: builtins.replaceStrings [ "." "-" ] [ "_" "_" ] domain;

  # ---- Per-site generation (one entry in flake.nix's hostedSites -> all of this) ----
  # Web ingress rule: <domain> -> the local Caddy on :80.
  siteIngress = map (s: {
    hostname = s.domain;
    service = "http://localhost:80";
  }) hostedSites;

  # Proxied apex CNAME -> tunnel (makes the ingress rule reachable) + proxied
  # www CNAME -> apex (so the edge redirect below fires). ttl = 1 == automatic
  # (required for proxied records). The www record is emitted only when the site
  # opts into it (`www ? true`) — a SUBDOMAIN site sets `www = false`, since
  # www.<subdomain> is nonsense.
  siteDnsRecords = builtins.listToAttrs (
    builtins.concatMap (
      s:
      let
        k = siteKey s.domain;
      in
      [
        {
          name = "${k}_apex";
          value = {
            zone_id = s.zoneId;
            name = s.domain;
            type = "CNAME";
            content = "${tunnelId}.cfargotunnel.com";
            proxied = true;
            ttl = 1;
          };
        }
      ]
      ++ (
        if (s.www or true) then
          [
            {
              name = "${k}_www";
              value = {
                zone_id = s.zoneId;
                name = "www.${s.domain}";
                type = "CNAME";
                content = s.domain;
                proxied = true;
                ttl = 1;
              };
            }
          ]
        else
          [ ]
      )
    ) hostedSites
  );

  # Single Redirect (http_request_dynamic_redirect phase) per site: any request whose
  # Host is www.<domain> gets a permanent 301 to the apex, query string preserved.
  # Executes at Cloudflare's edge BEFORE any origin/tunnel fetch — www is never served
  # directly, so there is deliberately no www ingress rule on the tunnel.
  siteRulesets = builtins.listToAttrs (
    builtins.concatMap (
      s:
      let
        k = siteKey s.domain;
      in
      if !(s.www or true) then
        [ ]
      else
        [
          {
            name = "redirect_www_${k}";
            value = {
              zone_id = s.zoneId;
              name = "redirect-www-to-apex-${k}";
              kind = "zone";
              phase = "http_request_dynamic_redirect";
              rules = [
                {
                  ref = "redirect_www_to_apex_${k}";
                  description = "301 www.${s.domain} -> ${s.domain} (canonical host)";
                  expression = ''(http.host eq "www.${s.domain}")'';
                  action = "redirect";
                  enabled = true;
                  action_parameters = {
                    from_value = {
                      status_code = 301;
                      preserve_query_string = true;
                      target_url = {
                        expression = ''concat("https://${s.domain}", http.request.uri.path)'';
                      };
                    };
                  };
                }
              ];
            };
          }
        ]
    ) hostedSites
  );
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
  # SSH to the public hostname, one web route per hosted site (-> local Caddy),
  # and the mandatory trailing catch-all 404.
  resource.cloudflare_zero_trust_tunnel_cloudflared_config.nixpi = {
    account_id = accountId;
    tunnel_id = tunnelId;
    config = {
      ingress = [
        # SSH ingress — nixpi.<domain> -> local sshd. Reached client-side with
        # `cloudflared access ssh --hostname nixpi.<domain>` (keys-only, the operator's
        # static key in modules/nixos/core.nix). No Access/identity layer.
        {
          hostname = publicHostname;
          service = "ssh://localhost:22";
        }
      ]
      ++ siteIngress
      ++ [
        # Required catch-all: any unmatched request returns 404.
        { service = "http_status:404"; }
      ];
    };
  };

  # ---- (c) DNS: SSH host CNAME + per-site apex/www CNAMEs ---------------------
  # The SSH host's proxied CNAME lives in the primary zone (`zoneId`); the per-site
  # apex/www records live in each site's own zone (s.zoneId), all -> the same tunnel.
  resource.cloudflare_dns_record = {
    nixpi = {
      zone_id = zoneId;
      name = publicHostname;
      type = "CNAME";
      content = "${tunnelId}.cfargotunnel.com";
      proxied = true;
      ttl = 1;
    };
  }
  // siteDnsRecords;

  # ---- (c2) Single Redirects: www.<domain> -> <domain> (301) per site --------
  resource.cloudflare_ruleset = siteRulesets;

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
