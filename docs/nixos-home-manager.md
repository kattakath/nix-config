# How NixOS + Home Manager fit together (in this repo)

A walkthrough of *this* flake — not a generic tutorial. Every claim cites a real
`file:line`. The goal: after reading this you can predict what each `*-rebuild`
command does and know which file to edit for a given change.

## The one idea everything else follows from

There are **two configuration layers**, each with its own owner, activation
moment, and (crucially) its own agenix decryption identity:

| | **NixOS / nix-darwin — SYSTEM layer** | **Home Manager — USER layer** |
|---|---|---|
| Owns | the machine: services, system users, kernel, `/etc`, firewall, the host's `cloudflared` daemon | your `$HOME`: shell, dotfiles, `git`/`neovim`/`tmux` config, per-user env vars + tokens |
| Runs as | root, at **boot** (system activation) | your user, at **login/session** |
| Defined in | `hosts/<host>.nix` + `modules/nixos/core.nix` (or `modules/darwin/core.nix`) | `modules/shared/home.nix` |
| agenix module | `agenix.nixosModules.default` (`flake.nix:102`) | **none** — HM does not use agenix (personal tokens left agenix; see below) |
| Secrets | host-scoped `.age`, decrypted by the HOST key (`modules/nixos/core.nix:55`) at boot | **not via Nix** — macOS Keychain + CLI logins (`gh`/`hf`/`docker`), host-local |

Home Manager is **not a separate tool you run** on these hosts. It is embedded
*inside* the system build as a module, so one rebuild provisions both layers.
That embedding is the whole trick — and it's wired three slightly different ways
here depending on platform.

## The three wirings (same user profile, three front doors)

All three import the **same** `modules/shared/home.nix` — that's the "single
source of truth for user logic" (`modules/shared/home.nix:1`). What differs is
how that profile gets nested into a system build.

1. **NixOS hosts (`nixbox`, `nixrpi`)** — Home Manager as a **NixOS module**.
   `flake.nix:87-119` (`mkNixos`) builds a `nixpkgs.lib.nixosSystem` whose
   `modules` list includes `home-manager.nixosModules.home-manager`
   (`flake.nix:104`) and then, inline, sets `home-manager.users.izzy.imports =
   [ ./modules/shared/home.nix ]`. So `nixos-rebuild switch --flake .#nixbox`
   builds the system AND your home generation in one shot. (HM no longer imports
   an agenix module — personal secrets left agenix; see below.)

2. **macOS host (`m3pro`)** — Home Manager via the **nix-darwin bridge**.
   `hosts/m3pro.nix` imports `home-manager.darwinModules.home-manager`
   (`m3pro.nix:15`) and nests the same profile. So
   `darwin-rebuild switch --flake .#m3pro` does the equivalent on macOS.

3. **Devcontainers** — Home Manager **standalone** (no system layer at all;
   there's no NixOS/darwin to manage in a container). Same `home.nix`, activated
   on its own. This is why the profile must stay platform-agnostic.

`useGlobalPkgs = true` + `useUserPackages = true` (`flake.nix:107-108`,
`m3pro.nix:26-27`) mean HM reuses the system's nixpkgs (one eval, no second copy)
and installs your packages into the system profile rather than a private one.

## What a rebuild actually does

`nixos-rebuild switch --flake .#nixbox`:
1. Evaluates the `nixbox` system closure (everything in `mkNixos`).
2. Builds it. Activates the **system**: writes `/etc/`, (re)starts services,
   runs the **system activation script** — which is where **system agenix**
   (`agenixInstall`) decrypts host-scoped secrets with the **host key** into
   `/run/agenix`, *before* `multi-user.target` services like `cloudflared`.
3. Activates **your home generation** (`home-manager-izzy.service`) — your
   shell, git, dotfiles. No secret decryption happens here anymore (personal
   tokens left agenix).

That two-phase activation is why **system** secrets work at boot while
**personal** secrets are deliberately out of Nix entirely:
- the tunnel cred (a **system** secret, host-key scoped) is decrypted by system
  agenix and up at boot, zero logins — phase 2 above. This is still agenix.
- personal tokens (`GH_TOKEN`, `HF_TOKEN`, …) are **not in Nix at all** — on the
  Mac they come from the login Keychain via `~/.zprofile`; everywhere they come
  from one-time CLI logins (`gh auth login`, etc.). They were removed from agenix
  to avoid version-control churn (every rotation was a committed `.age`). This is
  also why they never appeared on the server: they are simply not managed here.

## "What goes where?" — the practical rule

- A **service/daemon, system user, kernel/boot/network/firewall option, or a
  secret a service needs at boot** → SYSTEM layer (`hosts/*.nix` /
  `modules/nixos/*`). Example: `services.cloudflared` + `age.secrets.tunnel-creds`
  in `hosts/nixbox.nix`.
- A **dotfile, shell, `programs.git`/`neovim`/`tmux`** → USER layer
  (`modules/shared/home.nix`).
- A **CLI tool**: usually USER layer via `programs.<tool>` or `home.packages`
  — unless a system service needs it, then SYSTEM
  (`environment.systemPackages`, `core.nix:59-62`).
- A **secret**:
  - needed by a **system service at boot** → agenix, host-key scoped, in
    `hosts/*.nix` (`age.secrets`). Example: `services.cloudflared` +
    `age.secrets.tunnel-creds`.
  - a **personal token you use** → NOT in Nix. macOS Keychain (exported by
    `~/.zprofile`) or a one-time CLI login. See `secrets/README`.

Gotcha already learned: never list a tool in BOTH `home.packages` and its
`programs.*` module — they collide in the HM buildEnv (`home.nix:49-53`).

## Where to look next
- `flake.nix:87-123` — the `mkNixos` builder (NixOS+HM embedding).
- `hosts/m3pro.nix` — the nix-darwin+HM bridge, with explanatory header.
- `modules/shared/home.nix` — the shared user profile (all three wirings import it).
- `modules/nixos/core.nix` / `modules/darwin/core.nix` — per-platform system base.
- `CLAUDE.md` — build/test commands and the architecture summary.
