---
name: nixvm-ssh-loopback-2222
description: ssh -p 2222 localhost into nixvm needs THREE changes together (forward + bind + firewall), all in vmVariant so the base toplevel stays loopback-only. host.address is what keeps it off the LAN.
metadata:
  type: project
---

`ssh -p 2222 ismail@localhost` from the Mac reaches `nixvm`. Landed `d0ea8d8` (2026-10-06), all
three changes inside `virtualisation.vmVariant` in `hosts/nixvm.nix`.

**Why all three, together — each alone is inert:**

| Change | Alone it fails because |
|---|---|
| `virtualisation.forwardPorts` (`host.address = "127.0.0.1"`, `host.port = 2222`, `guest.port = 22`) | SLiRP delivers a hostfwd to the guest's **NIC** address (10.0.2.15), and `core.nix` binds sshd to `127.0.0.1` + `::1` only — a loopback sshd never sees it |
| `services.openssh.listenAddresses = lib.mkForce [ { addr = "0.0.0.0"; } ]` | `core.nix` sets `openFirewall = false` and the base firewall opens no TCP port globally, so the SYN is dropped |
| `services.openssh.openFirewall = lib.mkForce true` | nothing listens on the Mac without the forward |

`mkForce` on both openssh lines because `core.nix` **assigns** them (not `mkDefault`) — a plain
definition is a conflict, not an override.

**`host.address` is the whole safety story.** It is emitted verbatim into
`hostfwd=${proto}:${host.address}:…` (`qemu-vm.nix:1264`), giving
`hostfwd=tcp:127.0.0.1:2222-:22`, so SLiRP binds the Mac's loopback alone. Its default is `""`,
which would bind **every** Mac interface. Verified present at the pin: `forwardPorts` option
`qemu-vm.nix:632`, `host.address` at `:659`.

**IPv4 wildcard only, not nixpi's `0.0.0.0` + `::` pair.** QEMU forwards IPv4 exclusively
("Currently QEMU supports only IPv4 forwarding", the option's own description), so a v6 bind
would listen for traffic that cannot arrive — and it sidesteps the `ListenAddress ::1:22` parse
trap `core.nix:73-82` documents. `port` is omitted for the same reason.

**How to apply:** keep this in `vmVariant`. Do **not** relax `modules/nixos/core.nix` — its
loopback default is what keeps nixvm's **base** toplevel (what `nix flake check` builds, and
what every `lib.mkNixos` consumer inherits) and `nixpi` safe. Proven unregressed 2026-10-06:
base `listenAddresses` = `[{127.0.0.1},{::1}]`, base `openFirewall` = `false`, base
`allowedTCPPorts` = `[]`; vmVariant = `[{0.0.0.0}]`, `true`, `[22]`.
`checks.*.nixpi-security-posture` green on both systems.

Auth is unchanged and **key-only** — `PasswordAuthentication` / `KbdInteractiveAuthentication`
false, `PermitRootLogin "no"`, operator key already delivered by `mkNixos`. Note this interacts
with [[nixvm-autologin-locker-lockout-trap]]: there is **no password**, so SSH is key-only by
necessity, not just policy.

**Known annoyance:** deleting the qcow2 regenerates the guest host key, so the next connect
warns `REMOTE HOST IDENTIFICATION HAS CHANGED`. Fix: `ssh-keygen -R "[localhost]:2222"`.
**No Mac-side `~/.ssh/config` entry exists** — deliberately out of scope.
