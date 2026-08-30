# Repo map — the full fleet architecture

The detail behind [`CLAUDE.md`](../CLAUDE.md) § Overview and § Navigating the Codebase.
`CLAUDE.md` stays a scannable index (one line per path); this file holds the *why* and the
per-path specifics. **Update both together** — a path that changes shape here needs its
one-liner in `CLAUDE.md` refreshed too.

Two sibling docs carry the surfaces that outgrew this map:
[`mcp-gateway.md`](mcp-gateway.md) (the MCP server inventory) and
[`secrets-and-keychain.md`](secrets-and-keychain.md) (agenix + Keychain).

## The fleet

All-in-one Nix mono-repo managing a fully declarative **aarch64-only** fleet:

- **`macos`** (aarch64-darwin) — macOS/nix-darwin, the sole client Mac. No remote/incoming
  traffic; it is the SSH *client*, reaching `nixpi` via `cloudflared access ssh` over the
  tunnel, and builds `aarch64-linux` locally on Determinate's native Linux builder.
- **`nixpi`** (aarch64-linux) — NixOS Raspberry Pi 4, the **LIVE server**: static-key SSH
  over a Cloudflare Tunnel connector + Caddy. Generic and **site-free in this public repo** —
  the real hosted sites and dontsell.ai's second tunnel connector are supplied by the private
  nix-personal composition flake (see [`private-home-modules.md`](private-home-modules.md)).
- **`nixvm`** (aarch64-linux) — a throwaway NixOS dev VM materialised **only** as
  `nix run .#nixvm` (a build-vm XFCE desktop — no installed VM, no builder, no runner).
- **`macvm`** (aarch64-darwin) — a Tart guest on Apple Virtualization that shares macos's
  stack with a leaner Homebrew set + the MCP gateway trimmed off, activated *inside* the VM
  under the same operator identity as every other host.
- A matching **Devcontainer** image.

Single source of truth; platform divergence lives in `modules/`, never in ad-hoc shell.

## Entry points

### `flake.nix`

Pins `nixpkgs` + `nix-darwin` + `home-manager` + `treefmt-nix` + `git-hooks` +
`raspberry-pi-nix` + `nix-vscode-extensions` + `nix-homebrew` + `agenix` + Claude Code skill
inputs (`agent-skills-vercel`, `agent-skills-anthropic`, both `flake = false`).

Exports:

- `darwinConfigurations."macos"` / `"macvm"` (aarch64-darwin) — `macvm` is a Tart guest VM
  (Apple Virtualization + IPSW) sharing macos's stack with a leaner Homebrew set + the MCP
  gateway trimmed off.
- `nixosConfigurations."nixpi"` / `"nixvm"` (aarch64-linux) — `nixvm` is the throwaway GUI dev
  VM, materialised only via `nix run .#nixvm`.
- `packages` / `devShells` / `checks` / `formatter` per system via a `forAllSystems` helper.

There is **no `nixpi-installer`** — the LIVE `nixpi` sdImage is secret-free, so it *is* the
flashable artifact, prebuilt in CI as the `nixpi-sd-image` package and published to the
`installer-latest` release; token + Wi-Fi are planted post-flash on the FIRMWARE partition.

The FLEET is two systems: `aarch64-darwin` and `aarch64-linux` — **no x86_64 HOST anywhere**.
The devcontainer image is the sole exception: it also builds `x86_64-linux` (via
`devcontainerSystems`) so it runs on x86_64 GitHub Codespaces.

**Identity** (`loginName = "ismail"`, `domainName = "kattakath.com"`, `fullName`, `userEmail`)
is defined once as `let` bindings (`identityArgs`) and threaded through
`specialArgs`/`extraSpecialArgs`. `mkDarwin` takes an optional per-host `identity` override
(and `mkHomeManagerModule` is a function of it) so a host *could* run under a different
persona, but nothing in the fleet uses it today — `macos`, `macvm`, and `nixpi` all inherit
the same global identity; per-host divergence (leanness, package sets, desktop aesthetics) is
achieved entirely via `networking.hostName`-gated `lib.mkIf`, never via a separate identity.

### `flake.lock`

Pinned input revisions; commit every change, never hand-edit.

### `treefmt.nix`

Single source of truth for formatting + lint-fix (nixfmt + statix + deadnix). Drives
`nix fmt`, the `checks.formatting` CI gate, and the pre-commit hook — change a tool here and
every entrypoint follows.

### devShell

Entered with `nix develop` (in the devcontainer or on a nix host). There is **no**
`.envrc`/direnv auto-load — run `nix develop` explicitly.

### `secrets/secrets.nix`

agenix recipients rules — **two** committed secrets on **two different models**:

