# Login-Keychain item NAMES (never values) that more than one site hands to `secret exec`.
# One spelling each: a renamed item is then one edit here, not a hunt across the engine,
# the home profile and the packages. Shape `<service>:<host>:<scope>`.
#
# NOT auto-imported — `modules/_lib/` is excluded from import-tree by convention
# (see ./nix-ld-libraries.nix). Consumers `import` it explicitly; a package receives the
# names from the module that calls it, never by reaching into modules/ itself.
{
  cloudflare = {
    # Every Cloudflare stack's token, and a fleet-gauges expiry probe.
    api = "cf:cloudflare.com:api";
    nixpiTunnel = "cf:cloudflare.com:nixpi-tunnel";
    dontsellDns = "cf:cloudflare.com:dontsell-dns";
    # The cf-mcp-portals stack: the one token with MCP-portal write (the old mcp-public
    # stack's, hence the item name). `api` above cannot write /access/ai-controls/mcp.
    mcpPortals = "cf:cloudflare.com:mcp-public";
    # The cf-ai-search stack, the RAG corpus upload and the ircc-whatsapp-bot: AI Search
    # Edit + Run on the account (no other token reaches /ai-search, measured 2026-11-19).
    aiSearch = "cf:cloudflare.com:ai-search";
  };

  # The ircc-whatsapp-bot launchd agent (modules/parts/hosts.nix). The allowlist is
  # comma-separated phone digits: personal data, so a Keychain item, not a Nix value.
  ircc.allowedNumbers = "ircc:whatsapp:allowed-numbers";
  # Serper web search (the bot's CRAG fallback) and LangSmith tracing.
  serperApi = "serper.dev:api";
  langsmithApi = "langsmith:smith.langchain.com:api";

  # One fine-grained PAT per GitHub resource owner (a fine-grained token covers exactly
  # one), named by the owner: `githubPat orgName`, `githubPat userName`. Read by the
  # github + gws-chrome terranix stacks and fleet-gauges. Replaced the one classic
  # `gh:github.com:pat` on 2026-11-25.
  githubPat = owner: "gh:github.com:pat-${owner}";

  # The cf-mcp-portals stack (infra/cloudflare/mcp-portals.nix) reads all three as tofu
  # variables: the Google OAuth client id (per-person data, not a secret), its secret
  # (write-only at Cloudflare) and the family allowlist (a JSON list of emails; family
  # data, so never in the repo). The attr and item names are the retired Pomerium
  # gateway's (2026-11-14): renaming them means re-filing three Keychain items for no
  # behaviour change.
  workspaceGateway = {
    oauthClientId = "gcp:workspace-gateway:oauth-client-id";
    oauthClientSecret = "gcp:workspace-gateway:oauth-client-secret";
  };

  # The healthchecks.io project API key (the hc-checks stack).
  healthchecksApi = "hc:healthchecks.io:api";

  # The healthchecks.io project PING key: runitor pings with it (terranix-drift).
  healthchecksPingKey = "hc:healthchecks.io:ping-key";

  grafana = {
    # The OTLP gateway: base URL, instance id (basic-auth user), write token. Read by the
    # claude-otel collector and the fleet-gauges push.
    otlp = {
      endpoint = "grafana:otlp:endpoint";
      instance = "grafana:otlp:instance";
      token = "grafana:otlp:token";
      # logs:write ONLY, for allowlisted run metadata (ADR-011 § 4 exception). Minted by
      # the grafana stack (`grafana_cloud_access_policy_token.li_logs`); grafana-apply
      # pipes it in here. Its own policy, so revoking it stops those logs and nothing else.
      liLogsToken = "grafana:otlp:li-logs-token";
    };
    # The grafana stack's `terranix` service-account token (Admin) and the Synthetic
    # Monitoring access token.
    terranixToken = "grafana:terranix:token";
    smToken = "grafana:sm:token";
    # The Grafana Cloud (gcom) token: fleet-gauges lists access-token expiry with it, and
    # the grafana stack manages access policies with it (its policy holds accesspolicies:write).
    cloudToken = "grafana:cloud:gcx-token";
  };
}
