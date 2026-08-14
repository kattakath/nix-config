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
nix run .#browservm-vfkit-start     # boot fresh, prints the guest's IP once DHCP lands
nix run .#browservm-vfkit-status    # running state + current IP
nix run .#browservm-vfkit-ip        # just the IP (waits up to 30s by default)
nix run .#browservm-vfkit-ssh       # SSH in (operator key, same login as nixpi/nixvm)
nix run .#browservm-vfkit-stop      # tear down — nothing persists outside the Keychain
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

The guest config installs `ungoogled-chromium` but does **not** auto-start it —
that keeps this control-plane scoped to VM lifecycle only (matching
`macvm-tart.nix`'s scope: it doesn't manage what runs *inside* the guest either).
Launch it yourself over SSH once the guest is up:

```bash
nix run .#browservm-vfkit-ssh -- \
  'nohup chromium --headless=new --no-sandbox --remote-debugging-port=9222 \
     >/tmp/chromium.log 2>&1 & disown'
```

**CDP access needs an SSH tunnel, not a direct `guest-ip:9222` dial** — verified
live: modern Chromium ignores `--remote-debugging-address=0.0.0.0` and binds
DevTools to `127.0.0.1` only, regardless of that flag (deliberate hardening —
an exposed debug port is a known RCE vector, not a config bug on our end). Reach
it with a local port-forward:

```bash
nix run .#browservm-vfkit-ssh -- -L 9222:127.0.0.1:9222 -N &
# now http://127.0.0.1:9222 on the HOST reaches the guest's Chromium
```

Point `automation-session`'s `connectOverCDP` at that forwarded
`http://127.0.0.1:9222` — same Keychain-backed `seed`/`capture` flow as the
same-host `chrome-automation` path (see `docs/automation-browser.md`), just
tunneled rather than truly local. (This also means the guest and same-host paths
can't both use port 9222 on the host at once — pick a different local port for
the forward, e.g. `-L 9223:127.0.0.1:9222`, if you need both running.)

### Fresh login (no valid storageState yet, or a captured session expired)

X11 forwarding does **not** need an X server running in the guest — `ssh -X`
tunnels the X11 protocol back to XQuartz on the host, so Chromium just needs
`$DISPLAY` set to whatever ssh provides:

Combine `-X` (display forwarding) with `-L` (CDP forwarding) in the same SSH
session, since `automation-session capture`/`login` needs CDP either way:

```bash
nix run .#browservm-vfkit-ssh -- -X -L 9222:127.0.0.1:9222 -- \
  chromium --remote-debugging-port=9222
```

Log in visually in the forwarded window, then run `automation-session login
<site>` from the host (pointed at `http://127.0.0.1:9222`, the forwarded port)
to capture the session into
the Keychain — future runs go through the headless flow above instead.

## Commands

| App | Role |
|---|---|
| `browservm-vfkit-start` | Boot fresh from the Nix store (no create step — this IS create-and-run) |
| `browservm-vfkit-stop` | Kill the tracked runner process |
| `browservm-vfkit-ip` | Print the guest's current IP (from `dhcpd_leases`) |
| `browservm-vfkit-ssh` | SSH in; pass `-X` yourself for X11 forwarding |
| `browservm-vfkit-status` | Running state + IP + backend info |

## What not to do

- Don't expect a `browservm-vfkit-create` — there's nothing to create; `start` IS
  the whole lifecycle (build + boot), every time, from scratch.
- Don't confuse with `nix run .#nixvm` (throwaway XFCE desktop) or `macvm`
  (persistent macOS guest via Tart) — three different products, three different
  purposes.
- Don't assume the guest's Chromium is already running after `start` — launch it
  yourself (see "Driving Chromium" above); the control-plane only owns the VM,
  not what runs inside it.

## Source map

| Piece | Path |
|---|---|
| Host control-plane | `packages/browservm-vfkit.nix` |
| Guest profile | `hosts/browservm.nix` |
| Agent skill | `.claude/skills/browservm/SKILL.md` |
