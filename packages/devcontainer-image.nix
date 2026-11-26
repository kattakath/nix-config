# Nix-FULL devcontainer image for nix-config — the deliberate inverse of a
# nix-free application image. This repo's devcontainer exists to RUN Nix
# (`nix flake check`, `darwin-rebuild`, `nixos-rebuild`), so the baked payload
# IS a working Nix plus the DB-registered devShell closure: inside the
# container, `nix develop` realizes nothing (no build, no download).
#
# STORE ACCESS MODEL — Nix's MULTI-USER model (not single-user):
#   `streamLayeredImage` bakes /nix/store IMMUTABLY root-owned (it rebuilds the
#   store dir from the store-path layers and discards any chown/chmod of it).
#   That is the PRECONDITION of Nix multi-user, not a bug: the container starts
#   a root `nix-daemon` (via the entrypoint) and unprivileged `vscode` reaches
#   it over the socket (`NIX_REMOTE=daemon`), so the daemon does all privileged
#   store writes. Mirrors the first-party devcontainers/features/nix path — no
#   chown hacks, no sudo.
#
# Built by CI (.github/workflows/build-devcontainer.yml), pushed multi-arch to
# GHCR, referenced verbatim by .devcontainer/devcontainer.json (remoteUser
# vscode + overrideCommand:false so the daemon entrypoint runs). Replaces the
# old four-Features stack (nix / node / claude-code / github-cli).
#
#   nix build .#packages.<linux>.devcontainerImage   # ./result = stream script
#   ./result | docker load                           # local smoke test
#   ./result | gzip --fast | skopeo copy docker-archive:/dev/stdin docker://...  # CI push
#
# `devPackages` is the SHARED dev toolchain list from modules/parts/devshell.nix (config.devPackages),
# the same list the `nix develop` devShell uses — so image and shell never drift.
{
  pkgs,
  lib,
  devPackages,
  orgName,
  repoName,
  cachixUrl,
  cachixKey,
}:

