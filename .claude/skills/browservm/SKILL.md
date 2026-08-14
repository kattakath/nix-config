---
name: browservm
description: >
  Ephemeral headless-Chromium automation guest booted via microvm.nix's vfkit backend (Apple Virtualization Framework, no nesting).
  Use when: booting/stopping browservm, SSH from the Mac into the guest, driving Chromium inside it for browser automation, or a fresh-login flow via X11 forwarding.
---

# browservm

Canonical detail: [`docs/browservm-runbook.md`](../../../docs/browservm-runbook.md).

| Layer | Where | Notes |
|---|---|---|
| Hypervisor + runner | **Host** (`macos`) | microvm.nix's `vfkit` backend + Apple Virtualization; NO persistent disk |
| Guest NixOS | `nixosConfigurations.browservm` | Chromium + sshd, rebuilt from the Nix store every boot |
| Networking | Host ↔ guest, shared `vmnet` subnet | `192.168.64.0/24` — same subnet Tart's `macvm` uses; direct IP reachability verified live (0% ICMP loss) for SSH. **CDP (9222) is loopback-only in the guest** (Chromium ignores `--remote-debugging-address` — verified live) — reach it via `ssh -L`, not the guest IP directly |

`browservm` ≠ `nixvm` (throwaway XFCE desktop) ≠ `macvm` (persistent macOS guest
via Tart). There is **no create step** — `browservm-vfkit-start` builds and boots
the guest fresh every time.

## Day-to-day

```bash
nix run .#browservm-vfkit-start    # boot fresh, prints guest IP
nix run .#browservm-vfkit-status   # running state + IP
nix run .#browservm-vfkit-ip
nix run .#browservm-vfkit-ssh      # pass -X yourself for X11 forwarding (needs XQuartz)
nix run .#browservm-vfkit-stop
```

## Driving Chromium (not auto-started — the control-plane only owns the VM)

Headless, for routine/pipeline runs — launch, then tunnel CDP to the host:

```bash
nix run .#browservm-vfkit-ssh -- \
  'nohup chromium --headless=new --no-sandbox --remote-debugging-port=9222 \
     >/tmp/chromium.log 2>&1 & disown'
nix run .#browservm-vfkit-ssh -- -L 9222:127.0.0.1:9222 -N &
```

Then point `automation-session` at `http://127.0.0.1:9222` (the forwarded
port) for the Keychain `seed`/`capture` flow (see docs/automation-browser.md).

Fresh login (no valid storageState yet): combine `-X` (display forwarding,
needs no X server in the guest — ssh tunnels the protocol to XQuartz on the
host) with `-L` (CDP forwarding) in one session:

```bash
nix run .#browservm-vfkit-ssh -- -X -L 9222:127.0.0.1:9222 -- \
  chromium --remote-debugging-port=9222
```

Log in visually, then `automation-session login <site>` (pointed at
`http://127.0.0.1:9222`) captures the session into the Keychain.

## Do not

- Expect a `browservm-vfkit-create` — there's nothing to create; `start` builds
  and boots from scratch every time.
- Assume Chromium is running after `start` — launch it yourself over SSH.
- Confuse with `nixvm` or `macvm` — three different products.
