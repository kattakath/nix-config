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
  # Remote MCP Workers that live on their OWN hostname but are gated by the SAME
  # Access service token as the gateway. One credential for the whole published
  # MCP surface rather than one per origin.
  #
  # Each entry: { name; host; id ? name; label ? name; path ? "/mcp";
  #               description ? ""; }
  # `id`/`label` exist because a server registered in the portal BEFORE this
  # module owned it keeps its original identifiers (character-mcp), and changing
  # them would force a replace that every connected client would have to redo.
  externalServers ? [ ],
  ...
}:
let
  publicHost = "${publicSubdomain}.${domainName}";
  tunnelName = "mcp-public";

  # The MCP server portal these registrations attach to. Fixed identifiers rather
  # than module arguments, the same way `tunnelName` is: this module describes ONE
  # account's stack, and a terranix module argument would have to be threaded
  # through `_module.args` in flake.nix anyway (a default in the function head is
  # NOT honoured for a module argument — the module system queries `_module.args`
  # and errors before the default is ever consulted).
  #
  # The portal ALREADY EXISTS (created 2026-09-07). `tofu import` it; never let an
  # apply create it. Its OAuth/DCR allowlist — which clients may register — lives
  # on a DIFFERENT object, the `mcp_portal`-type Access application, and is
  # deliberately not declared here so an apply cannot widen it.
  portalId = "mcp-portal";
  portalName = "MCP Portal";
  portalHost = "mcp.${domainName}";
  tunnelId = "\${cloudflare_zero_trust_tunnel_cloudflared.mcp_public.id}";

  # Same key-sanitising rule the tunnel module uses: a Terraform resource name may
  # not start with a digit and may only hold letters/digits/underscore/dash.
  srvKey = name: builtins.replaceStrings [ "." "-" ] [ "_" "_" ] name;

  # The gateway serves Streamable HTTP at /servers/<name>/mcp — the same path
  # shape `endpointFor` builds for local clients, so the published URL and the
  # loopback URL can never drift.
  serverUrl = name: "https://${publicHost}/servers/${name}/mcp";

  # ============================ THE NAMING RULES ============================
  # Three rules, applied to EVERY object this module owns. They exist because the
  # first version of this file grew object by object and ended up with four
  # different shapes for two kinds of thing (2026-09-12).
  #
  #   1. A REGISTRATION ID says where the server runs: `gw-<name>` on the macos
  #      gateway, `ext-<name>` on its own origin. One grandfathered exception,
  #      `character-mcp`, which predates this module — `auth_type` and `id` are
  #      both ForceNew, so renaming it would replace the registration, drop the
  #      portal attachment, and make every client reconnect. nix-personal passes
  #      that `id` explicitly, so the exception is visible at its call site.
  #   2. A RESOURCE KEY mirrors the id with `-` -> `_`: `gw_memory`, `ext_character`.
  #      An Access application derived from one is prefixed `portal_` or `origin_`
  #      by layer, never by ad-hoc name.
  #   3. An ACCESS APPLICATION IS NAMED AFTER ITS DESTINATION — the hostname for
  #      an origin app, the server id for a portal app. So in the dashboard the
  #      "Application name" and "Destinations" columns read identically for every
  #      row this module owns, and no prose name has to be invented or kept in
  #      sync. The Type column already says which layer it is; the name repeating
  #      that was the noise.
  # ==========================================================================

  # Every published server, gateway and external alike, as ONE list. Both kinds
  # carry the same fields, so every object below is generated by the same `map`
  # over the same shape — the structural fix. Previously the gateway's origin app
  # was a hand-written literal while the external ones were generated, and
  # nothing forced the two to agree; they drifted immediately.
  published =
    map (n: {
      key = "gw_${srvKey n}";
      id = "gw-${n}";
      label = "gw-${n}";
      description = "Published from the macos MCP gateway (services.mcpGateway.public).";
      url = serverUrl n;
    }) publicServers
    ++ map (e: {
      key = "ext_${srvKey e.name}";
      id = e.id or "ext-${e.name}";
      label = e.label or e.name;
      description = e.description or "External MCP Worker behind the shared Access service token.";
      url = "https://${e.host}${e.path or "/mcp"}";
    }) externalServers;

  # Every hostname this module puts an Access application in front of. The
  # gateway is just another origin — treating it as a special case is what let
  # the two diverge.
  origins = [
    {
      key = "origin_gateway";
      host = publicHost;
    }
  ]
  ++ map (e: {
    key = "origin_${srvKey e.name}";
    inherit (e) host;
  }) externalServers;

  # Google Workspace. Pinned on EVERY application, including the service-token
  # origins whose only policy is `non_identity`. Empty means "accept every
  # configured IdP", including Cloudflare's own dashboard login — harmless while
  # no identity policy exists, and a silent hole the moment one is added. Pinning
  # it everywhere costs nothing and removes the "which apps did we pin?" question.
  idpGoogleWorkspace = "3227ee11-f5a4-40ae-a1a7-612e1f035c1c";

  # Reusable account policy `mcp-allow-operator` — one allow rule on the
  # operator's identity. Referenced by literal id, the same way
  # infra/cloudflare/nixpi-tunnel.nix:363 does, because it is an existing account
  # object and a second equivalent policy would just add a duplicate to audit.
  # Not a secret: an Access policy id is an identifier, not a credential.
  operatorPolicyId = "b3bd8c38-e231-4203-ba6b-69fe16e498b3";

  # Declared on every application. Anything genuinely shared lives here exactly
  # once, so two apps cannot drift apart again.
  accessAppCommon = {
    account_id = accountId;
    session_duration = "24h";
    auto_redirect_to_identity = false;
    allowed_idps = [ idpGoogleWorkspace ];
  };

  # ORIGIN app — gates a hostname. Service token only: the caller is the portal,
  # not a browser, so there is no identity to authenticate.
  originApp =
    host:
    accessAppCommon
    // {
      name = host; # rule 3
      type = "self_hosted";
      domain = host;
      destinations = [
        {
          type = "public";
          uri = host;
        }
      ];
      app_launcher_visible = false;
      http_only_cookie_attribute = true;
      # Both are `false` live. Declared rather than omitted: an omitted optional
      # plans as `false -> null` and hands the value to an API default.
      enable_binding_cookie = false;
      options_preflight_bypass = false;
      policies = [
        {
          id = "\${cloudflare_zero_trust_access_policy.mcp_public_service_token.id}";
          precedence = 1;
        }
      ];
    };

  # PORTAL app — gates ONE server as reached THROUGH the portal, by operator
  # identity. `enable_binding_cookie` and `options_preflight_bypass` are absent
  # on purpose: the provider rejects them on an mcp-type app, which has no
  # hostname and therefore no browser cookie or CORS behaviour.
  portalApp =
    p:
    accessAppCommon
    // {
      name = p.id; # rule 3
      type = "mcp";
      destinations = [
        {
          type = "via_mcp_server_portal";
          mcp_server_id = "\${cloudflare_zero_trust_access_ai_controls_mcp_server.${p.key}.id}";
        }
      ];
      policies = [
        {
          id = operatorPolicyId;
          precedence = 1;
        }
      ];
    };

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

  # ---- Portal registrations, one per published server ------------------------
  # Generated from `published`, so a gateway server and an external Worker differ
  # only in the fields that genuinely differ (id, url, description) — never in
  # shape. "bearer" + a headers object is how a static credential is presented;
  # not "oauth", because no origin in this stack runs an OAuth server any more.
  resource.cloudflare_zero_trust_access_ai_controls_mcp_server = builtins.listToAttrs (
    map (p: {
      name = p.key;
      value = {
        account_id = accountId;
        inherit (p) id description;
        name = p.label;
        hostname = p.url;
        auth_type = "bearer";
        auth_credentials = tokenHeaders;
      };
    }) published
  );

  # ---- Access applications: two layers, ONE shape each -----------------------
  # An ORIGIN app per hostname (service token) and a PORTAL app per published
  # server (operator identity). Both come from `originApp` / `portalApp`, which
  # share `accessAppCommon`, so a change to anything common cannot land on one
  # kind and miss the other. Previously the gateway's origin app was a
  # hand-written literal while the external ones were generated — nothing forced
  # them to agree, and they drifted immediately.
  #
  # The two layers are NOT redundant, which is the question this list keeps
  # raising: a server appears twice in the dashboard because two different hops
  # gate it. `origin_*` is the portal -> origin hop, gated by a service token.
  # `portal_*` is the client -> portal hop, gated by the operator's identity.
  # Deleting the origin app darks the server entirely (its Worker requires the
  # Access assertion); deleting the portal app makes it invisible to clients.
  resource.cloudflare_zero_trust_access_application =
    builtins.listToAttrs (
      map (o: {
        name = o.key;
        value = originApp o.host;
      }) origins
    )
    // builtins.listToAttrs (
      map (p: {
        name = "portal_${p.key}";
        value = portalApp p;
      }) published
    );

  # ---- The portal, and the attachment that actually publishes a server -------
  # REGISTERING a server and PUBLISHING it are two different things. A
  # `..._mcp_server` resource on its own is only an entry in the account: it can
  # reach `status = "ready"` with its tools discovered and still be invisible to
  # every client, because the portal's own `servers` list is what a client sees.
  # Measured 2026-09-12: three registrations `ready`, portal `servers: []`, and
  # the portal served NOTHING. Testing at the origin does not catch this — the
  # origin was answering 200 the whole time.
  resource.cloudflare_zero_trust_access_ai_controls_mcp_portal.mcp_portal = {
    account_id = accountId;
    id = portalId;
    name = portalName;
    hostname = portalHost;

    # Declared, not left to the provider. Both are optional+computed, so omitting
    # them plans as `true -> (known after apply)` and the apply is free to reset
    # the operator's choice. These are the values that were live on 2026-09-12.
    allow_code_mode = true;
    code_mode = "opt_in";

    # Every registration this module owns, gateway and external alike. Referenced
    # through the resources rather than by literal id so an apply cannot attach a
    # server that has not been created yet.
    servers = map (p: {
      server_id = "\${cloudflare_zero_trust_access_ai_controls_mcp_server.${p.key}.id}";
      # "Use end-user OAuth credentials when connecting this server to the
      # portal." The API defaults this to TRUE, which is wrong for every server
      # here: they all authenticate with `auth_type = "bearer"` against a stored
      # Access service token, and no origin in this stack runs an OAuth AS.
      on_behalf = false;
      # Published means published. A server attached but disabled-by-default is
      # the same invisible-to-clients state this resource exists to prevent.
      default_disabled = false;
    }) published;
  };

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
