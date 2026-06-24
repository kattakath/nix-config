# syntax=docker/dockerfile:1
###############################################################################
# PHASE 1 — working nix-devShell devcontainer, built FROM the noble base.
#
# Strategy (operator's, deliberate): get a WORKING prebuilt image first, off a
# known-good base; minify LATER. Phase 2 replaces this entire Dockerfile with a
# baseless `pkgs.dockerTools.streamLayeredImage` (devShell closure + nix +
# claude-code + gh, content-addressed layers). The paired devcontainer.json only
# swaps its `image:` tag between phases — so this file is a disposable scaffold,
# not sunk cost.
#
# What this image bakes in (replacing the old GHCR features):
#   - Nix (single-user, flakes on)         <- was ghcr.io/devcontainers/features/nix
#   - the flake devShell, PRE-WARMED        <- so first `nix develop` is instant
#   - gh CLI                                <- was devcontainers/features/github-cli
#   - claude-code (nvm path preserved)      <- was devcontainers-extra/claude-code
# Claude state persistence (was the claude-code-persistence feature) moves to a
# `mounts:` named volume in devcontainer.json — it was never an image concern.
#
# Local build + smoke test (this host has docker + the devcontainer CLI, no nix):
#   docker buildx build --platform linux/arm64 -f .devcontainer/Dockerfile \
#     -t nix-config-devcontainer:local --load .
#   (full smoke commands live in .devcontainer/README or the PR notes)
###############################################################################

# Pinning by digest is mandatory in phase 2 and advisable here; left as the
# moving :noble tag for phase 1 so the scaffold tracks the base it replaces.
FROM mcr.microsoft.com/devcontainers/base:noble

# noble already provides everything a dev container runtime probes for: the
# `vscode` non-root user (uid 1000) with a real /etc/passwd entry + writable
# home, /bin/sh + bash + zsh (/usr/bin/zsh), coreutils, locale, ca-certificates,
# git, curl. We KEEP all of it — that is the whole point of starting from noble.

# NIX_INSTALLER_VERSION pins the installer => indirectly pins Nix.
# CACHIX_CACHE (optional): pass a cache name to accelerate the warm.
# NODE_MAJOR: node line for the nvm-based claude-code install.
# (Dockerfile has no inline comments — `#` is only a comment at line start —
# so these notes must live on their own lines, NOT after the ARG values.)
ARG NIX_INSTALLER_VERSION=v3.5.2
ARG CACHIX_CACHE=ismailkattakath
ARG NODE_MAJOR=22

# --- 1. Nix (Determinate installer, single-user, no daemon) ------------------
# `--init none` => no systemd/daemon supervision (the only mode that reliably
# works baked into a Docker image, which has no init). `build-users-group =`
# (empty) => single-user store, no nixbld group needed. flakes enabled. We then
# hand /nix to vscode so the non-root remoteUser can realise paths from
# `nix develop` without sudo. (Phase-1 simplification; phase 2's store is
# read-only image layers and this chown disappears.)
RUN curl --proto '=https' --tlsv1.2 -sSf -L \
      "https://install.determinate.systems/nix/tag/${NIX_INSTALLER_VERSION}" \
    | sh -s -- install linux \
        --init none \
        --extra-conf "experimental-features = nix-command flakes" \
        --extra-conf "trusted-users = root vscode" \
        --extra-conf "build-users-group =" \
        --no-confirm

# Put nix on PATH for every later build layer AND at container runtime.
ENV PATH="${PATH}:/nix/var/nix/profiles/default/bin"

# Single-user store ownership for the non-root remoteUser.
RUN chown -R vscode:vscode /nix

# --- 2. gh + claude-code, matching the CURRENT image's binary paths ----------
# gh via the official apt repo => /usr/bin/gh (mirrors the github-cli feature;
# `arch=` keeps it correct on both amd64 and arm64). Auth stays a runtime
# `gh auth login` concern — nothing baked.
RUN install -dm755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y gh \
 && rm -rf /var/lib/apt/lists/*

# claude-code via the SAME nvm prefix the old feature used, so the existing
# `terminal.integrated.profiles.linux.claude` path
# (/usr/local/share/nvm/current/bin/claude) keeps working unchanged. Pulling it
# from nixpkgs (pkgs.claude-code, unfree) is a clean phase-2 task.
ENV NVM_DIR=/usr/local/share/nvm
RUN mkdir -p "$NVM_DIR" \
 && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash \
 && . "$NVM_DIR/nvm.sh" \
 && nvm install "${NODE_MAJOR}" \
 && ln -sfn "$NVM_DIR/versions/node/$(nvm version "${NODE_MAJOR}")" "$NVM_DIR/current" \
 && npm install -g @anthropic-ai/claude-code \
 && chmod -R a+rX "$NVM_DIR"

# Matches the devcontainer.json containerEnv; lets claude (unfree) run in-shell.
ENV NIXPKGS_ALLOW_UNFREE=1

# --- 3. PRE-WARM the flake devShell into the image's /nix/store --------------
# Copy ONLY the flake-eval inputs first, so this expensive layer is invalidated
# only when the lock/flake/treefmt change — NOT on every source edit.
USER vscode
WORKDIR /tmp/warm
COPY --chown=vscode:vscode flake.nix flake.lock treefmt.nix ./

# Flakes evaluate the git TREE, not the working dir (this repo's git-purity
# rule), and the devShell shellHook installs a pre-commit hook into .git/hooks.
# A throwaway git tree satisfies both; the hook it writes is discarded with the
# tree — the part we keep is the realised devShell closure in /nix/store.
RUN git init -q . \
 && git config user.email warm@build.local \
 && git config user.name warm \
 && git add -A

# Cachix: defaults to the public `ismailkattakath` cache so the warm becomes a
# download instead of a from-source build (important for the QEMU-emulated
# cross-arch leg). Public read needs NO token — `cachix use` only writes the
# substituter URL + public key. Pass --build-arg CACHIX_CACHE= to disable.
RUN if [ -n "${CACHIX_CACHE}" ]; then \
      nix profile install nixpkgs#cachix && cachix use "${CACHIX_CACHE}" || true ; \
    fi

# THE WARM: realises the devShell closure (.#default for THIS arch) into
# /nix/store and runs the shellHook. `--command true` exits immediately after.
# One retry guards a flaky network/hook in the minimal tree — the goal is the
# cached closure, not a green hook.
RUN nix develop .#default --command true \
 || nix develop .#default --command true

# Drop the throwaway tree; the realised store paths persist in the image layers.
WORKDIR /workspaces/nix-config
USER root
RUN rm -rf /tmp/warm
USER vscode

# No blocking Cmd/Entrypoint: the devcontainer CLI injects its own keepalive
# (overrideCommand defaults true for image-based containers). Phase-1 image is
# intentionally fat (noble + full store + node); minification is phase 2.
