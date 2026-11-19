# ---- Workspace MCP portals: Google's Workspace MCP servers behind Cloudflare Access ----
#
# ONE Cloudflare MCP server portal at https://mcp.kattakath.com/mcp holding one MCP server
# per Google-hosted Workspace MCP server (workspace-mcp-apps.nix), added in claude.ai as
# ONE custom connector, "Kattakath Workspace": one connect flow, every app inside.
#
# WHY CLOUDFLARE, NOT THE POMERIUM GATEWAY IT REPLACED (2026-11-14)
# ================================================================
# The job is: sign the user in, run a per-user OAuth flow to Google with OUR OAuth
# client (Google's MCP servers do no Dynamic Client Registration), STORE and refresh
# each user's Google token, and allow only a tool allowlist. Pomerium on Cloud Run did
# that, but needed a token store of its own (Neon, then a planned e2-micro Postgres with
# backups and monitoring). Cloudflare MCP portals (GA 2026-09-24) do every part as a
# managed service: "Static OAuth client credentials" (2026-07-31 changelog) for the
# non-DCR client, per-user grants held by Cloudflare, Access + the existing Google IdP
# for sign-in, and per-tool enablement. Measured the same day with a one-app spike:
# claude.ai web AND a phone cloud session both reached Google People through a portal.
# Motto: off-the-shelf over hand-rolled, and the account already had Cloudflare One.
#
# THREE NON-OBVIOUS SETTINGS, each measured in that spike
# ======================================================
# - `access_type=offline&prompt=consent` ride INSIDE `authorization_endpoint`: the manual
#   OAuth form has no field for extra parameters, and without `access_type=offline`
#   Google issues no refresh token (every user would re-consent hourly). Cloudflare
#   passes the query string through (seen in Google's authorize URL).
# - `is_shared_oauth_callback_enabled = true`: manual OAuth always uses Cloudflare's ONE
#   callback, https://oauth-callbacks.cloudflareaccess.com/cdn-cgi/access/outbound-oauth-callback,
#   which must be a redirect URI on the Google client (added in the Cloud console).
# - The API creates NEITHER the portal's Access application NOR its DNS record (the
#   dashboard does both). The apps are declared below; the proxied CNAMEs are in
#   kattakath-dns.nix (cf-zones), from the same apps list.
#
# NOT DECLARABLE: each server's one-time ADMIN authorization ("Authenticate server" in
# Zero Trust → Access controls → MCP Portals → MCP servers). Until then a server is
# `waiting` with no tools. Do it once per server after the first apply.
#
# The client secret and the allowlisted emails are variables fed from the login
# Keychain by `secret exec` (modules/parts/terranix.nix), never literals here.
# `client_secret` is write-only at the API, so state holds it (encrypted, like every
# stack's state) and an omitted value on update keeps the stored one.
{
  lib,
  accountId,
  domainName,
  accessIdpId,
  # The GCP project number, for a self-hosted app's Cloud Run URL.
  projectNumber,
  ...
}:
let
  inherit (import ./workspace-mcp-apps.nix) apps portalLabel runAppHost;
  portalHost = "${portalLabel}.${domainName}";
  upstreamOf = a: a.upstream or (runAppHost projectNumber a.selfHosted);

  # Our OAuth client, as Cloudflare's `auth_credentials` JSON. Rendered by Terraform
  # (jsonencode) because the client id is a variable, not a literal.
  authCredentials =
    a:
    "\${jsonencode({ auth_mode = \"manual\", config = { authorization_endpoint = \"https://accounts.google.com/o/oauth2/v2/auth?access_type=offline&prompt=consent\", token_endpoint = \"https://oauth2.googleapis.com/token\", issuer = \"https://accounts.google.com\", revocation_endpoint = \"https://oauth2.googleapis.com/revoke\" }, registration_info = { client_id = var.google_oauth_client_id, token_endpoint_auth_method = \"client_secret_post\", scope = \"${lib.concatStringsSep " " a.scopes}\" } })}";

  policyRef = [
    {
      id = "\${cloudflare_zero_trust_access_policy.allowed.id}";
      precedence = 1;
    }
  ];
