# nixpi's systemd units worth a panel or an alert, ONE list for two consumers:
# hosts/nixpi.nix ships all of them to Grafana (`local.alloyShipper.systemdUnits`), and
# infra/grafana/resources.nix alerts "service not active" on `longRunning` only — a
# timer-driven oneshot is inactive between runs by design.
#
# NOT auto-imported — `modules/_lib/` is excluded from import-tree by convention
# (see ./nix-ld-libraries.nix). Consumers `import` it explicitly.
{
  longRunning = [
    "caddy.service"
    "cloudflared-connector.service"
    "audiobookshelf.service"
    "alloy.service"
    "avahi-daemon.service"
    "sshd.service"
    "supplicant-wlan0.service"
    "dhcpcd.service"
  ];
  oneshot = [
    "service-heartbeat.service"
    "uplink-watchdog.service"
    "nix-gc.service"
  ];
}
