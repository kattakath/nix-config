# Claude Code plugin marketplaces — the MECHANISM, N of them.
#
# Claude Code installs plugins from "marketplaces": a directory (or git URL)
# carrying a .claude-plugin/marketplace.json. This module owns everything
# generic about DECLARING them — `extraKnownMarketplaces` + `enabledPlugins`,
# which is all Claude Code needs to fetch a marketplace and download its
# enabled plugins itself. WHICH marketplaces exist is data, declared through `local.claudePlugins.marketplaces` — by this
# repo (modules/home/default.nix) and, additively, by any private layer composed
# on top of it.
#
# The one imperative call left is a single `plugin marketplace add` per
# store-path marketplace, and it only removes a first-session lag — read the
# activation block's own comment, which carries the 2026-09-30 measurements.
#
# An attrsOf option merges by key, so any layer composed in through `extraHomeModules`
# ADDS one attribute (none does today) and there is exactly one activation script.
#
# WHY NOT `programs.claude-code.marketplaces` (upstream home-manager,
# modules/programs/claude-code/options.nix): its lib.nix hardcodes every entry to
# `source = "directory"`, so it cannot express the git/https sources this fleet's
# marketplaces are; its `mutableSettings` (which would give the mutable
# known_marketplaces.json Claude Code's reconcile needs) is all-or-nothing and would
# also take over settings.json — rejected in ./claude-code-settings.nix; and the reserved name
# `claude-plugins-official` must be an HTTPS/GitHub source (a directory pin is
# rejected as untrusted). Plugin install state therefore stays Claude-owned
# mutable ~/.claude, like a gh/hf one-time login — the same "let the tool own
# its own state" trade this repo makes elsewhere.
#
# AND WHY NOT THE SIBLING OPTION, `programs.claude-code.plugins` (same file,
# options.nix). It is an
# attrsOf (package|path) that SYMLINKS each plugin into configDir/skills/ and
# loads it as a personal plugin: fully declarative, no activation script, no CLI
# call, no mutable ~/.claude, and still an attrset, so a private layer would keep
# the same merge-by-key seam `local.claudePlugins.marketplaces` gives it today.
# On the motto's own terms that is the off-the-shelf option and this module is
# the hand-rolled one.
#
# It is NOT adopted, and the reason is scope, not preference: it installs plugin
# DIRECTORIES and has no concept of a marketplace. The operator's plugins
# (github:kattakath/skills since 2026-09-12) are a marketplace on purpose — a publishable artifact others can add by URL — and
# `plugins` would silently drop that, turning a shareable marketplace into
# private symlinks. Re-open this if either becomes true: upstream teaches
# `marketplaces` to accept a git/https source (which would retire this module
# outright), or the fleet stops caring about publishing plugins/ (which would
# make `plugins` strictly better). Measured against pinned home-manager
# 2026-09; re-grep after a bump rather than trusting this line.
#
# A SECOND reason, for the one store-path marketplace (xai-grok-build) where the
# git/https argument does not apply: `plugins` loads its entries as `@skills-dir`
# personal plugins, so the plugin ID changes. Claude Code keys a plugin's data dir
# on that ID (`plugins/data/<name>-<marketplace>`), so moving grok-build there would
# orphan its run history AND break stop-gate check 0, which reads
# `data/grok-build-xai-grok-build/state` by name. Found by the 2026-11-13 motto audit
# (inferred from the ID scheme, not migrated to prove it).
{
  pkgs,
  lib,
  config,
  osConfig ? { },
  ...
}:
let
  cfg = config.local.claudePlugins;
  isMacosHost = import ../_lib/is-macos-host.nix osConfig;

  # The plugins Nix must assert (#648's rule, below), as full "<plugin>@<marketplace>"
  # ids (the shape `settings.enabledPlugins` keys on). Written literally since
  # 2026-11-07: marketplaces carry no plugin list any more (Nix registers stores only).
  alwaysOnIds = [
    "nix-flake-kit@kattakath"
    "superhook@kattakath"
    "brain-signals@kattakath"
  ];

  # OPERATOR-ONLY on top of the floor — gated on isMacosHost (local.operatorHost), so a
  # template consumer still gets exactly the floor (checks.<system>.template-consumer).
  #   ci-watch  the operator's fleet lands changes by direct push to main (global
  #             claude/CLAUDE.md), and this plugin's asyncRewake hook is the ONLY report that
  #             lane gets. Without it a red push is silent (2026-11-07). The landing policy is
  #             the operator's, so it is not part of the floor a consumer inherits.
  #   slack-etiquette  the operator's sessions message his colleagues on Slack; the skill
  #             carries when to post, group vs DM, one fact once and preview-free links
  #             (2026-11-09). Workspace IDs stay in the hand-placed folder CLAUDE.md.
  operatorIds = lib.optionals isMacosHost [
    "ci-watch@kattakath"
    "slack-etiquette@kattakath"
  ];

  # ONE predicate for "this marketplace is a store path", shared by the three
  # places that must agree: the assertion, the settings-shape branch, and the
  # activation guard.
  isStorePath = mp: lib.hasPrefix "/nix/store/" mp.source;

  # The only marketplaces the activation guard touches. An https marketplace
  # needs nothing imperative at all; a store-path one needs one `marketplace
  # add` on a fresh Mac / after a bump, and the guard's comment says why.
  storePathMarketplaces = lib.filterAttrs (_: isStorePath) cfg.marketplaces;

  # Re-indent a generated block to the column its `${…}` interpolation sits at
  # AFTER Nix has stripped the '' string's common indentation (2), so the
  # emitted activation script stays readable when it is dumped for debugging.
  # Purely cosmetic — bash does not care.
  reindent = block: lib.concatStringsSep "\n  " (lib.splitString "\n" (lib.removeSuffix "\n" block));
