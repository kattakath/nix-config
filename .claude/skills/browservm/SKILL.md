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
nix run .#browservm-vfkit-up       # PRIMARY: boot (if needed) + wait for IP +
                                    # open/reuse the CDP tunnel + block until
                                    # Chromium answers. Run this before driving
                                    # anything with the playwright MCP.
nix run .#browservm-vfkit-start    # boot fresh only, prints guest IP
nix run .#browservm-vfkit-status   # running state + IP + CDP tunnel state
nix run .#browservm-vfkit-ip
nix run .#browservm-vfkit-ssh      # pass -X yourself for X11 forwarding (needs XQuartz)
nix run .#browservm-vfkit-stop     # tears down the VM AND the CDP tunnel
```

## Driving Chromium (auto-started as `browser-cdp.service`)

Normal flow: `nix run .#browservm-vfkit-up`, then point `automation-session`
(`login|seed|capture|status [site]`) or the `playwright` MCP at
`http://127.0.0.1:9222` — no manual launch/tunnel step needed.

Fresh login (no valid storageState yet, or a captured session expired) needs a
*headed* Chromium, which conflicts with the always-on headless service on the
same port — stop it first, do the visual login, restart it after:

```bash
nix run .#browservm-vfkit-ssh -- sudo systemctl stop browser-cdp
nix run .#browservm-vfkit-ssh -- -X -L 9222:127.0.0.1:9222 -- \
  chromium --remote-debugging-port=9222
# log in visually, then from the host: automation-session login <site>
nix run .#browservm-vfkit-ssh -- sudo systemctl start browser-cdp
```

X11 forwarding needs no X server in the guest — `ssh -X` tunnels the protocol
to XQuartz on the host.

## Do not

- Expect a `browservm-vfkit-create` — there's nothing to create; `start` builds
  and boots from scratch every time.
- Reach for the manual start+ssh+tunnel sequence for a normal job — use
  `browservm-vfkit-up`; the manual form is for debugging or the headed login
  flow above only.
- Confuse with `nixvm` or `macvm` — three different products.
- Reach for this skill/tool without checking
  [`.claude/rules/browser-automation-tool-choice.md`](../../rules/browser-automation-tool-choice.md)
  first if the task might instead be about the user's own live Chrome
  (`claude-in-chrome`), Opera in `macvm` (`opera-browser-connector`), or an
  explicit Kapture request.
