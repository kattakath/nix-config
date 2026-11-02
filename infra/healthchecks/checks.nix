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
# PROVIDER: kristofferahl/healthchecksio, pinned EXACTLY in ../provider-pins.nix
# (2.3.0, published 2025-04-13). Served by the OpenTofu registry (registry.opentofu.org lists 2.3.0
# with darwin/arm64 and linux/arm64 builds); nixpkgs does not package it, so
# `tofu init` fetches it — the same lane cloudflare/cloudflare and hashicorp/google
# use. EXACT rather than `>=` because this render
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
# ALERT CHANNELS: by default every check notifies the account's EMAIL integration,
# found by a `data "healthchecksio_channel"` lookup — so no per-account UUID sits in
# this public repo (the no-data rule). The lookup's two documented traps
# (data_source_channel.go at v2.3.0, read 2026-11-02): with `name` omitted it takes
# the FIRST channel of that kind, and an unmatched lookup sets an EMPTY id with no
# error. The second is closed by the `postcondition` below, so a missing email
# integration fails the plan loudly instead of creating checks that notify nobody.
# The first is accepted: the project has exactly one email integration (the default
# one healthchecks.io creates at signup). `fleet.heartbeatChannels`, when non-empty,
# OVERRIDES the lookup with explicit UUIDs (e.g. to add ntfy/Telegram).

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
    // {
      channels = if channels != [ ] then channels else [ "\${data.healthchecksio_channel.email.id}" ];
    }
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
    version = "= ${(import ../provider-pins.nix).healthchecksio}";
  };

  # api_key comes from HEALTHCHECKSIO_API_KEY (see AUTH above).
  provider.healthchecksio = { };

  # The default alert channel (see ALERT CHANNELS above). Rendered only when no
  # explicit UUIDs override it.
  data = lib.optionalAttrs (channels == [ ]) {
    healthchecksio_channel.email = {
      kind = "email";
      lifecycle.postcondition = [
        {
          condition = "\${self.id != \"\"}";
          error_message = "No email integration in the healthchecks.io project: create one (Integrations -> Email) or set fleet.heartbeatChannels.";
        }
      ];
    };
  };

  # The limit assert sits INSIDE the value, not above the module's attrset: a module
  # argument forced while the function is still being called to learn its shape
  # (here `heartbeats`, which comes from `_module.args`) recurses through `config`
  # — the same trap modules/parts/terranix.nix records at `dnsRecords`.
  resource.healthchecksio_check =
    assert lib.assertMsg (builtins.length (builtins.attrNames heartbeats) <= freePlanLimit)
      "fleet.heartbeats declares more than the healthchecks.io free plan's ${toString freePlanLimit} checks";
    lib.mapAttrs entry heartbeats;
}
