# browservm runbook (vfkit / Apple Virtualization)

Two layers — do not conflate:

| Layer | Owner | Notes |
|---|---|---|
| **Hypervisor + runner** | **vfkit** (via microvm.nix), on the **macos** host | Apple **Virtualization.framework** directly — no nesting, same tier as Tart (`macvm`) and Determinate's native Linux builder |
| **Guest NixOS** | `nixosConfigurations.browservm` | Headless Chromium + sshd; **no persistent disk at all** |

Unlike `macvm` (a persistent Tart disk under `~/.tart/`), browservm has **nothing to
create and nothing to wipe** — `browservm-vfkit-start` builds the guest fresh from
the Nix store and boots it every single time. There is no `create`/`ensure` step.

`nix run .#nixvm` is a different product (throwaway XFCE desktop via QEMU).
`macvm` is a different product (persistent macOS guest via Tart). **browservm is
none of those** — it's the disposable browser-automation guest.

## Prerequisites (host)

- `macos` activated.
- Determinate's **native Linux builder** active (`determinate-nixd version` must
  list `native-linux-builder`) — building the aarch64-linux guest closure needs
  it. If it's missing despite an account-level grant, the daemon likely isn't
  logged in to FlakeHub locally: see the auth-gotcha note in
  [`docs/mac-key-recovery-runbook.md`](mac-key-recovery-runbook.md).
- Operator SSH key at `~/.ssh/id_ed25519` (same key every host in this fleet uses).
- For the headed/login flow only: [XQuartz](https://www.xquartz.org/) installed
  and running as the local X11 display.

## Day-to-day

```bash
nix run .#browservm-vfkit-up        # ONE SHOT: boot (if needed) + wait for IP +
                                     # open the CDP tunnel + wait for Chromium to
                                     # answer. This is the primary entrypoint —
                                     # use this before automation-session/playwright.
nix run .#browservm-vfkit-start     # boot fresh only, prints the guest's IP once DHCP lands
nix run .#browservm-vfkit-status    # running state + current IP + CDP tunnel state
nix run .#browservm-vfkit-ip        # just the IP (waits up to 30s by default)
nix run .#browservm-vfkit-ssh       # SSH in (operator key, same login as nixpi/nixvm)
nix run .#browservm-vfkit-stop      # tear down (VM + tunnel) — nothing persists outside the Keychain
```

## Networking — verified, not assumed

vfkit's default guest networking rides macOS's `vmnet` **shared** subnet
(`192.168.64.0/24`) — the exact same subnet Tart's `macvm` already uses
(`hosts/macvm.nix`'s bridge). This was verified live, not taken on faith: a
`vfkit`-booted guest landed on `192.168.64.4` and answered ICMP pings from the
host with 0% packet loss. So despite vfkit's networking mode being called "NAT,"
the host and guest are direct peers on the same L3 segment — no port-forwarding,
no vsock, no nested virtualization required to reach the guest's SSH or CDP
(`9222`) ports.

`browservm-vfkit-ip`/`-ssh`/`-status` discover the guest's current IP by reading
macOS's own DHCP lease file, `/var/db/dhcpd_leases` (the same file backing
Tart's leases too — look for a `{ name=browservm ... }` block).

## Driving Chromium

The guest runs a `browser-cdp.service` systemd unit (`hosts/browservm.nix`) that
auto-starts headless `ungoogled-chromium` with CDP on boot — no manual launch
step. `browservm-vfkit-up` boots the VM, waits for the unit to actually answer,
and opens the CDP tunnel in one call; you should not need anything below this
line for the normal flow.

**CDP access needs an SSH tunnel, not a direct `guest-ip:9222` dial** — verified
live: modern Chromium ignores `--remote-debugging-address=0.0.0.0` and binds
DevTools to `127.0.0.1` only, regardless of that flag (deliberate hardening —
an exposed debug port is a known RCE vector, not a config bug on our end).
`browservm-vfkit-up` opens this tunnel for you; the manual form (for
debugging, or the `-X` login flow below) is:

```bash
nix run .#browservm-vfkit-ssh -- -L 9222:127.0.0.1:9222 -N &
# now http://127.0.0.1:9222 on the HOST reaches the guest's Chromium
```

Point `automation-session`'s `connectOverCDP` at that forwarded
`http://127.0.0.1:9222` for the Keychain-backed `seed`/`capture` flow (see
`docs/automation-browser.md`).

### Fresh login (no valid storageState yet, or a captured session expired)

The always-on `browser-cdp.service` is headless and already holds port 9222,
so a *headed* login session needs it stopped first (it restarts on its own —
`Restart = "on-failure"` — but not while you're mid-login, so stop it
explicitly rather than racing it):

```bash
nix run .#browservm-vfkit-ssh -- sudo systemctl stop browser-cdp
```

X11 forwarding does **not** need an X server running in the guest — `ssh -X`
tunnels the X11 protocol back to XQuartz on the host, so Chromium just needs
`$DISPLAY` set to whatever ssh provides. Combine `-X` (display forwarding)
with `-L` (CDP forwarding) in the same SSH session, since `automation-session
capture`/`login` needs CDP either way:

```bash
nix run .#browservm-vfkit-ssh -- -X -L 9222:127.0.0.1:9222 -- \
  chromium --remote-debugging-port=9222
```

Log in visually in the forwarded window, then run `automation-session login
<site>` from the host (pointed at `http://127.0.0.1:9222`, the forwarded port)
to capture the session into the Keychain. Afterwards, restart the headless
service for future headless runs:

```bash
nix run .#browservm-vfkit-ssh -- sudo systemctl start browser-cdp
```

## Commands

| App | Role |
|---|---|
| `browservm-vfkit-up` | **Primary entrypoint.** Boot (if needed) + wait for IP + open/reuse the CDP tunnel + block until Chromium answers |
| `browservm-vfkit-start` | Boot fresh from the Nix store only (no create step — this IS create-and-run) |
| `browservm-vfkit-stop` | Kill the tracked runner process + CDP tunnel |
| `browservm-vfkit-ip` | Print the guest's current IP (from `dhcpd_leases`) |
| `browservm-vfkit-ssh` | SSH in; pass `-X` yourself for X11 forwarding |
| `browservm-vfkit-status` | Running state + IP + CDP tunnel state + backend info |

## What not to do

- Don't expect a `browservm-vfkit-create` — there's nothing to create; `start` IS
  the whole lifecycle (build + boot), every time, from scratch.
- Don't confuse with `nix run .#nixvm` (throwaway XFCE desktop) or `macvm`
  (persistent macOS guest via Tart) — three different products, three different
  purposes.
- Don't reach for `browservm-vfkit-start` + a manual SSH tunnel for a normal
  automation job — use `browservm-vfkit-up`, which does both and waits for
  Chromium to actually answer before returning. The manual sequence is now
  only for debugging or the headed "Fresh login" flow above.
- For which browser-automation tool to reach for in the first place (this one
  vs. `claude-in-chrome` vs. `opera-browser-connector` vs. `kapture`), see
  [`.claude/rules/browser-automation-tool-choice.md`](../.claude/rules/browser-automation-tool-choice.md).

## Source map

| Piece | Path |
|---|---|
| Host control-plane | `packages/browservm-vfkit.nix` |
| Guest profile | `hosts/browservm.nix` |
| Agent skill | `.claude/skills/browservm/SKILL.md` |
