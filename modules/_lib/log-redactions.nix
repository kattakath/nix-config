# What nixpi's journal lines lose before they leave the host (ADR-011 § 5: no client IPs,
# MACs or network names). Shared DATA, read by two places so they cannot drift:
#   modules/nixos/alloy-shipper.nix  — one Alloy `stage.replace` per entry, in this order
#   modules/parts/checks.nix         — `checks.<system>.log-redaction`, which feeds sample
#                                      lines through these exact patterns
#
# Each `expr` is RE2 (Alloy's regex engine) with exactly ONE capture group, because
# `stage.replace` rewrites every capture group; inner groups are `(?:…)`. Raw strings here;
# the module escapes them for Alloy's string syntax.
#
# ORDER MATTERS: MACs before IPv6, so a MAC is never half-read as an IPv6 address.
#
# Why these shapes (the 2026-11-03 hygiene audit, measured): the old single pattern
# `(?:[0-9a-f]{1,4}:){2,7}[0-9a-f]{1,4}` redacted clock times (12:34:56) and let every
# COMPRESSED IPv6 address through (fe80::1, 2001:db8::1) — the common form in real logs.
# A compressed address needs one hex group before the `::` here; that keeps C++/Rust paths
# like `std::vector` or `fmt::Display` intact. The bare loopback `::1` is not redacted:
# it identifies nobody.
[
  {
    name = "mac";
    expr = ''(?i)(\b[0-9a-f]{2}(?:[:-][0-9a-f]{2}){5}\b)'';
    replace = "<mac>";
  }
  {
    name = "ipv6-full";
    expr = ''(?i)(\b(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}\b)'';
    replace = "<ip6>";
  }
  {
    name = "ipv6-compressed";
    expr = ''(?i)(\b(?:[0-9a-f]{1,4}:){1,7}:(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4}){0,6})?)'';
    replace = "<ip6>";
  }
  {
    name = "ipv4";
    expr = ''(\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b)'';
    replace = "<ip>";
  }
]
