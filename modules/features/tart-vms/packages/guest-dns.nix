# Guest DNS for every CI guest, in both lanes: the ONE snippet that the GitLab prepare shim
# (packages/gitlab-tart.nix) and the GitHub controller (packages/tart-runner.nix) run
# inside the guest before the job reaches the network.
#
# WHY. A Tart guest on the default NAT network gets the host's vmnet bridge
# (192.168.64.1) as its resolver, by DHCP. macOS forwards that bridge's DNS to the
# HOST's resolver config. When the host points its resolver at a loopback-only proxy
# (dnscrypt-proxy on 127.0.0.1, `local.encryptedDns`), that forwarding dies.
# MEASURED 2026-11-08: nothing listens on 192.168.64.1:53 (`sudo lsof`), and
# `dig @192.168.64.1 gitlab.com` timed out while `@127.0.0.1` answered. Every GitLab job
# then failed at `git clone` with "Could not resolve host: gitlab.com" (jobs 17839694965
# and 17839705805). Inside the guest, `dig @9.9.9.9` answered at the same time. So the
# guest gets a public resolver of its own, and it stops depending on how the host resolves.
#
# WHAT. Quad9 (the same operator as the host's encrypted DNS), IPv4 first, set on every
# guest network service. It is plain DNS from a throwaway guest, not DoH: the guest lives
# for one job. Best-effort and logged: a guest without passwordless sudo keeps its
# DHCP DNS, and that guest can still resolve whenever the host's resolver is not loopback.
#
# upstream-first: gitlab-tart-executor 1.28.0 has no DNS setting (its TART_EXECUTOR_*
# surface has none), `tart run` has no DNS flag (`--net-softnet` still rides vmnet), and
# the cirruslabs images take DNS from DHCP. So the guest is set after boot, with the
# guest's own `networksetup`.
{ writeText }:
writeText "tart-guest-dns.sh" ''
  if sudo -n true 2>/dev/null; then
    /usr/sbin/networksetup -listallnetworkservices | tail -n +2 | sed 's/^\*//' |
      while IFS= read -r svc || [ -n "$svc" ]; do
        if sudo -n /usr/sbin/networksetup -setdnsservers "$svc" 9.9.9.9 149.112.112.112 2620:fe::fe 2620:fe::9; then
          echo "tart-guest-dns: $svc -> Quad9" >&2
        else
          echo "tart-guest-dns: could not set DNS on $svc; it keeps DHCP DNS" >&2
        fi
      done
  else
    echo "tart-guest-dns: no passwordless sudo in the guest; it keeps DHCP DNS" >&2
  fi
''
