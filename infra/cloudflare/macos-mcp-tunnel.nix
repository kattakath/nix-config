# infra/cloudflare/macos-mcp-tunnel.nix — terranix (Nix -> OpenTofu/Terraform JSON)
# module provisioning the Mac's REMOTELY-MANAGED Cloudflare Tunnel that exposes the
# kapture-only MCP proxy to Grok (and any MCP client) as an OAuth-SECURED connector.
#
# WHY A SECOND TUNNEL (separate from nixpi's): kapture drives THIS Mac's Chrome, so
# the MCP origin must be the Mac. The Mac has no inbound network and nixpi's connector
# can only reach nixpi-local services, so the Mac originates its OWN outbound tunnel.
# The connector runs as a login-Keychain-token launchd user agent (see the
# `services.mcpGateway.publicTunnel` option in modules/shared/mcp.nix).
#
# WHAT THIS PROVISIONS (all declarative Terraform state, no imperative curl):
#   (a) a remotely-managed tunnel "macos-mcp" (config_src = "cloudflare");
#   (b) its ingress: mcp.<domain> -> the local kapture-only mcp-proxy on
#       http://localhost:<publicPort>, plus the mandatory catch-all 404;
#   (c) a proxied CNAME  mcp.<domain> -> <tunnel-id>.cfargotunnel.com;
#   (d) a Cloudflare Access SELF-HOSTED application for mcp.<domain> with
#       **Managed OAuth** enabled (oauth_configuration.enabled = true) — this turns
#       Access into a standard OAuth 2.1 authorization server (RFC 8414 + RFC 9728
#       discovery, PKCE, dynamic client registration) in front of the origin. It is
#       the exact flow a probe confirmed grok.com performs (401 -> discovery -> DCR
#       -> /authorize -> token). The origin (mcp-proxy) needs NO auth code: Access
#       enforces the policy at the edge, then forwards authenticated requests down
#       the tunnel. See Cloudflare's "Managed OAuth" docs (GA 2026-03-20);
#   (e) an Access POLICY allowing ONLY the operator's identity (Google IdP, matched
#       by email) — so even with the URL, nobody else can connect;
#   (f) the connector token, surfaced as a SENSITIVE output for `cf-mcp-apply` to
#       print; the operator stores it in the login Keychain via
#       `set-secret MCP_TUNNEL_TOKEN <token>` (never in git or the store).
#
# Provider v5 schemas (cloudflare/terraform-provider-cloudflare, docs/resources):
#   - cloudflare_zero_trust_tunnel_cloudflared / _config / data _token: as in
#     nixpi-tunnel.nix (remotely-managed; config_src = "cloudflare").
#   - cloudflare_zero_trust_access_application (self_hosted): required { domain,
#     type = "self_hosted" } + account_id; policies is a LIST OF OBJECTS
#     ({ id, precedence }); oauth_configuration = { enabled,
#     dynamic_client_registration = { enabled } }.
#   - cloudflare_zero_trust_access_policy: required { account_id, name, decision };
#     include is a set of objects — email match is { email = { email = "<addr>" } }.
# accountId / zoneId / domainName / operatorEmail / publicPort are threaded from
# flake.nix's single sources of truth (via _module.args), so nothing drifts.
{
  domainName,
  accountId,
  zoneId,
  operatorEmail,
  publicPort,
  ...
}:
let
  tunnelName = "macos-mcp";
  mcpHostname = "mcp.${domainName}"; # mcp.kattakath.com — the OAuth-gated connector host
  tunnelId = "\${cloudflare_zero_trust_tunnel_cloudflared.macos_mcp.id}";