let
  inherit (pkgs) dockerTools;

  username = "vscode";
  uid = 1000;
  gid = 1000;
  workdir = "/workspaces/nix-config";

  # Pieces the removed devcontainer Features provided, plus base userland. `nix`
  # is the whole point; `nodejs` is required because Claude Code's JS hooks run
  # bare `node` under /bin/sh. claude-code is NOT baked in (2026-11-25): nixpkgs
  # marks it redistributable = false and this image is public. The devShell
  # (modules/parts/devshell.nix) fetches it from Anthropic on `nix develop`.
  extraTools = with pkgs; [
    nix
    nodejs-slim_22 # `node` only: the hooks need no npm/corepack (image -12.4 MiB, measured)
    gh
    bashInteractive
    coreutils
    gnugrep
    gnused
    gawk
    findutils
    which
    cacert # CA bundle for every https client (nix substituters, gh, git)
    gnutar
    gzip
    xz
    openssh
    # Fleet Shape Program phase 6 (ADR-016 § 3: `.envrc` = `use flake` + `.env`). nix-direnv
    # replaces direnv's own `use flake` with a CACHED one: the stock loader re-evaluated the
    # flake on every reload, the VS Code restart loop that got direnv removed on 2026-06-22
    # (a0c12251).
    direnv
    nix-direnv
  ];

  basePackages = devPackages ++ extraTools;

  # Foreign (non-Nix) glibc binaries — e.g. the VS Code Server's bundled generic
  # `node` — hardcode the STANDARD ELF interpreter path in their PT_INTERP; the
  # kernel refuses them (exit 127) when it is absent, and this distroless image
  # has glibc only under /nix/store. So the standard loader path must be
  # populated. The image is multi-arch, so the loader FILENAME is derived from
  # the target platform, never hardcoded: ld-linux-aarch64.so.1 (canonically in
  # /lib) on aarch64, ld-linux-x86-64.so.2 (in /lib64) on x86_64.
  hostPlat = pkgs.stdenv.hostPlatform;
  loaderInfo =
    if hostPlat.isAarch64 then
      {
        name = "ld-linux-aarch64.so.1";
        libDir = "lib";
      }
    else if hostPlat.isx86_64 then
      {
        name = "ld-linux-x86-64.so.2";
        libDir = "lib64";
      }
    else
      throw "devcontainer-image: unsupported host platform ${hostPlat.system} — add its glibc loader name/dir";

  # nix-ld contract: the library search path exposed to FOREIGN (non-Nix) glibc
  # binaries (the VS Code Server's node, prebuilt language servers, …) via
  # NIX_LD_LIBRARY_PATH / LD_LIBRARY_PATH in config.Env. Imported from the shared
  # list the repo's NixOS hosts already use (modules/nixos/core.nix) so image and
  # hosts never drift — and so the NEXT foreign binary that needs zlib/openssl/
  # libGL just works with no image change. This is the ONE place the set grows,
  # instead of a per-soname shim added after each breakage.
  nixLdLibraries = import ../modules/_lib/nix-ld-libraries.nix pkgs;
  nixLdLibraryPath = lib.makeLibraryPath nixLdLibraries;

  # The `vscode` user plus Nix's build users. fakeNss yields a READ-ONLY /etc/passwd
  # (hence updateRemoteUserUID:false in the JSON); Nix only READS it. Build users are
  # the official NixOS/nix docker.nix layout, copied exactly: nixbld1..32, uid 30000+n,
  # gid 30000, home /var/empty, shell /bin/false, and the group line LISTS its members
  # (Nix's user-lock.cc reads gr_mem, not primary gids). Builds then run as a nixbld
  # uid, never root, so an unsandboxed builder cannot create /homeless-shelter, the
  # check that otherwise fails every later build (unix-derivation-builder.cc).
  buildUsers = map (n: "nixbld${toString n}") (lib.range 1 32);
  nss = pkgs.fakeNss.override {
    extraPasswdLines = [
      "${username}:x:${toString uid}:${toString gid}:${username}:/home/${username}:${pkgs.bashInteractive}/bin/bash"
    ]
    ++ lib.imap1 (
      n: u: "${u}:x:${toString (30000 + n)}:30000:Nix build user ${toString n}:/var/empty:/bin/false"
    ) buildUsers;
    extraGroupLines = [
      "${username}:x:${toString gid}:"
      "nixbld:x:30000:${lib.concatStringsSep "," buildUsers}"
    ];
  };

  # Container entrypoint: start the root nix-daemon (idempotent) then exec the
  # command. Plain backgrounded process, no systemd — the standard container
  # pattern, mirroring devcontainers/features/nix's nix-entrypoint.sh.
  #
  # writeShellApplication for ShellCheck, with `bashOptions = [ ]` ON PURPOSE: this
  # script never ran under `set -e`, and its bounded wait loop ends on a failing
  # `daemon_alive && break`. Adding errexit to a container entrypoint that cannot be
  # exercised from the Mac is a behaviour change, not hygiene.
  entrypoint = pkgs.writeShellApplication {
    name = "nix-daemon-entrypoint";
    bashOptions = [ ];
    text = ''
      socket=/nix/var/nix/daemon-socket/socket
      # LIVENESS, not mere presence: a crashed daemon leaves the socket INODE behind,
      # so the old `[ ! -S socket ]` file test saw a dead socket, skipped the restart,
      # and every client then got "Connection refused". Probe an actual store ping
      # (the same liveness check the CI smoke test uses); a stale inode fails it and
      # we reclaim it before rebinding.
      daemon_alive() {
        [ -S "$socket" ] && NIX_REMOTE=daemon ${pkgs.nix}/bin/nix store ping >/dev/null 2>&1
      }
      if ! daemon_alive; then
        rm -f "$socket"
        # CRITICAL: the image sets NIX_REMOTE=daemon for CLIENTS, but the daemon
        # itself must NOT inherit it — otherwise it opens a RemoteStore pointing at
        # its own socket and proxies to itself (binds the socket, then resets every
        # request → "Connection reset by peer"). Run the daemon with NIX_REMOTE
        # empty so it drives the LOCAL store directly.
        NIX_REMOTE=''' ${pkgs.nix}/bin/nix-daemon > /tmp/nix-daemon.log 2>&1 &
        # Bounded wait until it actually LISTENS (not merely until the file appears).
        for _ in $(seq 1 50); do daemon_alive && break; done
      fi
      exec "$@"
    '';
  };
in
dockerTools.streamLayeredImage {
  name = "nix-config-devcontainer";
  # Read by checks.<system>.ci-closures-redistributable: what the image ships.
  passthru = { inherit basePackages; };
  tag = "latest";

  # binSh / usrBinEnv are upstream dockerTools helpers that symlink /bin/sh ->
  # bashInteractive and /usr/bin/env -> coreutils env (see the FHS contract in
  # fakeRootCommands), replacing hand-rolled `ln -sf`.
  contents = basePackages ++ [
    nss
    dockerTools.binSh
    dockerTools.usrBinEnv
  ];

  # Store-path -> layer fan-out, under dockerTools' 125-layer ceiling.
  maxLayers = 120;

  # Register the closure of `contents` in the image's Nix DB so `nix develop`
  # sees VALID store paths (no rebuild/redownload). Upstream mechanism, replacing
  # a manual `nix-store --load-db`; also resets registrationTime to
  # SOURCE_DATE_EPOCH for reproducibility.
  includeNixDB = true;

  # enableFakechroot lets fakeRootCommands see the merged rootfs (so store paths
  # and /bin/sh resolve) via fakechroot+proot — forbidden on Darwin, fine in CI.
  enableFakechroot = true;
  fakeRootCommands = ''
    set -eu

    # ==========================================================================
    # FHS compat contract for the FOREIGN VS Code Server
    # --------------------------------------------------------------------------
    # This distroless image has NO base distro — glibc, a shell, and coreutils
    # live only under /nix/store. The VS Code Server (and other prebuilt binaries)
    # are generic-glibc FOREIGN binaries that make hardcoded FHS assumptions.
    # Every such assumption is satisfied HERE, deliberately in one place, instead
    # of reactively one breakage at a time. There are exactly three kinds:
    #
    #   (1) ELF loader — the nix-ld contract. Foreign binaries hardcode the
    #       STANDARD loader path in PT_INTERP; without it the kernel refuses them
    #       (exit 127). We OWN /lib*/ld-linux-* on a distroless image, and point it
    #       at the nix-ld SHIM, as NixOS's programs.nix-ld does (environment.ldso).
    #       The shim execs the real loader (NIX_LD) with NIX_LD_LIBRARY_PATH for
    #       THAT binary only; nothing is exported globally, so a Nix devShell from
    #       any nixpkgs keeps its own glibc. NOT via /lib symlinks or
    #       /etc/ld.so.cache, which the nixpkgs-patched loader ignores (SYSTEM_DIRS
    #       = the glibc store path; dont-use-system-ld-so-cache.patch).
    #   (2) Interpreter PATHS the kernel resolves BEFORE any ELF loader runs — a
    #       `#!/usr/bin/env sh` shebang and hardcoded `/bin/sh`. nix-ld cannot help
    #       here (this is path resolution, not dynamic loading); they must exist.
    #   (3) Distro identity — /etc/os-release, probed by the devcontainer runtime
    #       on every `devcontainer up`; ID=nixos also short-circuits the server's
    #       check-requirements.sh glibc-version probe.
    # ==========================================================================

    # (1) ELF loader: standard path -> nixpkgs glibc loader. Arch-derived name,
    #     mirrored across /lib <-> /lib64 for binaries that probe the sibling dir.
    mkdir -p lib lib64
    ln -sf ${pkgs.nix-ld}/libexec/nix-ld ${loaderInfo.libDir}/${loaderInfo.name}
    ${
      lib.optionalString (loaderInfo.libDir == "lib") ''
        ln -sf ${pkgs.nix-ld}/libexec/nix-ld lib64/${loaderInfo.name}
      ''
    }${
      lib.optionalString (loaderInfo.libDir == "lib64") ''
        ln -sf ${pkgs.nix-ld}/libexec/nix-ld lib/${loaderInfo.name}
      ''
    }

    # (2) Interpreter paths /bin/sh + /usr/bin/env come from dockerTools.binSh /
    #     dockerTools.usrBinEnv in `contents` (byte-identical symlinks to
    #     bashInteractive/bin/bash and coreutils/bin/env). /bin/sh is hardcoded by
    #     many tools + the entrypoint's exec target; the VS Code Server bootstrap
    #     scripts (check-requirements.sh and siblings) use `#!/usr/bin/env sh`, so
    #     without /usr/bin/env the kernel rejects the shebang (exit 126) and the
    #     server never installs.

    # (3) Distro identity — silences the devcontainer distro probe; ID=nixos also
    #     short-circuits the server's check-requirements.sh glibc-version check.
    mkdir -p etc usr/lib
    cat > etc/os-release <<'OSRELEASE'
    NAME="nix-config devcontainer"
    ID=nixos
    ID_LIKE=nixos
    PRETTY_NAME="nix-config devcontainer (distroless)"
    VERSION_ID="unstable"
    HOME_URL="https://github.com/${orgName}/${repoName}"
    OSRELEASE
    ln -sf /etc/os-release usr/lib/os-release

    # --- runtime writable dirs -----------------------------------------------
    # writable HOME for vscode (gh config, ~/.claude, npm cache).
    mkdir -p home/${username}
    chown -R ${toString uid}:${toString gid} home/${username}

    # world-writable, sticky /tmp (nix-daemon.log lands here; nix build tmp).
    mkdir -p tmp
    chmod 1777 tmp

    # workspace bind-mount target.
    mkdir -p .${workdir}
    chown -R ${toString uid}:${toString gid} workspaces

    # --- runtime Nix state dirs ----------------------------------------------
    # The store DB itself is baked by `includeNixDB = true` above (registers the
    # closure of `contents`); it also creates db/ + gcroots/. We still pre-create
    # daemon-socket/, profiles/ and temproots/ (with the upstream --daemon
    # installer's perms) so the daemon never has to mkdir them at runtime over
    # baked-immutable /nix — which can crash the worker after the listen socket is
    # already visible. CRITICAL: do NOT bind-mount a volume over /nix in
    # devcontainer.json — it shadows this baked warm store.
    mkdir -p nix/var/nix/db nix/var/nix/profiles nix/var/nix/gcroots nix/var/nix/temproots \
             nix/var/nix/daemon-socket
    chmod 0755 nix/var/nix/daemon-socket

    # --- direnv: config OUTSIDE $HOME (DIRENV_CONFIG, below) -------------------
    # A dotfiles repo or a home volume replaces ~/.bashrc and ~/.config, so the hook and
    # the nix-direnv loader live in /etc. bashInteractive is built with
    # SYS_BASHRC=/etc/bashrc, read by every interactive non-login shell (a VS Code
    # terminal). No whitelist on purpose: trust is per workspace (`direnv allow` from the
    # consumer's devcontainer.json), never a blanket prefix in a public image.
    mkdir -p etc/direnv
    cat > etc/direnv/direnvrc <<'DIRENVRC'
    source ${pkgs.nix-direnv}/share/nix-direnv/direnvrc
    DIRENVRC
    cat > etc/bashrc <<'BASHRC'
    [[ $- == *i* ]] && eval "$(${pkgs.direnv}/bin/direnv hook bash)"
    BASHRC

    # --- baked nix.conf: multi-user daemon + flakes + public Cachix (read) ----
    # sandbox=false: Docker's default seccomp profile blocks the namespaces the
    # sandbox needs, without --privileged (the official docker.nix sets it too).
    # build-users-group=nixbld: builds run as a nixbld uid (fakeNss above), as in
    # the official image. An EMPTY group built as root, and a root cargo build left
    # /homeless-shelter behind, which then failed every later build (2026-11-26).
    # trusted-users lets vscode add substituters / import paths interactively.
    # The Cachix key is public-read (verification key, mirrored in
    # modules/nixos/nix-cache.nix) — no token baked in.
    mkdir -p etc/nix
    cat > etc/nix/nix.conf <<'NIXCONF'
    experimental-features = nix-command flakes
    build-users-group = nixbld
    sandbox = false
    trusted-users = root vscode
    extra-substituters = ${cachixUrl}
    extra-trusted-public-keys = ${cachixKey}
    NIXCONF
  '';

  config = {
    # The image carries its own devcontainer settings (containers.dev spec: the
    # `devcontainer.metadata` label), so ANY consumer, not only this repo's
    # devcontainer.json, gets the user, the kept entrypoint (the daemon) and an init.
    # devcontainer.json keeps only what a label cannot carry. STATIC OCI labels only:
    # per-commit keys (revision, created) are index annotations at publish time
    # (.github/workflows/build-devcontainer.yml), or this drvPath would change on every
    # commit and defeat the publish gate.
    Labels = {
      "devcontainer.metadata" = builtins.toJSON [
        {
          remoteUser = username;
          updateRemoteUserUID = false;
          overrideCommand = false;
          init = true;
          # The direnv extension, version-pinned (third-party, reaches every consumer),
          # told the binary's absolute path: an extension host that cannot find direnv on
          # its PATH was the other half of the 2026-06-22 removal.
          customizations.vscode = {
            extensions = [ "mkhl.direnv@0.17.0" ];
            settings."direnv.path.executable" = "${pkgs.direnv}/bin/direnv";
          };
        }
      ];
      "org.opencontainers.image.source" = "https://github.com/${orgName}/${repoName}";
      "org.opencontainers.image.description" =
        "Nix devcontainer: multi-user Nix with a warm store, node, gh, direnv + nix-direnv. claude-code arrives via nix develop.";
    };

    # Container/entrypoint runs as ROOT so the nix-daemon starts privileged.
    # VS Code drops to the non-root `vscode` remoteUser for terminals/processes,
    # which reach the daemon over the socket (NIX_REMOTE=daemon below).
    User = "0:0";
    WorkingDir = workdir;

    # Entrypoint starts the daemon, then execs Cmd. Requires overrideCommand:false
    # in devcontainer.json so VS Code respects this entrypoint; Cmd = a keepalive
    # so the container stays up for `docker exec` sessions.
    Entrypoint = [ (lib.getExe entrypoint) ];
    Cmd = [
      "${pkgs.coreutils}/bin/sleep"
      "infinity"
    ];

    Env = [
      # /bin holds the /bin/sh symlink (from dockerTools.binSh); the FHS
      # /usr/local/bin:/usr/bin dirs are never created in this distroless Nix
      # image, so they were dead PATH entries and are omitted.
      "PATH=${lib.makeBinPath basePackages}:/bin"
      "HOME=/home/${username}"
      "USER=${username}"
      # Multi-user: clients talk to the root daemon over the socket.
      "NIX_REMOTE=daemon"
      "NIXPKGS_ALLOW_UNFREE=1"
      # TLS trust for every https client baked in.
      "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "LANG=C.UTF-8"
      "DEVCONTAINER=true"
      # direnv's config dir (internal/cmd/config.go reads DIRENV_CONFIG before XDG).
      "DIRENV_CONFIG=/etc/direnv"
      # nix-ld env contract for FOREIGN (non-Nix) glibc binaries (the VS Code
      # Server's node, prebuilt language servers): the /lib*/ld-linux-*.so.*
      # symlink (fakeRootCommands) lets the kernel EXEC them; these vars let the
      # loader FIND their shared libs. Baking the broad SHARED library set — the
      # same one the NixOS hosts use (modules/_lib/nix-ld-libraries.nix) — means
      # the next foreign binary needing zlib/openssl/libGL runs with no image
      # change, ending the per-soname whack-a-mole. NO global LD_LIBRARY_PATH: it
      # used to mirror this one (the loader was glibc itself), and it was benign only
      # for binaries from the image's OWN nixpkgs. A devShell on an older pin
      # (glibc 2.42 against the image's 2.44) died with a bus error (2026-11-26,
      # listing-lens and scrape-harness); the shim scopes the libs to foreign
      # binaries instead. CI's "older nixpkgs runs" guard keeps it that way.
      "NIX_LD=${pkgs.stdenv.cc.bintools.dynamicLinker}"
      "NIX_LD_LIBRARY_PATH=${nixLdLibraryPath}"
    ];
  };
}
