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

  # Resource keys of every registration this module declares — gateway servers
  # keyed by sanitised name, external ones prefixed `ext_`. Single-sourced so the
  # portal attachment below cannot drift from the registrations above.
  registrationIds =
    builtins.listToAttrs (
      map (n: {
        name = srvKey n;
        value = "gw-${n}";
      }) publicServers
    )
    // builtins.listToAttrs (
      map (e: {
        name = "ext_${srvKey e.name}";
        value = e.id or e.name;
      }) externalServers
    );
  registrationKeys = builtins.attrNames registrationIds;

  # Reusable account policy `mcp-allow-operator` — one allow rule on the
  # operator's identity. Referenced by literal id, the same way
  # infra/cloudflare/nixpi-tunnel.nix:363 does, because it is an existing
  # account object and declaring a second equivalent policy would just add a
  # duplicate to audit. Not a secret: an Access policy id is an internal
  # identifier, not a credential.
  operatorPolicyId = "b3bd8c38-e231-4203-ba6b-69fe16e498b3";

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
  # This is the ONLY per-server object. No DNS, no Access app, no OAuth.
  resource.cloudflare_zero_trust_access_ai_controls_mcp_server =
    builtins.listToAttrs (
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
    )
    # External Workers register the SAME way. They are not on the gateway, but
    # they sit behind the same Access service token, so the portal presents the
    # same headers and the origin verifies the same assertion. An external server
    # that still ran its own OAuth would be the odd one out: the portal would hold
    # a second credential, and a client could bypass the portal by driving that
    # OAuth directly (measured with Grok, 2026-09-12 — it was granted every scope).
    // builtins.listToAttrs (
      map (e: {
        name = "ext_${srvKey e.name}";
        value = {
          account_id = accountId;
          id = e.id or e.name;
          name = e.label or e.name;
          description = e.description or "External MCP Worker behind the shared Access service token.";
          hostname = "https://${e.host}${e.path or "/mcp"}";
          auth_type = "bearer";
          auth_credentials = tokenHeaders;
        };
      }) externalServers
    );

  # ---- External MCP Workers on their own hostname ----------------------------
  # Same service-token policy, one Access application per hostname. The Worker
  # behind it must ALSO verify the Access assertion itself (see character-mcp's
  # worker/access.ts): Access is the boundary, but a Worker that trusts the
  # network alone has no defence if the app is ever detached from the hostname.
  resource.cloudflare_zero_trust_access_application =
    builtins.listToAttrs (
      map (e: {
        name = "ext_${srvKey e.name}";
        value = {
          account_id = accountId;
          name = "MCP ${e.name} (service token)";
          type = "self_hosted";
          domain = e.host;
          destinations = [
            {
              type = "public";
              uri = e.host;
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
      }) externalServers
    )
    # ---- Portal VISIBILITY, one per registration -----------------------------
    # Attaching a server to the portal is still not enough. Measured 2026-09-12:
    # with all three attached, the portal listed only `character-mcp` — the one
    # that happened to have an `mcp`-type Access application. A registration with
    # no such app, or with one carrying no Allow policy, stays HIDDEN from every
    # client while reporting `status = "ready"`.
    #
    # So publishing a server takes three objects, not one:
    #   1. the registration            (..._mcp_server)
    #   2. attachment to the portal    (..._mcp_portal.servers)
    #   3. this app + an Allow policy  (type = "mcp", via_mcp_server_portal)
    # Note this gates the PORTAL hop by identity; the ORIGIN hop is gated
    # separately by the service token. Different hops, different credentials.
    // builtins.listToAttrs (
      map (key: {
        name = "portal_${key}";
        value = {
          account_id = accountId;
          name = registrationIds.${key};
          type = "mcp";
          # No `domain`: an mcp-type app is addressed through the portal, not a
          # hostname. The live object carries an empty domain for this reason.
          destinations = [
            {
              type = "via_mcp_server_portal";
              mcp_server_id = "\${cloudflare_zero_trust_access_ai_controls_mcp_server.${key}.id}";
            }
          ];
          # Google Workspace only. Leaving this empty accepts EVERY configured
          # IdP, including Cloudflare's own dashboard login — the loop
          # infra/cloudflare/nixpi-tunnel.nix:349 calls out. It is live on the
          # pre-existing app, so omitting it here does not merely "not set" it:
          # the plan reads `[...] -> null` and the apply WIDENS the gate.
          allowed_idps = [ "3227ee11-f5a4-40ae-a1a7-612e1f035c1c" ];
          session_duration = "24h";
          auto_redirect_to_identity = false;
          # `enable_binding_cookie` and `options_preflight_bypass` are NOT settable
          # on an mcp-type app — the provider rejects them ("can only be set if
          # type is one of self_hosted, ssh, vnc, rdp, mcp_portal"). The API still
          # mirrors them back as `false`, so the plan shows `false -> null` on the
          # adopted app. That is benign here, unlike `allowed_idps` above: both are
          # browser cookie/CORS behaviours, and an mcp-type app has no hostname.
          policies = [
            {
              id = operatorPolicyId;
              precedence = 1;
            }
          ];
        };
      }) registrationKeys
    )
    // {
      mcp_public = {
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
    };

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
    servers = map (key: {
      server_id = "\${cloudflare_zero_trust_access_ai_controls_mcp_server.${key}.id}";
      # "Use end-user OAuth credentials when connecting this server to the
      # portal." The API defaults this to TRUE, which is wrong for every server
      # here: they all authenticate with `auth_type = "bearer"` against a stored
      # Access service token, and there is no end-user OAuth credential to
      # delegate — no server in this stack runs an OAuth AS any more.
      on_behalf = false;
      # Published means published. A server attached but disabled-by-default is
      # the same invisible-to-clients state this resource exists to prevent.
      default_disabled = false;
    }) registrationKeys;
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
