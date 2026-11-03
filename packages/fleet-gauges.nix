# `fleet-gauges` — hourly fleet-health gauges (credential expiry, open security alerts,
# Time Machine) pushed to Grafana Cloud as OTLP JSON. ADR-011 step 7.
#
# The shape copies agentic-jobseek's scripts/evidence-metrics.py: a deterministic script,
# best-effort per source, credentials only from the environment. The wrapper builds that
# environment with `secret exec`, so no value reaches argv, the store or a log.
#
# no community tool owns this (searched: nixpkgs for "credential expiry exporter",
# "github security alerts exporter", "time machine exporter"): the nearest, a
# Prometheus exporter per vendor, would be three daemons for three hourly API calls.
{
  writers,
  writeShellApplication,
  python3,
  homeProfileDir,
  cloudflareItems ? [ ],
}:
let
  script = writers.writePython3Bin "fleet-gauges-run" {
    flakeIgnore = [
      "E501"
      "W503"
    ];
  } (builtins.readFile ./fleet-gauges.py);
  cfEnv = builtins.concatStringsSep " " (
    builtins.genList (i: "CF_TOKEN_${toString i}=${builtins.elemAt cloudflareItems i}") (
      builtins.length cloudflareItems
    )
  );
in
writeShellApplication {
  name = "fleet-gauges";
  runtimeInputs = [ python3 ];
  text = ''
    export CF_TOKEN_NAMES="${builtins.concatStringsSep " " cloudflareItems}"
    # shellcheck disable=SC2086 # cfEnv is a fixed list of ENV=item words
    exec ${homeProfileDir}/bin/secret exec \
      GRAFANA_OTLP_ENDPOINT=grafana:otlp:endpoint \
      GRAFANA_OTLP_INSTANCE=grafana:otlp:instance \
      GRAFANA_OTLP_TOKEN=grafana:otlp:token \
      GCOM_TOKEN=grafana:cloud:gcx-token \
      GH_TOKEN=gh:github.com:pat \
      ${cfEnv} \
      -- ${script}/bin/fleet-gauges-run
  '';
}
