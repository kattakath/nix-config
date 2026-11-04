# `fleet-gauges` — hourly fleet-health gauges (credential expiry, open security alerts,
# Time Machine, the terranix drift summary) pushed to Grafana Cloud as OTLP JSON. ADR-011 step 7.
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
  # The Home Manager profile whose `bin/secret` to call. null = `secret` from PATH (the
  # `nix run .#fleet-gauges` case), as in packages/terranix-drift.nix.
  homeProfileDir ? null,
  # Keychain item NAMES (modules/_lib/keychain-items.nix), handed in by the calling module.
  items,
  cloudflareItems ? [ ],
  # What to probe, from the calling module; empty = probe none (the generic package
  # carries no owner or region of its own).
  githubOrgs ? [ ],
  githubUsers ? [ ],
  gcomRegions ? [ ],
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
  secretBin = if homeProfileDir == null then "secret" else "${homeProfileDir}/bin/secret";
  words = builtins.concatStringsSep " ";
in
writeShellApplication {
  name = "fleet-gauges";
  text = ''
    export CF_TOKEN_NAMES="${words cloudflareItems}" GH_TOKEN_NAME=${items.githubPat}
    export GH_ORGS="${words githubOrgs}" GH_USERS="${words githubUsers}" GCOM_REGIONS="${words gcomRegions}"
    # The daily drift check's summary: packages/terranix-drift.nix writes it into its
    # fixed working dir, this exact path. Named here, once, so the script does not guess.
    export TERRANIX_DRIFT_SUMMARY="''${XDG_STATE_HOME:-$HOME/.local/state}/nix-config-terranix-drift/summary.json"
    # shellcheck disable=SC2086 # cfEnv is a fixed list of ENV=item words
    exec ${secretBin} exec \
      GRAFANA_OTLP_ENDPOINT=${items.grafana.otlp.endpoint} \
      GRAFANA_OTLP_INSTANCE=${items.grafana.otlp.instance} \
      GRAFANA_OTLP_TOKEN=${items.grafana.otlp.token} \
      GCOM_TOKEN=${items.grafana.cloudToken} \
      GH_TOKEN=${items.githubPat} \
      ${cfEnv} \
      -- ${script}/bin/fleet-gauges-run
  '';
}
