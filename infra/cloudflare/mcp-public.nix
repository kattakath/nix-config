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
  # THE origin hostname: where published MCP servers actually are, as opposed to
  # `mcp.<domainName>`, the portal clients talk to. "upstream" is the Cloudflare
  # portal's own word for a server registered behind it, and it is mechanism-
  # neutral — this hostname terminates the cloudflared tunnel AND carries Worker
  # routes, so naming it after either one would describe half its job. (It was
  # `connector` until 2026-09-12, named after the cloudflared connector: the same
  # mistake as the old `gw-` prefix, naming the implementation over the role.)
  #
  # No client ever sees this name. Only the portal dials it, with a service token.
  #
  # Single-label ONLY: the free Universal cert covers *.<domainName> at exactly one
  # level. A two-label name has no certificate (see calendly.ismail.<domain>).
  publicSubdomain ? "upstream",
  # Gateway server names published through the portal. Mirrors
  # services.mcpGateway.public; empty renders the tunnel + Access objects but
  # registers no server, so nothing is actually reachable.
  publicServers ? [ ],
  # Remote MCP Workers published under the SAME hostname as the gateway, as a
  # Cloudflare Worker *route* on `<publicSubdomain>/servers/<name>/*` rather than
  # a hostname of their own. They are not on the :8097 proxy — they are
  # independent origins with their own uptime — but a client cannot tell, and
  # should not care, which side of the edge answers.
  #
  # Each entry: { name; description ? ""; }
  # No `host` and no `id`: there is exactly ONE public hostname, and a server's
  # NAME is its id, its Access application name and its path segment — see THE
  # NAMING RULE below.
  #
  # The Worker route itself lives in that Worker's own wrangler config; this
  # module only registers and gates it. Access covers the whole hostname and
  # Cloudflare checks Access BEFORE a Worker runs, so a route needs no Access
  # object of its own.
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

  # ============================ THE NAMING RULE =============================
  # ONE rule, applied to every object this module owns:
  #
  #     A THING IS NAMED AFTER WHAT IT POINTS AT.
  #
  #   - an Access application over a hostname is named THAT HOSTNAME
  #     (`connector.kattakath.com`, `mcp.kattakath.com`, and in the sibling
  #     module `nixpi.kattakath.com`)
  #   - an Access application over a published server is named THAT SERVER
  #     (`memory`, `character`)
  #   - a registration's id, its portal app's name, and its `/servers/<x>/mcp`
  #     path segment are all the SAME string — the server's name.
  #
  # So in the dashboard "Application name" and "Destinations" read identically
  # for every row, and the "Type" column is what says which layer it is. Nothing
  # is a prose name that has to be invented or kept in sync.
  #
  # There is deliberately no `gw-` / `ext-` prefix. It used to encode WHICH
  # PROCESS served a server — the macos mcp-proxy or a Worker — and that stopped
  # being either visible or relevant when everything moved behind the one
  # hostname. A client cannot tell the difference and must not depend on it.
  # ==========================================================================

  # Every published server, gateway and external alike, as ONE list. Both kinds
  # carry the same fields, so every object below is generated by the same `map`
  # over the same shape — the structural fix. Previously the gateway's origin app
  # was a hand-written literal while the external ones were generated, and
  # nothing forced the two to agree; they drifted immediately.
  published =
    map (n: {
      key = "srv_${srvKey n}";
      id = n;
      description = "Published from the macos MCP gateway (services.mcpGateway.public).";
    }) publicServers
    ++ map (e: {
      key = "srv_${srvKey e.name}";
      id = e.name;
      description =
        e.description or "Cloudflare Worker route under the gateway hostname.";
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
        name = p.id;
        hostname = serverUrl p.id;
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
    {
      # THE origin. Singular, and that is the design: one public hostname for
      # every published MCP server, whether it is served by the macos mcp-proxy
      # down the tunnel or by a Worker route at the edge. A second hostname would
      # mean a second Access application, a second aud and a second DNS record to
      # keep in sync — which is exactly what this replaced.
      origin_gateway = originApp publicHost;

      # The portal's OWN Access application — the object that decides WHICH
      # CLIENTS may register against the portal, via
      # `oauth_configuration.dynamic_client_registration.allowed_uris`. It was
      # left undeclared while it was only being read; declaring it puts the
      # client allowlist in code rather than in whatever the dashboard happens to
      # hold, so an apply REVERTS an unintended widening instead of keeping it.
      #
      # Distinct from `..._mcp_portal` further down: that resource attaches
      # SERVERS to the portal, this one gates CLIENTS reaching it. One portal,
      # two objects, different directions.
      portal = {
      account_id = accountId;
      name = portalHost; # the naming rule
      type = "mcp_portal";
      domain = portalHost;
      session_duration = "24h";
      allowed_idps = [ idpGoogleWorkspace ];
      auto_redirect_to_identity = false;
      http_only_cookie_attribute = true;
      enable_binding_cookie = false;
      options_preflight_bypass = false;
      oauth_configuration = {
        enabled = true;
        dynamic_client_registration = {
          enabled = true;
          # THE client allowlist for the whole fleet. With no OAuth server left
          # on any origin, a client that cannot register here cannot reach any
          # published MCP server at all — and it is ONE list, not one per server.
          #
          # Trailing `/*` is required: cloud clients mint a per-connector
          # callback path, so an exact URI makes registration 400.
          allowed_uris = [
            "https://claude.ai/api/mcp/*"
            "https://claude.com/api/mcp/*"
            # Grok's connector callback. grok.com/connectors takes a URL and
            # nothing else — no header field — so the service-token origin is
            # unreachable to it and the portal is its only door.
            "https://grok.com/*"
          ];
          allow_any_on_localhost = true;
          allow_any_on_loopback = true;
        };
      };
      policies = [
        {
          id = operatorPolicyId;
          precedence = 1;
        }
      ];
    };
    }
    // builtins.listToAttrs (
      map (p: {
        name = "portal_${srvKey p.id}";
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