in
{
  # Declared UNCONDITIONALLY — an option declaration may never sit inside a
  # mkIf, and a Linux host declaring the option while contributing no config is
  # exactly the inert shape the NixOS hosts want.
  options.local.claudePlugins.marketplaces = lib.mkOption {
    type = lib.types.attrsOf (
      # A plain attrset module — no option reads a sibling, so no `{ config, ... }` head.
      lib.types.submodule {
        options = {
          source = lib.mkOption {
            type = lib.types.str;
            example = "https://github.com/anthropics/claude-plugins-official.git";
            description = ''
              Marketplace source exactly as `claude plugin marketplace add`
              takes it: an absolute /nix/store path, or an https:// git URL.
              Asserted to be one of those two — a bare `toString ../plugins`
              yields an impure ~/Developer path that pins nothing.

              PATH-LITERAL TRAP: write a store path as `"''${../plugins}"` IN
              THE FILE THAT OWNS THAT TREE. A Nix source path literal resolves
              relative to the .nix file it appears in, so the same line moved
              to another flake silently re-points at THAT flake's directory.

              SCALAR ON PURPOSE: a marketplace has exactly one source, so two
              differing definitions SHOULD be a loud conflict rather than a
              silent pick. Everything a downstream layer needs to ADD —
              marketplaces (attrsOf) — merges.
            '';
          };

          autoUpdate = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Let Claude Code refresh this marketplace in the background and
              update its plugins: the same switch as /plugin → Marketplaces →
              Enable auto-update, declared instead of clicked. Official
              Anthropic marketplaces already default to on; a third-party one
              defaults to off.

              Only meaningful for an https:// source (a store path has nothing
              to fetch), and asserted as such. It trades the flake.lock pin for
              the remote's own release discipline: whatever lands on the
              tracked branch reaches this Mac on the next background refresh.
            '';
          };
        };
      }
    );
    default = { };
    example = lib.literalExpression ''
      {
        my-marketplace = {
          source = "''${../plugins}";
        };
      }
    '';
    description = ''
      Claude Code plugin marketplaces to register. attrsOf, so a private layer ADDS a key and this repo's own
      marketplaces survive untouched.
    '';
  };

  # macOS only — programs.claude-code is itself isDarwin-gated in
  # modules/home/default.nix, so on nixpi/nixvm claude-code is a plain package
  # with no settings and no activation. Contributing an activation script there
  # would change those hosts' closures for no benefit.
  config = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    assertions =
      # Every always-on id must name a DECLARED marketplace, or the guard it exists for
      # would vanish silently. (Whether the plugin still exists upstream is not knowable
      # at eval; the old catalogue check only compared against a hand-written list.)
      map (id: {
        assertion = lib.hasAttr (lib.last (lib.splitString "@" id)) cfg.marketplaces;
        message = ''
          local.claudePlugins: always-on plugin "${id}" names a marketplace that is not
          declared in local.claudePlugins.marketplaces, so this guard would be silently off.
        '';
      }) (alwaysOnIds ++ operatorIds)
      ++ lib.mapAttrsToList (name: mp: {
        assertion = isStorePath mp || lib.hasPrefix "https://" mp.source;
        message = ''
          local.claudePlugins.marketplaces.${name}.source must be a /nix/store path
          or an https:// URL, got: ${mp.source}
          A path like /Users/... means `toString ../plugins` was used instead of
          string interpolation ("''${../plugins}") — that pins nothing and drifts.
        '';
      }) cfg.marketplaces
      ++ lib.mapAttrsToList (name: mp: {
        assertion = mp.autoUpdate -> lib.hasPrefix "https://" mp.source;
        message = ''
          local.claudePlugins.marketplaces.${name}.autoUpdate needs an https:// source;
          a /nix/store path has nothing to fetch, so it would silently never update.
        '';
      }) cfg.marketplaces;

    # EVERY declared marketplace lands here — this is the whole point of the
    # option. Claude Code fetches a settings-declared marketplace itself:
    # "A marketplace that settings declare but known_marketplaces.json lacks:
    # Claude Code clones it, then reloads plugins and downloads enabled plugins
    # that aren't cached yet" (docs/en/plugins/loading § Plugins and
    # marketplaces that aren't on disk at session start). User scope qualifies.
    #
    # Never filter this by autoUpdate: WHETHER a marketplace is declared and
    # whether Claude Code may refresh it in the background are independent. Emitting
    # `autoUpdate = true` unconditionally would also contradict the assertion
    # above, which forbids the flag on a store path.
    #
    # Source SHAPE is per-kind and must match what the CLI writes itself, or
    # this declares a second, differently-shaped entry instead of merging onto
    # the existing one. Both shapes measured from the live settings.json:
    #   https:// -> { source = "git";       url  = <url>;  }
    #   /nix/store -> { source = "directory"; path = <path>; }
    # settings.json is deep-merged with Nix winning on its own keys
    # (./claude-code-settings.nix).
    programs.claude-code.settings.extraKnownMarketplaces = lib.mapAttrs (
      _: mp:
      {
        source =
          if isStorePath mp then
            {
              source = "directory";
              path = mp.source;
            }
          else
            {
              source = "git";
              url = mp.source;
            };
      }
      // lib.optionalAttrs mp.autoUpdate { autoUpdate = true; }
    ) cfg.marketplaces;

    # A CURATED ALWAYS-ON SET — not every declared plugin (#648).
    #
    # This was `lib.genAttrs allIds (_: true)`, which force-enabled every plugin in
    # every declared marketplace and made a UI toggle non-durable: a rebuild reverted
    # whatever the operator chose. That inverted the decided architecture — Nix
    # guarantees the marketplaces are REGISTERED; which plugins are enabled is a
    # runtime choice that has to persist.
    #
    # MEMBERSHIP RULE: what this repo structurally BREAKS without, not what is merely
    # useful. Widening the bar was considered and declined (#648).
    #   nix-flake-kit  the `autostage-nix` + `nix-home-path-lint` hooks.
    #                    Without it a `.nix` edit can reach an eval unstaged, which is
    #                    the failure git-purity exists to prevent.
    #   superhook        the `Stop` + `PreToolUse:Bash` wrappers and the SessionStart
    #                    digest. Since #673 these arrive ONLY as plugin hooks —
    #                    `.claude/settings.json` wires neither — so without this
    #                    plugin both of the repo's guards are simply absent. #648 made
    #                    this member conditional on #651 landing as D1; #651 is closed
    #                    and #673 merged, so it is now unconditional.
    #   brain-signals    `claude-brain.nix`'s `outputStyle` declares a style that only this
    #                    plugin supplies. Dropping it was considered and declined.
    #
    # Everything else is the operator's to toggle, and the toggle now PERSISTS. A
    # fresh machine starts with this set and nothing more; the rest come back on
    # demand because their marketplace is declared.
    #
    # NO SECOND LANE since 2026-11-07. ADR-008's `local.claudePlugins.declared` (an
    # operator-written map re-asserted every activation) was RETIRED by the operator's
    # model: Nix REGISTERS marketplaces, plugin state is a runtime choice made in
    # `/plugin` or on claude.ai (`@synced`). The invariant #648 bought holds trivially:
    # Nix writes an `enabledPlugins` key only for the ids above, so every other
    # id keeps whatever the UI wrote, `false` included.
    programs.claude-code.settings.enabledPlugins = lib.genAttrs (alwaysOnIds ++ operatorIds) (_: true);

    # ONE `marketplace add` per store-path marketplace, and nothing else. It
    # buys exactly one thing: the FIRST session after a fresh install or a
    # content bump sees the plugin already there.
    #
    # WHAT THE DECLARATIONS ABOVE ALREADY DO, for every marketplace including a
    # store-path one — measured 2026-09-30, Claude Code 2.1.268, isolated
    # CLAUDE_CONFIG_DIR:
    #   1. The SESSION-START reconcile re-points a `directory`-source
    #      marketplace when settings.json's `source.path` changes, and it is NOT
    #      auth-gated: a logged-OUT TUI rendered `Not logged in` and
    #      `Plugins changed. Run /reload-plugins to activate.` in the same
    #      frame, and known_marketplaces.json moved to the new path.
    #   2. `~/.claude/plugins/cache` is NEVER READ at load for a directory
    #      source — such a plugin loads LIVE from the marketplace directory. A
    #      plugin whose recorded `installPath` did not exist on disk still
    #      loaded and executed.
    #
    # Finding 2 is why the uninstall → remove → re-add → re-install teardown this
    # block ran until 2026-09-30 is gone: there is no cache copy to go stale.
    #
    # STILL TRUE, and why the one call survives:
    #   3. The CLI does NOT propagate a settings change — neither
    #      `plugin update` NOR `marketplace update`. known_marketplaces.json is
    #      what a refresh reads, and only an explicit `plugin marketplace add`
    #      writes it. So the reconcile in finding 1 is the ONLY thing that
    #      re-points a marketplace, and it happens at SESSION START.
    #   4. `plugin marketplace add <path>` on an already-registered NAME with a
    #      DIFFERENT path succeeds and re-points — no remove-first dance.
    #
    # Hence the lag this guard removes, and its whole justification: without it
    # a fresh Mac's first session has the plugin ABSENT (the reconcile writes
    # known_marketplaces, the plugin is not there yet), and the first session
    # after each rebuild serves the PREVIOUS generation behind a "Plugins
    # changed" notice. Activation runs before any session does, so one `add`
    # collapses that to zero sessions of lag. Drop this block and nothing
    # breaks permanently — you just pay one stale session per bump.
    home.activation.claudeCodePlugins = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      # home-manager activation runs with a bare PATH (no ~/.nix-profile, no
      # /etc/profiles/per-user/<user>/bin). `claude` is invoked by absolute
      # store path, but its SUBPROCESSES are not: a bare `git` lookup failed
      # with "git ... not on PATH" here while every interactive PATH had it.
      # Measured against `plugin install` on a git-subdir source, which is gone;
      # kept because `marketplace add` may shell out the same way and one store
      # path on PATH is free. UNMEASURED for `add` alone — say so, don't imply.
      export PATH="${pkgs.git}/bin:$PATH"
      # Run with CLAUDE_CONFIG_DIR unset, i.e. the personal profile; the work profile's
      # plugins/ is a link to this one (./claude-profiles.nix), so one add covers both.
      # programs.claude-code.package is null (no bare `claude`), so use the shared one.
      claude="${lib.getExe config.local.claudeProfiles.package}"
      known_mps="${config.home.homeDirectory}/.claude/plugins/known_marketplaces.json"
      if [ -x "$claude" ]; then
        ${lib.concatStringsSep "\n\n  " (
          lib.mapAttrsToList (
            name: mp:
            reindent ''
              # ${name} — content-addressed source: the store path moves whenever the
              # pinned content changes. Key off the path actually RECORDED in
              # known_marketplaces.json (settings.json is not what the CLI reads), and
              # re-point in place: `add` on a registered name with a new path succeeds.
              mp_src=${lib.escapeShellArg mp.source}
              grep -qF "$mp_src" "$known_mps" 2>/dev/null || "$claude" plugin marketplace add "$mp_src" 2>&1 || true
            ''
          ) storePathMarketplaces
        )}
      fi
    '';
  };
}
