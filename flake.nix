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
    # Pin the brew CLI nix-homebrew installs to 6.0.15 (latest, 2026-08-03),
    # overriding nix-homebrew's default 6.0.11. The Homebrew cask JSON API advanced
    # to a new artifact stanza (`command_wrapper`/`generated_script`) that 6.0.11
    # doesn't implement, so `brew bundle` crashed parsing casks like inkscape/obs/vlc
    # ("undefined method 'command_wrapper'"), blocking activation. The nix-managed
    # brew can't self-update, so we bump the source pin. brew-src is a non-flake source.
    nix-homebrew.inputs.brew-src = {
      url = "github:Homebrew/brew/6.0.15";
      flake = false;
    };

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
    # The sole secret (./secrets/cloudflared-token.age) is encrypted to the
    # operator's ~/.ssh/id_ed25519 ALONE — an operator-only vault: decrypted on
    # the Mac to plant on nixpi's SD FIRMWARE partition, never on any host.
    # Recipients are declared in ./secrets/secrets.nix. Pure age/SSH — no
    # ssh-to-age step, no Go build. Follows our nixpkgs.
    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";

    # firmware-secrets — the reflash-safe FAT-firmware-partition secret provisioning
    # module, EXTRACTED FROM THIS REPO and published as a standalone MIT flake
    # (github.com/ismailkattakath/nix-firmware-secrets). nixpi now consumes its
    # nixosModule instead of the vendored copy — dogfooding our own extraction.
    # The module is pure (config/lib only), so follows our nixpkgs to avoid a 2nd copy.
    firmware-secrets.url = "github:ismailkattakath/nix-firmware-secrets";
    firmware-secrets.inputs.nixpkgs.follows = "nixpkgs";

    # keychain-secrets — the macOS login-Keychain `secret` CLI + every-shell loader,
    # EXTRACTED FROM THIS REPO into a standalone MIT flake
    # (github.com/ismailkattakath/nix-keychain-secrets). The macos host consumes its
    # home-manager module instead of the vendored packages + loader — dogfooding.
    keychain-secrets.url = "github:ismailkattakath/nix-keychain-secrets";
    keychain-secrets.inputs.nixpkgs.follows = "nixpkgs";
    keychain-secrets.inputs.home-manager.follows = "home-manager";

    # cloudflared-connector — the loginless token Cloudflare Tunnel connector NixOS
    # module, EXTRACTED FROM THIS REPO into a standalone MIT flake
    # (github.com/ismailkattakath/nix-cloudflared-connector). nixpi consumes its
    # nixosModule instead of the vendored copy — dogfooding. Pure (config/lib/pkgs).
    cloudflared-connector.url = "github:ismailkattakath/nix-cloudflared-connector";
    cloudflared-connector.inputs.nixpkgs.follows = "nixpkgs";

    # local-rag — the local-first RAG stack (loopback launchd Postgres+pgvector +
    # a local Ollama embed model + an in-DB embed() function for plain-SQL RAG),
    # EXTRACTED FROM THIS REPO into a standalone MIT flake
    # (github.com/ismailkattakath/nix-local-rag). The macos host consumes its two
    # home-manager modules (services.ollamaLocal + services.pgvectorLocal) instead
    # of the vendored modules/shared/{ollama,postgres-pgvector}.nix — dogfooding.
    local-rag.url = "github:ismailkattakath/nix-local-rag";
    local-rag.inputs.nixpkgs.follows = "nixpkgs";
    local-rag.inputs.home-manager.follows = "home-manager";

    # vast-provision — the Vast.ai GPU-template provisioning CLI toolkit
    # (vast-template-apply / vast-repo-check / vast-account-vars-set /
    # vast-ssh-key-set / vast-init-repo / vast-rent), EXTRACTED FROM THIS REPO
    # into a standalone MIT flake (github.com/ismailkattakath/nix-vast-provision)
    # — phase 2 of the extraction (phase 1 backported local-only features
    # upstream first). Consumed by reaching into its store path for
    # packages/vast-provision.nix directly, with orgName/repoName/rev
    # OVERRIDDEN to nix-config's own identity (see the callPackage in
    # `packages` below) — UNLIKE the other extracted flakes above, its own
    # packages.<system>.* outputs are hardcoded to ismailkattakath/
    # nix-vast-provision, wrong for OUR raw-URL construction. Pure
    # (writeShellApplication/runCommand only), so follows our nixpkgs to
    # avoid a 2nd copy.
    vast-provision.url = "github:ismailkattakath/nix-vast-provision";
    vast-provision.inputs.nixpkgs.follows = "nixpkgs";

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
    # ---- Additional third-party skill collections (source-only, flake = false) --
    # Wired into programs.claude-code.skills alongside the two above. Chosen to
    # DRIVE tools this fleet already has (Cloudflare Tunnel + cloudflare/cloudflare-docs
    # MCP, the playwright/postgres/macos-automator MCP servers, the Excalidraw
    # connector, the Google Drive connector). Bumped via `nix flake update`; nothing vendored.
    agent-skills-cloudflare = {
      # OFFICIAL Cloudflare (Apache-2.0): `cloudflare` + `cloudflare-one` (Access/Tunnel) product reference.
      url = "github:cloudflare/skills";
      flake = false;
    };
    agent-skills-anthropic-official = {
      # Anthropic's official skills marketplace (source-available): mcp-builder, webapp-testing,
      # pdf/docx/pptx/xlsx. DISTINCT from `agent-skills-anthropic` (= anthropics/claude-code, the
      # plugin-dev + hookify AUTHORING skills) — this is the anthropics/skills content repo.
      url = "github:anthropics/skills";
      flake = false;
    };
    agent-skills-jeffallan = {
      # MIT: `postgres-pro` (senior-Postgres skill) — pairs with the postgres MCP server + local pgvector RAG.
      url = "github:Jeffallan/claude-skills";
      flake = false;
    };
    agent-skills-mac-automation = {
      # MIT: `automating-mac-apps` foundation (AppleScript/JXA) — pairs with the macos-automator MCP server.
      url = "github:SpillwaveSolutions/automating-mac-apps-plugin";
      flake = false;
    };
    agent-skills-excalidraw = {
      # Generates .excalidraw diagrams (Playwright render-loop) — pairs with the Excalidraw connector.
      # Root-level SKILL.md, so the whole repo IS the skill dir. No LICENSE file (source-available; personal pin only).
      url = "github:coleam00/excalidraw-diagram-skill";
      flake = false;
    };
    agent-skills-trailofbits = {
      # Trail of Bits security skills (CC-BY-SA-4.0): gh-cli (prefer authenticated gh over raw curl) +
      # supply-chain-risk-auditor (dependency takeover/typosquat risk scoring). Wired in programs.claude-code.skills.
      url = "github:trailofbits/skills";
      flake = false;
    };
    agent-skills-superpowers = {
      # obra/superpowers (MIT): ONLY the systematic-debugging skill is pinned (cherry-picked subpath, NOT the
      # whole 14-skill plugin) — a hypothesis-driven debugging methodology. Keeps the always-loaded set lean.
      url = "github:obra/superpowers";
      flake = false;
    };
    agent-skills-jsonresume = {
      # Paramchoudhary/ResumeSkills (MIT, 1.4k★): 21 job-search agent skills. We cherry-pick a LEAN,
      # complementary subset in programs.claude-code.skills (JD analysis / ATS / cover-letter / interview /
      # salary) — NOT resume-tailor, which the json-native .claude/skills/jsonresume-tailor supersedes.
      # These are plain-markdown workflows over pasted text; they DON'T touch resume.json / resume-cli.
      url = "github:Paramchoudhary/ResumeSkills";
      flake = false;
    };
    agent-skills-vercel-agent = {
      # OFFICIAL Vercel Labs monorepo (vercel-labs/agent-skills — DISTINCT from `agent-skills-vercel` =
      # vercel-labs/skills, the find-skills discovery tool). We cherry-pick ONLY `vercel-cli-with-tokens`
      # in programs.claude-code.skills — it drives the `vercel` CLI (hosts/macos.nix Homebrew) for
      # non-interactive/token auth. No top-level LICENSE (source-available; personal pin only, like excalidraw).
      url = "github:vercel-labs/agent-skills";
      flake = false;
    };
    agent-skills-vercel-workflow = {
      # OFFICIAL Vercel Workflow SDK repo (vercel/workflow, Apache-2.0, 2.3k★) — the durable/resumable
      # TypeScript workflow engine, DISTINCT from the two vercel-labs skill repos above. We cherry-pick
      # its three USER-facing skills in programs.claude-code.skills (workflow / workflow-init /
      # migrating-to-workflow-sdk); we deliberately DROP `internal-dev-workbench`, which only sets up a
      # tmux/portless dev session for contributors HACKING ON the SDK repo itself — irrelevant to this fleet.
      url = "github:vercel/workflow";
      flake = false;
    };
    agent-skills-litellm = {
      # OFFICIAL BerriAI repo (MIT): litellm-skills — drives a live LiteLLM proxy (create/update/delete
      # users, teams, keys, models, orgs, MCP servers, agents; query usage) by running curl against the
      # proxy's admin API. Pulled whole (21 self-contained skill dirs, one per verb) since it's a single
      # coherent admin toolkit, not a grab-bag — pairs with the TakeoffAiGate LiteLLM deployment.
      url = "github:BerriAI/litellm-skills";
      flake = false;
    };
    # Anthropic's OFFICIAL first-party plugin marketplace (Apache-2.0). Pinned to enable the in-repo
    # `security-guidance` plugin (hook-driven secret/injection warnings + Stop-hook diff review) via
    # programs.claude-code.marketplaces + enabledPlugins — the same declarative path as grok-build.
    claude-plugins-official = {
      url = "github:anthropics/claude-plugins-official";
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
      firmware-secrets,
      keychain-secrets,
      cloudflared-connector,
      local-rag,
      vast-provision,
      mcp-servers-nix,
      agent-skills-vercel,
      agent-skills-anthropic,
      agent-skills-cloudflare,
      agent-skills-anthropic-official,
      agent-skills-jeffallan,
      agent-skills-mac-automation,
      agent-skills-excalidraw,
      agent-skills-trailofbits,
      agent-skills-superpowers,
      agent-skills-jsonresume,
      agent-skills-vercel-agent,
      agent-skills-vercel-workflow,
      agent-skills-litellm,
      claude-plugins-official,
      grok-build-plugin-cc,
      ...
    }:
    let
      # ---- Single source of truth for the human identity ---------------------
      # loginName is the POSIX ACCOUNT on every host (users.users.${loginName},
      # home-manager.users.${loginName}, /Users/ismail on the Mac) — NOT a label.
      # It is deliberately NOT the GitHub handle: renaming it would repoint
      # home-manager at a user that does not exist on the machine.
      loginName = "ismail";
      domainName = "kattakath.com";
      fullName = "Ismail Kattakath";

      # userName is the human's cross-service HANDLE — the "username" field on
      # GitHub, GitLab, HuggingFace, LinkedIn, … (all the same string today). It is
      # NOT the POSIX login (that's loginName) and, since the fleet moved under the
      # `kattakath` org, NO LONGER the repo owner (that's orgName) — just the person.
      userName = "ismailkattakath";

      # Git identity. Its own binding rather than "${loginName}@${domainName}",
      # so the commit address can be GitHub's noreply (which never leaks a real
      # mailbox) without dragging the POSIX account name along with it.
      userEmail = "8927166+${userName}@users.noreply.github.com";

      # ---- Optional: JSON Resume gist ----------------------------------------
      # The GitHub Gist ID hosting resume.json (jsonresume.org). OPTIONAL — set to
      # null to disable. When non-null it composes jsonResumeUrl below (the raw
      # resume.json URL), which is BAKED into the `jsonresume` package as its default
      # --url (packages/jsonresume.nix) — no ambient env var, since that package is
      # its only consumer. Owner is the GitHub handle (userName), not the POSIX loginName.
      jsonResumeGistId = "5fc44006a632f8466f09b61749129a88";

      # The raw resume.json URL, derived from the gist id + handle (null when the id is
      # null). Threaded to the jsonresume package (via home.nix + the packages fold) as
      # its baked-in default --url — the composition lives here, in one place.
      jsonResumeUrl =
        if jsonResumeGistId == null then
          null
        else
          "https://gist.githubusercontent.com/${userName}/${jsonResumeGistId}/raw/resume.json";

      # The raw logo.svg URL, from the SAME gist — one canonical source of truth for
      # identity assets (resume + logo). null when the gist id is null. Baked into the
      # email-signature package as its default --logo-url; the generator fetches it, caches
      # it locally (~/.local/share/email-signature/logo.svg), and rasterizes it. Kept here
      # so the composition lives in one place, alongside jsonResumeUrl.
      logoUrl =
        if jsonResumeGistId == null then
          null
        else
          "https://gist.githubusercontent.com/${userName}/${jsonResumeGistId}/raw/logo.svg";

      # The raw brand design-tokens URL (W3C DTCG), from the SAME gist. null when the gist id
      # is null. Baked into the email-signature package as its default --tokens-url; the
      # generator reads colors + font family from it (falling back to built-in defaults when
      # unavailable), so the palette/typography stay in one canonical place.
      tokensUrl =
        if jsonResumeGistId == null then
          null
        else
          "https://gist.githubusercontent.com/${userName}/${jsonResumeGistId}/raw/tokens.json";

      # ---- Single source of truth for the GitHub owner -----------------------
      # The org that owns the repo and the Cachix cache.
      # Split from userName so the two can never be confused again: everything
      # that says "who publishes this" is orgName; everything that says "who is
      # the person" is userName/loginName.
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

      # ---- Sites served on nixpi: composition hook, not a live list -----------
      # nixpi's Caddy vhosts are driven ENTIRELY by mkNixos's `hostedSites`
      # parameter (see mkNixos below) — this public repo defines the SHAPE and
      # the GENERIC Caddy-generation code (hosts/nixpi.nix), never any real
      # site. Shape: { domain; zoneId ? null; root; www ? true; ownTunnel ? false }
      # (root = a path Caddy file_servers). infra/cloudflare/nixpi-tunnel.nix's
      # `cfTunnelConfig` maps the SAME shape to tunnel ingress + DNS (also
      # overridable — see that binding below). Public hosts pass nothing, so
      # `hostedSites` defaults to `[ ]`: Caddy runs, zero vhosts, the sdImage
      # stays secret- and site-free. The real production sites (kattakath.com,
      # snoringirl.com, ismail.kattakath.com, dontsell.ai) are supplied by the
      # private nix-personal composition flake's `nixosConfigurations.nixpi`,
      # mirroring the Vast-provisioner pattern (`extraHomeModules` for the Mac;
      # `hostedSites` + `extraModules` for nixpi) — see
      # docs/private-home-modules.md.

      # ---- DRY system mapping -------------------------------------------------
      # A 2-SYSTEM aarch64-only FLEET (aarch64-darwin: macos + macvm; aarch64-linux: nixpi + nixvm):
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
        {
          system,
          # Same hostedSites shape/default as mkNixos — public callers (the
          # cf-tunnel-apply/destroy apps below) pass nothing, rendering an
          # ingress/DNS config with zero sites. A private composition flake
          # calls this directly with its own real site list.
          hostedSites ? [ ],
        }:
        terranix.lib.terranixConfiguration {
          inherit system;
          # domainName is the zone name, plus the account/zone ids — threaded from
          # the single flake bindings above (one source of truth, no re-hardcoding).
          modules = [
            ./infra/cloudflare/nixpi-tunnel.nix
            {
              _module.args = {
                inherit domainName hostedSites;
                accountId = cloudflareAccountId;
                zoneId = cloudflareZoneId;
              };
            }
          ];
        };

      # ---- Generic terranix renderer for external/private callers -----------
      # A raw wrapper around this flake's own pinned `terranix` input -- lets a
      # private composition flake render ITS OWN terranix module (e.g. a
      # different Cloudflare account's tunnel stack) without needing its own
      # terranix flake input. No site-specific content lives here; this is
      # purely a library primitive, mirroring cfTunnelConfig's own closure
      # trick but fully generic (any modules list, any system).
      terranixRender =
        { system, modules }:
        terranix.lib.terranixConfiguration {
          inherit system modules;
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

      # ---- HyperFrames self-host (terranix -> OpenTofu) -----------------------
      # Renders infra/hyperframes/stack.nix: stamps VM .env + docker compose up
      # for Kinocut+HyperFrames behind mcp-auth-proxy, Caddy, and Tailscale Funnel
      # (Funnel runs on the Linux VM only — Darwin host stays isolated).
      # Public non-Nix tree: packages/hyperframes-selfhost/ (see docs/hyperframes-selfhost.md).
      hfStackConfig =
        system:
        terranix.lib.terranixConfiguration {
          inherit system;
          modules = [
            ./infra/hyperframes/stack.nix
            {
              _module.args = {
                inherit operatorEmail;
                # Overridden at apply via TF_VAR_stack_dir (absolute path on the VM).
                stackDir = ".";
                externalUrl = "";
                tsHostname = "hyperframes";
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
            cp ${cfTunnelConfig { inherit system; }} config.tf.json
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
      # module consumer are carried: loginName (core/host), fullName+userEmail
      # (home.nix), domainName (nixpi's Caddy vhost + the darwin file-rotation
      # launchd label). userName only builds userEmail above, and orgName is
      # consumed only by PACKAGES (via callPackage, not specialArgs) now that the
      # self-hosted runners are gone — so neither is threaded.
      identityArgs = {
        inherit
          loginName
          fullName
          userEmail
          domainName
          ;
      };

      # The Home-Manager sub-module embedded in every host, built from an identity
      # attrset (`idArgs` = { loginName; fullName; userEmail; domainName; }) so a host
      # can carry a PER-HOST persona (e.g. macvm's `aloshy`) rather than the single
      # global identity. Called with `identityArgs` by default; hosts that override
      # (mkDarwin's `identity` arg) pass their own. The home-manager profile keys on
      # idArgs.loginName, and extraSpecialArgs threads that same identity into
      # modules/shared/home.nix. extraSpecialArgs also adds mcp-servers-nix etc.
      #
      # `extraHomeModules` is the public COMPOSITION HOOK for private (or third-party)
      # home-manager modules — same role as `provision.sh` for Vast stacks: this
      # flake owns the contract, never the private stack. Callers (typically a
      # private flake that re-exports `darwinConfigurations.macos` via `lib.mkDarwin`)
      # pass zero or more modules; the public tree ships none. See
      # docs/private-home-modules.md.
      mkHomeManagerModule =
        {
          idArgs,
          extraHomeModules ? [ ],
        }:
        {
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            # Back up (don't abort on) any pre-existing UNMANAGED file that a newly
            # Nix-managed home.file would clobber — e.g. ~/.claude/settings.json and
            # ~/.claude/plugins/known_marketplaces.json, now owned by the
            # programs.claude-code marketplaces/settings options. Without this, HM
            # activation hard-fails on the first such collision.
            backupFileExtension = "hm-bak";
            extraSpecialArgs = idArgs // {
              inherit
                mcp-servers-nix
                agent-skills-vercel
                agent-skills-anthropic
                agent-skills-cloudflare
                agent-skills-anthropic-official
                agent-skills-jeffallan
                agent-skills-mac-automation
                agent-skills-excalidraw
                agent-skills-trailofbits
                agent-skills-superpowers
                agent-skills-jsonresume
                agent-skills-vercel-agent
                agent-skills-vercel-workflow
                agent-skills-litellm
                claude-plugins-official
                grok-build-plugin-cc
                keychain-secrets
                local-rag
                # mcpPublicPort: the public (OAuth-gated) mcp-proxy port consumed by
                # modules/shared/mcp.nix (inert on the NixOS hosts).
                mcpPublicPort
                # jsonResumeUrl: the raw resume.json URL (or null), consumed by home.nix
                # to bake into the jsonresume package as its default --url (darwin
                # home.packages; inert on the NixOS hosts).
                jsonResumeUrl
                # logoUrl: the raw logo.svg URL from the same gist (or null), consumed by
                # home.nix to bake into the email-signature package as its default
                # --logo-url (darwin only; inert on the NixOS hosts).
                logoUrl
                # tokensUrl: the raw tokens.json (DTCG brand tokens) URL from the same gist
                # (or null), baked into the email-signature package as its default
                # --tokens-url (darwin only; inert on the NixOS hosts).
                tokensUrl
                # operatorSshKey: fleet operator public key — home.nix writes
                # ~/.ssh/allowed_signers from it so git can verify SSH commit sigs
                # (and the file stays in lockstep with secrets/operator-key.nix).
                operatorSshKey
                ;
            };
            users.${idArgs.loginName} = {
              imports = [ ./modules/shared/home.nix ] ++ extraHomeModules;
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
          # Sites Caddy serves on this host — see the comment above and
          # docs/private-home-modules.md. Public hosts pass nothing (Caddy
          # still runs, zero vhosts); a private composition flake overrides it.
          hostedSites ? [ ],
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
            inherit
              cachixUrl
              cachixKey
              operatorSshKey
              firmware-secrets
              cloudflared-connector
              hostedSites
              ;
          };
          modules = [
            { nixpkgs.hostPlatform = system; }
            ./hosts/${hostname}.nix
            ./modules/nixos/core.nix
            ./modules/shared/nix-cache.nix # Cachix binary cache (read)
            home-manager.nixosModules.home-manager
            (mkHomeManagerModule { idArgs = identityArgs; }) # NixOS hosts use the global identity
          ]
          ++ extraModules;
        };

      # ---- nix-darwin system builder ------------------------------------------
      # Mirrors mkNixos for the Mac. hostPlatform is driven from `system` (NOT
      # hardcoded in modules/darwin/core.nix) even though this fleet has a single
      # darwin host today.
      # `identity` defaults to the global identityArgs; a host passes its own to run
      # under a PER-HOST persona (e.g. macvm → the `aloshy` account: different
      # loginName/fullName/userEmail/domainName). It flows to the system modules via
      # specialArgs AND to home-manager via mkHomeManagerModule, so the two agree.
      mkDarwin =
        {
          system,
          hostname,
          identity ? identityArgs,
          extraModules ? [ ],
          # Private / third-party home-manager modules (see docs/private-home-modules.md).
          # Public hosts pass nothing; a private composition flake passes its modules here.
          extraHomeModules ? [ ],
        }:
        nix-darwin.lib.darwinSystem {
          inherit system;
          specialArgs = identity;
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
            ./hosts/${hostname}.nix
            home-manager.darwinModules.home-manager
            (mkHomeManagerModule {
              idArgs = identity;
              inherit extraHomeModules;
            })
          ]
          ++ extraModules;
        };
    in
    {
      # ---- Composition API (private flakes, local overrides) --------------------
      # Mirrors the Vast provisioner contract: this public flake is the engine;
      # private stacks plug in via `extraHomeModules` without forking hosts/.
      # Consumers: a private flake calls `nix-config.lib.mkDarwin { …; extraHomeModules = [ … ]; }`.
      lib = {
        inherit
          mkDarwin
          mkNixos
          mkHomeManagerModule
          identityArgs
          cfTunnelConfig
          terranixRender
          ;
      };

      # ---- Machine-readable identity ------------------------------------------
      # The flake's single-source `let` identity bindings, surfaced so `bootstrap.sh`
      # can guard on them BEFORE activating. `key-recover` reads
      #   nix eval --raw <flake>#identity.loginName
      # right after cloning and HARD-FAILS if it does not equal the macOS login
      # (`id -un`): a mismatch would half-activate home-manager for a POSIX user that
      # does not exist and build /Users/<wrong> paths. This attrset references NO
      # flake inputs, so the eval is instant and fetches nothing — unlike reading
      # `darwinConfigurations.macos.config.system.primaryUser` (which equals loginName
      # by construction, core.nix, but forces the whole darwin module fixpoint and
      # every input) and is hostname-independent (does not depend on the "macos" attr
      # key). A forker who sets `loginName` here is exactly who the guard lets through.
      identity = {
        inherit
          loginName
          orgName
          domainName
          userName
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

        # A Tart guest VM (aarch64-darwin, Apple Virtualization + IPSW) — the
        # darwin analogue of `nixvm`: the full shared stack as `macos`, but a
        # leaner Homebrew set and the MCP gateway trimmed off (see hosts/macvm.nix).
        # Runs under a SEPARATE persona (the `aloshy` / aloshy.ai account) — same
        # person, isolated local identity — via the per-host `identity` override.
        # Activated INSIDE the VM, whose macOS login account must be `aloshy`.
        # Host control plane: nix run .#macvm-tart-* (packages/macvm-tart.nix).
        "macvm" = mkDarwin {
          system = "aarch64-darwin";
          hostname = "macvm";
          identity = {
            loginName = "aloshy";
            fullName = "aloshy";
            userEmail = "hi@aloshy.ai";
            domainName = "aloshy.ai";
          };
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
              inherit orgName flakeRef userEmail;
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

        # macvm Tart control-plane (host Mac only) — Apple Virtualization + IPSW.
        # Disks under ~/.tart/ (never the store). See packages/macvm-tart.nix.
        # tart is unfree; pkgsFor (legacyPackages) may not allow it, so import
        # nixpkgs with allowUnfree for this kit only.
        (nixpkgs.lib.genAttrs darwinSystems (
          system:
          let
            pkgsUnfree = import nixpkgs {
              inherit system;
              config.allowUnfree = true;
            };
            kit = pkgsUnfree.callPackage ./packages/macvm-tart.nix { };
          in
          {
            inherit (kit)
              macvm-tart-doctor
              macvm-tart-list
              macvm-tart-create
              macvm-tart-ensure
              macvm-tart-start
              macvm-tart-stop
              macvm-tart-ip
              macvm-tart-ssh
              macvm-tart-bootstrap-print
              ;
          }
        ))

        # WireGuard operator (darwin) — confs stay outside the store; tool is public.
        # Also on PATH via home.packages on darwin (modules/shared/home.nix).
        (nixpkgs.lib.genAttrs darwinSystems (system: {
          vpn = (pkgsFor system).callPackage ./packages/vpn.nix { };
        }))

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

        # HyperFrames self-host (Kinocut + mcp-auth-proxy + Caddy + Funnel on a
        # Linux VM). Public tree under packages/hyperframes-selfhost/; terranix
        # plan from infra/hyperframes/stack.nix. See docs/hyperframes-selfhost.md.
        (forAllSystems (
          system:
          let
            kit = (pkgsFor system).callPackage ./packages/hyperframes-selfhost.nix {
              hfStackConfig = hfStackConfig system;
              inherit operatorEmail;
              hyperframesSelfhostSrc = ./packages/hyperframes-selfhost;
            };
          in
          {
            inherit (kit) hf-export;
            inherit (kit) hf-apply;
            inherit (kit) hf-doctor;
          }
        ))

        # `secret <set|get|rm|ls|load>` / `set-secret` / `remove-secret` — the
        # macOS login-Keychain CLI. NOW sourced from the extracted keychain-secrets
        # flake (github:ismailkattakath/nix-keychain-secrets), not vendored packages —
        # dogfooding. The home-manager module (modules/shared/home.nix) installs the
        # same CLIs + the every-shell loader; these apps just expose `nix run`.
        # DARWIN-ONLY: the Keychain is macOS-only.
        (nixpkgs.lib.genAttrs darwinSystems (system: {
          inherit (keychain-secrets.packages.${system}) set-secret remove-secret secret;
        }))

        # Vast.ai template-provisioning toolkit (macOS only) — PHASE 2 of the
        # extraction (phase 1 backported local-only features upstream first,
        # already merged): the CLI *logic* now comes from the vast-provision
        # flake input (github:ismailkattakath/nix-vast-provision) — dogfooding
        # our own extraction, same idea as firmware-secrets/keychain-secrets/
        # cloudflared-connector/local-rag above. UNLIKE those four, we reach
        # into the input's STORE PATH for the raw .nix file (it exposes no
        # .nix-file output, only prebuilt packages/apps) and OVERRIDE
        # orgName/repoName/rev to THIS repo's own coordinates: Vast fetches
        # packages/vast-bootstrap.sh and packages/templates/provisioner/
        # provision-lib.sh over raw HTTP from nix-config at instance-boot time
        # (PROVISIONING_SCRIPT/PROVISION_LIB_URL), so the raw-URL construction
        # MUST point here, never at the extraction's own identity. Both served
        # files stay vendored locally for that reason — see
        # docs/vastai-template-provisioning.md and the vast-lib-drift check
        # (checks.<system>, below) that guards the two copies from diverging.
        # NO stack-specific manifest content (e.g. a concrete ComfyUI workflow)
        # is ever vendored here — that lives in a PRIVATE aggregator repo
        # (--repo gitlab:... --workflow-name NAME), never in this public repo.
        (nixpkgs.lib.genAttrs darwinSystems (
          system:
          let
            pkgs = pkgsFor system;
            kit = pkgs.callPackage "${vast-provision}/packages/vast-provision.nix" {
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

        # `jsonresume <download|print|markdown|text>` (macOS only) — fetch a JSON Resume
        # and render it (PDF via a theme, or theme-less Markdown/plain text to stdout)
        # via the npm resume CLI. Exposed as a package so `nix flake check`
        # BUILDS it (writeShellApplication shellcheck). Also on PATH via home.packages
        # and runnable with `nix run .#jsonresume`. See packages/jsonresume.nix.
        (nixpkgs.lib.genAttrs darwinSystems (system: {
          jsonresume = (pkgsFor system).callPackage ./packages/jsonresume.nix {
            defaultUrl = jsonResumeUrl;
          };
        }))

        # `email-signature` (macOS only) — render a paste-ready HTML email signature from
        # the same JSON Resume (baked jsonResumeUrl) plus the logo.svg fetched from the same
        # gist (baked logoUrl), rasterized via librsvg. Exposed as a package so `nix flake
        # check` BUILDS it (writeShellApplication
        # shellcheck); on PATH via home.packages, run on activation, and `nix run
        # .#email-signature`. See packages/email-signature/ (default.nix).
        (nixpkgs.lib.genAttrs darwinSystems (system: {
          email-signature = (pkgsFor system).callPackage ./packages/email-signature {
            defaultUrl = jsonResumeUrl;
            inherit logoUrl tokensUrl;
          };
        }))

        # `design-tokens` (macOS only) — transform the same gist tokens.json (baked
        # tokensUrl) into SCSS/CSS/JS via Style Dictionary (v4, via npx), so any consumer
        # builds from one source of truth. Exposed as a package so `nix flake check` BUILDS
        # it (writeShellApplication shellcheck); on PATH via home.packages + `nix run
        # .#design-tokens`. See packages/design-tokens/ (default.nix).
        (nixpkgs.lib.genAttrs darwinSystems (system: {
          design-tokens = (pkgsFor system).callPackage ./packages/design-tokens {
            inherit tokensUrl;
          };
        }))

        # `jobspy` (macOS only) — scrape jobs from LinkedIn/Indeed/Glassdoor/etc. into
        # CSV/JSON via the off-the-shelf python-jobspy library, run in an ephemeral uv
        # env. Exposed as a package so `nix flake check` BUILDS it (writeShellApplication
        # shellcheck); on PATH via home.packages + `nix run .#jobspy`. See packages/jobspy.nix.
        (nixpkgs.lib.genAttrs darwinSystems (system: {
          jobspy = (pkgsFor system).callPackage ./packages/jobspy.nix { };
        }))

        # `obs-fb-setup` (macOS only) — write an OBS "Facebook" profile for Facebook Live,
        # injecting FB_PERSISTENT_STREAM_KEY from the login Keychain at run time (never in
        # git/store). Package so `nix flake check` shellchecks it; on PATH + `nix run`.
        (nixpkgs.lib.genAttrs darwinSystems (system: {
          obs-fb-setup = (pkgsFor system).callPackage ./packages/obs-fb-setup.nix { };
        }))

        # `chrome-automation` (macOS only) — launch a dedicated, logged-in Chrome (own
        # profile + CDP debug port) that the Playwright MCP server attaches to, so an agent
        # drives a session-aware browser in parallel. Package so `nix flake check`
        # shellchecks it; on PATH + `nix run .#chrome-automation`.
        (nixpkgs.lib.genAttrs darwinSystems (system: {
          chrome-automation = (pkgsFor system).callPackage ./packages/chrome-automation.nix { };
        }))
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
            # login == this flake's `loginName` (#identity.loginName), then either
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

            # First activation of the macvm Tart guest (run INSIDE the VM, whose
            # login account must be `aloshy`), before darwin-rebuild is on PATH.
            # Thereafter: darwin-rebuild switch --flake .#macvm
            # Host-side Tart control plane: nix run .#macvm-tart-* (packages/macvm-tart.nix).
            #
            # First-boot footguns this wrapper fixes:
            # 1. `sudo` preserves HOME=/Users/aloshy while uid=0 → home-manager aborts
            #    with "$HOME is not owned by you" and the user profile never activates.
            #    Force HOME=/var/root for the root rebuild; nix-darwin still activates
            #    HM for aloshy under the correct user.
            # 2. Determinate's installer leaves an unmanaged /etc/nix/nix.custom.conf
            #    that nix-darwin refuses to clobber — move it aside once if not a symlink.
            aarch64-darwin.macvm = {
              type = "app";
              program = "${(pkgsFor "aarch64-darwin").writeShellScript "activate-macvm" ''
                set -euo pipefail
                rebuild="${self.darwinConfigurations.macvm.config.system.build.darwin-rebuild}/bin/darwin-rebuild"
                flake="${self}#macvm"

                # Determinate installer → nix-darwin handoff (idempotent).
                if [ -e /etc/nix/nix.custom.conf ] && [ ! -L /etc/nix/nix.custom.conf ]; then
                  echo "macvm: moving unmanaged /etc/nix/nix.custom.conf → nix.custom.conf.before-nix-darwin" >&2
                  /bin/mv /etc/nix/nix.custom.conf /etc/nix/nix.custom.conf.before-nix-darwin
                fi

                run_as_root() {
                  # Root-owned HOME so HM does not refuse activation (sudo keeps
                  # HOME=/Users/aloshy by default on macOS).
                  exec /usr/bin/env HOME=/var/root USER=root LOGNAME=root \
                    "$rebuild" switch --flake "$flake" "$@"
                }

                if [ "$(/usr/bin/id -u)" -eq 0 ]; then
                  run_as_root "$@"
                else
                  # Re-exec under sudo with a root HOME (not sudo's preserved HOME).
                  exec /usr/bin/sudo /usr/bin/env HOME=/var/root USER=root LOGNAME=root \
                    "$rebuild" switch --flake "$flake" "$@"
                fi
              ''}";
              meta.description = "Activate macvm (Tart guest) as aloshy; safe under sudo (fixes HOME ownership + Determinate nix.custom.conf handoff)";
            };

            # Host-side Tart lifecycle for macvm (Apple Virtualization + IPSW).
            aarch64-darwin.macvm-tart-doctor = {
              type = "app";
              program = "${self.packages.aarch64-darwin.macvm-tart-doctor}/bin/macvm-tart-doctor";
              meta.description = "Health-check the host Tart macvm guest (Apple Virtualization)";
            };
            aarch64-darwin.macvm-tart-list = {
              type = "app";
              program = "${self.packages.aarch64-darwin.macvm-tart-list}/bin/macvm-tart-list";
              meta.description = "List Tart VMs";
            };
            aarch64-darwin.macvm-tart-create = {
              type = "app";
              program = "${self.packages.aarch64-darwin.macvm-tart-create}/bin/macvm-tart-create";
              meta.description = "Create macvm from Apple IPSW via Tart (disk under ~/.tart)";
            };
            aarch64-darwin.macvm-tart-ensure = {
              type = "app";
              program = "${self.packages.aarch64-darwin.macvm-tart-ensure}/bin/macvm-tart-ensure";
              meta.description = "Ensure Tart macvm exists (exit 0) or print create help (exit 2)";
            };
            aarch64-darwin.macvm-tart-start = {
              type = "app";
              program = "${self.packages.aarch64-darwin.macvm-tart-start}/bin/macvm-tart-start";
              meta.description = "Start Tart macvm with Screengrab VirtioFS share";
            };
            aarch64-darwin.macvm-tart-stop = {
              type = "app";
              program = "${self.packages.aarch64-darwin.macvm-tart-stop}/bin/macvm-tart-stop";
              meta.description = "Stop Tart macvm";
            };
            aarch64-darwin.macvm-tart-ip = {
              type = "app";
              program = "${self.packages.aarch64-darwin.macvm-tart-ip}/bin/macvm-tart-ip";
              meta.description = "Print Tart macvm guest IP (tart ip)";
            };
            aarch64-darwin.macvm-tart-ssh = {
              type = "app";
              program = "${self.packages.aarch64-darwin.macvm-tart-ssh}/bin/macvm-tart-ssh";
              meta.description = "SSH into Tart macvm (aloshy + operator key)";
            };
            aarch64-darwin.macvm-tart-bootstrap-print = {
              type = "app";
              program = "${self.packages.aarch64-darwin.macvm-tart-bootstrap-print}/bin/macvm-tart-bootstrap-print";
              meta.description = "Print in-guest macvm bootstrap checklist for Tart";
            };

            # WireGuard operator — confs in ~/.config/wireguard (not in the store).
            aarch64-darwin.vpn = {
              type = "app";
              program = "${self.packages.aarch64-darwin.vpn}/bin/vpn";
              meta.description = "WireGuard operator: vpn list|status|up|down|switch|restart|doctor (idempotent, no key leak)";
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

            # `nix run .#remove-secret -- KEY` — delete KEY from the macOS login
            # Keychain and unregister it (alias for `set-secret --remove`). Bare
            # `nix run` only mutates the Keychain; the remove-secret shell function
            # (modules/shared/home.nix) also unsets it from the current shell.
            aarch64-darwin.remove-secret = {
              type = "app";
              program = "${self.packages.aarch64-darwin.remove-secret}/bin/remove-secret";
              meta.description = "Delete KEY from the macOS login Keychain and unregister it from the set-secret index (alias for set-secret --remove)";
            };

            # `nix run .#secret -- <set|get|rm|list> …` — the primary noun-verb
            # interface to the Keychain secret store (set-secret/remove-secret are
            # its aliases). `secret load` is shell-function-only (mutates the
            # current shell); the app covers the Keychain-only verbs.
            aarch64-darwin.secret = {
              type = "app";
              program = "${self.packages.aarch64-darwin.secret}/bin/secret";
              meta.description = "Keychain secret store: secret set|get|rm|list (primary interface; set-secret/remove-secret are aliases)";
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
            aarch64-darwin.vast-rent = {
              type = "app";
              program = "${self.packages.aarch64-darwin.vast-rent}/bin/vast-rent";
              meta.description = "Rent a live, BILLED Vast.ai GPU instance from a template (--template-name|--template-hash, --offer, --gpu, --disk, --max-price, --dry-run)";
            };

            # `nix run .#jsonresume -- <download|print|markdown|text> …` — fetch a JSON
            # Resume and render it (PDF, or theme-less Markdown/text to stdout) via the
            # npm resume CLI (also on PATH via home.packages).
            aarch64-darwin.jsonresume = {
              type = "app";
              program = "${self.packages.aarch64-darwin.jsonresume}/bin/jsonresume";
              meta.description = "Fetch a JSON Resume (--url, else the baked-in default) and render it — PDF (theme from meta.theme), or Markdown/plain text to stdout: jsonresume download|print|markdown|text";
            };

            # `nix run .#email-signature -- [--url URL] [--out DIR]` — render a self-contained
            # HTML email signature from the JSON Resume + bundled logo (also on PATH via
            # home.packages, and regenerated on activation).
            aarch64-darwin.email-signature = {
              type = "app";
              program = "${self.packages.aarch64-darwin.email-signature}/bin/email-signature";
              meta.description = "Render a paste-ready HTML email signature from your JSON Resume (--url, else baked default) + bundled logo into ~/.local/share/email-signature/signature.html";
            };

            # `nix run .#design-tokens -- [--tokens-url URL] [--out DIR]` — transform the gist
            # DTCG tokens.json into SCSS/CSS/JS via Style Dictionary (also on PATH via
            # home.packages).
            aarch64-darwin.design-tokens = {
              type = "app";
              program = "${self.packages.aarch64-darwin.design-tokens}/bin/design-tokens";
              meta.description = "Transform the gist brand tokens.json (--tokens-url, else baked default) into SCSS/CSS/JS via Style Dictionary, into ~/.local/share/design-tokens/";
            };

            # `nix run .#jobspy -- --search "…" --location "…" …` — scrape jobs from
            # multiple boards into CSV/JSON via python-jobspy (also on PATH via home.packages).
            aarch64-darwin.jobspy = {
              type = "app";
              program = "${self.packages.aarch64-darwin.jobspy}/bin/jobspy";
              meta.description = "Scrape jobs (LinkedIn/Indeed/Glassdoor/…) into CSV/JSON via python-jobspy: jobspy --search … --location … [--sites …] [--results N] [--remote]";
            };

            # `nix run .#obs-fb-setup` — write an OBS "Facebook" profile for Facebook Live,
            # injecting FB_PERSISTENT_STREAM_KEY from the login Keychain (also on PATH).
            aarch64-darwin.obs-fb-setup = {
              type = "app";
              program = "${self.packages.aarch64-darwin.obs-fb-setup}/bin/obs-fb-setup";
              meta.description = "Write an OBS 'Facebook' profile for Facebook Live, injecting FB_PERSISTENT_STREAM_KEY from the login Keychain (never in git)";
            };

            # `nix run .#chrome-automation` — launch the dedicated logged-in Chrome (own
            # profile + CDP port 9222) that the Playwright MCP server attaches to.
            aarch64-darwin.chrome-automation = {
              type = "app";
              program = "${self.packages.aarch64-darwin.chrome-automation}/bin/chrome-automation";
              meta.description = "Launch a dedicated automation Chrome (separate profile + CDP debug port 9222) for the Playwright MCP server to attach to";
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
              hf-export = {
                type = "app";
                program = "${self.packages.${system}.hf-export}/bin/hf-export";
                meta.description = "Export the HyperFrames self-host public tree (+ terranix config.tf.json) for a Linux VM or public repo";
              };
              hf-apply = {
                type = "app";
                program = "${self.packages.${system}.hf-apply}/bin/hf-apply";
                meta.description = "On the Linux VM: tofu apply the HyperFrames stack (needs TF_VAR_ts_authkey + Google OAuth vars + HF_STACK_DIR)";
              };
              hf-doctor = {
                type = "app";
                program = "${self.packages.${system}.hf-doctor}/bin/hf-doctor";
                meta.description = "Run the HyperFrames self-host doctor script against HF_STACK_DIR (or CWD)";
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
        # Drift guard: nix-config vendors its OWN physical copies of the two
        # instance-side scripts a live Vast instance fetches over raw HTTP at
        # boot (packages/vast-bootstrap.sh, packages/templates/provisioner/
        # provision-lib.sh) — required because PROVISIONING_SCRIPT/
        # PROVISION_LIB_URL are built from THIS repo's orgName/repoName (the
        # vast-provision.nix callPackage override above), not the
        # vast-provision flake input's own identity. The input ALSO carries
        # its own copies of both files (for its own CI + as what forks
        # reference). Nothing else catches the two silently diverging — this
        # fails loudly the moment they do.
        vast-lib-drift =
          (pkgsFor system).runCommand "vast-lib-drift" { nativeBuildInputs = [ (pkgsFor system).diffutils ]; }
            ''
              diff -u ${./packages/vast-bootstrap.sh} ${vast-provision}/packages/vast-bootstrap.sh
              diff -u ${./packages/templates/provisioner/provision-lib.sh} \
                ${vast-provision}/packages/templates/provisioner/provision-lib.sh
              touch "$out"
            '';
      });
    };
}
