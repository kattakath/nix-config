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
  };

  # The operator's classic PAT: the GitHub terranix stack and fleet-gauges' alert counts.
  githubPat = "gh:github.com:pat";

  # The healthchecks.io project API key (the hc-checks stack).
  healthchecksApi = "hc:healthchecks.io:api";

  # The healthchecks.io project PING key: runitor pings with it (terranix-drift, doctor-report weekly).
  healthchecksPingKey = "hc:healthchecks.io:ping-key";

  grafana = {
    # The OTLP gateway: base URL, instance id (basic-auth user), write token. Read by the
    # claude-otel collector and the fleet-gauges push.
    otlp = {
      endpoint = "grafana:otlp:endpoint";
      instance = "grafana:otlp:instance";
      token = "grafana:otlp:token";
    };
    # The grafana stack's `terranix` service-account token (Admin) and the Synthetic
    # Monitoring access token.
    terranixToken = "grafana:terranix:token";
    smToken = "grafana:sm:token";
    # The Grafana Cloud (gcom) token fleet-gauges lists access-token expiry with.
    cloudToken = "grafana:cloud:gcx-token";
  };
}
