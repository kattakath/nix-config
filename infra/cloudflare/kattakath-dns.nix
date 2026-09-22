# ---- kattakath.com DNS records, as data ------------------------------------
#
# ADR-005 phase 2 (docs/iac-coverage-adr.md). This is the ONE zone this public
# repo declares, and the reason is OWNERSHIP, not secrecy: DNS is a world-readable
# query, so publishing the operator's own zone discloses nothing `dig` does not —
# while publishing the other six would publish businesses that are not only his.
#
# Records are DATA, rendered by one `map` in infra/cloudflare/zones.nix. That is
# deliberate: cf-terraforming emits HCL, and hand-translating HCL into Nix is
# exactly the drift this repo exists to prevent. It is used for import IDs only.
#
# NOT DECLARED HERE, because another stack already owns them — importing one
# twice is how a plan grows a destroy:
#   nixpi.kattakath.com     -> cf-tunnel  (infra/cloudflare/nixpi-tunnel.nix)
#   upstream.kattakath.com  -> mcp-public (infra/cloudflare/mcp-public.nix)
#   mcp.kattakath.com       -> created by Cloudflare with the MCP portal itself;
#                              no terranix resource points at it, and adopting it
#                              would put us in a fight with the portal feature.
#
# A PLAIN LIST, not a flake-parts module and not a `fleet.*` option. It has
# exactly ONE consumer (modules/parts/terranix.nix), and routing it through the
# module system cost an infinite recursion for nothing: `config` inside a
# terranix `_module.args` block resolves to that module's own config, so the
# read recursed (measured 2026-09-22). Data with one consumer is just data.
#
# `key` is the Terraform resource name and MUST stay stable: changing one is a
# destroy + create of a live DNS record, not a rename. Indices exist only where a
# (type, name) pair repeats — the apex MX set and its three TXT records.
[

  {
    key = "aaaa_calendly";
    type = "AAAA";
    name = "calendly.kattakath.com";
    content = "100::";
    ttl = 1;
    proxied = true;
    comment = "proxy placeholder for dynamic redirect";
  }
  {
    key = "aaaa_claim";
    type = "AAAA";
    name = "claim.kattakath.com";
    content = "100::";
    ttl = 1;
    proxied = true;
    comment = "proxy placeholder for dynamic redirect";
  }
  {
    key = "aaaa_contact";
    type = "AAAA";
    name = "contact.kattakath.com";
    content = "100::";
    ttl = 1;
    proxied = true;
    comment = "proxy placeholder for dynamic redirect";
  }
  {
    key = "aaaa_mta_sts";
    type = "AAAA";
    name = "mta-sts.kattakath.com";
    content = "100::";
    ttl = 1;
    proxied = true;
  }
  {
    key = "cname_apex";
    type = "CNAME";
    name = "kattakath.com";
    content = "kattakath.github.io";
    ttl = 1;
    proxied = false;
  }
  {
    key = "cname_h3pzs7hoiybe_ismail";
    type = "CNAME";
    name = "h3pzs7hoiybe.ismail.kattakath.com";
    content = "gv-tx3lglni5detek.dv.googlehosted.com";
    ttl = 1;
    proxied = false;
    comment = "Google domain verification";
  }
  {
    key = "cname_ismail";
    type = "CNAME";
    name = "ismail.kattakath.com";
    content = "kattakath.github.io";
    ttl = 1;
    proxied = false;
  }
  {
    key = "cname_www";
    type = "CNAME";
    name = "www.kattakath.com";
    content = "kattakath.com";
    ttl = 1;
    proxied = true;
  }
  {
    key = "mx_apex_1";
    type = "MX";
    name = "kattakath.com";
    content = "alt4.aspmx.l.google.com";
    ttl = 1;
    proxied = false;
    priority = 10;
  }
  {
    key = "mx_apex_2";
    type = "MX";
    name = "kattakath.com";
    content = "alt3.aspmx.l.google.com";
    ttl = 1;
    proxied = false;
    priority = 10;
  }
  {
    key = "mx_apex_3";
    type = "MX";
    name = "kattakath.com";
    content = "alt2.aspmx.l.google.com";
    ttl = 1;
    proxied = false;
    priority = 5;
  }
  {
    key = "mx_apex_4";
    type = "MX";
    name = "kattakath.com";
    content = "alt1.aspmx.l.google.com";
    ttl = 1;
    proxied = false;
    priority = 5;
  }
  {
    key = "mx_apex_5";
    type = "MX";
    name = "kattakath.com";
    content = "aspmx.l.google.com";
    ttl = 1;
    proxied = false;
    priority = 1;
  }
  {
    key = "txt_apex_1";
    type = "TXT";
    name = "kattakath.com";
    content = "\"cloudflare_dashboard_sso=db04b8738b49461f15b573307bb60055\"";
    ttl = 1;
    proxied = false;
  }
  {
    key = "txt_apex_2";
    type = "TXT";
    name = "kattakath.com";
    content = "v=spf1 include:_spf.google.com ~all";
    ttl = 1;
    proxied = false;
    comment = "SPF record for email authentication";
  }
  {
    key = "txt_apex_3";
    type = "TXT";
    name = "kattakath.com";
    content = "\"ENS1 0x238A8F792dFA6033814B18618aD4100654aeef01 0x4fcDB32E5787212c82Db0543bDaA382ca53237bE\"";
    ttl = 1;
    proxied = false;
  }
  {
    key = "txt_dmarc";
    type = "TXT";
    name = "_dmarc.kattakath.com";
    content = "v=DMARC1; p=reject; sp=reject; pct=100; fo=1; rua=mailto:dmarc-reports@kattakath.com; ruf=mailto:dmarc-failures@kattakath.com";
    ttl = 3600;
    proxied = false;
    comment = "p=reject 2026-09-12: 60/61 sampled msgs were spoofed; only Google sends, passes 100%";
  }
  {
    key = "txt_github_pages_challenge_kattakath";
    type = "TXT";
    name = "_github-pages-challenge-kattakath.kattakath.com";
    content = "44a486dcdef22b3947019a10f5718e";
    ttl = 300;
    proxied = false;
    comment = "GitHub Pages domain verification (org kattakath) - prevents subdomain takeover";
  }
  {
    key = "txt_google_domainkey";
    type = "TXT";
    name = "google._domainkey.kattakath.com";
    content = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEArRjZyFKh9Fv9+F9st6lMIIsP+ZMXmwhjD/FIn5QcRVJCeOH2jG7ad/rc75xzaKq4Om7gmvTANWsPlaKCLzcdaO7+DsbBUwWmpj6s5y4DBp+zoyOjTWAdxBopz4EvEB/OrBL4Pojf0ZyziZx58x9PupuNGUOcHH5dn1nQeTpiVYLz+GJkJNSy7CF6IVcFcj9xIafip8V2xbtgp6CStCm80PV35hSMMVDP8do9F+99KiFF4LGt5NdViHI8+sy/digHqkUQ510i/WRIfGqAJkXNJwTJh6QN4TbQIt0VYYy1Z7el6W1IZwXy3p5aueLckazHUzyJQsRgRnpUGNetrNLIsQIDAQAB";
    ttl = 300;
    proxied = false;
    comment = "Google Workspace DKIM - 2048-bit (rotated from 1024 on 2026-09-12)";
  }
  {
    key = "txt_izzykatt_ca_report_dmarc";
    type = "TXT";
    name = "izzykatt.ca._report._dmarc.kattakath.com";
    content = "v=DMARC1";
    ttl = 3600;
    proxied = false;
    comment = "RFC 7489 external report authorisation for izzykatt.ca";
  }
  {
    key = "txt_mta_sts";
    type = "TXT";
    name = "_mta-sts.kattakath.com";
    content = "v=STSv1; id=20260912044403";
    ttl = 3600;
    proxied = false;
    comment = "MTA-STS policy pointer";
  }
  {
    key = "txt_smtp_tls";
    type = "TXT";
    name = "_smtp._tls.kattakath.com";
    content = "v=TLSRPTv1; rua=mailto:dmarc-reports@kattakath.com";
    ttl = 3600;
    proxied = false;
    comment = "TLS-RPT: SMTP TLS failure reporting";
  }
]
