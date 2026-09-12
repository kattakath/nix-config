# infra/cloudflare/mcp-public.nix — terranix module for the PUBLISHED MCP gateway.
#
# Pairs with `services.mcpGateway.public` in modules/shared/mcp.nix. That flag puts
# the opt-in subset of gateway servers on a SECOND mcp-proxy (127.0.0.1:8097) on
# macos; this module is everything Cloudflare-side that makes it reachable:
#
#   (a) a remotely-managed tunnel + connector for the MAC (distinct from nixpi's —
#       a connector is per-host, and cloudflared dials OUTBOUND, so the Mac still
#       accepts no inbound connection);
#   (b) ingress: <publicHost> -> http://127.0.0.1:8097, plus the mandatory 404
#       catch-all so nothing else on the Mac is reachable through this tunnel;
#   (c) the proxied CNAME for <publicHost>;
#   (d) ONE Access application over that hostname whose policy is a SERVICE TOKEN
#       (decision = non_identity) — non-interactive, because the caller is the MCP
#       portal, not a browser;
#   (e) the service token itself.
#
# The portal presents the token as request headers. Cloudflare's own provider
# schema documents exactly this shape for
# `cloudflare_zero_trust_access_ai_controls_mcp_server.auth_credentials`:
#   {"headers":{"cf-access-client-id":"…","cf-access-client-secret":"…"}}
# which is why publishing a server needs no per-server DNS and no per-server Access
# object — only a portal registration. See docs/mcp-public-exposure-design.md.
#
# WHY A SECOND GATEWAY AND NOT AN INGRESS ONTO :8096 — the load-bearing decision:
# Access protects a HOSTNAME, not a path. Pointing this tunnel at the main gateway
# would make a leaked service token reach every path on it: 7 Gmail accounts,
# production WordPress, Postgres, Telegram. With a separate process an unpublished
# server is not merely unrouted, it is ABSENT.
#
# Schemas verified against the pinned provider via `tofu providers schema -json`,
# not from docs.
{
  domainName,
  accountId,
  zoneId,
  # Single-label ONLY: the free Universal cert covers *.<domainName> at exactly one
  # level. A two-label name has no certificate (see calendly.ismail.<domain>).
  publicSubdomain ? "connector",
  # Gateway server names published through the portal. Mirrors
  # services.mcpGateway.public; empty renders the tunnel + Access objects but
  # registers no server, so nothing is actually reachable.
  publicServers ? [ ],
  ...
}:
let
  publicHost = "${publicSubdomain}.${domainName}";
  tunnelName = "mcp-public";
  tunnelId = "\${cloudflare_zero_trust_tunnel_cloudflared.mcp_public.id}";

  # Same key-sanitising rule the tunnel module uses: a Terraform resource name may
  # not start with a digit and may only hold letters/digits/underscore/dash.
  srvKey = name: builtins.replaceStrings [ "." "-" ] [ "_" "_" ] name;

  # The gateway serves Streamable HTTP at /servers/<name>/mcp — the same path
  # shape `endpointFor` builds for local clients, so the published URL and the
  # loopback URL can never drift.
  serverUrl = name: "https://${publicHost}/servers/${name}/mcp";

  # Service-token headers, referenced from the portal registration. Terraform
  # resolves these at apply time; the secret is never a literal in this file.
  tokenHeaders = builtins.toJSON {
    headers = {
      "cf-access-client-id" = "\${cloudflare_zero_trust_access_service_token.mcp_public.client_id}";
      "cf-access-client-secret" =
        "\${cloudflare_zero_trust_access_service_token.mcp_public.client_secret}";
    };
  };