in
{
  terraform.required_providers.cloudflare = {
    source = "cloudflare/cloudflare";
    version = "= ${(import ../provider-pins.nix).cloudflare}";
  };

  variable = {
    google_oauth_client_id = {
      type = "string";
      description = "The \"Kattakath MCP Gateway\" Google OAuth client id (Keychain).";
    };
    google_oauth_client_secret = {
      type = "string";
      sensitive = true;
      description = "Its secret (Keychain). Write-only at Cloudflare.";
    };
  };

  # ONE allow policy, reused by every portal and server app: EVERY account in the
  # Workspace domain (operator, 2026-11-19: "all kattakath.com users by default"; it
  # replaced a hand-kept email list that silently refused a new family member). Each
  # user still signs in with Google through the Workspace-only IdP and grants each app
  # on their OWN account, so a user reaches only their own data. The domain comes from
  # identity (domainName), never a literal.
  resource.cloudflare_zero_trust_access_policy.allowed = {
    account_id = accountId;
    name = "workspace-mcp-allowed-domain";
    decision = "allow";
    include = [ { email_domain.domain = domainName; } ];
  };

  resource.cloudflare_zero_trust_access_ai_controls_mcp_server = lib.mapAttrs (
    app: a:
    {
      account_id = accountId;
      id = app;
      name = "Kattakath ${a.title}";
      # Google's Workspace servers serve /mcp/v1; Maps and every self-hosted
      # server serve /mcp (each app's `path`). A self-hosted app's host is its Cloud Run
      # URL (`runAppHost` in workspace-mcp-apps.nix).
      hostname = "https://${upstreamOf a}${a.path or "/mcp/v1"}";
      auth_type = "oauth";
      auth_credentials = authCredentials a;
      client_secret = "\${var.google_oauth_client_secret}";
      is_shared_oauth_callback_enabled = true;
      # The dashboard's "Authenticate server" (Edit, then Save) writes a SERVER-level
      # `updated_tools` list, and it WIDENS what the portal exposes: measured 2026-11-19,
      # docsread showed 7 tools through the portal against an allowlist of 5, its server list
      # having all 7 enabled. So a self-hosted app's server list is DECLARED, equal to its
      # allowlist: a dashboard click that widens it shows up as drift on the next plan.
      # Google's servers have no such list (none was ever saved), so theirs stays unset.
    }
    // lib.optionalAttrs (a ? selfHosted) {
      updated_tools = map (t: {
        name = t;
        enabled = true;
      }) a.tools;
    }
  ) apps;

  # ONE portal, ONE claude.ai connector ("Kattakath Workspace" at https://mcp.<zone>/mcp,
  # claude.ai's own URL convention, https://mcp.example.com/mcp), every app a server in it.
  # A portal aggregates up to 120 servers and prefixes each tool with its server id
  # (`gmail_search_threads`). The allowlist lives HERE: each server is attached with
  # every tool off by default (`default_disabled`) and only the listed ones turned on, so
  # a tool Google adds upstream stays off until workspace-mcp-apps.nix lists it. Listing
  # a tool the server has not SYNCED is a 400 ("Tool 'x' does not exist on server"), so
  # the servers' one-time admin authorization comes before this resource can be created.
  resource.cloudflare_zero_trust_access_ai_controls_mcp_portal.workspace = {
    account_id = accountId;
    id = "workspace";
    name = "Kattakath Workspace";
    hostname = portalHost;
    code_mode = "off";
    secure_web_gateway = false;
    servers = lib.mapAttrsToList (app: a: {
      server_id = "\${cloudflare_zero_trust_access_ai_controls_mcp_server.${app}.id}";
      on_behalf = true;
      default_disabled = true;
      updated_tools = map (t: {
        name = t;
        enabled = true;
      }) a.tools;
    }) apps;
  };

  # Two hops are gated: the CLIENT reaching the portal (`portal`, type mcp_portal: who
  # may sign in, and which MCP clients may register) and each SERVER as seen through
  # the portal (`server_*`, type mcp). A portal whose server has no app shows "No allowed
  # servers available" (Cloudflare troubleshooting).
  resource.cloudflare_zero_trust_access_application = {
    portal = {
      account_id = accountId;
      name = portalHost;
      type = "mcp_portal";
      domain = portalHost;
      # The domain is the portal's hostname, not a reference, so order it explicitly.
      depends_on = [ "cloudflare_zero_trust_access_ai_controls_mcp_portal.workspace" ];
      allowed_idps = [ accessIdpId ];
      auto_redirect_to_identity = true;
      session_duration = "24h";
      http_only_cookie_attribute = true;
      oauth_configuration = {
        enabled = true;
        dynamic_client_registration = {
          enabled = true;
          # The MCP CLIENTS that may register (operator's pick, 2026-11-14). A client
          # missing here fails at registration with "redirect_uri is not allowed by the
          # account configuration" (measured with Grok), and a change takes ~1 min to
          # reach the account-wide registration endpoint. Trailing /* where a client
          # mints a per-connector callback path. Who may SIGN IN is still the Access
          # email policy plus each app's Google consent; this list only names clients.
          allowed_uris = [
            "https://claude.ai/api/mcp/*"
            "https://claude.com/api/mcp/*"
            # Grok (grok.com/connectors-oauth-exchange-code…).
            "https://grok.com/*"
            # ChatGPT: the fixed URI (when the server returns RFC 9207 `iss`) and the
            # per-callback fallback (OpenAI Apps SDK, "Authentication").
            "https://chatgpt.com/connector_platform_oauth_redirect"
            "https://chatgpt.com/connector/oauth/*"
            # Mistral Le Chat (from a third-party integration guide; unverified upstream).
            "https://callback.mistral.ai/*"
            # Cloudflare Workers AI Playground (Cloudflare's own Managed OAuth example).
            "https://playground.ai.cloudflare.com/*"
            # VS Code's web redirect; its desktop flow uses loopback (below).
            "https://vscode.dev/redirect"
            # Cursor: web/cloud agents and the desktop custom scheme (desktop also uses
            # localhost:8787, below). Custom schemes must match exactly (Cloudflare docs).
            "https://www.cursor.com/agents/mcp/oauth/callback"
            "cursor://anysphere.cursor-mcp/oauth/callback"
          ];
          # Local clients (Claude Code, Gemini CLI, Codex, MCP Inspector, Windsurf, VS
          # Code and Cursor desktop) call back on a random localhost/127.0.0.1 port.
          allow_any_on_localhost = true;
          allow_any_on_loopback = true;
        };
        # Cloudflare's recommendation for agents: a short access token and a 1-2 week
        # grant, so a connector refreshes silently instead of re-signing in daily.
        grant = {
          access_token_lifetime = "15m";
          session_duration = "336h";
        };
      };
      policies = policyRef;
    };
  }
  // lib.mapAttrs' (app: _: {
    name = "server_${app}";
    value = {
      account_id = accountId;
      name = "mcp-server-${app}";
      type = "mcp";
      allowed_idps = [ accessIdpId ];
      session_duration = "24h";
      destinations = [
        {
          type = "via_mcp_server_portal";
          mcp_server_id = "\${cloudflare_zero_trust_access_ai_controls_mcp_server.${app}.id}";
        }
      ];
      policies = policyRef;
    };
  }) apps;
}
