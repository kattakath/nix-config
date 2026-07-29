# Private home-manager modules — composition contract

This public flake is the **fleet engine**. Personal or sensitive home-manager
stacks (anything you do not want in a public tree) live in a **separate private
flake** and plug in through a fixed contract — the same boundary as Vast
provisioner repos (`provision.sh` + marker) vs this repo's generic
`vast-template-apply`.

## Boundary

| Layer | Lives where | Contains |
|---|---|---|
| **Engine** | `github:kattakath/nix-config` (public) | hosts, shared profile, `lib.mkDarwin` / `lib.mkHomeManagerModule` |
| **Private stack** | your private forge (GitLab/GitHub) | home-manager modules only you should see |
| **Contract** | `extraHomeModules` on `lib.mkDarwin` | list of HM modules; public hosts pass `[]` |

**No private stack is referenced from this repository** — not as a flake input, not
as a path, not as a URL. The public `flake.lock` never locks a private repo.

## Contract

1. Private flake depends on **this** flake as an input (not the other way around).
2. Private flake rebuilds the host via the exported builder:

   ```nix
   # private flake (illustrative)
   {
     inputs.nix-config.url = "github:kattakath/nix-config";

     outputs =
       { self, nix-config, ... }:
       {
         homeManagerModules.default = ./modules/my-private.nix;

         darwinConfigurations.macos = nix-config.lib.mkDarwin {
           system = "aarch64-darwin";
           hostname = "macos";
           # Optional: identity override, extraModules, …
           extraHomeModules = [
             self.homeManagerModules.default
           ];
         };
       };
   }
   ```

3. Activate **from the private flake** (not from public `.#macos` when you need the
   private modules):

   ```bash
   # SSH (preferred — no token in the URL)
   darwin-rebuild switch --flake 'git+ssh://git@gitlab.com/<you>/<private>.git#macos'

   # or a local clone
   darwin-rebuild switch --flake ~/path/to/private#macos
   ```

4. Public `darwin-rebuild switch --flake github:kattakath/nix-config#macos` remains
   the **fleet-only** path (no private modules).

## Ops checklist

1. Create a **private** repo on GitLab (or GitHub); do not put personal modules here.
   This fleet’s private composition flake is **`gitlab.com/ismailkattakath/nix-personal`**
   (never a flake input of the public tree — activate *from* that repo).
2. Export `homeManagerModules.*` and `darwinConfigurations.macos` / `macvm` that call
   `nix-config.lib.mkDarwin { extraHomeModules = [ … ]; }` (macvm needs the aloshy
   `identity` override — copy from public `flake.nix`).
3. Prefer `git+ssh://…` flake URLs so credentials never appear in `flake.lock` URLs.
4. Pin `nix-config` by revision in the private `flake.lock` (same discipline as other inputs).
5. When the private stack grows, keep **one** private composition flake (or a small
   set of `homeManagerModules.*` attrs) — do not re-open a public PR for personal
   modules.

### Day-to-day activate (with private modules)

```bash
# macos
sudo nix run ~/Developer/gitlab.com/ismailkattakath/nix-personal#macos

# macvm (from the host) — guest usually has no GitLab SSH, so sync the private
# clone then activate the path flake:
NP=~/Developer/gitlab.com/ismailkattakath/nix-personal
CFG=~/Developer/github.com/kattakath/nix-config
tar -C "$NP" --exclude result --exclude .direnv -cf - . |
  nix run "$CFG#macvm-tart-ssh" -- 'mkdir -p ~/nix-personal && tar -C ~/nix-personal -xf -'
nix run "$CFG#macvm-tart-ssh" -- sudo nix run /Users/aloshy/nix-personal#macvm
```

Fleet-only (no private modules): `github:kattakath/nix-config#macos` / `#macvm`.

## Analogy to Vast provisioners

| Vast | Private home modules |
|---|---|
| Public bootstrap / `vast-*` apps in this repo | Public `lib.mkDarwin` + `extraHomeModules` |
| Private `owner/stack` repo with `provision.sh` | Private flake with HM modules |
| Template holds no secrets | Public tree holds no private module URLs |
| Activate instance via Vast | Activate Mac via private flake `#macos` |

## WireGuard (and other private *files*)

Private **keys / `.conf` bodies** should not use `home.file.source = ./secret.conf`
even in a private flake — Nix copies them into the **world-readable store**.

Prefer:

1. Operator plant directory outside git (this fleet: `~/.local/share/wireguard-configs`
   → HM activation sync to `~/.config/wireguard` via `local.wireguardConfigs` in the
   public engine — confs never evaluated as Nix paths).
2. Or a private flake that only ships the *module* and still `cp`s from a host-local
   path at activation.

See `docs/macvm-tart-runbook.md` (WireGuard section).

## What this is not

- Not an in-tree `private/` directory (that is still a public git trace).
- Not a flake input on this public flake (that would leak the private repo name into
  `flake.lock` for every clone/CI job).
- Not required for the fleet: Pi, VMs, and a clean Mac bootstrap stay on public `#macos`.
