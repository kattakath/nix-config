# ---- healthchecks.io checks (terranix -> OpenTofu) --------------------------
#
# The SIXTH stack, and a stack is a blast radius: breaking this one silences the
# fleet's dead man's switches (a check deleted or paused here stops alerting on its
# own silence) — it cannot take a host, a tunnel or mail down. That shares nothing
# with the Cloudflare or GCP stacks, which is the ADR-005 §4 reason for a separate
# state and a separate credential.
#
# ONE resource per registry entry. The registry is `config.fleet.heartbeats`
# (modules/parts/heartbeats.nix), handed in as the `heartbeats` module arg by
# modules/parts/terranix.nix; this file is the renderer and that file is the
# content, the same split zones.nix / kattakath-dns.nix use. The slug a host pings
# (modules/nixos/service-heartbeat.nix) and the slug created here are the SAME
# attribute name — that is the whole point of the registry.
#
# PROVIDER: kristofferahl/healthchecksio, pinned EXACTLY (2.3.0, published
# 2025-04-13). Served by the OpenTofu registry (registry.opentofu.org lists 2.3.0
# with darwin/arm64 and linux/arm64 builds); nixpkgs does not package it, so
# `tofu init` fetches it — the same lane cloudflare/cloudflare and hashicorp/google
# use. EXACT rather than `>=` (nixpi-tunnel.nix uses a floor) because this render
# is written against the schema read at that tag (resource_check.go: slug, timeout,
# grace, schedule, timezone, channels, tags, desc) — a community SDKv2 plugin, so a
# later minor is a re-read, not a free upgrade.
#
# AUTH: the provider reads HEALTHCHECKSIO_API_KEY from the environment
# (healthchecksio/config.go `APIKeyEnvName`) — so no key is in this file, in the
# rendered JSON, or in the store. This is the project's READ-WRITE *API key*, a
# different credential from the *ping key* hosts hold: the API key manages checks,
# the ping key can only ping them.
#
# ALERT CHANNELS are data (`channels`, a list of integration UUIDs), EMPTY by
# default. Create the integration once in the healthchecks.io dashboard
# (Integrations -> Add), copy its UUID into `fleet.heartbeatChannels`. REJECTED:
# `data "healthchecksio_channel"` lookups by kind — they would keep the UUID out of
# the repo, but with `name` omitted they take the FIRST channel of that kind
# (data_source_channel.go `isTarget`), and an unmatched lookup sets an empty id with
# no error. A pinned UUID is explicit and fails loudly (the provider validates
# `channels` as UUIDs).
#
# FREE PLAN LIMIT: 20 checks. The module refuses a registry over it at eval rather
# than letting the 21st fail mid-apply with a partial roster.
{
  lib,
  heartbeats,
  channels ? [ ],
  ...
}:
let
  freePlanLimit = 20;

  # Same alphabet the provider's own validator enforces on `slug`
  # (`^[a-z0-9_-]+$`) — checked here so a bad name fails at eval with the entry named,
  # not at apply with a provider error.
  slugOk = s: builtins.match "[a-z0-9_-]+" s != null;

  # The resource label IS the slug (hyphens kept — legal in a Terraform label), so
  # `tofu state list` reads the same as the ping URL's last path segment.
  entry =
    slug: hb:
    assert lib.assertMsg (slugOk slug)
      "fleet.heartbeats.${slug}: name must match [a-z0-9_-]+ (healthchecks.io slug alphabet)";
    assert lib.assertMsg ((hb.schedule == null) != (hb.period == null))
      "fleet.heartbeats.${slug}: set exactly one of `schedule` (cron) and `period` (seconds), not both and not neither";
    {
      name = slug;
      inherit slug;
      inherit (hb) grace tags desc;
    }
    // lib.optionalAttrs (channels != [ ]) { inherit channels; }
    // (
      if hb.schedule != null then
        {
          inherit (hb) schedule timezone;
        }
      else
        { timeout = hb.period; }
    );
in
{
  terraform.required_providers.healthchecksio = {
    source = "kristofferahl/healthchecksio";
    version = "2.3.0";
  };

  # api_key comes from HEALTHCHECKSIO_API_KEY (see AUTH above).
  provider.healthchecksio = { };

  # The limit assert sits INSIDE the value, not above the module's attrset: a module
  # argument forced while the function is still being called to learn its shape
  # (here `heartbeats`, which comes from `_module.args`) recurses through `config`
  # — the same trap modules/parts/terranix.nix records at `dnsRecords`.
  resource.healthchecksio_check =
    assert lib.assertMsg (builtins.length (builtins.attrNames heartbeats) <= freePlanLimit)
      "fleet.heartbeats declares more than the healthchecks.io free plan's ${toString freePlanLimit} checks";
    lib.mapAttrs entry heartbeats;
}