in
{
  # ---- (a) The Mac's tunnel --------------------------------------------------
  resource.cloudflare_zero_trust_tunnel_cloudflared.mcp_public = {
    account_id = accountId;
    name = tunnelName;
    config_src = "cloudflare";
  };

  # ---- (b) Ingress -----------------------------------------------------------
  resource.cloudflare_zero_trust_tunnel_cloudflared_config.mcp_public = {
    account_id = accountId;
    tunnel_id = tunnelId;
    config = {
      ingress = [
        {
          hostname = publicHost;
          service = "http://127.0.0.1:8097";
        }
        # Mandatory catch-all. Without it the connector would happily proxy any
        # other hostname routed to this tunnel.
        { service = "http_status:404"; }
      ];
      # Not a private-network connector. Declared so an apply cannot silently
      # turn it on the way omitting it turned nixpi's off.
      warp_routing.enabled = false;
    };
  };

  # ---- (c) DNS ---------------------------------------------------------------
  resource.cloudflare_dns_record.mcp_public = {
    zone_id = zoneId;
    name = publicHost;
    type = "CNAME";
    content = "${tunnelId}.cfargotunnel.com";
    proxied = true;
    ttl = 1;
    comment = "published MCP gateway (services.mcpGateway.public) - Access service token only";
  };

  # ---- (e) The service token -------------------------------------------------
  # NOTE — this token DOES expire. Leaving `duration` unset does not avoid an
  # expiry: the provider default is 8760h, so the first apply (2026-09-12) created
  # one valid until 2027-09-12. It is the ONLY credential the portal holds, so when
  # it lapses EVERY published server goes dark at once, with no partial failure to
  # warn you first. Rotating is a `tofu apply` plus re-registering the headers.
  # Set `duration` explicitly here if a different window is wanted.
  resource.cloudflare_zero_trust_access_service_token.mcp_public = {
    account_id = accountId;
    name = "mcp-public-gateway";
  };

  # ---- (d) One Access application over the whole published gateway -----------
  # decision = "non_identity": the caller is a machine (the portal), so there is
  # no user to authenticate and no browser to redirect. A service-token policy is
  # the only thing that can satisfy it — a human hitting this hostname in a
  # browser is refused, which is the intent.
  resource.cloudflare_zero_trust_access_policy.mcp_public_service_token = {
    account_id = accountId;
    name = "mcp-public: service token only";
    decision = "non_identity";
    include = [
      {
        service_token.token_id = "\${cloudflare_zero_trust_access_service_token.mcp_public.id}";
      }
    ];
  };

  resource.cloudflare_zero_trust_access_application.mcp_public = {
    account_id = accountId;
    name = "MCP public gateway";
    type = "self_hosted";
    domain = publicHost;
    destinations = [
      {
        type = "public";
        uri = publicHost;
      }
    ];
    session_duration = "24h";
    app_launcher_visible = false;
    auto_redirect_to_identity = false;
    http_only_cookie_attribute = true;
    enable_binding_cookie = false;
    options_preflight_bypass = false;
    policies = [
      {
        id = "\${cloudflare_zero_trust_access_policy.mcp_public_service_token.id}";
        precedence = 1;
      }
    ];
  };

  # ---- Portal registrations, one per published server ------------------------
  # This is the ONLY per-server object. No DNS, no Access app, no OAuth.
  resource.cloudflare_zero_trust_access_ai_controls_mcp_server = builtins.listToAttrs (
    map (name: {
      name = srvKey name;
      value = {
        account_id = accountId;
        id = "gw-${name}";
        name = "gw-${name}";
        description = "Published from the macos MCP gateway (services.mcpGateway.public).";
        hostname = serverUrl name;
        # "bearer" + a headers object is how a static credential is presented.
        # Not "oauth": this origin has no OAuth of its own by design — Access is
        # the boundary, and the portal holds the token.
        auth_type = "bearer";
        auth_credentials = tokenHeaders;
      };
    }) publicServers
  );

  # The connector token, surfaced the same way nixpi's is: a SENSITIVE output the
  # apply prints once, for the operator to store in the login Keychain. Never
  # written to git or the store.
  output.mcp_public_connector_token = {
    value = "\${data.cloudflare_zero_trust_tunnel_cloudflared_token.mcp_public.token}";
    sensitive = true;
  };

  data.cloudflare_zero_trust_tunnel_cloudflared_token.mcp_public = {
    account_id = accountId;
    tunnel_id = tunnelId;
  };

  output.mcp_public_hostname = {
    value = publicHost;
    description = "Published MCP gateway hostname (Access service token required).";
  };
}
