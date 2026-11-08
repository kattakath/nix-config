# System-wide encrypted DNS: every lookup goes to dnscrypt-proxy on 127.0.0.1 / ::1,
# which forwards it as DoH (DNS over HTTPS) to Quad9, with Cloudflare as the fallback.
# Nothing leaves the Mac as plaintext UDP/53 to the ISP's resolvers.
#
# UPSTREAM-FIRST. Three pinned nix-darwin options do all of the work:
#   - services.dnscrypt-proxy.{enable,settings} (nix-darwin/modules/services/dnscrypt-proxy.nix):
#     the package, the `_dnscrypt-proxy` system user, the TOML render and the launchd daemon.
#   - networking.dns + networking.knownNetworkServices (nix-darwin/modules/networking/default.nix):
#     activation runs `networksetup -setdnsservers <service> <dns…>` on each listed service
#     (and `-setsearchdomains <service> empty`; no service here has any search domain).
# Nothing custom beyond the settings and one override, below.
#
# THE ONE OVERRIDE: the daemon starts as ROOT. Upstream runs the daemon as
# `_dnscrypt-proxy`, which cannot listen on port 53: MEASURED 2026-11-08 on this Mac
# (macOS 27.2), a non-root bind() to 127.0.0.1:53 and to ::1:53 fails with EACCES. (The
# Mojave relaxation covers only the wildcard 0.0.0.0 / ::, which would turn this into a
# resolver for the whole LAN.) So launchd starts it as root, and dnscrypt-proxy's own
# `user_name` drops it to `_dnscrypt-proxy` right after the sockets are bound. Pinned source
# dnscrypt-proxy 2.1.18 config.go, `ConfigLoad`: the privilege drop runs BEFORE
# `loadSources`, so the network-facing code and the cache file only ever run as the
# unprivileged user. `_dnscrypt-proxy` is a system service user (shell /usr/bin/false),
# not a second login account.
#
# LAUNCHD NAMING: this daemon is a boot-ordering exception (.claude/rules/launchd-naming.md).
# Upstream emits it with `script =`, so arg0 is `/bin/sh -c '/bin/wait4path /nix/store &&
# exec …'`. That is correct for a RunAtLoad daemon run from /nix: it must be up at boot,
# because the system resolver points at it. It reads no TCC folder (only
# /var/lib/dnscrypt-proxy), so only BTM legibility is lost.
#
# RESOLVERS — pinned BY NAME, from the minisign-signed public list:
#   - Quad9, DoH, the filtered variant (malware blocklist, DNSSEC, no logs, no ECS):
#     quad9-doh-ip4-port443-filter-pri, quad9-doh-ip6-port443-filter-pri
#   - Cloudflare 1.1.1.1, DoH (DNSSEC, no logs, no filter): cloudflare, cloudflare-ipv6
#   Every stamp in that list carries the server's IP address, so queries never need any
#   other resolver. Why names and not literal `[static]` stamps: Quad9's stamps pin a TLS
#   certificate hash. A copied stamp breaks silently when Quad9 rotates that certificate,
#   but the signed list follows the rotation. The minisign key keeps the list
#   tamper-proof.
#
# REQUIREMENTS: require_dnssec and require_nolog are ON. require_nofilter is OFF, because
# the operator CHOSE Quad9's filtering. With it ON, both Quad9 entries are dropped.
#
# "PRIMARY / FALLBACK" is by latency. It is not a strict order. dnscrypt-proxy 2.1.18
# has no priority strategy (lb_strategy is one of wp2|p2|ph|p<n>|first|random), and the
# order of server_names means nothing. `p2` picks one of the two fastest live servers.
# MEASURED 2026-11-08 on the home network: Quad9 v4/v6 31 ms, Cloudflare 69/79 ms, so the
# two fastest are both Quad9. A dead server leaves the pool under any strategy, so
# Cloudflare takes over when Quad9 is down. Rejected: `wp2` (the default), which picks from
# two RANDOM candidates and so sends a share of the queries to Cloudflare while Quad9
# is healthy. Weakest assumption: that Quad9 is faster on other networks too. The startup
# "Sorted latencies" lines in the log show which one is faster on each network.
#
# BOOTSTRAP. `bootstrap_resolvers` is PLAINTEXT UDP/53 by design. dnscrypt-proxy uses it
# for one job only: to resolve the hosts it downloads the resolver list from, when no
# encrypted server is live yet. In practice that means the first start, before the
# cache file exists. After that it resolves through itself. Queries are never sent there.
# Upstream's example suggests a bootstrap operator other than the DoH operator. Ours is
# deliberately the SAME two operators (9.9.9.9, 1.1.1.1). Every answer it gives is only
# used to fetch a list that is then minisign-verified, so a lying bootstrap can block the
# download but cannot inject a server. Using the same two operators means no third
# party (the example's 8.8.8.8) ever sees a query. `ignore_system_dns = true` is
# REQUIRED: the system resolver is this proxy, so falling back to it is a loop, and it
# also means the ISP resolver is never asked.
#
# NETWORK SERVICES: the physical ones only, as `networksetup -listallnetworkservices`
# printed them 2026-11-08: "Wi-Fi", "Thunderbolt Bridge". The seven WireGuard services
# (MANILA … TORONTO) are left out ON PURPOSE. Activation would overwrite their DNS on
# every switch. While a tunnel is up, it pushes its own DNS and that DNS wins: expected,
# and the queries travel encrypted inside the tunnel anyway. Tart CI VMs set their own
# public DNS per job and are unaffected. `networkServices` applies even when `enable` is
# off: with `networking.dns` empty, activation writes `empty` to each service, so turning
# this off returns Wi-Fi to DHCP DNS instead of leaving it pointed at a dead 127.0.0.1.
#
# IPv6-ONLY NETWORKS (a NAT64 phone hotspot): IPv4-only names need the carrier's DNS64,
# and Quad9/Cloudflare do not synthesise AAAA records. Use the escape below there, as
# for a captive portal. (Upstream's `[captive_portals]` map was rejected: it only answers
# the OS's probe names, and the portal's own login page still needs the network's DNS.)
#
# CAPTIVE-PORTAL ESCAPE (hotel/airport Wi-Fi): hand Wi-Fi back to the network's DHCP DNS:
#   sudo networksetup -setdnsservers Wi-Fi empty
# The next `activate` sets 127.0.0.1 / ::1 again, or run
# `sudo networksetup -setdnsservers Wi-Fi 127.0.0.1 ::1` once you are logged in.
{
  config,
  lib,
  ...
}:
let
  cfg = config.local.encryptedDns;
  stateDir = config.users.users._dnscrypt-proxy.home;
