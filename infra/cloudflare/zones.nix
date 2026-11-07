# ---- kattakath.com zone records (terranix -> OpenTofu) ---------------------
#
# ADR-005 phase 2. One of three Cloudflare stacks, and the split is deliberate:
#
#   cf-tunnel      breaking it takes the Pi offline
#   cf-access-org  breaking it takes EVERY Access sign-in down
#   cf-zones       breaking it takes MAIL offline       <- this file
#
# > A stack is a blast radius, not a category.
#
# (A fourth, mcp-public, took the MCP portal offline when broken. Its
# infrastructure was destroyed and the stack deleted 2026-10-02.)
#
# MX, DKIM, DMARC and TLS-RPT are the highest consequence-per-byte objects in the
# account and share no failure mode with a tunnel. They must not ride in a plan
# whose other half is a Raspberry Pi.
#
# Records come from the `dnsRecords` module arg (a plain list imported from
# infra/cloudflare/kattakath-dns.nix by modules/parts/terranix.nix) as DATA and
# are rendered by one `map` — the same shape `hostedSites` already uses. Nothing
# about a record is computed here; this file is the renderer, that file is the
# content.
#
# THIS STACK OWNS NO TUNNEL, NO ACCESS OBJECT AND NO ZONE SETTING. Zone settings
# for kattakath.com are already declared by nixpi-tunnel.nix, and declaring them
# twice is how two stacks fight over one object on alternate applies.
{
  lib,
  zoneId,
  domainName,
  # The records to manage, as `infra/cloudflare/kattakath-dns.nix` builds them. REQUIRED, not
  # defaulted: a `? [ ]` here would render an empty zone, and an empty render
  # against a populated state is the exact shape that DELETES every record while
  # reporting success. Let it fail at eval instead.
  dnsRecords,
  # The zone's one dynamic-redirect entrypoint, as infra/cloudflare/kattakath-redirects.nix
  # builds it. Required for the same reason: a missing ruleset would plan a destroy.
  zoneRedirects,
  ...
}:
let
  # A Terraform resource name may hold letters, digits, underscore and dash, and
  # may not start with a digit. `key` is hand-written in kattakath-dns.nix; this asserts each one is a
  # valid resource name rather than sanitising it — rewriting a key would rename
  # the resource, i.e. a destroy + create.
  badKeys = builtins.filter (r: !(builtins.match "[a-z][a-z0-9_]*" r.key != null)) dnsRecords;

  # The apex is spelled as the bare domain, subdomains fully qualified. Cloudflare
  # accepts both; normalising here means the data file never has to think about it.
  recordResource =
    r:
    {
      inherit (r)
        type
        name
        content
        ttl
        ;
      zone_id = zoneId;
      proxied = r.proxied or false;
    }
    // lib.optionalAttrs (r ? priority) { inherit (r) priority; }
    // lib.optionalAttrs (r ? comment) { inherit (r) comment; };

  redirectRule = r: {
    inherit (r) ref description;
    expression = ''(http.host eq "${r.host}")'';
    action = "redirect";
    enabled = true;
    action_parameters.from_value = {
      status_code = 301;
      preserve_query_string = r.preserveQueryString or false;
      target_url =
        if r ? targetExpression then { expression = r.targetExpression; } else { value = r.targetUrl; };
    };
  };
in
{
  # Version pinned exactly in ../provider-pins.nix (one place for every stack).
  terraform.required_providers.cloudflare = {
    source = "cloudflare/cloudflare";
    version = "= ${(import ../provider-pins.nix).cloudflare}";
  };

  provider.cloudflare = { };

  # One resource per record, keyed by kattakath-dns.nix's stable `key`. A changed
  # key is a DESTROY + CREATE of a live record, never a rename.
  #
  # Both assertions live INSIDE this value on purpose. As a top-level
  # `assert … ; { … }` they forced the `dnsRecords` module argument while the
  # module system was still constructing the module — an infinite recursion whose
  # error names the argument rather than the cause (measured 2026-09-22). Inside a
  # value they are forced at RENDER time, which is when they can still help.
  resource.cloudflare_dns_record =
    assert lib.assertMsg (badKeys == [ ])
      "infra/cloudflare/zones.nix: dnsRecords keys must match [a-z][a-z0-9_]* (Terraform resource names): ${
        toString (map (r: r.key) badKeys)
      }";
    assert lib.assertMsg (dnsRecords != [ ])
      "infra/cloudflare/zones.nix: dnsRecords is EMPTY. Rendering an empty zone over a populated state deletes every record. Refusing at eval.";
    builtins.listToAttrs (
      map (r: {
        name = r.key;
        value = recordResource r;
      }) dnsRecords
    );

  # A record created out-of-band carries `importId` (zone_id/record_id), so it is
  # ADOPTED rather than created twice. OpenTofu skips an import block whose
  # address is already in state, so the entry is inert after the first apply.
  import =
    map (r: {
      to = "cloudflare_dns_record.${r.key}";
      id = r.importId;
    }) (builtins.filter (r: r ? importId) dnsRecords)
    ++ [
      {
        to = "cloudflare_ruleset.redirects";
        id = zoneRedirects.importId;
      }
    ];

  resource.cloudflare_ruleset.redirects = {
    zone_id = zoneId;
    inherit (zoneRedirects) name;
    kind = "zone";
    phase = "http_request_dynamic_redirect";
    rules = map redirectRule zoneRedirects.rules;
  };

  # Surfaced so the apply wrapper can assert the render is the size it expects
  # before it touches anything.
  output.record_count.value = builtins.length dnsRecords;
  output.zone.value = domainName;
}
