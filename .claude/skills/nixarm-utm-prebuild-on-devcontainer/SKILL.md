---
name: nixarm-utm-prebuild-on-devcontainer
description: >
  Build the nixarm qcow2 image from macOS using the repo's devcontainer CLI — no separate Linux
  machine or CI runner needed. Use when asked to "build nixarm image from Mac", "use devcontainer
  CLI to build", "build without a Linux machine", "devcontainer exec nix build", or "build nixarm-image
  in the devcontainer". The repo's devcontainer runs on aarch64 (Apple Silicon Docker Desktop), has Nix
  + flakes pre-installed, and bind-mounts the workspace so result/ lands directly on the Mac.
---

# devcontainer-build — build nixarm-image from macOS via devcontainer CLI

## This vs other build paths

| | **devcontainer-build** (this skill) | **nixarm-vm** | **utm-vm-provision** |
|---|---|---|---|
| Build location | Repo devcontainer (aarch64 Docker) | Needs qcow2 already built | Needs qcow2 already built |
| macOS requirement | Docker Desktop + devcontainer CLI | Apple Silicon + HVF | Apple Silicon + UTM |
| Speed | Slow — TCG emulation (20–40 min) | Fast boot (HVF) | Fast boot (UTM) |
| result/ location | `<workspace>/result/` on Mac | N/A | N/A |
| CI equivalent | Yes — same as `.github/workflows/` | No | No |

Use this skill to **produce the qcow2**. Use **nixarm-vm** or **utm-vm-provision** to run it afterward.

## Gotchas (read first)

- **TCG = slow**: The devcontainer has no `/dev/kvm`. The `nixarm-image` build runs under QEMU TCG
  emulation (needed for the aarch64-linux image). Expect 20–40 minutes for a clean build.
- **Docker Desktop must be running** with VirtioFS or gRPC-FUSE file sharing enabled for the
  workspace bind-mount to work.
- **Nix PATH in exec**: `devcontainer exec` does not source a login shell. Nix is usually on PATH
  via `/etc/profile.d/nix.sh`, but if you see `nix: command not found`, prefix with
  `/nix/var/nix/profiles/default/bin/nix`.
- **git add before nix eval**: Flakes ignore untracked files. The bind-mount means git state is
  shared — `git add -A` on the host or inside the container both work.
- **`result` is DANGLING on the Mac.** It's a symlink to `/nix/store/...`, which exists only
  inside the container — so `ls -L result/` and `cp result/*.qcow2` run *on macOS* fail with
  "No such file or directory". Do the copy **inside the container** (where `/nix/store` is real),
  writing to the bind-mounted workspace so the file lands on the Mac. The symlink itself is still
  visible on the host (`ls -l result` without `-L`), just not followable.
- **VirtioFS forbids guest chmod on the bind-mount.** The store source is `0444`, so any copy
  lands read-only and `chmod`/`cp --no-preserve=mode` *inside the container* fail with "Permission
  denied". Flip it writable from the **Mac side** (`chmod u+w`), where you own the file as your
  host uid. Stream-copy with `cat src > dst` (not `cp`) to dodge the in-guest chmod entirely.
- **Container identity**: the container runs as `vscode` (UID 1000). The Nix store is owned by
  root but group-accessible; `nix build` works without sudo.

## Prerequisites

Install the devcontainer CLI on macOS (once):

```bash
npm install -g @devcontainers/cli
# or:
brew install devcontainer
```

Verify Docker Desktop is running and the workspace folder path is correct:

```bash
docker info          # must succeed
ls ~/path/to/nix-config/.devcontainer/devcontainer.json
```

## Step 1 — Start the container

```bash
devcontainer up --workspace-folder ~/path/to/nix-config
```

This command is idempotent — safe to run if the container is already up. On first run it pulls
the base image and runs `nix develop --command true` (the `updateContentCommand`) to pre-build
the devShell. That takes a few extra minutes.

Check that the container is running:

```bash
docker ps --filter "label=devcontainer.local_folder=$(realpath ~/path/to/nix-config)"
```

## Step 2 — Stage files

```bash
devcontainer exec --workspace-folder ~/path/to/nix-config -- git add -A
```

Or run this on the macOS host — the bind-mount makes git state shared:

```bash
cd ~/path/to/nix-config && git add -A
```

## Step 3 — Build the nixarm qcow2

```bash
devcontainer exec --workspace-folder ~/path/to/nix-config -- \
  nix build .#nixarm-image --print-out-paths
```

If `nix` is not on PATH inside exec, use the full path:

```bash
devcontainer exec --workspace-folder ~/path/to/nix-config -- \
  /nix/var/nix/profiles/default/bin/nix build .#nixarm-image --print-out-paths
```

The build takes 20–40 minutes under TCG emulation. The `--print-out-paths` flag shows the Nix
store path when done.

## Step 4 — Get the result onto macOS

The `result` symlink points into the container's `/nix/store`, so it is **dangling on the Mac** —
you cannot `cp result/*.qcow2` from the host. Copy the qcow2 out **from inside the container**
into the bind-mounted workspace (which lands it on the Mac), then make it writable from the host.

```bash
# 1. Stream-copy inside the container (cat avoids the in-guest chmod that VirtioFS rejects):
devcontainer exec --workspace-folder ~/path/to/nix-config -- \
  bash -lc 'cat result/*.qcow2 > nixarm.qcow2'

# 2. Verify byte-for-byte (sizes must match exactly):
devcontainer exec --workspace-folder ~/path/to/nix-config -- bash -lc '
  echo "src : $(stat -c%s "$(readlink -f result/*.qcow2)")"
  echo "copy: $(stat -c%s nixarm.qcow2)"'

# 3. Make it writable FROM THE MAC (the copy is 0444; chmod inside the container fails on VirtioFS):
chmod u+w ~/path/to/nix-config/nixarm.qcow2
ls -lh ~/path/to/nix-config/nixarm.qcow2     # → ~3 GB, rw-
```

`nixarm.qcow2` is gitignored (alongside `result`), so it won't pollute git or flake evals. From
there, stage it for whichever runner you want:

```bash
# For nix run .#nixarm-vm (see nixarm-vm skill):
mkdir -p ~/.local/state/nixarm-vm
cp ~/path/to/nix-config/nixarm.qcow2 ~/.local/state/nixarm-vm/nixarm.qcow2

# For UTM import (see utm-vm-provision skill):
cp ~/path/to/nix-config/nixarm.qcow2 ~/path/to/utm-bundle/Data/nixarm.qcow2
```

## Other useful commands

```bash
# Run nix flake check inside the container (includes formatting + lint):
devcontainer exec --workspace-folder ~/path/to/nix-config -- \
  bash -c 'git add -A && nix flake check'

# Open an interactive shell:
devcontainer exec --workspace-folder ~/path/to/nix-config -- zsh
# or bash:
devcontainer exec --workspace-folder ~/path/to/nix-config -- bash

# Stop the container:
docker stop $(docker ps -q --filter "label=devcontainer.local_folder=$(realpath ~/path/to/nix-config)")
```

## Cross-references

- **nixarm-vm** skill — run the built qcow2 in QEMU with HVF acceleration (no UTM needed).
- **utm-vm-provision** skill — import the qcow2 into UTM for vmnet-shared networking and the GUI.
- **agenix-host-rekey** skill — re-encrypt host secrets to the new VM's SSH host key after first boot.
