# ---- kattakath.com zone records (terranix -> OpenTofu) ---------------------
#
# ADR-005 phase 2. The THIRD Cloudflare stack, and the split is deliberate:
#
#   cf-tunnel   breaking it takes the Pi offline
#   mcp-public  breaking it takes the MCP portal offline
#   cf-zones    breaking it takes MAIL offline          <- this file
#
# > A stack is a blast radius, not a category.
#
# MX, DKIM, DMARC and MTA-STS are the highest consequence-per-byte objects in the
# account and share no failure mode with a tunnel. They must not ride in a plan
# whose other half is a Raspberry Pi.
#
# Records come from `config.fleet.dnsRecords` (modules/parts/dns.nix) as DATA and
# are rendered by one `map` — the same shape `hostedSites` and `publicMcpServers`
# already use. Nothing about a record is computed here; this file is the renderer,
# that file is the content.
#
# THIS STACK OWNS NO TUNNEL, NO ACCESS OBJECT AND NO ZONE SETTING. Zone settings
# for kattakath.com are already declared by nixpi-tunnel.nix, and declaring them
# twice is how two stacks fight over one object on alternate applies.
{
  lib,
  zoneId,
  domainName,
  # The records to manage, as `modules/parts/dns.nix` builds them. REQUIRED, not
  # defaulted: a `? [ ]` here would render an empty zone, and an empty render
  # against a populated state is the exact shape that DELETES every record while
  # reporting success. Let it fail at eval instead.
  dnsRecords,
  ...
}:
let
  # A Terraform resource name may hold letters, digits, underscore and dash, and
  # may not start with a digit. `key` is already sanitised by dns.nix; this is the
  # assertion that it stayed that way, not a second sanitiser — two sanitisers
  # disagreeing is worse than one that is checked.
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
in
{
  terraform.required_providers.cloudflare.source = "cloudflare/cloudflare";

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

  # Surfaced so the apply wrapper can assert the render is the size it expects
  # before it touches anything.
  output.record_count.value = builtins.length dnsRecords;
  output.zone.value = domainName;
}
