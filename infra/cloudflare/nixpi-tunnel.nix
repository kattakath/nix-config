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
# ([ { domain; zoneId ? null; root; www ? true; ownTunnel ? false } ]) and threaded
# here via _module.args, so adding a site is ONE list entry — the ingress rule is
# generated for every site EXCEPT those with `ownTunnel = true`; the apex CNAME and
# (when www) the www CNAME + redirect are generated ONLY for sites that set
# `zoneId` (a site whose zone lives in a different Cloudflare account can omit it —
# e.g. to keep that account's zone id out of this public repo — and its DNS +
# redirect are then managed out-of-band, directly in that account). A site whose
# zone lives in a DIFFERENT Cloudflare account from this tunnel MUST also set
# `ownTunnel = true`: a `cfargotunnel.com` CNAME only resolves within the tunnel's
# own account, so it needs its own separate tunnel + connector (hand-written in
# hosts/nixpi.nix) rather than an ingress rule here. hosts/nixpi.nix generates the
# matching Caddy vhost from the same list for EVERY site, needing only domain/root.
# accountId / zoneId (the SSH host's zone) / domainName also come from flake.nix's
# single sources (via _module.args in cfTunnelConfig).
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
  # Web ingress rule: <domain> -> the local Caddy on :80. Excludes sites that opt
  # into `ownTunnel = true` — a `cfargotunnel.com` CNAME only resolves within the
  # SAME Cloudflare account as the tunnel (confirmed via Cloudflare's own docs), so
  # a site whose zone lives in a DIFFERENT account (e.g. dontsell.ai, in the
  # separate DontSell account) cannot be routed by this (Personal-account) tunnel
  # at all — it gets its own hand-written connector unit in hosts/nixpi.nix instead
  # (Caddy still serves it locally; only the tunnel ingress is excluded here).
  siteIngress = map (s: {
    hostname = s.domain;
    service = "http://localhost:80";
  }) (builtins.filter (s: !(s.ownTunnel or false)) hostedSites);

  # Proxied apex CNAME -> tunnel (makes the ingress rule reachable) + proxied
  # www CNAME -> apex (so the edge redirect below fires). ttl = 1 == automatic
  # (required for proxied records). The www record is emitted only when the site
  # opts into it (`www ? true`) — a SUBDOMAIN site sets `www = false`, since
  # www.<subdomain> is nonsense.
  siteDnsRecords = builtins.listToAttrs (
    builtins.concatMap (
      s:
      if !(s ? zoneId) then
        [ ]
      else
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
      if !(s ? zoneId) || !(s.www or true) then
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
  # ---- (e) Zone settings: the TLS floor, declared rather than clicked ---------
  # These were applied by hand during the 2026-09-12 audit and existed nowhere in
  # Nix, so nothing reproduced them and they would drift silently. Declared here
  # for every zone THIS module manages — the SSH host's zone plus each hosted
  # site's zone. Zones outside this module (aloshy.ai, etuper.com, izzykatt.ca,
  # silvercreek.ai) are deliberately NOT covered: they have no terranix module in
  # this repo, and dontsell.ai has its own in the private flake.
  #
  # `value` is schema-typed `dynamic`, so a string for the scalar settings and an
  # attrset for security_header — matching exactly what the API returns, so
  # `tofu plan` reads clean rather than fighting the provider.
  # Zone -> a readable Terraform resource key, DEDUPED BY ZONE ID. Two things
  # force this shape: a Terraform resource name may not start with a digit (so a
  # raw zone id is illegal), and ismail.kattakath.com shares the apex's zone, so
  # keying by domain alone would declare the same setting twice for one zone and
  # the two resources would fight.
  zoneKeyPairs = [
    {
      key = siteKey domainName;
      id = zoneId;
    }
  ]
  ++ (map (s: {
    key = siteKey s.domain;
    id = s.zoneId;
  }) (builtins.filter (s: (s.zoneId or null) != null) hostedSites));

  dedupedZones = builtins.foldl' (
    acc: pair: if builtins.any (q: q.id == pair.id) acc then acc else acc ++ [ pair ]
  ) [ ] zoneKeyPairs;

  zoneSettings = {
    # Origin certificates are validated. Safe for every hostname here: the origin
    # is either the tunnel (Cloudflare-issued cert) or a Cloudflare-internal
    # service, never a bare self-signed host.
    ssl = "strict";
    # TLS 1.0/1.1 were accepted until 2026-09-12. Below the modern baseline and
    # every PCI profile since 3.2.1.
    min_tls_version = "1.2";
    # Plaintext HTTP served a real 200 before this.
    always_use_https = "on";
  };

  # HSTS: include_subdomains stays FALSE on purpose. Any subdomain without its own
  # working TLS would be hard-broken by it, and the wildcard cert does not cover
  # two-label names like <x>.ismail.<domain>. Revisit only after auditing every
  # subdomain's certificate coverage.
  hstsValue = {
    strict_transport_security = {
      enabled = true;
      max_age = 15768000;
      include_subdomains = false;
      preload = false;
      nosniff = true;
    };
  };

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

      # WARP routing is ON in the live account. It MUST be declared here: the
      # provider sends the whole `config` block, so omitting it would silently
      # flip the live tunnel's warp-routing off on the next apply. Private
      # network reachability is gated by the Gateway L4 "Default deny for
      # private traffic" rule, not by this switch.
      warp_routing.enabled = true;
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

  # ---- (e) Zone settings + the Access application, as resources --------------
  resource.cloudflare_zone_setting = builtins.listToAttrs (
    builtins.concatMap (
      zp:
      (builtins.attrValues (
        builtins.mapAttrs (setting: val: {
          name = "${zp.key}_${setting}";
          value = {
            zone_id = zp.id;
            setting_id = setting;
            value = val;
          };
        }) zoneSettings
      ))
      ++ [
        {
          name = "${zp.key}_security_header";
          value = {
            zone_id = zp.id;
            setting_id = "security_header";
            value = hstsValue;
          };
        }
      ]
    ) dedupedZones
  );

  # The Access application fronting the SSH host. This was hand-created and
  # ALREADY VANISHED ONCE (2026-08-20) — when it does, `cloudflared access ssh`
  # fails with "failed to find token" and BOTH deploy paths die with it, since the
  # only route to this host is the tunnel. Declaring it means a rebuild restores
  # the gate instead of an operator rediscovering it.
  #
  # Enforcement is at the EDGE only: cloudflared proxies raw TCP to localhost:22,
  # so the origin never sees a JWT. That is why modules/nixos/core.nix binds sshd
  # to loopback — the two halves are one control and neither works alone.
  #
  # The policy is NOT declared here. `mcp-allow-operator` is a REUSABLE policy
  # shared with the MCP portal and character-mcp; owning it from this module would
  # let a change here silently retarget those. Referenced by id instead.
  resource.cloudflare_zero_trust_access_application.nixpi_ssh = {
    account_id = accountId;
    # An Access application is named after what it points at — the same rule
    # infra/cloudflare/mcp-public.nix states in full. "nixpi SSH" was prose that
    # duplicated the Type column and had to be kept in sync by hand.
    name = publicHostname;
    type = "self_hosted";
    domain = publicHostname;
    # `self_hosted_domains` is DEPRECATED and mutually exclusive with
    # `destinations` — the provider errors with "Attribute self_hosted_domains
    # cannot be specified when destinations is specified". The API returns both
    # (it mirrors one into the other), so read the live object and declare only
    # `destinations`.
    destinations = [
      {
        type = "public";
        uri = publicHostname;
      }
    ];
    # Google Workspace only. Leaving this empty accepts EVERY configured IdP,
    # including Cloudflare's own dashboard login — a loop where the account that
    # administers Access is also a login to it.
    allowed_idps = [ "3227ee11-f5a4-40ae-a1a7-612e1f035c1c" ];
    session_duration = "1h";
    app_launcher_visible = false;
    auto_redirect_to_identity = false;
    http_only_cookie_attribute = true;
    # Both are `false` live. Declared explicitly rather than omitted: leaving them
    # out makes the provider plan `false -> null`, i.e. hand them back to whatever
    # the API defaults to. Declaring reality keeps the plan genuinely zero-diff.
    enable_binding_cookie = false;
    options_preflight_bypass = false;
    policies = [
      {
        id = "b3bd8c38-e231-4203-ba6b-69fe16e498b3"; # mcp-allow-operator (reusable)
        precedence = 1;
      }
    ];
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
