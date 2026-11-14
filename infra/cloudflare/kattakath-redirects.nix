# ---- kattakath.com edge redirects, as data ---------------------------------
#
# The zone's ONE `http_request_dynamic_redirect` entrypoint ruleset, rendered by
# infra/cloudflare/zones.nix. A zone has exactly one entrypoint per phase, so every
# redirect on kattakath.com lives in this list or nowhere.
#
# Adopted 2026-11-07. cf-tunnel created the ruleset (its name is that stack's
# `redirect-www-to-apex-<key>` scheme) while kattakath.com was a hosted site, then
# dropped it from state when the site moved off nixpi; the last three rules were
# added by hand. `rulesetId` is the bare ruleset id (zones.nix composes the
# `zones/<zone_id>/<ruleset_id>` import id); `ref` keeps each live rule's id, so
# adopting it rewrites nothing.
#
# The www rule's DNS (`cname_www`) and the three `*_placeholder` AAAA records it
# needs (proxied 100::, so the edge sees the request) are in ./kattakath-dns.nix.
{
  rulesetId = "3574a9add8a94993a15cf76d439628f7";
  name = "redirect-www-to-apex-kattakath_com";
  rules = [
    {
      ref = "0410508777d84cb794a4da67b193160e";
      description = "301 www.kattakath.com -> kattakath.com (canonical host)";
      host = "www.kattakath.com";
      targetExpression = ''concat("https://kattakath.com", http.request.uri.path)'';
      preserveQueryString = true;
    }
    {
      ref = "cdf509c0731a4df081d900b92d121343";
      description = "301 claim.kattakath.com -> forms.gle (was HTTP-only external redirector)";
      host = "claim.kattakath.com";
      targetUrl = "https://forms.gle/kTtihYjhdBKyL2Uu7";
    }
    {
      ref = "df55c558bf6b4cc78b1681e9080f67ef";
      description = "301 calendly.kattakath.com -> calendly.com (was HTTP-only external redirector)";
      host = "calendly.kattakath.com";
      targetUrl = "https://calendly.com/ismailkattakath";
    }
    {
      ref = "ba53186b92564deb99f2bf1aefebb01c";
      description = "301 contact.kattakath.com -> docs.google.com (was HTTP-only external redirector)";
      host = "contact.kattakath.com";
      targetUrl = "https://docs.google.com/forms/d/e/1FAIpQLSeN1m3WJ63uftyKDX7pqaVBnpsveJ1QKVbTcHuZe3gDyM3BJQ/viewform";
    }
  ];
}