- `secrets/cloudflared-token.age` (nixpi's Cloudflare tunnel token) — encrypted to the
  **operator's key alone**, the **operator-only vault** model: the operator decrypts it on the
  Mac to plant on the SD card's FAT `FIRMWARE` partition, and it is NEVER decrypted on nixpi.
- `secrets/gh-app-dontsell-ai-key.age` (the `macos` runner's GitHub App RS256 private key) —
  recipients are operator **+ the `macos` host key**, so this one IS **host-decrypted at
  activation** into `/run/agenix/`. The host-decryption path is live; do not describe it as
  unused.

Both are safe to commit. Full rules: [`secrets-and-keychain.md`](secrets-and-keychain.md).

## `hosts/` — per-host entry profiles

- **`macos.nix`** — the darwin client host. Imports `../modules/darwin/github-runner.nix` and
  enables `services.macosGithubRunner` with `count = 2` for the **`dontsell-ai`** org (see that
  module's section below) — nix-config's *own* CI is fully GitHub-hosted and uses no runner, but
  this Mac is not runner-free. Carries its own Homebrew brew/cask/masApps lists, incl. a
  `libreoffice` cask backing the docx/pptx/xlsx/pdf Claude Code skills' `soffice` dependency.
- **`macvm.nix`** — Tart aarch64-darwin guest: leaner Homebrew, no masApps, MCP gateway +
  desktop aesthetics off, red accent tell. Same operator identity as every host, no `identity`
  override; activated *inside* the VM as `ismail`. Host→guest SSH is Apple's sshd via
  `services.openssh` + keys-only operator key + ALF off. Host control plane
  `packages/macvm-tart.nix` / `nix run .#macvm-tart-*`; clipboard sync + `tart exec` /
  `tart ip --resolver=agent` RPC via the `packages/tart-guest-agent.nix`-backed
  `launchd.user.agents.tart-guest-agent`. Runbook: [`macvm-tart-runbook.md`](macvm-tart-runbook.md).
- **`nixpi.nix`** — Pi 4, LIVE: boot fixes + cloudflared + upstream `services.caddy`. Its
  `sdImage` is prebuilt in CI and published to the `installer-latest` release, since it bakes
  no secrets.
- **`nixvm.nix`** — a SLIM throwaway aarch64-linux dev VM: no disko, no runner, no install;
  materialised only as the graphical `nix run .#nixvm` build-vm, whose guest builds locally on
  the native Linux builder or substitutes from Cachix.

## `modules/` — reusable modules split by platform

Platform branching lives **here** behind `lib.mkIf`, not duplicated across hosts.

### `modules/shared/`

`modules/shared/{home.nix,mcp.nix,desktop-aesthetics.nix,nix-cache.nix,nix-ld-libraries.nix,wireguard-configs.nix,claude-otel.nix,hm-launchd/}`
— the Home Manager profile loaded on every host.

- **`home.nix`** — git/ssh-signing, zsh+starship, direnv, gh, bash, claude-code + nerd-fonts;
  darwin-only ssh/vscode blocks gated `lib.mkIf pkgs.stdenv.isDarwin`. Host-gated: RAG
  (ollama/pgvector) + public MCP tunnel only when `networking.hostName == "macos"`.
  `home.packages` also carries `pandoc`/`poppler` (nixpkgs, darwin-only) — together with
  macos's `libreoffice` cask, these satisfy the docx/pptx/xlsx/pdf skills' stated runtime deps
  (LibreOffice/poppler/pandoc), a gap flagged inline at that skills block since it was first
  wired. Also declares Spotlight-visible, focus-or-launch `.app` bundles for the Android
  emulator and `macvm` (`home.file."Applications/Android Emulator.app"` / `"Mac VM.app"`,
  backed by `packages/spotlight-launchers.nix`, macos-only).
- **`mcp.nix`** — the claude-code MCP-server config. See [`mcp-gateway.md`](mcp-gateway.md).
- **`desktop-aesthetics.nix`** — the macOS desktop look, split in two:
  - **Terminal.app** is UNGATED on every darwin host — 16pt type on EVERY profile + stock
    `Pro` as default/startup, driven through Terminal's own AppleScript `settings set` API
    since Terminal owns `com.apple.Terminal` and clobbers direct plist writes. Guarded on
    Terminal already running so a rebuild never launches it (`ps`, not `pgrep` — the latter
    can't see it from activation). This repo used to VENDOR an "Ubuntu" profile + generator
    here; dropped once stock `Pro` proved fine, the type size being the only part worth
    declaring.
  - The **custom wallpaper** stays behind `local.desktopAesthetics.enable` (default true;
    `macvm` sets it false to keep the stock desktop as a visual tell).
- **`nix-cache.nix`** — the Cachix binary-cache option (see § Binary cache below).
- **`nix-ld-libraries.nix`** — the shared nix-ld library list.
- **`wireguard-configs.nix`** — operator-managed WG confs synced to `~/.config/wireguard`, no
  autostart. See [`wireguard-vpn.md`](wireguard-vpn.md).
- **`claude-otel.nix`** — `services.claudeOtel`, real-Mac-only: a local OTel Collector
  receiving Claude Code's native OpenTelemetry `tool_decision`/`tool_result` events over
  localhost OTLP, writing a rotating JSONL for `/routing-review` to mine for
  deterministic-routing hardening candidates. See
  [`claude-code-observability-runbook.md`](claude-code-observability-runbook.md).
- **`hm-launchd/`** — replaces stock HM launchd so every agent's `ProgramArguments[0]`
  basename is `nix-<activity>` (macOS BTM rule — tags nix-config origin; **never** a bare
  interpreter like `sh`/`python3`; wait4path stays inside the wrapper). This is **mandatory
  for every launchd unit this repo authors**: HM user agents are auto-wrapped here, and any
  hand-written `launchd.daemons`/`launchd.agents` MUST point `arg0` at a
  `writeShellScriptBin "nix-<activity>"` wrapper (canonical:
  `telegramMcp`/`wpMcp`/`cloudflaredConnector` in `mcp.nix`) — codified as the always-applied
  [`launchd-naming.md`](../.claude/rules/launchd-naming.md) rule, which also documents the
  three known-upstream `/bin/sh` exceptions that are NOT ours and must never be renamed.

### `modules/darwin/`

`modules/darwin/{core.nix,homebrew.nix,nix-homebrew.nix,xcode-license.nix,github-runner.nix}`

- **`core.nix`** — macOS system defaults (dock/finder/NSGlobalDomain, Touch ID for sudo,
  `stateVersion = 5`). On **macos only**: login openers (`nix-*` BTM wrappers) + hourly
  Screengrab rotation (`~/Pictures/Screengrab`, shared R/W into macvm via Tart VirtioFS).
- **`homebrew.nix`** — the declarative Homebrew **framework**: owns only
  `enable`/`onActivation` with `cleanup = "uninstall"`/`taps`. The actual
  `brews`/`casks`/`masApps` lists live **per host** in `hosts/<host>.nix` so macos and macvm
  carry different app sets.
- **`nix-homebrew.nix`** — Homebrew-itself install via `nix-homebrew`.
- **`xcode-license.nix`** (macos only) — runs *before* `brew bundle` to `mas install` Xcode
  when declared in `masApps` and `xcodebuild -license accept`, so formulae are not blocked by
  an unaccepted SDK license (Brewfile order is brews→casks→mas).
- **`github-runner.nix`** — `services.macosGithubRunner`: N hand-rolled launchd daemons running
  **ephemeral, org-level self-hosted GitHub Actions runners**. Built then retired 2026-07-16
  once nix-config's own CI no longer needed one; **revived 2026-08-23 for a different consumer**
  — `dontsell-ai`'s repos, whose macOS + Playwright + Prisma jobs neither GitHub-hosted (no
  hosted-minutes budget on that org) nor the native Linux builder (build-only, ephemeral,
  1-CPU/8 GB) can serve. `hosts/macos.nix` enables it with `count = 2`.
  - **Hand-rolled on purpose:** nix-darwin's `services.github-runners` hard-asserts
    `nix.enable = true` (it takes the runner's `nix` from `config.nix.package`), which is
    mutually exclusive with Determinate Nix (`nix.enable = false`). This module reproduces
    upstream's launchd setup and substitutes `pkgs.nix` — nothing else differs.
  - **Auth:** a GitHub **App** RS256 private key (the host-decrypted
    `gh-app-dontsell-ai-key.age`), used to mint a fresh ~1 h installation token per
    registration rather than holding a long-lived bearer credential. Scoped to *only*
    "Organization permissions → Self-hosted runners: Read and write".
  - **Security:** `--ephemeral` (one job per registration; launchd restart + re-register makes
    it self-healing), outbound-only. Only trusted push jobs may target `runs-on: [self-hosted,
    …]` — **never fork-PR workflows**, since the daemon inherits the operator's login
    environment. `arg0` is `nix-github-runner-<instance>` per the launchd-naming rule.
  - Also pins `postgresql`+pgvector onto the runners' PATH (`modules/shared/home.nix`, `hiPrio`
    to resolve the duplicate `bin/psql`).

### `modules/nixos/`

- **`modules/nixos/core.nix`** — shared NixOS baseline: the `ismail` user + authorized SSH key (the
  operator's static ed25519 key, the sole network login credential on every host), keys-only
  sshd (no password, no root login), firewall (TCP 22, UDP 5353 for mDNS), avahi
  `<host>.local` publishing, native `programs.nix-ld`, zram swap, automatic GC. `nixpi`'s sshd
  is reached over the Cloudflare tunnel
  (`cloudflared access ssh --hostname nixpi.kattakath.com`); `nixvm` is only ever the throwaway
  local `nix run .#nixvm` desktop, so it has no networked login path.
- **`modules/nixos/desktop-vm.nix`** — opt-in `services.desktopVm.enable` (default false): a lightweight X11
  **XFCE** desktop with passwordless autologin (the `loginName` specialArg) plus QEMU/SPICE
  guest integration (`qemuGuest`, `spice-vdagentd`) for the `nixvm` sandbox.
  `hosts/nixvm.nix` enables it **only inside `virtualisation.vmVariant`**, so the desktop
  materialises for the graphical `nix run .#nixvm` / `build-vm` path — the sole way `nixvm` is
  ever booted.

### NixOS modules consumed as flake inputs

- **the `nix-cloudflared-connector` flake** — opt-in `services.cloudflared-connector.enable`
  (default false); hardened `systemd.services.cloudflared-connector` running a
  **remotely-managed (token)** Cloudflare Tunnel — no `cloudflared tunnel login`, no cert.pem.
  Token read from `tokenFile` (module default `/etc/secrets/cloudflared-token`,
  operator-placed), never in git; an activation script warns (doesn't abort) if absent. Only
  `nixpi` enables it — and `nixpi` **overrides `tokenFile` to `/run/cloudflared-token`**, a
  root-only file that `services.firmwareProvisioning` populates at boot from the token
  operator-planted on the SD card's FAT `FIRMWARE` partition. This deliberately replaced
  agenix: agenix binds the token to nixpi's SSH host key, but a fresh SD flash rotates that
  key, breaking decryption and killing the tunnel — the sole remote path in.
- **`services.firmwareProvisioning`** — reusable `files.<name>` mechanism: each entry becomes
  a oneshot that, once `/boot/firmware` is mounted, copies an operator-planted file off the
  FAT `FIRMWARE` partition into a root-only `/run` file before its consumer starts (`required`
  fails the unit if absent; else it skips cleanly). This module was **EXTRACTED from this repo
  into a standalone MIT flake** — `nix-firmware-secrets`
  (github:kattakath/nix-firmware-secrets) — and `nixpi` now consumes it as a flake input
  (`firmware-secrets.nixosModules.default`, threaded via `mkNixos` specialArgs in `flake.nix`,
  imported in `hosts/nixpi.nix`) rather than a vendored copy; the repo dogfoods its own
  extraction. `nixpi` uses it for BOTH the Cloudflare connector token AND Wi-Fi
  (`wpa_supplicant.conf`) — host-key-independent secrets a fresh SD flash needs, since agenix
  (which binds to the rotated host key) would lock us out. Planted from macOS by the
  `nixpi-provision`/`nixpi-flash` apps.

### Web serving on `nixpi`

Uses upstream `services.caddy.virtualHosts` directly (in `hosts/nixpi.nix`), **no wrapper
module**: one `http://<domain>` vhost per `mkNixos`'s `hostedSites` parameter (see
[`private-home-modules.md`](private-home-modules.md)), each `file_server`ing its `root`. This
public repo passes no `hostedSites` (`[ ]` default), so the public
`nixosConfigurations.nixpi` boots Caddy with **zero vhosts** — the real production sites
(`kattakath.com`, `snoringirl.com`, `ismail.kattakath.com`, `dontsell.ai`) live only in the
private layer. Caddy sits **behind** the Cloudflare Tunnel (tunnel → Caddy on :80), so no
public IP/port-forward is needed and TLS terminates at Cloudflare's edge (the `http://` prefix
disables Caddy auto-HTTPS to avoid a redirect loop back through the tunnel).

## `packages/`

Core package set:

- **`devcontainer-image.nix`** — MULTI-ARCH devcontainer OCI image (arm64+amd64,
  `dockerTools.streamLayeredImage`), published to GHCR as a manifest list; arch-parameterized
  loader path inside.
- **`nixpi-provision.nix`** — macOS-only: the four
  `nixpi-flash`/`nixpi-provision`/`nixpi-wifi-creds`/`nixpi-vault-token`
  `writeShellApplication` flake apps that flash the SD card and plant the token+Wi-Fi onto its
  FIRMWARE partition — the executable companion to the `nix-firmware-secrets` flake's
  `services.firmwareProvisioning`.
- **`macvm-tart.nix`** — macOS-only: host Tart control plane for `macvm` (create from IPSW,
  doctor, ensure, start/stop/ssh/ip); disk under `~/.tart/`, never in the store. See
  [`macvm-tart-runbook.md`](macvm-tart-runbook.md).
- **`key-recovery.nix`** — macOS-only: the `key-backup`/`key-recover` apps, stage 2 of Mac
  bootstrap/recovery, shellcheck-gated. `key-recover` clones, HARD-FAILS unless the login
  `id -un` == the flake's `loginName` (via the `#identity.loginName` output), then RESTORES
  from an iCloud kit or `--fresh`-FOUNDS a new operator identity, and activates `#macos`.
- **`vast-bootstrap.sh`** + **`templates/provisioner/provision-lib.sh`** — the two files a
  live Vast instance still fetches over raw HTTP from THIS repo at boot (see § Vast.ai below
  for why the `vast-*` CLI logic itself is no longer vendored here).
- **`spotlight-launchers.nix`** — macOS-only: from-scratch `.app` bundle generator (original
  in-Nix SVG/icns icons via librsvg+libicns) giving the Android emulator and `macvm` a
  Spotlight-visible, focus-or-launch identity; consumed by `modules/shared/home.nix`'s
  `home.file."Applications/*.app"`.
- **`tart-guest-agent.nix`** — macvm-only: `fetchurl` derivation for cirruslabs' ad-hoc-signed
  guest-agent binary (clipboard sync + `tart exec` / `tart ip --resolver=agent` RPC), run via
  `hosts/macvm.nix`'s `launchd.user.agents.tart-guest-agent`.

The no-Nix stage-1 `bootstrap.sh` (the `curl … | bash` entrypoint) lives at the **repo root** —
it is shellchecked as the `key-recovery-bootstrap` derivation and `key-backup` publishes it
into the iCloud kit as the offline copy.

Smaller, single-purpose CLIs:

- **`android-phone.nix`** — macOS-only: deterministic wired/wireless ADB operator
  (`list|pair|connect|disconnect|unpair|tcpip|wireless|mirror|doctor`) plus scrcpy mirroring
  for a PHYSICAL Android device; hardens around two live-reproduced adb bugs, an mDNS-cache
  staleness and duplicate-transport device listings. Its operator knowledge is also a GLOBAL
  skill, `skills/android-phone`.
- **`fix-google-video.nix`** — detects and re-encodes video files with editor-incompatible
  codecs (most commonly VP9-in-MP4, the flavor Google Photos' download button serves for
  videos not backed up at Original quality) into H.264+AAC via VideoToolbox with a libx264
  fallback, idempotent.
- **`jobspy.nix`** — a reproducible `uv`-ephemeral wrapper CLI around the `python-jobspy`
  library for scraping job boards.
- **`jsonresume.nix`** — dual-engine `jsonresume <download|print|validate|markdown|text>`
  wrapper (`resumed` for PDF/validate, `resume-cli` where `resumed` falls short); see the
  `jsonresume-tailor` skill.
- **`mermaid-ascii.nix`** — packages `AlexanderGrooff/mermaid-ascii`, not in nixpkgs, for the
  diagrams-as-ASCII convention.
- **`obs-fb-setup.nix`** — macOS-only: configures an OBS "Facebook" profile, stream key read
  live from the Keychain, never in git/store.
- **`vpn.nix`** — the WireGuard `vpn` operator CLI. See [`wireguard-vpn.md`](wireguard-vpn.md).
- **`claude-otel-doctor.nix`** — health check for the `services.claudeOtel` collector (launchd
  agent, OTLP port, events-file freshness). See
  [`claude-code-observability-runbook.md`](claude-code-observability-runbook.md).
- **`fidelity-enhance.nix`** — macOS-only: the referee for an agentic image-editing loop. Grok
  Imagine generates, this judges each result against the ORIGINAL via SSIM/LPIPS/ArcFace-identity
  and returns retry/next-step/done plus prompt guidance. Ships `fidelity-enhance-mcp` (stdio
  MCP server) + `fidelity-enhance` (CLI) from one ephemeral `uv` env, Python 3.12 pinned for
  torch/insightface wheel coverage; exposed via `home.packages` + `nix run .#fidelity-enhance`.
- **`resend-cli.nix`** — the official Resend CLI, not yet in nixpkgs so `npx`-wrapped and
  version-pinned same as `mcp-wordpress`/`telegram-mcp`; injects `RESEND_API_KEY` from the
  login Keychain at run time — wired only via `home.packages`, no matching flake app.
- **`design-tokens/`** / **`email-signature/`** — small self-contained build-script-backed
  packages for their respective assets.
- **`hyperframes-selfhost(.nix)`** — see [`hyperframes-selfhost.md`](hyperframes-selfhost.md).
- **`packages/runpod-provision.nix`** — the RunPod analogue of the Vast subsystem
  (`runpod-template-apply`, macOS-only): since the official `runpod/comfyui` image has no
  Vast-style provisioning hook, it overrides `dockerEntrypoint`/`dockerStartCmd` with a wrapper
  that clones a private `comfyui-workflows`-shaped repo and runs its `runpod/provision.sh`
  before handing off to the image's `/start.sh`; secrets are RunPod **account** secrets
  (`{{ RUNPOD_SECRET_name }}`), never baked into the template.

## `infra/` — terranix (Nix → OpenTofu/Terraform JSON)

### `infra/cloudflare/nixpi-tunnel.nix`

Declares `nixpi`'s **remotely-managed** Cloudflare Tunnel itself:

- a `cloudflare_zero_trust_tunnel_cloudflared` (`config_src = "cloudflare"`),
- its ingress (`cloudflare_zero_trust_tunnel_cloudflared_config`: SSH → `ssh://localhost:22`,
  one rule per `hostedSites` entry → the local Caddy at `http://localhost:80`, plus the
  mandatory catch-all `http_status:404`),
- one proxied `cloudflare_dns_record` CNAME per site → `<tunnel-id>.cfargotunnel.com`,
- the connector **token** surfaced as a sensitive `output` (via the
  `cloudflare_zero_trust_tunnel_cloudflared_token` data source).

A pure function of its `hostedSites`/`domainName`/`accountId`/`zoneId` module args (same
shape/default as `mkNixos` — see [`private-home-modules.md`](private-home-modules.md)); the
public `cfTunnelConfig`/`cf-tunnel-apply`/`cf-tunnel-destroy` flake apps pass none, rendering
an ingress with zero sites, while the private nix-personal flake calls `lib.cfTunnelConfig`
directly with the real site list. Applied/destroyed via the `cf-tunnel-apply`/`cf-tunnel-destroy`
flake apps (an API credential must be exported first — never in Nix); `cf-tunnel-apply` prints
the token to stdout to be stored via `nix run .#nixpi-vault-token` into
`secrets/cloudflared-token.age`, never written to git/store in plaintext.

### `infra/hyperframes/stack.nix`

See [`hyperframes-selfhost.md`](hyperframes-selfhost.md).

### The Vast.ai GPU-template provisioning subsystem

The **`vast-provision` flake input** (`github:kattakath/nix-vast-provision`, EXTRACTED FROM
THIS REPO — phase 2 of the extraction, phase 1 backported local-only features upstream first)
plus the locally-vendored `packages/vast-bootstrap.sh` and
`packages/templates/provisioner/provision-lib.sh`.

**Off-fleet control plane** darwin flake apps (parallel to the Cloudflare `cf-tunnel-*` apps —
the tooling runs on the Mac, it provisions external x86_64 cloud GPUs; **Vast is NOT a fleet
host**). The CLI *logic* —

- `vast-template-apply` (create/REPLACE a template by name — delete+create, since Vast's PUT is
  broken),
- `vast-repo-check` (validate a provisioner repo's `.provisioner-template.json` marker),
- `vast-account-vars-set` (sync read-only `VAST_*` Keychain tokens → Vast account env vars),
- `vast-ssh-key-set` (register the operator SSH key on the Vast account),
- `vast-init-repo` (scaffold a provisioner repo — now from the extracted flake's own baked
  scaffold),
- `vast-rent` (rents a live, **BILLED** GPU instance from a template by name/hash — the one
  command in the kit that spends real money)

— is `callPackage`d straight from the input's store path
(`"${vast-provision}/packages/vast-provision.nix"` in `flake.nix`), with
`orgName`/`repoName`/`rev` OVERRIDDEN to nix-config's own identity: dogfooding, but the raw-URL
construction must still point HERE, since a live Vast instance fetches
`packages/vast-bootstrap.sh` and `packages/templates/provisioner/provision-lib.sh` over raw
HTTP from THIS repo at boot (`PROVISIONING_SCRIPT`/`PROVISION_LIB_URL`) — both stay vendored
here for that reason, and `checks.<system>.vast-lib-drift` diffs them against the input's own
copies so the two can never silently diverge.

No stack-specific manifest content (a concrete ComfyUI workflow, etc.) is ever vendored in this
public repo — that belongs in a private aggregator repo
(`--repo gitlab:... --workflow-name NAME`), never committed here. Templates use `runtype=args` + `OPEN_BUTTON_PORT` +
`PORTAL_CONFIG` on `vastai/base-image`; instances boot `PROVISIONING_SCRIPT` → the raw-URL
`vast-bootstrap.sh` (pinned to this flake's rev) → clone a private provisioner repo → run its
self-contained `provision.sh` (e.g. a ComfyUI stack). Secrets never touch the template — they
are Vast account-level env vars. See
[`vastai-template-provisioning.md`](vastai-template-provisioning.md).

## Claude Code surface

MCP servers have their own doc: [`mcp-gateway.md`](mcp-gateway.md).

### `.claude/commands/`

| Command | What it does |
|---|---|
| `/eval` | stage + `nix flake check` |
| `/hygiene` | LEAN/DRY audit→fix→gate via skill `nix-hygiene` |
| `/update-input` | bump one flake input + commit the lock |
| `/superhook-review` | triage the hook-supervisor log |
| `/pretooluse-review` | triage the `PreToolUse`/`Write\|Edit` prompt-hook attempt/outcome log written by `pretooluse-log.js`, since those hooks have no logging of their own |
| `/remember-nix` | capture into project memory |
| `/vpn` | operate WireGuard via the fleet `vpn` CLI — macvm-only, see [`wireguard-vpn.md`](wireguard-vpn.md) |
| `/gmail-account` | add/authenticate/remove a Gmail MCP multi-account, see [`gmail-mcp-multi-account-runbook.md`](gmail-mcp-multi-account-runbook.md) |
| `/routing-review` | triage Claude Code's own OTel tool-decision log for deterministic-routing hardening candidates, see [`claude-code-observability-runbook.md`](claude-code-observability-runbook.md) |
| `/mcp-scout` | discover → vet → DECLARATIVELY adopt an MCP server into the gateway via skill `mcp-scout`; imperative installer CLIs / config-writing install tools are never used |
| `/fleet-doctor` | fleet-wide consistency sweep (branches/worktrees/PRs/CI/cross-repo pins/GC/host re-activation) across every repo in `.claude/skills/fleet-doctor/fleet-repos.txt`, via skill `fleet-doctor`; composes `nix-hygiene`, `git-purity.md`, `pr-consolidation.md` |

### `.claude/rules/` — always applied

- [`git-purity.md`](../.claude/rules/git-purity.md) — stage `.nix` files before eval.
- [`pr-consolidation.md`](../.claude/rules/pr-consolidation.md) — reuse the current session's
  open PR/branch for follow-up changes instead of opening a new PR each time; start a fresh PR
  only once the prior one has merged (or the user explicitly asks for a separate one).
- [`launchd-naming.md`](../.claude/rules/launchd-naming.md) — every launchd unit this repo
  authors must expose a `nix-<kebab>` `arg0` basename (never a bare `sh`/`python3`); documents
  the known upstream `/bin/sh` exceptions (`org.nixos.activate-system`,
  `org.nixos.activate-agenix`, `systems.determinate.nix-installer.nix-hook`) that are NOT ours
  and must not be renamed.

### `.claude/hooks/`

- **`stop-gate.js`** — Stop gate: blocks until configs evaluate clean.
- **`pretooluse-bash-guard.js`** — `PreToolUse:Bash`: deterministic port of the
  Cloudflare-API-call / Cloudflare-docs / desktop-commander-nudge / approved-CLI policy that
  used to live as a `type: "prompt"` LLM-judged hook; see the file header for the 2026-08-19
  incident that motivated the switch.
- Both are wrapped by **`superhook.js`** (crash-safety + loop-breaking + logging — the sole
  supervisor for command-type decision hooks). It structurally CANNOT wrap `type: "prompt"`
  hooks, which is why the remaining `Write|Edit` secret-detection gate in
  `.claude/settings.json` stays unsupervised prompt-based — that one is a genuine semantic
  judgment call, unlike the Bash gate's mostly-syntactic rules.
- **`superhook-digest.js`** — SessionStart digest of supervisor findings.
- **`routing-review-digest.js`** — SessionStart nudge for unreviewed
  `user_temporary`/`user_permanent` Claude Code routing decisions; mirrors
  `superhook-digest.js` exactly, threshold-gated, see
  [`claude-code-observability-runbook.md`](claude-code-observability-runbook.md).
- **`fleet-doctor-digest.js`** — SessionStart nudge when `/fleet-doctor` hasn't run in a while;
  reads only a local timestamp, no network/git calls, so it stays fast on every session start.
- **`memory-loader.js`** — SessionStart context surfacing.
- **`autostage-nix.js`** — PostToolUse git-purity net.
- **`nix-home-path-lint.js`** — PostToolUse, `.nix` only: flags a hardcoded
  `/Users/<name>/`/`/home/<name>/` runtime-path VALUE per the "Paths — two axes" convention —
  advisory, not a hard gate.
- **`pretooluse-log.js`** — PreToolUse+PostToolUse observer for `Bash`/`Write|Edit`; logs
  attempt/executed pairs to `.claude/hooks/pretooluse.log` for `/pretooluse-review`; never
  influences the decision.

Decoder for what these hooks print: [`claude-hook-messages.md`](claude-hook-messages.md).

### `.claude/skills/` — project skills

Active only when working in this repo: `nix-hygiene`, `nixpi-firmware-provision`, `macvm-tart`,
`vast-instance-log-tail`, `jsonresume-tailor`, `wireguard-vpn`, `gmail-mcp-accounts`,
`mcp-scout`, `fleet-doctor` (its own `fleet-repos.txt` manifest lists every repo in scope — add
a line there when a new flake is extracted from this repo, nothing else needs to change).
`skills-lock.json` (the `npx skills` CLI lockfile) pins any CLI-vendored ones (currently none —
prefer the flake path below).

### Global skills

Placed at `~/.claude/skills/<name>/` declaratively by `programs.claude-code.skills`
(`modules/shared/home.nix`, darwin-gated) on `darwin-rebuild switch`. Most are sourced from
PINNED `flake = false` inputs (`agent-skills-vercel` = vercel-labs/skills → `find-skills`;
`agent-skills-anthropic` = anthropics/claude-code → the plugin-dev + hookify authoring skills),
**NOT vendored**; `nix flake update` bumps them.

A small exception is **vendored in-repo**: the top-level `skills/` directory holds skills wired
into the same `programs.claude-code.skills` option alongside the flake-input-sourced ones —
forks of upstream skills that needed a local patch (`skills/brag`, `skills/brags-review`,
`skills/rag` — see `skills/brag/FORK-NOTES.md` for the vendoring rationale) plus originals
authored here:

- **`skills/android-phone`** — operator knowledge for `packages/android-phone.nix`, global so
  ADB sessions launched from ANY directory know the wrapper's command surface and adb
  footguns, not just sessions rooted in this repo.
- **`skills/nix-dev-toolkit`** — how to make *another* repo self-sufficient with Nix: a
  working `flake.nix` template + `.envrc` (`assets/`), the env-catalogue pattern, a
  project-local Postgres+pgvector stack, and `nix run .#<verb>` lifecycle apps
  (`references/`). Global precisely because the point is to apply it to a repo that does
  **not** have it yet — its `stack-up`/`deploy-prod`/`env-doctor` app names are the
  template's, **not** flake apps of this repo. Carries the Nix/Postgres/Prisma traps
  (`withPackages` union prefix, socket port, the macOS socket-length cap).

### `plugins/`

This repo's OWN Claude Code plugin marketplace (`kattakath-nix-config`), the third alongside
`xai-grok-build` (pinned flake input) and `claude-plugins-official` (HTTPS).
`plugins/.claude-plugin/marketplace.json` lists each in-repo plugin; `modules/shared/home.nix`
pins it as a **Nix source path** (`localPluginsMarketplace = "${../../plugins}"`) and installs
its ids via the same `claudePluginIds` + `home.activation.claudeCodePlugins` path as every
other plugin. Because it is a source path, the store path changes whenever plugin content
changes — activation keys the marketplace re-pin (and a reinstall of the copies under
`~/.claude/plugins/cache`) off exactly that, so an in-repo plugin can never serve a previous
generation's content.

Today, two:

- **`plugins/llmstxt`** — `llms.txt` authoring skill + `/llmstxt` command + a stdlib-only spec
  linter; see `plugins/llmstxt/README.md`.
- **`plugins/seargraph`** — the `seargraph-langgraph` **subagent** (LangGraph pipeline
  design/implementation for the SEARGraph project: fidelity metrics, constrained optimization,
  iterative refinement, character embeddings). It is a plugin rather than a vendored skill for
  one structural reason: `programs.claude-code.skills` has no `agents/` capability — only a
  plugin can ship a subagent.

Adding one = a `plugins/<name>/` tree with `.claude-plugin/plugin.json` + a `marketplace.json`
entry + its id in `claudePluginIds`; validate with `claude plugin validate --strict`. A
**skill** that needs no command/hook/MCP/agent surface still belongs in top-level `skills/` —
reach for a plugin only when the unit is more than a skill.

### `memory/`

**Gitignored** project memory (decisions/findings/values/evolution): the candid "why" behind
the repo, surfaced each session by `memory-loader.js`. Never `git add`.

## CI, release, publishing

`.github/workflows/nix-ci.yml` — 2-leg Nix CI on GitHub Actions, ALL on GitHub-**HOSTED**
runners (`ubuntu-24.04-arm` for aarch64-linux — evaluates `nixpi`+`nixvm`; `macos-latest` for
aarch64-darwin — evaluates `macos`; both free & unlimited on public repos). Each leg *builds*
the lint/format `checks` with `nix-fast-build` (pushed to the `kattakath` Cachix cache) and
*evaluates* (no build) its host config toplevel(s). Building host toplevels is deferred to
release time (`build-installers`, also hosted).

**No workflow in this repo targets a self-hosted runner** — every leg is GitHub-hosted (fork
PRs need no runner fallback), and day-to-day local aarch64-linux builds use Determinate's
native Linux builder on the Mac. Branch protection requires the aggregate `required-checks`
job.

Do **not** read that as "the Mac has no runners": `macos` does host two ephemeral self-hosted
runners, registered to the **`dontsell-ai`** org, for *that* org's CI — see
`modules/darwin/github-runner.nix` above. The two facts are about different repos.

Also in `.github/workflows/`: `auto-merge.yml`, `build-devcontainer.yml`,
`build-installers.yml`, `claude*.yml`, `gitleaks.yml`, and `flakehub-publish.yml` — the last
publishes each push to `main` as a rolling release to FlakeHub via
`DeterminateSystems/flakehub-push`, authenticated by OIDC/`id-token: write` with **no** stored
token; per FlakeHub's trusted-platform model, flakes publish only from CI, never ad-hoc from a
laptop. Merge mechanics: [`auto-merge-and-merge-queue.md`](auto-merge-and-merge-queue.md).

## Binary cache (Cachix)

The public `kattakath` cache is consumed by every host (`modules/shared/nix-cache.nix`, wired
in via the flake's module lists) and the devcontainer. Read is public — only the substituter
URL + public key, **NO token on any consumer**. The write credential `CACHIX_AUTH_TOKEN` lives
in exactly two places: a **GitHub Actions secret** (used by `cachix/cachix-action` in
`nix-ci.yml`, `build-devcontainer.yml`, and `build-installers.yml` to push build closures) and
— since 2026-08-21 — the operator's **login Keychain** (registered via `secret set`,
loader-exported like every personal token) for ad-hoc local `cachix push kattakath <paths>`;
never in Nix or git, and consumers still substitute tokenless (read stays public). Note the
token does NOT influence builds or substitution — Nix sandboxes scrub the environment, so it is
only ever consumed by the `cachix` CLI at push time.
