# infra/cloudflare/litellm.nix — terranix (Nix → OpenTofu/Terraform JSON) module
# provisioning the DEDICATED, remotely-managed (token) Cloudflare Tunnel + DNS +
# Cloudflare Access in front of the LiteLLM proxy container.
#
# This REPLACES the old imperative scripts/cf-litellm-provision.sh. Rendered to a
# config.tf.json by `terranix.lib.terranixConfiguration` and applied by the
# `nix run .#cf-litellm-apply` app (OpenTofu + the Cloudflare provider v5).
#
# Topology it declares (identical to the retired shell script):
#   (a) a remotely-managed named tunnel "litellm" (config_src = cloudflare);
#   (b) its connector token, surfaced as a SENSITIVE `tunnel_token` output;
#   (c) HTTP ingress  litellm.kattakath.com -> http://localhost:4000  + 404 catch-all
#       (the origin is the loopback address LiteLLM binds on the nixrpi host —
#        the container runs with --network=host, so the connector reaches it on
#        127.0.0.1:4000; this replaced the docker-DNS `http://litellm:4000` used
#        by the retired compose deploy);
#   (d) a proxied CNAME  litellm.kattakath.com -> <tunnel-id>.cfargotunnel.com;
#   (e) a self-hosted Access application for that hostname with TWO policies:
#         - allow  : the operator's Google Workspace DOMAIN kattakath.com
#                    (browser/dashboard + LiteLLM's own Google SSO — the
#                    Google -> /sso/callback redirect must first clear Access);
#         - non_identity : a service token (programmatic API clients pass Access
#                          via CF-Access-Client-Id / CF-Access-Client-Secret);
#   (f) the Access service token, with client_id + client_secret as SENSITIVE
#       outputs.
#
# Retrieve the secrets after apply:
#   tofu output -raw tunnel_token           # -> deploy/litellm/.env TUNNEL_TOKEN
#   tofu output -raw service_token_client_id
#   tofu output -raw service_token_client_secret
#
# Provider v5 note: the whole Zero-Trust surface was renamed from v4
# (cloudflare_tunnel / cloudflare_access_* / cloudflare_record) to the
# cloudflare_zero_trust_* / cloudflare_dns_record names used below. All resource
# and attribute names here are the VERIFIED v5 schema.
_:
let
  accountId = "726e0b2aa2bc2c6944f96a042e3c461b";
  zoneId = "6e28971881e488941d052bbbf50d69cd"; # kattakath.com
  hostname = "litellm.kattakath.com";
  originService = "http://127.0.0.1:4000"; # loopback origin: LiteLLM binds 127.0.0.1:4000 on the nixrpi host (--network=host); IPv4 literal — localhost resolves ::1 first on the Pi and litellm binds IPv4-only
  # Browser/dashboard allow policy is scoped to the whole Google Workspace
  # DOMAIN, not a single email. This is what lets LiteLLM's own Google SSO work
  # behind Access: the Google -> https://litellm.kattakath.com/sso/callback
  # redirect is a browser navigation that must first clear Access; an
  # email-domain allow means any already-Access-authenticated kattakath.com user
  # sails straight through to LiteLLM's SSO. (Alternative — a `bypass` policy on
  # /sso/* — would punch an UNAUTHENTICATED hole in Access for that path and is
  # deliberately NOT used here; the domain allow keeps Access defense-in-depth.)
  allowEmailDomain = "kattakath.com"; # operator's Google Workspace domain
  sessionDuration = "24h";

  # Terraform interpolation refs. Escaped as ''${...} so Nix leaves the ${} for
  # OpenTofu to resolve at plan/apply time.
  tunnelId = "\${cloudflare_zero_trust_tunnel_cloudflared.litellm.id}";
  allowPolicyId = "\${cloudflare_zero_trust_access_policy.allow_email.id}";
  svcPolicyId = "\${cloudflare_zero_trust_access_policy.service_auth.id}";
  svcTokenId = "\${cloudflare_zero_trust_access_service_token.litellm.id}";