in
{
  # ---- Provider: API token from the CLOUDFLARE_API_TOKEN env var --------------
  provider.cloudflare = { };

  terraform.required_providers.cloudflare = {
    source = "cloudflare/cloudflare";
    version = ">= 5.0.0";
  };

  # ---- (a) The remotely-managed tunnel --------------------------------------
  resource.cloudflare_zero_trust_tunnel_cloudflared.macos_mcp = {
    account_id = accountId;
    name = tunnelName;
    config_src = "cloudflare";
  };

  # ---- (b) The tunnel ingress ------------------------------------------------
  # mcp.<domain> -> the kapture-only mcp-proxy on localhost:<publicPort>. That
  # proxy hosts ONLY the published servers (never the personal :8096 gateway).
  resource.cloudflare_zero_trust_tunnel_cloudflared_config.macos_mcp = {
    account_id = accountId;
    tunnel_id = tunnelId;
    config = {
      ingress = [
        {
          hostname = mcpHostname;
          service = "http://localhost:${toString publicPort}";
        }
        # Required catch-all: any unmatched request returns 404.
        { service = "http_status:404"; }
      ];
    };
  };

  # ---- (c) Proxied CNAME  mcp.<domain> -> <tunnel-id>.cfargotunnel.com --------
  # MUST be proxied (orange-cloud) so Cloudflare Access can enforce at the edge.
  resource.cloudflare_dns_record.macos_mcp = {
    zone_id = zoneId;
    name = mcpHostname;
    type = "CNAME";
    content = "${tunnelId}.cfargotunnel.com";
    proxied = true;
    ttl = 1;
  };

  # ---- (e) Access policy: allow ONLY the operator (Google IdP, by email) -----
  # A standalone policy referenced by the application below. include matches the
  # operator's Google-identity email; everything else is implicitly denied.
  resource.cloudflare_zero_trust_access_policy.mcp_operator = {
    account_id = accountId;
    name = "mcp-allow-operator";
    decision = "allow";
    include = [
      {
        email = {
          email = operatorEmail;
        };
      }
    ];
  };

  # ---- (d) Access self-hosted application + Managed OAuth --------------------
  # Managed OAuth makes Access the OAuth 2.1 authorization server for this app:
  # non-browser MCP clients get a 401 + WWW-Authenticate pointing at Access's
  # discovery endpoints, do the browser login (Google), and receive a Bearer
  # token Access validates at the edge. dynamic_client_registration is required
  # because Grok registers itself as a public client (POST /register).
  resource.cloudflare_zero_trust_access_application.macos_mcp = {
    account_id = accountId;
    name = "MCP (kapture) — OAuth connector";
    domain = mcpHostname;
    type = "self_hosted";
    session_duration = "24h";
    # allowed_idps is left unset so every configured IdP (incl. Google) is offered
    # at login; the policy above is what restricts access to the operator. To skip
    # the IdP chooser, set allowed_idps = [ "<google-idp-id>" ] and
    # auto_redirect_to_identity = true.
    oauth_configuration = {
      enabled = true;
      dynamic_client_registration = {
        enabled = true;
      };
    };
    policies = [
      {
        id = "\${cloudflare_zero_trust_access_policy.mcp_operator.id}";
        precedence = 1;
      }
    ];
  };

  # ---- (f) Connector token (data source, sensitive output) -------------------
  data.cloudflare_zero_trust_tunnel_cloudflared_token.macos_mcp = {
    account_id = accountId;
    tunnel_id = tunnelId;
  };

  # ---- Outputs ---------------------------------------------------------------
  output.macos_mcp_tunnel_id = {
    value = tunnelId;
  };
  output.macos_mcp_access_app_id = {
    value = "\${cloudflare_zero_trust_access_application.macos_mcp.id}";
  };
  # SECRET — printed by cf-mcp-apply for storage in the login Keychain via
  # `set-secret MCP_TUNNEL_TOKEN <token>`. NEVER written to git or the store.
  output.macos_mcp_connector_token = {
    value = "\${data.cloudflare_zero_trust_tunnel_cloudflared_token.macos_mcp.token}";
    sensitive = true;
  };
}
