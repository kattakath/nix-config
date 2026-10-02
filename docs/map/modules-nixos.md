Part of the [repo map](../repo-map.md) — the full fleet architecture.

## `modules/nixos/`

- **`modules/nixos/core.nix`** — shared NixOS baseline: the `ismail` user + authorized SSH key (the
  operator's static ed25519 key, the sole network login credential on every host), keys-only
  sshd (no password, no root login, no keyboard-interactive), a firewall that opens **no TCP
  port at all** (UDP 5353 only, for mDNS), avahi `<host>.local` publishing, native
  `programs.nix-ld`, zram swap, automatic GC.
  **sshd binds loopback only BY DEFAULT** — `listenAddresses = 127.0.0.1 + ::1` with
  `openFirewall = false` (clearing `allowedTCPPorts` alone is NOT enough; sshd's own module
  re-opens the port). On that default a host's sshd is reachable *only* from on-host, which in
  practice means the tunnel connector terminating there
  (`cloudflared access ssh --hostname nixpi.kattakath.com`) — closing the LAN path that walked
  around the Access application entirely.
  **`nixpi` OPTS OUT of that default since 2026-10-01** (`lan-recovery.nix`, below), because
  loopback-only also meant the tunnel was a SINGLE POINT OF FAILURE: when the connector died
  that day the host was unreachable by every route and recovery was a ~40-minute physical SD
  reflash. `nixvm`, and every `lib.mkNixos` consumer, keep the loopback-only default. The
  physical console is the break-glass path below both.
  `nixvm` is only ever the local `nix run .#nixvm` desktop and has no networked login path
  either — but note it autologins with **no password** AND keeps a persistent `/home` in its
  qcow2 (see `nixvm.nix` above), so that image is durable unencrypted local state rather than
  a scratch buffer.

  **That posture is now a GATE, not just these paragraphs** —
  `checks.<system>.nixpi-security-posture` (2026-09-21, `modules/parts/checks.nix` via
  `mkHostContract`, so it reports every broken leg at once). It is **ungated** — built on
  `aarch64-darwin` as well as `aarch64-linux`, because the edits it guards are made ON the Mac:
  Linux-gating it would let an operator relax `core.nix`, run `/eval` clean, and learn otherwise
  only from CI. Cost measured 2026-09-21: one extra `nixpi` module eval on the darwin leg (~1 s;
  nothing else on that leg forces this config), and no `aarch64-linux` build, because only
  numbers and strings escape into the derivation. A comment cannot fail a build, and
  each of these lines is a one-token edit away from a posture nobody chose — in EITHER
  direction. **Widening:** a port opened GLOBALLY renders with no interface match, and since
  Access enforces at the EDGE such a connection is not merely unauthenticated, it produces **no
  access log at all**. **Narrowing:** putting sshd back on loopback, or dropping the
  per-interface allow-list, silently restores the single point of failure that cost the
  2026-10-01 reflash. 22 legs, each naming its own silent-failure mode:
  - `openFirewall = false` — upstream defaults it **true** and feeds `cfg.ports` straight into
    `allowedTCPPorts`, i.e. the GLOBAL list, so deleting that one line opens 22 on every
    interface the host has with no other file changing.
  - `listenAddresses` NON-EMPTY, checked BEFORE the address-equality leg: an empty list emits no
    `ListenAddress` line and OpenSSH binds the wildcard by default, so an EMPTY list and the
    declared wildcard pair produce the same binds — and a check cannot tell a deliberate
    deletion from a careless one. The pair is therefore written out explicitly and compared as a
    sorted EQUALITY, which also proves both families are bound.
  - every listen address carries a **string** `addr` — its own leg, and the precondition both
    sorted comparisons need. The submodule declares `addr` as `nullOr str` defaulting to null
    (pinned nixpkgs `sshd.nix:325-328`), so the attribute always EXISTS, `a.addr or ""` never
    fires, and a malformed entry reached `null < "127.0.0.1"` — a throw from inside a
    trivial-builder stack trace instead of this check's own message. Both dependent legs are
    guarded by a lazy `&&`: the rendered leg below forces `extraConfig`, where upstream
    interpolates `addr` straight into a string (`sshd.nix:901`, "cannot coerce null to a
    string" — measured), so guarding only the sort was not enough.
  - the **RENDERED** `ListenAddress` lines are that same wildcard pair — an address smuggled
    through `services.openssh.extraConfig` binds exactly as well as one in `listenAddresses`,
    and no option read catches it. `extraConfig` is CUMULATIVE, so now that the expected pair IS
    the wildcard this leg catches a THIRD address appearing rather than a widening; the option
    leg beside it is what catches a narrowing.
    This leg parses the MERGED `extraConfig` back into addresses and
    compares sorted. A bare `hasInfix "ListenAddress"` was NOT viable: upstream puts its own
    generated block in that same string at `mkOrder 0` (`sshd.nix:893-902`), so the grep is
    TRUE on a healthy host. The parser lowercases each line (sshd keywords are
    case-insensitive) and accepts `=` as a separator; a leading `#` is not whitespace, so
    comments do not match.
  - no explicit `port` on a listen address — nixpkgs renders `ListenAddress ::1:22`
    UNBRACKETED, OpenSSH reads that as `::0.1.0.34`, the v6 bind fails, and sshd SURVIVES
    (a failed bind is fatal only if every bind fails), so v6 loopback silently vanishes.
  - the allow-list is **several** legs, not one, because several options reach the same iptables
    accept rule. The GLOBAL `allowedTCPPorts` is EXACTLY `[ 80 ]` — core.nix's `[ ]` MERGES with
    `hosts/nixpi.nix`'s Caddy ORIGIN port (443 omitted; TLS terminates at Cloudflare) — and that
    one renders with **no `-i`** (`firewall-iptables.nix:160-165`), which is why a separate leg
    also asserts no sshd port appears in it. The GLOBAL `allowedTCPPortRanges` is `[ ]`
    (`:182-183`). The per-interface sets are read through the INTERNAL `allInterfaces`
    (`firewall.nix:305-311`) rather than the user-facing `interfaces`, because `allInterfaces` is
    the attrset every one of the four accept loops actually walks (`:165`, `:183`, `:195`,
    `:213`), so a future upstream route into those loops surfaces here as a new key instead of
    slipping past — and the `default` key IS the global list under another name
    (`firewall.nix:308-311`), so the per-interface legs drop it. And `trustedInterfaces` is
    `[ "lo" ]` — a trusted interface accepts EVERYTHING on it, no port list consulted
    (`firewall-iptables.nix:149`), and upstream sets that value itself (`firewall.nix:334`), so
    the leg pins it rather than emptiness. Plus password / keyboard-interactive / root-login
    denials.
  - **the SECOND INGRESS, five legs, reading the per-interface path in the OPPOSITE direction.**
    Since 2026-10-01 that path is not purely a widening risk — it is where `nixpi`'s LAN recovery
    ingress lives, so its ABSENCE is now a failure too: `local.lanRecovery.enable` is true; a
    per-interface allow-list exists at all; its keys are EXACTLY the interfaces
    `local.lanRecovery` declares; those names equal
    `local.uplinkWatchdog.wiredInterface` ∪ `attrNames networking.supplicant` (the two places
    `end0` and `wlan0` are independently spelled on this host, so a rename in one cannot leave
    the LAN list stale); and each named interface opens EXACTLY `services.openssh.ports` and
    nothing else on any protocol, which is the widening guard the leg always was. The check's job
    stays "make a change loud", not "bless the current width": a legitimate new port means
    editing a literal on purpose.
  - `distributedBuilds`, `buildMachines` and the rendered `nix.settings.builders` are three
    SEPARATE legs, because upstream says the first does not inhibit the second (`buildMachines
    != [ ]` alone renders `/etc/nix/machines`) and nulls the third only WHILE `distributedBuilds`
    is false. This is about a leaf host growing **outbound** build trust and a stray machines
    file — not about the Pi compiling, which stays owned by the PreToolUse guard's Rule 1d and
    `deploy.nix`'s `remoteBuild = false`.

  **Not nixpkgs' own `assertions`:** their only natural home is `modules/nixos/core.nix`, which
  `nixvm` and every `lib.mkNixos` consumer also import — baking "exactly one open TCP port" in
  there breaks a stranger's host, the precise leak the `template-consumer` check exists to
  prevent. This is a FLEET contract about one named host.

  **NOT COVERED — and the headline is that this check CANNOT TELL YOU THE PI IS UP.** It is
  EVAL, not runtime — no `sshd -G`, no `iptables -S` (that, not `nft list ruleset`, is the
  runtime counterpart: nixpi runs the **iptables** backend, `networking.nftables.enable = false`,
  measured), no TCP connect, no ping; an already-flashed Pi also keeps its current generation
  until the next deploy. On 2026-10-01 **every leg was GREEN while the host was unreachable by
  every route** — connector dead, site answering Cloudflare 1033, SSH timing out at banner
  exchange. A green build means "the config still declares the posture it is supposed to", and
  nothing more. Reachability is not checkable from a derivation (a network probe would be
  fixed-output cached, non-hermetic, and would fail CI for every unrelated change during a router
  outage); runtime health belongs to a monitor, and **there is none today**. What that outage DID
  buy is the second-ingress legs above: the config now has to keep declaring a non-tunnel path,
  so the next edit that restores the single point of failure fails the build instead of waiting
  for the next outage to announce itself.
  Four further CONFIG paths are known and deliberately ungated: `networking.firewall.extraCommands`,
  the iptables backend's raw escape hatch (`firewall-iptables.nix:235`), already NON-EMPTY on
  nixpi because the nat module contributes its own teardown preamble, so there is no empty
  baseline to assert against; `extraInputRules`, which is not a path on this host at all — it
  exists only in `firewall-nftables.nix` (`:24-26`, rendered at `:179`), so flipping
  `networking.nftables.enable` moves the whole rule set to a renderer none of these legs read
  and needs NEW legs rather than an edit to these; **UDP**, ports and ranges both, since the
  failure this check exists to catch is an unauthenticated unlogged path to sshd and sshd is
  TCP; and the rest of `sshd_config` — a `Port` smuggled through `extraConfig` is harmless
  here (the allow-lists are pinned per interface) but a `Match` block relaxing an auth
  setting is invisible. Nothing here stops the Pi compiling locally either (`max-jobs` is
  still `auto`), and the Access application itself lives in Cloudflare's API, where its
  2026-08-20 disappearance was invisible to eval then and still is.
- **`modules/nixos/lan-recovery.nix`** — `local.lanRecovery` (default off; `nixpi` turns it on,
  `hosts/nixpi.nix`). **The SECOND INGRESS**, added 2026-10-01 after a dead cloudflared connector
  left the host unreachable by every route — Access healthy and still issuing a login URL, the
  zone healthy, the site answering HTTP 530 / Cloudflare 1033, SSH timing out *during banner
  exchange* — and recovery was a ~40-minute physical SD reflash. `uplink-watchdog.nix` had
  already written the gap down from the other side ("sshd is loopback-bound and the Cloudflare
  tunnel needs working internet, so a dead uplink means no LAN path either"); the watchdog can
  only ever hand the tunnel a working uplink and is powerless when the connector itself dies.
  Two settings, both of them upstream options:
  `services.openssh.listenAddresses = mkForce [ 0.0.0.0, :: ]` and
  `networking.firewall.interfaces.<iface>.allowedTCPPorts = services.openssh.ports` for each
  declared interface. Entry point is **mDNS** — `ssh ismail@nixpi.local`, already published by
  avahi with UDP 5353 already open in `core.nix` — so no address is written down on either side.
  - **The scope is an INTERFACE, not a subnet, and that is the design.** nixpi is dual-homed onto
    one router (`end0` wired, `wlan0` on its SSID) and fails over to a phone HOTSPOT on a
    different, DHCP-assigned subnet, so a rule written against `10.0.0.0/24` is dead in the state
    where it is needed most. Interface names are stable across both states;
    `firewall-iptables.nix:160-165` renders a per-interface entry as `-i <iface>` while the
    `default` pseudo-interface renders with no `-i` at all.
  - **`mkForce`, not an append.** `listenAddresses` is a list, so appending would leave sshd with
    `127.0.0.1` AND `0.0.0.0` on port 22; sshd sets SO_REUSEADDR but not SO_REUSEPORT
    (`sshd.c:844`), the wildcard bind would lose to the specific address with EADDRINUSE, and a
    failed bind is fatal only if EVERY bind fails (`sshd.c:857-863` `continue`s) — so the LAN
    path would silently not exist. Both families are named explicitly and do NOT collide: sshd
    sets `IPV6_V6ONLY` on every AF_INET6 listener (`sshd.c:851-853` via `misc.c:2044-2056`, read
    at the source), so `0.0.0.0` and `::` are two disjoint sockets. An explicit pair beats
    `listenAddresses = [ ]` — same binds, but the empty list is the ACCIDENTAL wildcard this
    fleet guards against. The wildcard covers loopback, so the connector's `localhost:22` dial is
    unaffected.
  - **UPSTREAM FIRST** (grepped the pinned nixpkgs, 2026-10-01). OpenSSH has no
    bind-to-interface keyword, so the scope cannot live in `sshd_config` at all.
    `systemd.sockets.sshd.socketConfig.BindToDevice` was considered and REJECTED: SO_BINDTODEVICE
    is a stronger scope than a filter rule, but one socket unit takes one device, so two
    interfaces mean forking sshd onto `startWhenNeeded` socket activation plus a second
    hand-written unit — a bigger change to the host's SSH lifecycle than the thing it protects.
    An RFC1918 source match via `extraInputRules` was also rejected: that option exists only in
    `firewall-nftables.nix` and nixpi is on iptables, leaving only `extraCommands` (raw shell,
    invisible to every leg of `nixpi-security-posture`). Both candidate segments are private
    already, so the interface IS the RFC1918 scope.
  - **The exposure, stated plainly.** TCP 22 answers on `end0`/`wlan0`, keys-only
    (`PasswordAuthentication`/`KbdInteractiveAuthentication` off, `PermitRootLogin no`), to one
    operator ed25519 key. NOT internet-reachable: no port-forward, no public IP, tunnel
    outbound-only. The real cost is that a LAN connection does **not** traverse Cloudflare
    Access, so it is neither identity-gated nor logged there. Accepted because the segment was
    never zero-exposure — `allowedTCPPorts = [ 80 ]` is the `default` pseudo-interface, i.e. no
    `-i`, so Caddy has always answered on the LAN. This adds a pubkey-gated service beside an
    already-LAN-reachable web server and buys back the 40-minute reflash. It cannot reach a host
    that is off, whose card is corrupt, or whose radio and wired port are both down, and it is no
    help from off-segment; the physical console stays the last break-glass path.
  - Gated by the five second-ingress legs of `checks.<system>.nixpi-security-posture` above,
    which also join the interface list to the two other places those names are spelled.
- **`modules/nixos/nix-cache.nix`** — the binary-cache substituters, as plain
  `nix.settings.extra-substituters`/`extra-trusted-public-keys`: the public `kattakath` Cachix
  cache **and** `install.determinate.systems`, which is where the prebuilt aarch64-linux
  Determinate Nix comes from (a MISS on cache.nixos.org and on Cachix, verified 2026-09-21 —
  without it a NixOS host would build Nix from C++ source, and **`nixpi` must never build**).
  Wired into `mkNixos`'s module list only (`modules/parts/compose.nix:299`); the Mac gets the
  same cache through `determinateNix.customSettings` because Determinate owns its `nix.conf`.
  **It lived in `modules/shared/` until 2026-10-02** while its own line 3 said
  *"NixOS-ONLY module"* — ADR-009 §9b; moved here so the directory and the header agree.
- **`modules/nixos/desktop-vm.nix`** — opt-in `services.desktopVm.enable` (default false): a lightweight X11
  **XFCE** desktop with passwordless autologin (the `loginName` specialArg) plus QEMU/SPICE
  guest integration (`qemuGuest`, `spice-vdagentd`) for the `nixvm` sandbox.
  `hosts/nixvm.nix` enables it **only inside `virtualisation.vmVariant`**, so the desktop
  materialises for the graphical `nix run .#nixvm` / `build-vm` path — the sole way `nixvm` is
  ever booted. Its `systemPackages` are deliberately two browsers plus a terminal: **plain
  `chromium`, not `ungoogled-chromium`** — ungoogled patches out the Chrome Web Store and
  swaps the Google search engine for a "No Search" stub (both measured in
  `modules/home/chromium.nix`), and nixpkgs enables Widevine only for plain chromium, so
  all three cut against a guest whose point is signing into Google. `opera` is not an option
  at all: nixpkgs removed it 2025-05-19, so the name *throws* at eval on every system. Both
  browsers substitute from `cache.nixos.org` for aarch64-linux, so neither is ever built on
  the 1-CPU native Linux builder — but chromium adds ~856 MiB of incremental closure that the
  erofs store image re-materialises on **every** boot.
- **`modules/nixos/uplink-watchdog.nix`** — `local.uplinkWatchdog` (default off; `nixpi` turns
  it on), a systemd timer + oneshot for the failure where the ROUTER keeps its LAN alive but
  loses its uplink: `end0` keeps carrier so dhcpcd keeps a default route, `wlan0` stays
  associated because the AP is still beaconing, and **both paths are dead with nothing
  noticing**. A route-metric change cannot fix it — both default routes terminate on the same
  router. Upstream-first came back empty (grepped the pinned nixpkgs 2026-09-22: `dhcpcd.nix`
  exposes no metric/nogateway option, `RouteMetric` is networkd-only and this host runs
  scripted networking, and nothing under `services/networking/` does connectivity-based
  failover), so the probe-and-escalate loop is genuinely ours and deliberately small. It
  probes the DEFAULT ROUTE (never a specific interface — `curl --interface wlan0` fails
  whenever wlan0 does not own the route, reporting a healthy link as dead) against two IP
  literals, since DNS may be the broken thing. After `failuresBeforeAction` consecutive
  failures a three-step ladder runs, each step verified by the next probe rather than
  assumed: **demote the wired default route** → **invert the Wi-Fi priorities onto the
  fallback network** → **restore the shipped configuration** and start over. Everything is
  written to the RUNTIME `wpa_supplicant.conf` only; the card's copy on the FAT `FIRMWARE`
  partition stays the source of truth, so the worst case of any escalation is one supplicant
  restart, and a reboot undoes it. Gated by `checks.<system>.uplink-watchdog-paths-agree`,
  which fails if the watchdog and `local.firmwareProvisioning.files.wifi` stop naming the
  same runtime file, planted filename, or ordered-before unit — and, since 2026-10-01, if either
  of those interface names stops matching `local.lanRecovery.interfaces`. **It cannot conjure an
  uplink** — the fallback AP only helps while it is actually broadcasting, and a phone
  hotspot that sleeps with no client attached is not an unattended backup. **Nor is it a
  connector watchdog:** it only ever hands the tunnel a working uplink, so it did nothing for the
  2026-10-01 outage, where the uplink was fine and `cloudflared` itself was the dead part. That
  is `lan-recovery.nix`'s job, not this one's.
  - **CORRECTION to the #717 story — the bug froze the LADDER, it never removed the default
    route.** PR #717's title and body say the escalation left nixpi with "NO DEFAULT ROUTE,
    permanently". That is **false**, and it is recorded here because a PR title cannot be edited
    while this map can. Two independent refutations, either sufficient:
    1. The route re-add was `restore()`'s **first** statement and ended `|| true`, so the
       `set -euo pipefail` abort could never reach it. It was unabortable.
    2. Stronger: step 2's delete was `ip route del default dev <wiredInterface>` — **dev-scoped
       to `end0`**. dhcpcd independently installs a SECOND default on `wlan0`, measured live on
       the Pi at metric **3003** against `end0`'s **1002**, both from dhcpcd with no
       configuration of ours. Deleting the wired leg therefore left a default route in place
       throughout. **There was never a moment without one.**

    **What actually broke:** `set_state normal` sits at the END of `restore()`, after the step
    that aborted — so the state file froze at `wired-demoted` forever, every later cycle
    re-entered step 3 and died on the same line, and **step 1, the hotspot grab, never ran
    again.** Why the distinction is worth a paragraph and not a footnote: *"no default route"*
    describes a host that can reach nothing and needs hands on the hardware; *"frozen ladder"*
    describes a host that still routes fine and has silently lost its failover. At 3am those
    send you to opposite places, and the first sends you to the SD card for nothing.
  - **And the 2026-09-23 outage was NOT this module** — it was not even running. `nixos-rebuild
    list-generations` on the dead card showed **generation 1 only**, nixpkgs dated **09-07**,
    while `local.uplinkWatchdog` was born 2026-09-22 and no deploy ever landed. Every symptom
    first blamed on the watchdog came from **hand edits made over SSH** to
    `/boot/firmware/wpa_supplicant.conf`, including the inverted Wi-Fi priorities that actually
    stranded the host. Blaming the module is blaming code that was not on the machine — and the
    general rule is the one in [`false-success-signals.md`](../false-success-signals.md): confirm a
    change is DEPLOYED before attributing a symptom to it.

## NixOS modules that are not in `modules/nixos/`

Both are in-tree capsules (`modules/features/`), and both are threaded into
`hosts/nixpi.nix` through `mkNixos` specialArgs as an already-resolved MODULE — never as a
flake, and never imported by path from the host.

- **`modules/features/cloudflared-connector/`** (an IN-TREE CAPSULE, not an input — it was
  the `nix-cloudflared-connector` flake until ADR-002 wave 3 absorbed it) — opt-in
  `local.cloudflaredConnector.enable`
  (default false); hardened `systemd.services.cloudflared-connector` running a
  **remotely-managed (token)** Cloudflare Tunnel — no `cloudflared tunnel login`, no cert.pem.
  Token read from `tokenFile` (module default `/etc/secrets/cloudflared-token`,
  operator-placed), never in git; an activation script warns (doesn't abort) if absent. Only
  `nixpi` enables it — and `nixpi` **overrides `tokenFile` to `/run/cloudflared-token`**, a
  root-only file that `local.firmwareProvisioning` populates at boot from the token
  operator-planted on the SD card's FAT `FIRMWARE` partition. This deliberately replaced
  agenix: agenix binds the token to nixpi's SSH host key, but a fresh SD flash rotates that
  key, breaking decryption and killing the tunnel — the sole remote path in.
  Reached through the flake's own `flake.modules.nixos` registry (flake-parts
  `extras/modules.nix`), threaded into `hosts/nixpi.nix` by `mkNixos` specialArgs as
  `cloudflaredConnectorModule`. Its own eval check came with it
  (`checks.aarch64-linux.cloudflared-connector-module`),
  and `checks.aarch64-linux.nixpi-firmware-names` pins the four unit/`/run` names the next SD
  flash depends on, because a rename there is invisible to `nix flake check` AND to
  `--dry-activate` on an already-provisioned card.
- **`modules/features/firmware-secrets/`** (an IN-TREE CAPSULE — it was extracted from this
  repo into the standalone MIT `nix-firmware-secrets` flake, then absorbed back by ADR-002
  wave 4) — `local.firmwareProvisioning`, a reusable `files.<name>` mechanism: each entry
  becomes a oneshot that, once `/boot/firmware` is mounted, copies an operator-planted file off
  the FAT `FIRMWARE` partition into a root-only `/run` file before its consumer starts
  (`required` fails the unit if absent; else it skips cleanly). `nixpi` uses it for BOTH the
  Cloudflare connector token AND Wi-Fi (`wpa_supplicant.conf`) — host-key-independent secrets a
  fresh SD flash needs, since agenix (which binds to the rotated host key) would lock us out.
  Planted from macOS by the `nixpi-provision`/`nixpi-flash` apps. Reached through
  `flake.modules.nixos` and threaded into `hosts/nixpi.nix` by `mkNixos` specialArgs as
  `firmwareSecretsModule`; its own eval check came with it
  (`checks.aarch64-linux.firmware-secrets-module`). **Two things did NOT come along:** the
  satellite's `apps/firmware-plant.nix` (a second, unused copy of what
  `packages/nixpi-provision.nix` already does — two copies of one procedure is two chances for
  the planted basenames to drift) and its `examples/pi-cloudflared.nix` (a stale sketch;
  `hosts/nixpi.nix` is the real example, and it is evaluated on every PR).

## Web serving on `nixpi`

Uses upstream `services.caddy.virtualHosts` directly (in `hosts/nixpi.nix`), **no wrapper
module**: one `http://<domain>` vhost per `mkNixos`'s `hostedSites` parameter, each
`file_server`ing its `root`. `hostedSites` still defaults to `[ ]` (the parameter stays generic),
but `modules/parts/hosts.nix`'s own `nixpi` call passes the real list directly
(`config.fleet.hostedSites`, `modules/parts/identity.nix`) since the private nix-personal flake
that used to supply it was retired 2026-09-15. It is **one site** today — `snoringirl.com` —
down from four: `dontsell.ai`'s apex moved to Vercel 2026-09-06 (its terranix module deleted
2026-09-14), `kattakath.com` left for GitHub Pages 2026-09-07, and `ismail.kattakath.com`
followed on **2026-09-16**, moved off the Pi while nixpi was down so the landing page stops
depending on it. That last one is served by the `kattakath/ismail-landing` repo now, and its DNS
is a plain **CNAME → `kattakath.github.io` (DNS-only)** declared in
`infra/cloudflare/kattakath-dns.nix` — no longer a proxied tunnel CNAME rendered here.

**`sites/ismail-landing` stays in the tree regardless** — absent from `hostedSites` means "Caddy
no longer serves it", not "nothing reads it": its `fonts/` subdir is LIVE, read by
`modules/home/next-right-thing.nix` for the übersicht widget's typography.

One site also means the `cf-tunnel` **≤2-ingress site-free floor can never fire for it** — this
render carries three entries (SSH + the site + the mandatory catch-all 404). That floor is an
absolute "is the render blank" check, not a diff against what is live; the guard that catches a
single silently-dropped site is the **dropped-record** check beside it, which compares the
addresses state holds against the addresses the render declares and refuses on any drop.

Caddy sits **behind** the Cloudflare Tunnel (tunnel → Caddy on :80), so no
public IP/port-forward is needed and TLS terminates at Cloudflare's edge (the `http://` prefix
disables Caddy auto-HTTPS to avoid a redirect loop back through the tunnel).