in
{
  # ---- Provider: API token from the CLOUDFLARE_API_TOKEN env var --------------
  # OpenTofu reads CLOUDFLARE_API_TOKEN from the environment automatically for the
  # `api_token` provider arg, so no explicit token/variable is declared here (the
  # cf-litellm-apply app requires the env var to be set).
  provider.cloudflare = { };

  terraform.required_providers.cloudflare = {
    source = "cloudflare/cloudflare";
    version = ">= 5.0.0";
  };

  # ---- (a) remotely-managed named tunnel "litellm" ---------------------------
  # config_src = "cloudflare" makes it remotely-managed; no tunnel_secret needed
  # (that is only for locally-managed/"local" tunnels).
  resource.cloudflare_zero_trust_tunnel_cloudflared.litellm = {
    account_id = accountId;
    name = "litellm";
    config_src = "cloudflare";
  };

  # ---- (b) connector token (data source) -------------------------------------
  data.cloudflare_zero_trust_tunnel_cloudflared_token.litellm = {
    account_id = accountId;
    tunnel_id = tunnelId;
  };

  # ---- (c) HTTP ingress config ------------------------------------------------
  # `config` is a SINGLE object; `ingress` is a list — the last entry is the
  # required catch-all (a service-only rule with no hostname).
  resource.cloudflare_zero_trust_tunnel_cloudflared_config.litellm = {
    account_id = accountId;
    tunnel_id = tunnelId;
    config.ingress = [
      {
        inherit hostname;
        service = originService;
      }
      { service = "http_status:404"; }
    ];
  };

  # ---- (d) proxied CNAME  litellm.kattakath.com -> <tunnel-id>.cfargotunnel.com
  # v5 renamed cloudflare_record -> cloudflare_dns_record; the value field is
  # `content` (not `value`); ttl is required and ttl = 1 means "auto".
  resource.cloudflare_dns_record.litellm = {
    zone_id = zoneId;
    name = hostname;
    type = "CNAME";
    content = "\${cloudflare_zero_trust_tunnel_cloudflared.litellm.id}.cfargotunnel.com";
    proxied = true;
    ttl = 1;
  };

  # ---- Access service token ---------------------------------------------------
  resource.cloudflare_zero_trust_access_service_token.litellm = {
    account_id = accountId;
    name = "litellm-api-client";
  };

  # ---- (e) Access policies (separate top-level resources in v5) ---------------
  # v5 split policies out of the application: they are their own resources and the
  # application references them by id. `precedence` lives ONLY in the app's
  # policies list, not on the policy resource. `include` is a list of selector
  # objects keyed by selector type.
  # Allow any member of the operator's Google Workspace domain in via the browser
  # (dashboard + LiteLLM's Google SSO). v5 selector: `email_domain = { domain }`
  # (verified against the cloudflare/cloudflare provider v5
  # cloudflare_zero_trust_access_policy schema). Restricting SSO to the SAME
  # domain is ALSO enforced inside LiteLLM via ALLOWED_EMAIL_DOMAINS=kattakath.com,
  # so the two layers agree.
  resource.cloudflare_zero_trust_access_policy.allow_email = {
    account_id = accountId;
    name = "Allow Workspace domain (browser SSO)";
    decision = "allow";
    include = [
      {
        email_domain = {
          domain = allowEmailDomain;
        };
      }
    ];
  };

  # decision "non_identity" is the v5 value for the service-token flow (v4's
  # "service_auth" was removed). This is what lets API clients pass Access with
  # the CF-Access-Client-Id / CF-Access-Client-Secret headers.
  resource.cloudflare_zero_trust_access_policy.service_auth = {
    account_id = accountId;
    name = "Allow API service token";
    decision = "non_identity";
    include = [
      {
        service_token = {
          token_id = svcTokenId;
        };
      }
    ];
  };

  # ---- Access self-hosted application ----------------------------------------
  resource.cloudflare_zero_trust_access_application.litellm = {
    account_id = accountId;
    name = "litellm";
    type = "self_hosted";
    domain = hostname;
    session_duration = sessionDuration;
    app_launcher_visible = false;
    policies = [
      {
        id = allowPolicyId;
        precedence = 1;
      }
      {
        id = svcPolicyId;
        precedence = 2;
      }
    ];
  };

  # ---- (f) Outputs — retrieve with `tofu output -raw <name>` ------------------
  output.tunnel_token = {
    value = "\${data.cloudflare_zero_trust_tunnel_cloudflared_token.litellm.token}";
    sensitive = true;
  };
  output.service_token_client_id = {
    value = "\${cloudflare_zero_trust_access_service_token.litellm.client_id}";
    sensitive = true;
  };
  output.service_token_client_secret = {
    value = "\${cloudflare_zero_trust_access_service_token.litellm.client_secret}";
    sensitive = true;
  };
}
