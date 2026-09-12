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

    # ---- The flake framework (ADR-002 wave 2) --------------------------------
    # THE flake-parts ANCHOR — now a DIRECT input, not a transitive one.
    #
    # It was already forced and undroppable: six of our seven extracted flakes
    # call `flake-parts.lib.mkFlake`, and each shipped its own flake-parts node
    # AND its own nixpkgs.lib node — 8 nodes for one library — until they were
    # collapsed onto ONE (previously reached through `firmware-secrets/flake-parts`,
    # an arbitrary anchor). Since THIS flake is now built on it too, the anchor
    # belongs here, where it is declared rather than borrowed.
    #
    # The nixpkgs-lib line is upstream-blessed, not a hack: `terranix` already
    # carries exactly this follows, and flake-parts documents the override with a
    # 23.05 floor our nixpkgs.lib clears by three years. Note nixpkgs-lib CANNOT be
    # `follows = ""` — flake-parts does `inherit (nixpkgs-lib) lib` (lib.nix:12),
    # so rebinding the name to THIS flake makes it `lib` of a thing with no `lib`.
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    # The module index: `modules/parts/*.nix` are discovered by reading the
    # directory, never by a hand-written `imports = [ … ]` that drifts.
    #
    # MEASURED TRAP (import-tree default.nix:48): its DEFAULT filter is EVERY
    # `.nix` file that is not under a `/_` path — so pointing it at `./modules`
    # bare would feed home-manager modules, NixOS modules and callPackage
    # functions to the FLAKE module system, which is an eval failure, not a
    # warning. The `.match` regex below is therefore mandatory, not decoration.
    import-tree.url = "github:vic/import-tree";

    # Git pre-commit hooks, installed automatically on `nix develop`.
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
    # git-hooks' flake-compat feeds only its legacy non-flake shim (default.nix /
    # shell.nix), which reads the rev out of git-hooks' OWN vendored flake.lock
    # rather than from `inputs` — its `outputs = { self, nixpkgs, ... }` never even
    # destructures it. We reach git-hooks solely through `lib.<system>.run`, so the
    # fetch is pure waste. (`follows = ""` REBINDS the name to this flake, it does
    # not delete it — only safe because nothing ever forces it.)
    git-hooks.inputs.flake-compat.follows = "";

    # Raspberry Pi 4 NixOS support: kernel, firmware, and SD-card image builder.
    #
    # ARCHIVED UPSTREAM, KEPT DELIBERATELY. `gh api repos/nix-community/raspberry-pi-nix`
    # reports `archived: true`, last push 2025-03-23; our pin (3e8100d5, 2025-03-17) is
    # therefore permanent — update-flake-lock.yml allowlists this input but can never
    # move it. It is also the single largest input in the lock: itself plus 9 pinned
    # source inputs (rpi-linux-*, rpi-firmware*, libcamera, libpisp, rpicam-apps), out
    # of 62 nodes total.
    #
    # WHY IT STAYS: it is the only source of the `linux-rpi` vendor kernel and the
    # bcm2711 sdImage builder. nixos-hardware's raspberry-pi/4 profile is board TUNING
    # only — it does not ship a kernel — so it is not a drop-in. And hosts/nixpi.nix:53
    # and :62 carry two mkForce workarounds written specifically against linux-rpi's
    # behaviour (tpm2 modules-shrunk failure; systemd-initrd stage-1 hang), which a
    # kernel swap would invalidate rather than inherit.
    #
    # MIGRATION TRIGGER — revisit when either fires, not on a schedule:
    #   1. a kernel CVE affecting the Pi 4 with no backport onto this frozen rev, or
    #   2. a nixpkgs bump that breaks the modules-shrunk build against this kernel.
    # EXIT PATH: mainline `linux_rpi4` from nixpkgs + nixos-hardware's raspberry-pi/4
    # for tuning, re-testing both mkForce workarounds (they may become unnecessary),
    # and rebuilding the SD image from scratch (docs/nixpi-sd-flashing-runbook.md).
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
    # agenix pulls a WHOLE SECOND nix-darwin tree plus a stale (April-2025)
    # home-manager, used at exactly three eval sites — all inside its own `checks`
    # / `darwinConfigurations` / `legacyPackages` integration tests, which we never
    # force (we consume `packages.<system>.default` and `darwinModules.default`
    # only). Deduped onto ours rather than dropped, because agenix's `outputs`
    # pattern is CLOSED (no `...`): the names must still resolve, and our newer
    # trees expose the same `lib.darwinSystem` / `darwinModules` surface anyway.
    agenix.inputs.darwin.follows = "nix-darwin";
    agenix.inputs.home-manager.follows = "home-manager";
    # `systems` (nix-systems/default) is genuinely FORCED — `import systems` feeds
    # agenix's `packages`, which our devShell pulls — so it can only be deduped,
    # never dropped. Three inputs pull the identical rev; terranix's copy is the
    # arbitrary-but-stable anchor for all of them. Fragility worth knowing: drop
    # `terranix` and this line fails at LOCK time (loudly, not at eval).
    agenix.inputs.systems.follows = "terranix/systems";

    # (firmware-secrets was an input here until ADR-002 wave 4 ABSORBED it as a
    # capsule — modules/features/firmware-secrets/. Same module, same
    # `services.firmwareProvisioning` option surface, one fewer lock node and one
    # fewer CI pipeline; the origin repo is archived and its history stays there.
    # It was ALSO this flake's flake-parts anchor until wave 2 declared
    # flake-parts directly above — had that not already happened, removing this
    # input would have broken four unrelated `follows` lines at LOCK time.)

    # (keychain-secrets was an input here until ADR-002 wave 4 ABSORBED it as a
    # capsule — modules/features/keychain-secrets/. Same module, same
    # `programs.keychainSecrets` option surface (loaderRelPath BYTE-IDENTICAL —
    # modules/darwin/core.nix derives BASH_ENV from it), same three darwin
    # packages/apps, one fewer lock node and one fewer CI pipeline; the origin
    # repo is archived and its history stays there.)

    # (media-cli was an input here until ADR-002 wave 5 ABSORBED it as a capsule
    # — modules/features/media-cli/. Same module, same `programs.mediaCli`
    # option surface, the same eleven package derivations byte-for-byte, one
    # fewer lock node and one fewer CI pipeline; the origin repo is archived and
    # its history stays there. It had been EXTRACTED from this repo on
    # 2026-09-05 to prove `programs.mediaCli.enable = false` could strip the
    # whole feature in one line — which it still does, now from in-tree.)

    # (cloudflared-connector was an input here until ADR-002 wave 3 ABSORBED it as
    # the first capsule — modules/features/cloudflared-connector/. Same module,
    # same option surface, one fewer lock node and one fewer CI pipeline; the
    # origin repo is archived and its history stays there.)

    # deploy-rs — remote NixOS activation for `nixpi` WITH MAGIC ROLLBACK. This
    # input exists for exactly one property `nixos-rebuild switch --target-host`
    # does not have: an undo. `nixos-rebuild` activates and walks away — if the new
    # generation breaks sshd, the Cloudflare Tunnel connector, or networking, the Pi
    # is simply gone, and the only recovery is walking to the shelf, pulling the SD
    # card, and reflashing (docs/nixpi-sd-flashing-runbook.md, ~40 min). deploy-rs
    # instead activates behind a watchdog ON THE TARGET: the deployer must reconnect
    # over a SECOND ssh session and confirm within `confirmTimeout`, or the Pi rolls
    # ITSELF back to the previous generation unattended. An unreachable Pi becomes a
    # failed deploy instead of a physical recovery.
    # Consumed purely as a flake `lib` (`deploy-rs.lib.<system>.activate` /
    # `.deployChecks`) plus the `deploy` CLI in the devShell — it is NOT a
    # nixos/home-manager module and nothing on any host imports it.
    deploy-rs.url = "github:serokell/deploy-rs";
    deploy-rs.inputs.nixpkgs.follows = "nixpkgs";
    # flake-compat exists only so non-flake consumers can `import` deploy-rs; a
    # pure-flake consumer never evaluates it, so drop the fetch outright. Its
    # sibling `utils` (flake-utils) is NOT droppable — deploy-rs builds the
    # per-system `lib.<system>` attrset we consume with `utils.lib.eachSystem`, so
    # following it to "" would delete the very API this input is here for.
    deploy-rs.inputs.flake-compat.follows = "";
    # flake-utils' only input is `systems`, and it does `import systems` in a CLOSED
    # outputs pattern — forced, so dedupe onto the same anchor agenix uses rather
    # than drop. Same rev, third fetch of a two-file repo otherwise.
    deploy-rs.inputs.utils.inputs.systems.follows = "terranix/systems";

    # (local-rag was an input here until ADR-002 wave 6 ABSORBED it as a capsule
    # — modules/features/local-rag/. The local-first RAG stack: a loopback
    # launchd Postgres+pgvector, a local Ollama embed model, and the in-DB
    # embed() function that makes retrieval plain SQL. Same two home-manager
    # modules (services.ollamaLocal + services.pgvectorLocal), now reached
    # through the flake's own capsule registry instead of a fetch.
    #
    # It was the LAST satellite, and the last `follows = "flake-parts"` line —
    # see docs/repo-map.md § flake.lock, which tracked that row shrinking as
    # each capsule landed. It was also the only one with a cross-repo consumer:
    # ircc-whatsapp-bot pinned it too, which is why ADR-002 wave 0 made that
    # unpin (ircc grew a `botOnly` output) a prerequisite rather than part of
    # this diff.
    #
    # `services.pgvectorLocal.databaseUri` — the seam modules/shared/mcp.nix
    # hands the `postgres` MCP server, i.e. the whole career RAG — is unchanged
    # and pinned as a literal by the capsule's own check.)

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
    # MCP, the postgres/macos-automator MCP servers, the Excalidraw
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

  # ---- Entry point: flake-parts + import-tree (ADR-002 wave 2) --------------
  #
  # This file is now inputs + this call. EVERYTHING else lives in
  # modules/parts/*.nix, one file per concern, discovered by import-tree rather
  # than by a hand-written `imports = [ … ]` that silently drifts.
  #
  # WHY THE `.match` REGEX IS MANDATORY. import-tree's DEFAULT filter is every
  # `.nix` file under the path that is not below a `/_` segment (pinned
  # import-tree default.nix:48 — `nixFilter = andNot (hasInfix "/_")
  # (hasSuffix ".nix")`). `./modules` also holds home-manager modules, NixOS
  # modules and callPackage functions; handing any of those to the FLAKE module
  # system is an eval failure, not a warning. The regex is matched against the
  # path RELATIVE to the added root (default.nix:88-96), i.e. "/parts/hosts.nix".
  #
  # It is written as an ALLOWLIST of the engine directory rather than a denylist
  # of everything else, so a new `modules/<anything>/` tree stays invisible here
  # by default. ADR-002 wave 3 added the capsules' alternative to this ONE regex
  # rather than a second `.addPath ./modules`, because `.match` ACCUMULATES with
  # `and` (pinned import-tree default.nix:234) — chaining two matches would
  # intersect them and load nothing, and two separate entries would walk the same
  # tree twice.
  #
  # `/features/<name>/flake-module.nix` and NOTHING else under a capsule: its
  # module.nix, checks/ and packages/ are reached downward FROM that entry file,
  # never imported by the flake module system (they are nixos/home-manager
  # modules and plain functions — the same eval failure the `.match` exists to
  # prevent). The cost is that a MISNAMED entry file silently drops a whole
  # capsule with CI green, which is why `checks.<system>.capsule-registry`
  # (modules/parts/capsules.nix) asserts this regex's result against
  # `readDir ./modules/features`.
  outputs =
    inputs@{ flake-parts, import-tree, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        ((import-tree.match ".*/(parts/[^/]+|features/[^/]+/flake-module)\\.nix").addPath ./modules)
      ];
    };
}