in
{
  options.local.encryptedDns = {
    enable = lib.mkEnableOption "system-wide encrypted DNS (dnscrypt-proxy DoH on 127.0.0.1 / ::1)";
    networkServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "Wi-Fi"
        "Thunderbolt Bridge"
      ];
      description = ''
        Network services (as `networksetup -listallnetworkservices` prints them) whose DNS
        this module owns. They point at the proxy when enabled and fall back to DHCP DNS when
        disabled. Leave VPN services out, so they keep the DNS their tunnel pushes.
      '';
    };
  };

  config = lib.mkMerge [
    { networking.knownNetworkServices = cfg.networkServices; }

    (lib.mkIf cfg.enable {
      networking.dns = [
        "127.0.0.1"
        "::1"
      ];

      services.dnscrypt-proxy = {
        enable = true;
        settings = {
          listen_addresses = [
            "127.0.0.1:53"
            "[::1]:53"
          ];
          user_name = "_dnscrypt-proxy";

          server_names = [
            "quad9-doh-ip4-port443-filter-pri"
            "quad9-doh-ip6-port443-filter-pri"
            "cloudflare"
            "cloudflare-ipv6"
          ];
          ipv4_servers = true;
          ipv6_servers = true;
          doh_servers = true;
          dnscrypt_servers = false;
          require_dnssec = true;
          require_nolog = true;
          require_nofilter = false;
          lb_strategy = "p2";

          bootstrap_resolvers = [
            "9.9.9.9:53"
            "1.1.1.1:53"
          ];
          ignore_system_dns = true;

          sources.public-resolvers = {
            urls = [
              "https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md"
              "https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md"
            ];
            # ABSOLUTE on purpose. dnscrypt-proxy chdirs into the config file's directory
            # (config.go `cdFileDir`), which is the read-only /nix/store. A relative
            # cache_file there cannot be written, and the daemon would never start.
            cache_file = "${stateDir}/public-resolvers.md";
            # The resolver list's published minisign PUBLIC key (upstream example-dnscrypt-proxy.toml),
            # not a secret, so it is gitleaks-allowed.
            minisign_key = "RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3"; # gitleaks:allow
            refresh_delay = 73;
          };
        };
      };

      # Root for the bind; `user_name` above does the drop (see the header).
      launchd.daemons.dnscrypt-proxy.serviceConfig = {
        UserName = lib.mkForce null;
        GroupName = lib.mkForce null;
      };
    })
  ];
}
