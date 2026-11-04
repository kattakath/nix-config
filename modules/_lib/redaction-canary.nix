# The ACTIVE redaction canary (ADR-013): one WARNING line nixpi logs daily, carrying
# addresses that MUST be redacted before Grafana sees them. Shared DATA, read by:
#   modules/nixos/alloy-shipper.nix  — the daily timer that logs it
#   infra/grafana/resources.nix      — two rules: the line arrived UNREDACTED (the redact
#                                      stage failed), or did not arrive (shipping is broken)
#
# Every value is reserved, so the canary can never point at a real host or device:
# 2001:db8::/32 is the IPv6 documentation range (RFC 3849), fe80::/10 is link-local, and a
# MAC whose first octet is 02 is locally administered and unicast.
#
# Limit, stated so nobody reads more into it: a canary proves the pipeline redacts the
# shapes it plants. Nothing can detect a shape that no pattern describes.
{
  marker = "redaction-canary";
  values = [
    "2001:db8::c4a7"
    "fe80::c4a7:1"
    "02:00:5e:c4:a7:01"
  ];
}
