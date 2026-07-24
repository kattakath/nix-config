{
  description = "Greenfield aarch64 Nix mono-repo: macOS (nix-darwin) client, a Raspberry Pi 4 NixOS server (nixpi), and a throwaway aarch64-linux NixOS dev VM (nixvm) booted only via `nix run .#nixvm` — single source of truth across the fleet.";

  inputs = {
    # Unstable channel as the single source of truth for every platform.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # macOS system layer (standalone, not NixOS). Follows the parent nixpkgs
    # so we never download a second copy of the package set.
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    # User layer, shared by every host.
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # Formatting/lint aggregator: one config (./treefmt.nix) drives `nix fmt`,
    # the `checks.formatting` CI gate, and the pre-commit hook. Single source.
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    # Git pre-commit hooks, installed automatically on `nix develop`.
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";

    # Raspberry Pi 4 NixOS support: kernel, firmware, and SD-card image builder.
    raspberry-pi-nix.url = "github:nix-community/raspberry-pi-nix";
    raspberry-pi-nix.inputs.nixpkgs.follows = "nixpkgs";

    # Daily-updated VS Code Marketplace + Open VSX mirror. Lets us pin editor
    # extensions declaratively (programs.vscode). macOS-only consumer — the
    # vscode block in modules/shared/home.nix is gated `mkIf isDarwin`, so the
    # Linux hosts never reference it (and never receive it as a specialArg).
    nix-vscode-extensions.url = "github:nix-community/nix-vscode-extensions";
    nix-vscode-extensions.inputs.nixpkgs.follows = "nixpkgs";

    # Declaratively INSTALLS Homebrew itself at the arch-correct prefix
    # (/opt/homebrew on Apple Silicon `macos`) — the prefix is auto-selected
    # from the host's stdenv platform. Runs UNDER nix-darwin's built-in
    # `homebrew.*` module, which still owns brews/casks (see
    # modules/darwin/homebrew.nix). No `nixpkgs` input to follow — the module
    # uses the consumer's pkgs.
    nix-homebrew.url = "github:zhaofengli/nix-homebrew";

    # Nix -> OpenTofu/Terraform JSON renderer for the Cloudflare-side tunnel
    # objects (infra/cloudflare/nixpi-tunnel.nix — the remotely-managed tunnel +
    # ingress + proxied CNAME + connector-token output).
    terranix.url = "github:terranix/terranix";
    terranix.inputs.nixpkgs.follows = "nixpkgs";

    # Determinate Nix — on the `macos` host ONLY, `determinate-nixd` takes over
    # the Nix daemon and owns /etc/nix/nix.conf (nix.enable = false there). The
    # NixOS hosts stay on standard `nix.settings`. Sourced from FlakeHub.
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/*";

    # agenix — encrypted secrets committed to THIS repo (age, SSH-key based).
    # Each secret in ./secrets/*.age is encrypted to its target host's SSH host
    # key (so the host decrypts at activation with /etc/ssh/ssh_host_ed25519_key)
    # plus the operator's key; recipients are declared in ./secrets/secrets.nix.
    # Pure age/SSH — no ssh-to-age step, no Go build. Follows our nixpkgs.
    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";

    # MCP (Model Context Protocol) server packaging for Claude Code. We use its
    # `lib.mkConfig` to render a PINNED {mcpServers:{…}} JSON (the 4 packaged
    # servers become reproducible store-path commands) that our localhost
    # mcp-proxy gateway consumes via --named-server-config. Threaded to
    # modules/shared/mcp.nix (darwin-gated) through extraSpecialArgs — NOT as a
    # home-manager module (the client side uses upstream
    # `programs.claude-code.mcpServers` directly). Follows our nixpkgs so we
    # never pull a second package set.
    mcp-servers-nix.url = "github:natsukium/mcp-servers-nix";
    mcp-servers-nix.inputs.nixpkgs.follows = "nixpkgs";

    # ---- Agent skills for Claude Code (source-only, flake = false) -------------
    # Placed at ~/.claude/skills/<name>/ declaratively by programs.claude-code.skills
    # (modules/shared/home.nix, darwin-gated). Pinned in flake.lock, bumped via
    # `nix flake update` — the reproducible replacement for imperative
    # `npx skills add --global`, with NO vendored copies committed here.
    # find-skills: skill discovery from skills.sh.
    agent-skills-vercel = {
      url = "github:vercel-labs/skills";
      flake = false;
    };
    # Anthropic's official claude-code repo — source of the plugin-dev + hookify
    # AUTHORING skills (agent/skill/plugin/hook development) for smarter setup.
    agent-skills-anthropic = {
      url = "github:anthropics/claude-code";
      flake = false;
    };
    # xAI's OFFICIAL Claude Code plugin (grok-build-plugin-cc) — the sanctioned
    # Grok Build <-> Claude Code bridge (/grok-build:{review,critique,delegate,
    # import,...}). Pinned flake=false; its self-contained plugin dir is wired into
    # programs.claude-code.plugins (modules/shared/home.nix, darwin-gated). Needs
    # grok on PATH (home.sessionPath ~/.grok/bin) + Node; grok must be authenticated.
    grok-build-plugin-cc = {
      url = "github:xai-org/grok-build-plugin-cc";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nix-darwin,
      home-manager,
      treefmt-nix,
      git-hooks,
      raspberry-pi-nix,
      nix-vscode-extensions,
      nix-homebrew,
      terranix,
      determinate,
      agenix,
      mcp-servers-nix,
      agent-skills-vercel,
      agent-skills-anthropic,
      grok-build-plugin-cc,
      ...
    }:
    let
      # ---- Single source of truth for the human identity ---------------------
      # userName is the POSIX ACCOUNT on every host (users.users.${userName},
      # home-manager.users.${userName}, /Users/ismail on the Mac) — NOT a label.
      # It is deliberately NOT the GitHub handle: renaming it would repoint
      # home-manager at a user that does not exist on the machine.
      userName = "ismailkattakath";
      domainName = "kattakath.com";
      fullName = "Ismail Kattakath";

      # The human's GitHub handle. Since the fleet moved under the `kattakath`
      # org this is NO LONGER the repo owner — it is just the person.
      handleName = "ismailkattakath";

      # Git identity. Its own binding rather than "${userName}@${domainName}",
      # so the commit address can be GitHub's noreply (which never leaks a real
      # mailbox) without dragging the POSIX account name along with it.
      userEmail = "8927166+${handleName}@users.noreply.github.com";

      # ---- Single source of truth for the GitHub owner -----------------------
      # The org that owns the repo, the Cachix cache and the self-hosted runners.
      # Split from handleName so the two can never be confused again: everything
      # that says "who publishes this" is orgName; everything that says "who is
      # the person" is handleName/userName.
      orgName = "kattakath";
      repoName = "nix-config";
      flakeRef = "github:${orgName}/${repoName}";

      # ---- Single source of truth for the Cachix binary cache ----------------
      # The public read-only CI cache, consumed by every host. Threaded into the
      # NixOS builder's specialArgs (modules/shared/nix-cache.nix) and into the
      # macOS host's Determinate customSettings — one literal, no duplication.
      cachixUrl = "https://${orgName}.cachix.org";
      cachixKey = "${orgName}.cachix.org-1:y/w6wnb4ZArdlbfWJ82c81uCXeYgG/sGDUYCszavmEw=";

      # ---- Single source of truth for the operator SSH public key ------------
      # The sole network login credential on every NixOS host AND the agenix
      # "keep editable" recipient. Public, so the secret-free sdImage embeds it
      # freely. Threaded to core.nix via mkNixos specialArgs and read directly by
      # secrets/secrets.nix — one file to edit on rotation (see secrets/operator-key.nix).
      operatorSshKey = import ./secrets/operator-key.nix;

      # ---- Single source of truth for the live-wallpaper loopback port -------
      # The darkhttpd server (modules/darwin/core.nix) serves packages/live-wallpaper
      # on this port and Plash is pointed at it by the home.nix activation. Two
      # module systems (nix-darwin + home-manager) that MUST agree, so it is one
      # binding threaded to both rather than a literal duplicated across files.
      wallpaperPort = 8765;

      # ---- Single source of truth for the public (OAuth-gated) MCP port ------
      # The kapture-only mcp-proxy (modules/shared/mcp.nix) binds this loopback
      # port and the Mac tunnel ingress (infra/cloudflare/macos-mcp-tunnel.nix)
      # forwards mcp.<domain> to it. Threaded to BOTH so they cannot drift.
      mcpPublicPort = 8099;

      # ---- Operator identity email for the MCP Access policy ------------------
      # The Google-IdP email allowed by the Cloudflare Access policy on
      # mcp.<domain> (infra/cloudflare/macos-mcp-tunnel.nix). This is the real
      # login identity, distinct from `userEmail` (the GitHub noreply commit
      # address). Not a secret.
      operatorEmail = "ismail@${domainName}";

      # ---- Single source of truth for the Cloudflare account/zone ------------
      # Threaded (with domainName) into the cfTunnelConfig terranix stack via
      # `_module.args`, so the account/zone ids and the domain live in ONE place
      # instead of being re-hardcoded. These are IDENTIFIERS, not credentials
      # (safe to commit); the API token stays in the CLOUDFLARE_API_TOKEN env var.
      cloudflareAccountId = "726e0b2aa2bc2c6944f96a042e3c461b";
      cloudflareZoneId = "6e28971881e488941d052bbbf50d69cd"; # the domainName zone

      # ---- DRY system mapping -------------------------------------------------
      # A 2-host aarch64-only FLEET (macos + nixpi; nixvm is a throwaway build-vm):
      # no x86_64 HOST anywhere. Every package /
      # devShell / check output is generated for the fleet systems via
      # forAllSystems. (The devcontainer IMAGE is the one multi-arch output — it
      # adds x86_64-linux via devcontainerSystems below, for Codespaces; that is a
      # dev tool, not a fleet host, so the invariant holds where it matters.)
      linuxSystems = [
        "aarch64-linux"
      ];
      darwinSystems = [
        "aarch64-darwin"
      ];
      allSystems = linuxSystems ++ darwinSystems;

      # The devcontainer image — and ONLY the image — is multi-arch. The FLEET
      # stays aarch64-only (linuxSystems), but the devcontainer is a dev tool, not
      # a host: GitHub Codespaces is x86_64-only, and an arm64-only image qemu-
      # emulates (which breaks the nix-daemon container), so the image is built for
      # both. Kept OUT of linuxSystems on purpose — adding x86_64 there would spawn
      # x86 devShells/checks/formatter and break the single-arch invariant that the
      # actual hosts rely on.
      devcontainerSystems = linuxSystems ++ [ "x86_64-linux" ];

      # Dev-tooling outputs (devShell + its treefmt eval) must cover every arch a
      # human might DEVELOP on: the fleet arches PLUS the devcontainer's x86_64.
      # `devcontainer.json` runs `nix develop .#default` as its terminal, so a
      # Codespaces user on x86_64 needs devShells.x86_64-linux.default to exist —
      # without it the container's shell errors out (and the CI smoke test does
      # too). This is NOT the fleet: no host/check/config is generated for x86_64,
      # only the dev environment. CI builds .#checks.<system> (aarch64 only), never
      # a full `nix flake check`, so no aarch64 runner tries to build this.
      devToolingSystems = nixpkgs.lib.unique (allSystems ++ devcontainerSystems);

      forAllSystems = f: nixpkgs.lib.genAttrs allSystems f;

      # Per-system nixpkgs accessor (legacyPackages avoids a redundant eval).
      pkgsFor = system: nixpkgs.legacyPackages.${system};

      # Unfree-permitting nixpkgs, ONLY for the devcontainer image (claude-code is
      # unfree). legacyPackages has unfree disabled, so the image needs its own
      # instance. Deliberately scoped here — no other output imports it.
      pkgsUnfreeFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

      # ---- Cloudflare TUNNEL provisioning (terranix -> OpenTofu) --------------
      # Renders infra/cloudflare/nixpi-tunnel.nix (the remotely-managed tunnel +
      # ingress + proxied CNAME + connector-token output for nixpi) to its own
      # config.tf.json, per system.
      cfTunnelConfig =
        system:
        terranix.lib.terranixConfiguration {
          inherit system;
          # domainName is the zone name, plus the account/zone ids — threaded from
          # the single flake bindings above (one source of truth, no re-hardcoding).
          modules = [
            ./infra/cloudflare/nixpi-tunnel.nix
            {
              _module.args = {
                inherit domainName;
                accountId = cloudflareAccountId;
                zoneId = cloudflareZoneId;
              };
            }
          ];
        };

      # Renders infra/cloudflare/macos-mcp-tunnel.nix (the Mac's OAuth-gated MCP
      # tunnel + Cloudflare Access Managed-OAuth app + policy + connector-token
      # output) to its own config.tf.json, per system.
      cfMcpConfig =
        system:
        terranix.lib.terranixConfiguration {
          inherit system;
          modules = [
            ./infra/cloudflare/macos-mcp-tunnel.nix
            {
              _module.args = {
                inherit domainName operatorEmail;
                accountId = cloudflareAccountId;
                zoneId = cloudflareZoneId;
                publicPort = mcpPublicPort;
              };
            }
          ];
        };

      # writeShellApplication wrapper around `tofu <action>` for the rendered
      # nixpi tunnel config (guards on CLOUDFLARE_API_TOKEN, copies the read-only
      # rendered config out of the store first). On `apply`, it additionally prints the
      # SENSITIVE connector token (a sensitive tofu output) to STDOUT, clearly
      # labeled, so the operator can store it in the vault (`nix run
      # .#nixpi-vault-token`) and plant it on nixpi's FIRMWARE partition. The token
      # is NEVER written to git or the /nix/store — only echoed to the terminal.
      mkCfTunnelTofu =
        {
          system,
          name,
          action,
        }:
        let
          pkgs = pkgsFor system;
          printToken = ''

            echo "----- CONNECTOR TOKEN for nixpi (SECRET) -----"
            echo "TUNNEL_TOKEN=$(tofu output -raw nixpi_connector_token)"
            echo ""
            echo "Store it (from the repo root): pipe the TUNNEL_TOKEN= line above into"
            echo "  nix run .#nixpi-vault-token"
            echo "then plant it on a mounted card with"
            echo "  nix run .#nixpi-provision --token        # (or reflash)"
            echo "----- end nixpi -----"
          '';
        in
        pkgs.writeShellApplication {
          inherit name;
          runtimeInputs = [ pkgs.opentofu ];
          text = ''
            if [ -z "''${CLOUDFLARE_API_TOKEN:-}" ]; then
              echo "ERROR: CLOUDFLARE_API_TOKEN is unset. Export a token with" >&2
              echo "  Account Cloudflare Tunnel:Edit + Zone DNS:Edit on ${domainName}." >&2
              exit 1
            fi
            rm -f config.tf.json
            cp ${cfTunnelConfig system} config.tf.json
            tofu init
            tofu ${action}
          ''
          + nixpkgs.lib.optionalString (action == "apply") printToken;
        };

      # writeShellApplication wrapper around `tofu <action>` for the rendered Mac
      # MCP tunnel config. Like mkCfTunnelTofu, but on `apply` it prints the
      # connector token with the Keychain-store instruction (the Mac connector
      # reads MCP_TUNNEL_TOKEN from the login Keychain — see modules/shared/mcp.nix).
      mkCfMcpTofu =
        {
          system,
          name,
          action,
        }:
        let
          pkgs = pkgsFor system;
          printToken = ''

            echo "----- CONNECTOR TOKEN for the Mac MCP tunnel (SECRET) -----"
            echo "Store it in the login Keychain (the connector reads it there):"
            echo "  set-secret MCP_TUNNEL_TOKEN $(tofu output -raw macos_mcp_connector_token)"
            echo ""
            echo "Then the mcp-tunnel-connector agent picks it up (or: launchctl kickstart)."
            echo "Connector URL for Grok:  https://mcp.${domainName}/servers/kapture/sse"
            echo "----- end Mac MCP tunnel -----"
          '';
        in
        pkgs.writeShellApplication {
          inherit name;
          runtimeInputs = [ pkgs.opentofu ];
          text = ''
            if [ -z "''${CLOUDFLARE_API_TOKEN:-}" ]; then
              echo "ERROR: CLOUDFLARE_API_TOKEN is unset. Export a token with" >&2
              echo "  Account: Cloudflare Tunnel:Edit + Access: Apps and Policies:Edit," >&2
              echo "  Zone DNS:Edit on ${domainName}." >&2
              exit 1
            fi
            rm -f config.tf.json
            cp ${cfMcpConfig system} config.tf.json
            tofu init
            tofu ${action}
          ''
          + nixpkgs.lib.optionalString (action == "apply") printToken;
        };

      # ---- Formatting / lint (treefmt-nix) ------------------------------------
      # The wrapper backs `nix fmt`; the `.config.build.check` derivation backs
      # the CI formatting gate.
      # Evaluated for the fleet systems PLUS the devcontainer's extra arch
      # (x86_64-linux): devPackagesFor bakes treefmtEval.<system>.build.wrapper
      # into the image, so the x86_64 image needs an x86_64 treefmt eval. This is
      # a pure eval and feeds nothing else x86 — `checks`/`packages` keep their own
      # forAllSystems (allSystems) fold, so the fleet stays aarch64-only.
      treefmtEval = nixpkgs.lib.genAttrs devToolingSystems (
        system: treefmt-nix.lib.evalModule (pkgsFor system) ./treefmt.nix
      );

      # ---- Shared dev toolchain -----------------------------------------------
      # Pinned dev tools consumed by BOTH the `nix develop` devShell AND the
      # prebuilt devcontainer image, so the two can never drift.
      # (preCommit.enabledPackages is added on the devShell side only; the image
      # bakes the treefmt wrapper directly.)
      devPackagesFor =
        system:
        let
          pkgs = pkgsFor system;
        in
        [
          pkgs.git
          pkgs.nixd # eval-aware Nix LSP
          home-manager.packages.${system}.default
          treefmtEval.${system}.config.build.wrapper # `treefmt` / `nix fmt`
          # nixfmt as a standalone bin so bare `nixfmt` resolves on PATH for the
          # editor (devcontainer.json's nix.formatterPath + nixd formatting.command
          # both invoke it directly). Sourced from treefmt's own resolved package so
          # it can NEVER drift from the binary the wrapper/CI/pre-commit run.
          treefmtEval.${system}.config.programs.nixfmt.package
          pkgs.statix # anti-pattern linter — .vscode "nix: statix" task
          pkgs.deadnix # dead-code linter — .vscode "nix: deadnix" task
          pkgs.jq # flattens deadnix JSON for the problem matcher
          # agenix secret editing: `agenix -e secrets/<name>.age` (recipients in
          # secrets/secrets.nix). Pure age/SSH — no ssh-to-age needed.
          agenix.packages.${system}.default
        ];

      # ---- Pre-commit hooks (git-hooks.nix) -----------------------------------
      # A single hook runs the treefmt wrapper, so the commit-time tool list can
      # never drift from `nix fmt` / CI — they are literally the same binary.
      preCommitFor =
        system:
        git-hooks.lib.${system}.run {
          src = ./.;
          hooks.treefmt = {
            enable = true;
            package = treefmtEval.${system}.config.build.wrapper;
          };
        };

      # ---- Shared identity + Home-Manager module ------------------------------
      # Threaded into BOTH builders (mkNixos + mkDarwin) so system specialArgs and
      # the embedded Home-Manager block can never drift. Only args with a live
      # module consumer are carried: userName (core/host), fullName+userEmail
      # (home.nix), domainName (nixpi's Caddy vhost + the darwin file-rotation
      # launchd label). handleName only builds userEmail above, and orgName is
      # consumed only by PACKAGES (via callPackage, not specialArgs) now that the
      # self-hosted runners are gone — so neither is threaded.
      identityArgs = {
        inherit
          userName
          fullName
          userEmail
          domainName
          ;
      };

      # The Home-Manager sub-module embedded identically in every host, defined
      # once here instead of inline in each builder. extraSpecialArgs adds
      # mcp-servers-nix (consumed by modules/shared/mcp.nix) to the identity set.
      homeManagerModule = {
        home-manager = {
          useGlobalPkgs = true;
          useUserPackages = true;
          # Back up (don't abort on) any pre-existing UNMANAGED file that a newly
          # Nix-managed home.file would clobber — e.g. ~/.claude/settings.json and
          # ~/.claude/plugins/known_marketplaces.json, now owned by the
          # programs.claude-code marketplaces/settings options. Without this, HM
          # activation hard-fails on the first such collision.
          backupFileExtension = "hm-bak";
          extraSpecialArgs = identityArgs // {
            inherit
              mcp-servers-nix
              agent-skills-vercel
              agent-skills-anthropic
              grok-build-plugin-cc
              # wallpaperPort: consumed by the darwin-gated Plash activation in
              # home.nix (inert on the NixOS hosts).
              wallpaperPort
              # mcpPublicPort: the public (OAuth-gated) mcp-proxy port consumed by
              # modules/shared/mcp.nix (inert on the NixOS hosts).
              mcpPublicPort
              ;
          };
          users.${userName} = {
            imports = [ ./modules/shared/home.nix ];
            home.stateVersion = "24.05";
          };
        };
      };

      # ---- NixOS system builder -----------------------------------------------
      # Full NixOS system with Home Manager embedded, using the same shared user
      # profile as the darwin host.
      mkNixos =
        {
          system,
          hostname,
          extraModules ? [ ],
        }:
        nixpkgs.lib.nixosSystem {
          # Set the platform via the MODERN `nixpkgs.hostPlatform` module option
          # (below), NOT nixosSystem's legacy `system` arg — that arg only sets
          # the deprecated `nixpkgs.system`, leaving `nixpkgs.hostPlatform`
          # undefined. Modules that read `config.nixpkgs.hostPlatform.system`
          # would otherwise fail with "option `nixpkgs.hostPlatform' was accessed
          # but has no value". The two cannot both be set (nixpkgs forbids it), so
          # we drop the arg entirely.
          # Cachix substituter URL + trusted-PUBLIC-key (verification key, safe to
          # expose — NOT a secret) consumed by modules/shared/nix-cache.nix;
          # operatorSshKey (the authorizedKeys credential) by modules/nixos/core.nix.
          # Both are NixOS-only, so they are not in mkDarwin's specialArgs.
          specialArgs = identityArgs // {
            inherit cachixUrl cachixKey operatorSshKey;
          };
          modules = [
            { nixpkgs.hostPlatform = system; }
            ./hosts/${hostname}.nix
            ./modules/nixos/core.nix
            ./modules/shared/nix-cache.nix # Cachix binary cache (read)
            agenix.nixosModules.default # encrypted in-repo secrets (./secrets/*.age)
            home-manager.nixosModules.home-manager
            homeManagerModule
          ]
          ++ extraModules;
        };

      # ---- nix-darwin system builder ------------------------------------------
      # Mirrors mkNixos for the Mac. hostPlatform is driven from `system` (NOT
      # hardcoded in modules/darwin/core.nix) even though this fleet has a single
      # darwin host today.
      mkDarwin =
        {
          system,
          hostname,
          extraModules ? [ ],
        }:
        nix-darwin.lib.darwinSystem {
          inherit system;
          # Shared identity set + wallpaperPort → modules/darwin/core.nix's
          # darkhttpd live-wallpaper server.
          specialArgs = identityArgs // {
            inherit wallpaperPort;
          };
          modules = [
            {
              nixpkgs.hostPlatform = system;
              nixpkgs.overlays = [ nix-vscode-extensions.overlays.default ];
            }
            # Determinate Nix owns the daemon + /etc/nix/nix.conf on macOS
            # (implies nix.enable = false). Route the Cachix cache through
            # /etc/nix/nix.custom.conf via customSettings — NEVER hand-write
            # environment.etc."nix/nix.custom.conf" (that aborts the 2nd rebuild
            # with "custom settings in /etc/nix/nix.custom.conf, aborting
            # activation"). Replaces ./modules/shared/nix-cache.nix here (that
            # module is now NixOS-only, since nix.settings is unavailable once
            # Determinate manages Nix).
            determinate.darwinModules.default
            {
              determinateNix.enable = true; # implies nix.enable = false
              determinateNix.customSettings = {
                extra-substituters = [ cachixUrl ];
                extra-trusted-public-keys = [ cachixKey ];
              };
              # LINUX BUILDS ON macOS (for `nix run .#nixvm`, `.#nixpi`):
              # Determinate's NATIVE Linux builder (Apple Virtualization framework —
              # no remote builder, no Docker) is ENABLED on this host, so aarch64-linux
              # and x86_64-linux derivations build locally on-demand. Verify with
              # `determinate-nixd version` (shows `native-linux-builder`); it appears
              # as an `external-builders` entry in `nix config show`. It is NOT
              # configured from Nix — `external-builders` is a reserved setting
              # Determinate manages and `determinateNix.customSettings` rejects it
              # (asserts at eval); it is a FlakeHub/account-level feature enabled
              # out-of-band via https://dtr.mn/features. It is a build-only, ephemeral,
              # 1-CPU/8GB sandbox — heavy multi-core builds (e.g. the cold RPi kernel)
              # are still best done in the GitHub-hosted CI. nix-darwin's
              # `nix.linux-builder` is unusable here — it requires `nix.enable = true`,
              # which Determinate turns off (nix-darwin#1505).
            }
            nix-homebrew.darwinModules.nix-homebrew # declaratively install brew (arch-correct prefix)
            agenix.darwinModules.default # encrypted in-repo secrets (./secrets/*.age)
            ./hosts/${hostname}.nix
            home-manager.darwinModules.home-manager
            homeManagerModule
          ]
          ++ extraModules;
        };
    in
    {
      # ---- Machine-readable identity ------------------------------------------
      # The flake's single-source `let` identity bindings, surfaced so `bootstrap.sh`
      # can guard on them BEFORE activating. `key-recover` reads
      #   nix eval --raw <flake>#identity.userName
      # right after cloning and HARD-FAILS if it does not equal the macOS login
      # (`id -un`): a mismatch would half-activate home-manager for a POSIX user that
      # does not exist and build /Users/<wrong> paths. This attrset references NO
      # flake inputs, so the eval is instant and fetches nothing — unlike reading
      # `darwinConfigurations.macos.config.system.primaryUser` (which equals userName
      # by construction, core.nix, but forces the whole darwin module fixpoint and
      # every input) and is hostname-independent (does not depend on the "macos" attr
      # key). A forker who sets `userName` here is exactly who the guard lets through.
      identity = {
        inherit
          userName
          orgName
          domainName
          handleName
          ;
      };

      # ---- macOS system configurations ---------------------------------------
      # Built with `darwin-rebuild switch --flake .#macos`.
      darwinConfigurations = {
        # Apple Silicon Mac (aarch64-darwin), client only — no incoming traffic.
        "macos" = mkDarwin {
          system = "aarch64-darwin";
          hostname = "macos";
        };
      };

      # ---- NixOS system configurations -------------------------------------------
      # Built with `nixos-rebuild switch --flake .#<hostname>`.
      # SD card image for the Pi: nix build .#nixosConfigurations.nixpi.config.system.build.sdImage
      nixosConfigurations = {
        # Raspberry Pi 4 — LIVE server (kattakath.com static landing page).
        "nixpi" = mkNixos {
          system = "aarch64-linux";
          hostname = "nixpi";
          extraModules = [
            raspberry-pi-nix.nixosModules.raspberry-pi
            raspberry-pi-nix.nixosModules.sd-image
          ];
        };

        # Throwaway aarch64-linux dev VM, materialised ONLY as the graphical
        # `build-vm` variant behind `nix run .#nixvm` (an XFCE desktop in a
        # native QEMU window — it boots a THROWAWAY overlay, never an installed
        # disk). Since Determinate's native Linux builder is now enabled on the
        # macos host, the aarch64-linux guest closure builds locally with NO
        # provisioning — there is no installed nixvm, no builder VM, no runner.
        "nixvm" = mkNixos {
          system = "aarch64-linux";
          hostname = "nixvm";
          extraModules = [
            # The `build-vm` variant runs on the aarch64-darwin Mac, so its QEMU
            # runner must be macOS-native. host.pkgs is the pkgs whose qemu the
            # generated run-nixvm-vm executes — point it at aarch64-darwin. LAZY:
            # only the `system.build.vm` path forces this, so the aarch64-linux
            # toplevel eval (CI) never pulls in darwin pkgs. The rest of the variant
            # (graphics, desktop) lives in hosts/nixvm.nix.
            { virtualisation.vmVariant.virtualisation.host.pkgs = nixpkgs.legacyPackages."aarch64-darwin"; }
          ];
        };

        # (There is no separate `nixpi-installer`. The LIVE `nixpi` sdImage above
        # IS the flashable artifact — it bakes NO secrets (the tunnel token + Wi-Fi
        # are planted on the FAT FIRMWARE partition post-flash by nixpi-flash), so
        # it is a pure function of the flake and is prebuilt in CI, published to the
        # installer-latest release, and Cachix-warmed. `nix run .#nixpi-flash`
        # flashes it in one step — the old two-step "boot a minimal installer, ssh
        # nixos@nixpi-installer.local, nixos-rebuild" image was redundant and removed.)
      };

      # ---- Packages: container images + installer images ------------------------
      # `nix build .#packages.aarch64-linux.devcontainerImage` → devcontainer stream script
      # `nix build .#nixpi-sd-image`                           → nixpi SD image → ./result/
      # One fold merges base (all systems) → single-system, flatter than nesting
      # recursiveUpdate calls.
      packages = nixpkgs.lib.foldl' nixpkgs.lib.recursiveUpdate { } [
        # Devcontainer image is a Linux OCI artifact — gate to the linux triple
        # (aarch64-only in this fleet). Built with unfree pkgs (claude-code) and
        # the SHARED dev toolchain, so `nix develop` inside the container resolves
        # from the baked store.
        (nixpkgs.lib.genAttrs devcontainerSystems (system: {
          devcontainerImage = (pkgsUnfreeFor system).callPackage ./packages/devcontainer-image.nix {
            devPackages = devPackagesFor system;
            # Identity single-sources (not in pkgs, so callPackage can't autofill):
            # the image's os-release HOME_URL + baked nix.conf Cachix lines reuse
            # these instead of re-hardcoding the handle/cache.
            inherit orgName cachixUrl cachixKey;
          };
        }))

        # Key-recovery kit (macOS only). Exposed as packages so `nix flake check`
        # BUILDS them — which is what runs writeShellApplication's shellcheck on
        # key-backup/key-recover and the explicit shellcheck on the no-Nix
        # bootstrap script. Before this, the recovery scripts lived as loose bash
        # in an iCloud folder that nothing linted and nothing evaluated.
        (nixpkgs.lib.genAttrs darwinSystems (
          system:
          let
            kit = (pkgsFor system).callPackage ./packages/key-recovery.nix {
              # The PINNED agenix, not `nix run github:ryantm/agenix` at runtime:
              # a recovery must not depend on whatever agenix master is that day.
              agenix = agenix.packages.${system}.default;
              inherit orgName;
              inherit flakeRef;
            };
          in
          {
            inherit (kit) key-backup key-recover key-recovery-bootstrap;
          }
        ))

        # nixpi SD-card provisioning toolkit (macOS only). Exposed as packages so
        # `nix flake check` BUILDS them — running writeShellApplication's shellcheck
        # on each of the four apps. See packages/nixpi-provision.nix.
        (nixpkgs.lib.genAttrs darwinSystems (
          system:
          let
            kit = (pkgsFor system).callPackage ./packages/nixpi-provision.nix {
              inherit orgName repoName;
            };
          in
          {
            nixpi-wifi-creds = kit.wifi-creds;
            nixpi-provision = kit.provision;
            nixpi-flash = kit.flash;
            nixpi-vault-token = kit.vault-token;
          }
        ))

        {
          # The LIVE nixpi SD image (not a separate installer): prebuilt in CI
          # (build-installers), published to the installer-latest release, and
          # Cachix-warmed so `nixpi-flash` substitutes it instead of building.
          # Secret-free — token + Wi-Fi are planted post-flash on the FIRMWARE
          # partition, so this public artifact carries only the operator PUBLIC key.
          aarch64-linux.nixpi-sd-image = self.nixosConfigurations.nixpi.config.system.build.sdImage;
        }

        # Cloudflare tunnel provisioning apps (terranix -> OpenTofu), exposed as
        # packages too so `nix flake check` builds them and runs the
        # writeShellApplication shellcheck on each wrapper.
        (forAllSystems (system: {
          cf-tunnel-apply = mkCfTunnelTofu {
            inherit system;
            name = "cf-tunnel-apply";
            action = "apply";
          };
          cf-tunnel-destroy = mkCfTunnelTofu {
            inherit system;
            name = "cf-tunnel-destroy";
            action = "destroy";
          };
          cf-mcp-apply = mkCfMcpTofu {
            inherit system;
            name = "cf-mcp-apply";
            action = "apply";
          };
          cf-mcp-destroy = mkCfMcpTofu {
            inherit system;
            name = "cf-mcp-destroy";
            action = "destroy";
          };
        }))

        # `set-secret <KEY> [VALUE]` — store a secret in the macOS login Keychain
        # (encrypted at rest) and register it for the login export loop
        # (modules/shared/home.nix). DARWIN-ONLY: the Keychain is macOS-only.
        (nixpkgs.lib.genAttrs darwinSystems (system: {
          set-secret = (pkgsFor system).callPackage ./packages/set-secret.nix { };
        }))

        # Vast.ai template-provisioning toolkit (macOS only) — exposed as packages
        # so `nix flake check` BUILDS them (writeShellApplication shellcheck) and
        # lints the committed public bootstrap. The bootstrap's raw URL is pinned to
        # THIS flake's rev. See packages/vast-provision.nix +
        # docs/vastai-template-provisioning.md.
        (nixpkgs.lib.genAttrs darwinSystems (
          system:
          let
            kit = (pkgsFor system).callPackage ./packages/vast-provision.nix {
              inherit orgName repoName userName;
              rev = self.rev or "main";
            };
          in
          {
            vast-template-apply = kit.template-apply;
            vast-repo-check = kit.repo-check;
            vast-account-vars-set = kit.account-vars-set;
            vast-ssh-key-set = kit.ssh-key-set;
            vast-init-repo = kit.init-repo;
            vast-rent = kit.rent;
            vast-scripts-lint = kit.scripts-lint;
          }
        ))

        # RunPod pod-template provisioning (macOS only) — the RunPod analogue of the
        # vast-* apps. Creates a RunPod POD template on runpod/comfyui for a workflow from
        # the --repo workflows repo, provisioned at boot via dockerStartCmd. See
        # packages/runpod-provision.nix.
        (nixpkgs.lib.genAttrs darwinSystems (
          system:
          let
            kit = (pkgsFor system).callPackage ./packages/runpod-provision.nix { };
          in
          {
            runpod-template-apply = kit.template-apply;
          }
        ))
      ];

      # ---- Apps: dev VM + Cloudflare provisioning ----------------------------
      # `nix run .#nixvm` (on the aarch64-darwin Mac) — build the graphical
      # build-vm variant and boot it in a native QEMU window: a THROWAWAY XFCE dev
      # VM, no installed disk, no provisioning. The runner wrapper is a darwin
      # derivation (host.pkgs override above); the aarch64-linux guest closure now
      # builds locally on Determinate's native Linux builder (enabled on the macos
      # host — see the macos block above), or is substituted from Cachix.
      #
      # `nix run .#cf-tunnel-apply` / `.#cf-tunnel-destroy` — render
      # infra/cloudflare/nixpi-tunnel.nix (terranix) then `tofu init` + apply
      # (destroy). Provisions nixpi's remotely-managed tunnel + ingress +
      # proxied CNAME; cf-tunnel-apply additionally PRINTS the connector token to be
      # stored in the vault (`nix run .#nixpi-vault-token`) and planted on the
      # FIRMWARE partition (never written to git/store). Token scope: Account
      # Cloudflare Tunnel:Edit + Zone DNS:Edit on kattakath.com.
      #
      # All need a live token in the environment, e.g.
      #   CLOUDFLARE_API_TOKEN=<scoped> nix run .#cf-tunnel-apply
      # Merged with recursiveUpdate so the static darwin entries and the
      # forAllSystems cf-* apps coexist under one `apps` attribute (a bare
      # `apps.x.y = …` alongside `apps = …` is a duplicate-definition error).
      apps =
        nixpkgs.lib.recursiveUpdate
          {
            # `nix run .#nixvm` — build the graphical build-vm variant and
            # boot it in a native macOS QEMU window: a THROWAWAY XFCE dev VM (no
            # installed disk, no provisioning). The runner wrapper is a darwin
            # derivation (host.pkgs = aarch64-darwin); the aarch64-linux guest
            # closure builds on Determinate's native Linux builder (enabled on the
            # macos host) or is substituted from Cachix. run-nixvm-vm is the
            # qemu-vm.nix script name for "nixvm".
            aarch64-darwin.nixvm = {
              type = "app";
              program = "${self.nixosConfigurations.nixvm.config.system.build.vm}/bin/run-nixvm-vm";
              meta.description = "Boot a THROWAWAY nixvm dev VM with an XFCE desktop in a QEMU window (builds locally on the native Linux builder)";
            };

            # `nix run github:kattakath/nix-config#macos` — one-line first
            # activation of the macos nix-darwin host straight from the flake (the
            # darwin analog of nixpi's `nixos-rebuild switch --flake …#nixpi`).
            # After Determinate Nix is
            # installed but before darwin-rebuild is on PATH, this builds
            # darwin-rebuild from the flake and `switch`es against this SAME
            # revision (${self}); darwin-rebuild self-elevates via sudo/Touch ID.
            # Subsequent rebuilds just use `darwin-rebuild switch --flake .#macos`.
            # `nix run .#key-backup` — on a HEALTHY Mac, before you wipe it:
            # publishes the passphrase-encrypted operator key + the bootstrap
            # script + a (non-secret) fingerprint manifest into iCloud.
            aarch64-darwin.key-backup = {
              type = "app";
              program = "${self.packages.aarch64-darwin.key-backup}/bin/key-backup";
              meta.description = "Publish the encrypted key-recovery kit to iCloud (run BEFORE resetting this Mac)";
            };

            # `nix run .#key-recover` — stage 2 of recovery/founding. bootstrap.sh
            # execs this once Determinate Nix exists. It clones, verifies the macOS
            # login == this flake's `userName` (#identity.userName), then either
            # (kit) decrypts the operator key + re-keys agenix to the new host key,
            # or (--fresh, no kit) FOUNDS a new operator identity + re-initialises
            # the macos service secret to a placeholder — then activates #macos.
            # Stage 1 (the stale-Nix preflight + the installer itself) cannot run
            # under Nix and lives in bootstrap.sh at the repo root.
            aarch64-darwin.key-recover = {
              type = "app";
              program = "${self.packages.aarch64-darwin.key-recover}/bin/key-recover";
              meta.description = "Restore (kit) or found (--fresh) the operator key, re-key agenix to this Mac's host key, and activate #macos";
            };

            aarch64-darwin.macos = {
              type = "app";
              program = "${(pkgsFor "aarch64-darwin").writeShellScript "activate-macos" ''
                exec ${self.darwinConfigurations.macos.config.system.build.darwin-rebuild}/bin/darwin-rebuild switch --flake "${self}#macos" "$@"
              ''}";
              meta.description = "First activation of the macos nix-darwin host from the flake (after Determinate Nix)";
            };

            # `nix run .#set-secret -- KEY [VALUE]` — store a secret in the macOS
            # login Keychain (encrypted at rest) + register it for the login
            # export loop. Bare `nix run` only persists; the `set-secret` shell
            # function (modules/shared/home.nix) also applies it to the current
            # shell. Darwin-only (Keychain).
            aarch64-darwin.set-secret = {
              type = "app";
              program = "${self.packages.aarch64-darwin.set-secret}/bin/set-secret";
              meta.description = "Store KEY=VALUE in the macOS login Keychain (encrypted) and register it for login-shell export; omit VALUE for a hidden prompt";
            };

            # nixpi SD-card provisioning (macOS). The executable runbook: build +
            # verified dd + plant token/wifi (nixpi-flash), plant onto a mounted card
            # (nixpi-provision), emit a wpa_supplicant.conf from this Mac's Wi-Fi
            # (nixpi-wifi-creds), and re-encrypt a rotated token into the vault
            # (nixpi-vault-token). See packages/nixpi-provision.nix + the flashing runbook.
            aarch64-darwin.nixpi-flash = {
              type = "app";
              program = "${self.packages.aarch64-darwin.nixpi-flash}/bin/nixpi-flash";
              meta.description = "Fresh reflash: build (or --image) → verified dd → auto-plant token+wifi (--disk /dev/diskN)";
            };
            aarch64-darwin.nixpi-provision = {
              type = "app";
              program = "${self.packages.aarch64-darwin.nixpi-provision}/bin/nixpi-provision";
              meta.description = "Plant the connector token and/or wpa_supplicant.conf onto a mounted nixpi FIRMWARE partition (--all|--token|--wifi)";
            };
            aarch64-darwin.nixpi-wifi-creds = {
              type = "app";
              program = "${self.packages.aarch64-darwin.nixpi-wifi-creds}/bin/nixpi-wifi-creds";
              meta.description = "Emit a wpa_supplicant.conf from this Mac's current Wi-Fi network (SSID + keychain PSK + locale country)";
            };
            aarch64-darwin.nixpi-vault-token = {
              type = "app";
              program = "${self.packages.aarch64-darwin.nixpi-vault-token}/bin/nixpi-vault-token";
              meta.description = "Re-encrypt a new connector token (stdin/$TUNNEL_TOKEN) into secrets/cloudflared-token.age (run from the repo root)";
            };

            # Vast.ai template provisioning (macOS). vast-template-apply reconciles
            # (create/update BY NAME) a template that boots via PROVISIONING_SCRIPT ->
            # the committed bootstrap -> clone the target repo (public/private) + run
            # its entrypoint; vast-account-vars-set syncs read-only VAST_* Keychain
            # tokens to Vast account env vars. See docs/vastai-template-provisioning.md.
            aarch64-darwin.vast-template-apply = {
              type = "app";
              program = "${self.packages.aarch64-darwin.vast-template-apply}/bin/vast-template-apply";
              meta.description = "Create/update (reconcile-by-name) a Vast.ai template that boots via the PROVISIONING_SCRIPT bootstrap (--template-name, --repo [github:|gitlab:]owner/repo)";
            };
            aarch64-darwin.vast-repo-check = {
              type = "app";
              program = "${self.packages.aarch64-darwin.vast-repo-check}/bin/vast-repo-check";
              meta.description = "Validate a repo is a legit provisioner repo (structural: .provisioner-template.json marker + required files; github:/gitlab:)";
            };
            aarch64-darwin.vast-account-vars-set = {
              type = "app";
              program = "${self.packages.aarch64-darwin.vast-account-vars-set}/bin/vast-account-vars-set";
              meta.description = "Sync read-only VAST_* Keychain tokens to Vast.ai account-level env vars (GITLAB_TOKEN/HF_TOKEN/CIVITAI_TOKEN/GH_TOKEN)";
            };
            aarch64-darwin.vast-ssh-key-set = {
              type = "app";
              program = "${self.packages.aarch64-darwin.vast-ssh-key-set}/bin/vast-ssh-key-set";
              meta.description = "Register the operator SSH public key on the Vast.ai account (idempotent) for passwordless root SSH into instances";
            };
            aarch64-darwin.vast-init-repo = {
              type = "app";
              program = "${self.packages.aarch64-darwin.vast-init-repo}/bin/vast-init-repo";
              meta.description = "Scaffold a new provisioner repo from provisioner-template on GitHub/GitLab, public/private (--repo, --template)";
            };

          }
          (
            forAllSystems (system: {
              cf-tunnel-apply = {
                type = "app";
                program = "${self.packages.${system}.cf-tunnel-apply}/bin/cf-tunnel-apply";
                meta.description = "Render infra/cloudflare/nixpi-tunnel.nix (terranix), tofu apply it, and print the connector token (needs CLOUDFLARE_API_TOKEN)";
              };
              cf-tunnel-destroy = {
                type = "app";
                program = "${self.packages.${system}.cf-tunnel-destroy}/bin/cf-tunnel-destroy";
                meta.description = "tofu destroy the nixpi Cloudflare tunnel/ingress/CNAME (needs CLOUDFLARE_API_TOKEN)";
              };
              cf-mcp-apply = {
                type = "app";
                program = "${self.packages.${system}.cf-mcp-apply}/bin/cf-mcp-apply";
                meta.description = "Render infra/cloudflare/macos-mcp-tunnel.nix (terranix), tofu apply the Mac MCP tunnel + Access Managed-OAuth app, and print the connector token (needs CLOUDFLARE_API_TOKEN)";
              };
              cf-mcp-destroy = {
                type = "app";
                program = "${self.packages.${system}.cf-mcp-destroy}/bin/cf-mcp-destroy";
                meta.description = "tofu destroy the Mac MCP tunnel + Cloudflare Access app/policy (needs CLOUDFLARE_API_TOKEN)";
              };
            })
          );

      # ---- Multi-architecture dev shell --------------------------------------
      # `nix develop` on any target. Used as the default Devcontainer profile.
      # statix/deadnix/jq are exposed as standalone binaries (NOT via
      # preCommit.enabledPackages, which only yields the treefmt wrapper) so the
      # .vscode lint tasks can call them directly.
      # devToolingSystems (fleet + x86_64), NOT forAllSystems: the x86_64
      # devcontainer's terminal runs `nix develop .#default`, so that arch needs a
      # devShell output or the container shell errors. See devToolingSystems above.
      devShells = nixpkgs.lib.genAttrs devToolingSystems (
        system:
        let
          pkgs = pkgsFor system;
          preCommit = preCommitFor system;
        in
        {
          default = pkgs.mkShell {
            # Shared with the devcontainer image (devPackagesFor) so the pinned
            # nixd/treefmt/statix/deadnix/jq/home-manager set never drifts.
            packages = devPackagesFor system ++ preCommit.enabledPackages;

            # We deliberately DO NOT run git-hooks.nix's installer
            # (${preCommit.shellHook}). That installer would symlink
            # .pre-commit-config.yaml, run `git config core.hooksPath`, and write
            # .git/hooks/pre-commit with a /nix/store bash shebang. But `.git/` is
            # bind-mounted and shared between this Nix devcontainer and the Nix-less
            # macOS host (see .devcontainer/devcontainer.json workspaceMount): a
            # store-path hook installed here makes host-side `git commit` fail with
            # `fatal: cannot exec` — the kernel cannot resolve the /nix/store
            # interpreter off-Nix. A single hook file cannot be correct in both a Nix
            # and a non-Nix environment, so we skip local install entirely. The
            # `checks.pre-commit` CI gate + `nix fmt` run the same treefmt pass, so no
            # coverage is lost; run `nix fmt` before committing.
            shellHook = ''
              echo "nix-config devShell ready on ${system} — run 'nix fmt' before committing (pre-commit auto-install disabled: .git is shared with a Nix-less host; CI enforces the gate)"
            '';
          };
        }
      );

      # ---- Formatter: `nix fmt` runs treefmt (nixfmt + statix + deadnix) ------
      formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

      # ---- Checks: `nix flake check` enforces formatting + lint + hooks ------
      # Lint/format only, to keep merge CI fast. The host toplevels are
      # deliberately NOT checks: BUILDING them (esp. the cold Pi kernel, ~1h) is
      # a RELEASE-time concern. Merge CI instead EVALUATES the host configs
      # (cheap, catches config/eval errors) without building — see
      # .github/workflows/nix-ci.yml.
      checks = forAllSystems (system: {
        formatting = treefmtEval.${system}.config.build.check self;
        pre-commit = preCommitFor system;
      });
    };
}
