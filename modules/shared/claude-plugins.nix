# Claude Code plugin marketplaces — the MECHANISM, N of them.
#
# Claude Code installs plugins from "marketplaces": a directory (or git URL)
# carrying a .claude-plugin/marketplace.json. This module owns everything
# generic about DECLARING them — `extraKnownMarketplaces` + `enabledPlugins`,
# which is all Claude Code needs to fetch a marketplace and download its
# enabled plugins itself. WHICH marketplaces exist and which plugins come from
# each is data, declared through `local.claudePlugins.marketplaces` — by this
# repo (modules/shared/home.nix) and, additively, by any private layer composed
# on top of it.
#
# The one imperative call left is a single `plugin marketplace add` per
# store-path marketplace, and it only removes a first-session lag — read the
# activation block's own comment, which carries the 2026-09-30 measurements
# (including the premise they refuted).
#
# It was a SINGLE-marketplace mechanism inlined in home.nix until the private
# nix-personal flake needed a second one and grew a near-verbatim copy of the
# whole activation script (ordered `entryAfter [ "claudeCodePlugins" ]` so the
# two would not race on the same mutable ~/.claude state). An attrsOf option
# merges by key instead, so the private layer now ADDS one attribute and there
# is exactly one script again — no copy to keep in sync, and no race to order
# around.
#
# WHY NOT `programs.claude-code.marketplaces` (upstream home-manager,
# modules/programs/claude-code/options.nix): that option writes a Nix-managed
# known_marketplaces.json SYMLINK, while both Claude Code's own session-start
# reconcile and `claude plugin marketplace add` need a mutable file; and the
# reserved name
# `claude-plugins-official` must be an HTTPS/GitHub source (a directory pin is
# rejected as untrusted). Plugin install state therefore stays Claude-owned
# mutable ~/.claude, like a gh/hf one-time login — the same "let the tool own
# its own state" trade this repo makes for grokMcp.
#
# AND WHY NOT THE SIBLING OPTION, `programs.claude-code.plugins` (same file,
# options.nix:150) — the half this note used to leave unexamined. It is an
# attrsOf (package|path) that SYMLINKS each plugin into configDir/skills/ and
# loads it as a personal plugin: fully declarative, no activation script, no CLI
# call, no mutable ~/.claude, and still an attrset, so a private layer would keep
# the same merge-by-key seam `local.claudePlugins.marketplaces` gives it today.
# On the motto's own terms that is the off-the-shelf option and this module is
# the hand-rolled one.
#
# It is NOT adopted, and the reason is scope, not preference: it installs plugin
# DIRECTORIES and has no concept of a marketplace. This repo's plugins/ tree is a
# marketplace on purpose — a publishable artifact others can add by URL — and
# `plugins` would silently drop that, turning a shareable marketplace into three
# private symlinks. Re-open this if either becomes true: upstream teaches
# `marketplaces` to accept a directory pin (which would retire this module
# outright), or the fleet stops caring about publishing plugins/ (which would
# make `plugins` strictly better). Measured against pinned home-manager
# 2026-09; re-grep after a bump rather than trusting this line.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.local.claudePlugins;

  # "<plugin>@<marketplace>" — the id shape `settings.enabledPlugins` keys on,
  # derived from the marketplace name so a plugin's id can never drift from the
  # marketplace it came from through a typo.
  idsOf = name: mp: map (p: "${p}@${name}") mp.plugins;
  allIds = lib.concatLists (lib.mapAttrsToList idsOf cfg.marketplaces);

  # The three plugins #648 decided Nix must assert, by bare name. Resolved against the
  # declared marketplaces so a name cannot drift from its source.
  alwaysOnNames = [
    "claude-code-nix"
    "superhook"
    "brain-signals"
  ];
  alwaysOnIds = lib.filter (id: lib.elem (lib.head (lib.splitString "@" id)) alwaysOnNames) allIds;

  # ADR-008's `declared` lane: the ids the operator has given a REPRODUCIBLE value,
  # floor-of-three excluded. Keyed by full id and never derived from `allIds` — the
  # invariant in the `enabledPlugins` note below depends on that.
  declaredIds = lib.attrNames cfg.declared;
  idParts = id: lib.splitString "@" id;
  idIsWellFormed =
    id:
    let
      parts = idParts id;
    in
    lib.length parts == 2 && lib.head parts != "" && lib.last parts != "";

  # ONE predicate for "this marketplace is a store path", shared by the three
  # places that must agree: the assertion, the settings-shape branch, and the
  # activation guard. It REPLACED a `repin` option whose only value was ever its
  # derived default (`hasPrefix "/" source`) — nothing in this repo, and nothing
  # a composed layer could plausibly want, ever set it. Deleted 2026-09-30 with
  # the re-pin machinery it named.
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
  # exactly the inert shape the two NixOS hosts want.
  options.local.claudePlugins.marketplaces = lib.mkOption {
    type = lib.types.attrsOf (
      # A plain attrset module — no `{ config, ... }` head: the last option that
      # read a sibling (`repin`, defaulting off `config.source`) is gone.
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
              marketplaces (attrsOf) and their plugins (listOf) — merges.
            '';
          };

          plugins = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "llmstxt" ];
            description = ''
              Bare plugin names inside this marketplace; the install id is
              derived as "<plugin>@<marketplace-name>". listOf, so a private
              layer can append to a marketplace THIS repo declares without
              forking its list.
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
          plugins = [ "my-plugin" ];
        };
      }
    '';
    description = ''
      Claude Code plugin marketplaces to register, and the plugins to install
      from each. attrsOf, so a private layer ADDS a key and this repo's own
      marketplaces survive untouched.
    '';
  };

  # The SECOND declarative lane (ADR-008 §6, `declared`). `marketplaces.*.plugins`
  # is a CATALOGUE — it makes `<plugin>@<marketplace>` resolvable and nothing more,
  # which is exactly the trap #751 fell into and #754 reverted. This option is the
  # only thing in the repo that can turn one of those ids on, or off.
  options.local.claudePlugins.declared = lib.mkOption {
    type = lib.types.attrsOf lib.types.bool;
    default = { };
    example = {
      "silent-instruments@kattakath" = true;
      "llmstxt@kattakath" = false;
    };
    description = ''
      Plugin ids whose enabled state this repo DECLARES, re-asserted on every
      activation into `~/.claude/settings.json`. `true` enables, `false`
      disables — both are first-class in Claude Code, where `enabledPlugins` is
      a MAP resolved per id, so an id named here touches no other id.

      THIS IS THE DEFAULT LANE, NOT A FLOOR. The operator may still flip any of
      these in `/plugin`; the next `activate` restores the value declared here.
      That is the whole trade ADR-008 §6 names, and it is why an id the operator
      wants permanently hand-controlled belongs in NEITHER this option nor the
      always-on set — which is the default for every id.

      FULL IDS, NOT BARE NAMES, unlike the always-on three. A bare name resolved
      against `marketplaces` cannot express an id from a marketplace this repo
      does not declare — `<plugin>@synced` (claude.ai sync) is live on this Mac
      and is unreachable any other way. The typo guard the derived form bought is
      kept where it still applies: an id whose marketplace IS declared here must
      name a plugin in that marketplace's `plugins` list, asserted below.

      NOT THE `assured` LANE. ADR-008 also proposes a root-owned managed-settings
      tier that no lower scope can retract; that is NOT implemented, and its §7
      measurements are still open. Everything here is user scope.
    '';
  };

  # macOS only — programs.claude-code is itself isDarwin-gated in
  # modules/shared/home.nix, so on nixpi/nixvm claude-code is a plain package
  # with no settings and no activation. Contributing an activation script there
  # would change those hosts' closures for no benefit.
  config = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    assertions =
      # Every always-on name must resolve to exactly one declared plugin. Without
      # this, renaming a plugin upstream (or dropping its marketplace) would leave a
      # member matching NOTHING and the guard it exists for would vanish silently —
      # the same "a rule naming something that does not exist is no rule" failure
      # claude-guardrails.nix warns about. A build error is the only honest outcome.
      map (n: {
        assertion = lib.length (lib.filter (id: lib.hasPrefix "${n}@" id) allIds) == 1;
        message =
          let
            hits = lib.length (lib.filter (id: lib.hasPrefix "${n}@" id) allIds);
          in
          ''
            local.claudePlugins: always-on plugin "${n}" resolves to ${toString hits} declared plugins, expected exactly 1.
            It is in the curated always-on set (#648), so a name matching nothing would
            silently disable a guard this repo depends on. Either the plugin was renamed
            upstream, or its marketplace is no longer declared.
          '';
      }) alwaysOnNames
      ++ lib.mapAttrsToList (name: mp: {
        assertion = isStorePath mp || lib.hasPrefix "https://" mp.source;
        message = ''
          local.claudePlugins.marketplaces.${name}.source must be a /nix/store path
          or an https:// URL, got: ${mp.source}
          A path like /Users/... means `toString ../plugins` was used instead of
          string interpolation ("''${../plugins}") — that pins nothing and drifts.
        '';
      }) cfg.marketplaces
      ++ map (id: {
        assertion = idIsWellFormed id;
        message = ''
          local.claudePlugins.declared key "${id}" is not a plugin id.
          `enabledPlugins` keys on "<plugin>@<marketplace>" — exactly one "@", neither
          half empty. A bare plugin name here would silently enable nothing, which is
          the #751 failure this option exists to make impossible.
        '';
      }) declaredIds
      ++ map (id: {
        assertion = !(lib.elem id alwaysOnIds);
        message = ''
          local.claudePlugins.declared may not name "${id}" — it is already in the
          curated always-on set (#648), which this repo structurally breaks without.
          The two lanes are deliberately disjoint: a `declared` value is the operator's
          to flip until the next activation, an always-on one is not negotiable. If the
          intent is to DROP the plugin, remove it from `alwaysOnNames` and say why;
          declaring `false` beside the floor would be a silent contradiction.
        '';
      }) declaredIds
      ++ map (
        id:
        let
          mpName = lib.last (idParts id);
          pluginName = lib.head (idParts id);
        in
        {
          # Only checkable when this repo declares the marketplace — an id like
          # "<plugin>@synced" names a marketplace Claude Code owns, whose plugin
          # list is not knowable at eval. Guarded on well-formedness so a malformed
          # key reports the shape error above rather than a bogus membership one.
          assertion =
            !(idIsWellFormed id)
            || !(lib.hasAttr mpName cfg.marketplaces)
            || lib.elem pluginName cfg.marketplaces.${mpName}.plugins;
          message = ''
            local.claudePlugins.declared names "${id}", but "${pluginName}" is not in
            local.claudePlugins.marketplaces.${mpName}.plugins.
            Enabling an id its marketplace does not carry installs nothing and reports
            nothing at runtime. Add the plugin to that marketplace's catalogue, or fix
            the typo.
          '';
        }
      ) declaredIds
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
    # DO NOT FILTER THIS BY autoUpdate. Until 2026-09-30 it read
    # `filterAttrs (_: mp: mp.autoUpdate)`, so only `kattakath` — one of four —
    # was ever declared. The other three existed on disk purely because the
    # activation script below re-added them imperatively, which made the
    # declaration cosmetic and a reset Mac silently short of three marketplaces.
    # Measured by eval, not read: claude-plugins-official=false,
    # context7-marketplace=false, kattakath=true, xai-grok-build=false.
    #
    # The two facts are independent: WHETHER a marketplace is declared, and
    # whether Claude Code may refresh it in the background. Emitting
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

    # A CURATED ALWAYS-ON SET OF THREE — not every declared plugin (#648).
    #
    # This was `lib.genAttrs allIds (_: true)`, which force-enabled every plugin in
    # every declared marketplace and made a UI toggle non-durable: a rebuild reverted
    # whatever the operator chose. That inverted the decided architecture — Nix
    # guarantees the marketplaces are REGISTERED; which plugins are enabled is a
    # runtime choice that has to persist.
    #
    # MEMBERSHIP RULE: what this repo structurally BREAKS without, not what is merely
    # useful. Widening the bar was considered and declined (#648).
    #   claude-code-nix  the `autostage-nix` + `nix-home-path-lint` PreToolUse hooks.
    #                    Without it a `.nix` edit can reach an eval unstaged, which is
    #                    the failure git-purity exists to prevent.
    #   superhook        the `Stop` + `PreToolUse:Bash` wrappers and the SessionStart
    #                    digest. Since #673 these arrive ONLY as plugin hooks —
    #                    `.claude/settings.json` wires neither — so without this
    #                    plugin both of the repo's guards are simply absent. #648 made
    #                    this member conditional on #651 landing as D1; #651 is closed
    #                    and #673 merged, so it is now unconditional.
    #   brain-signals    `claude-brain.nix:34` declares an output style that only this
    #                    plugin supplies. Dropping it was considered and declined.
    #
    # Everything else is the operator's to toggle, and the toggle now PERSISTS. A
    # fresh machine starts with these three and nothing more; the rest come back on
    # demand because their marketplace is declared.
    #
    # Ids are resolved through `idsOf` rather than written literally, so a member can
    # never drift from the marketplace it came from, and the assertion below fails the
    # build if a name stops matching instead of silently enabling nothing.
    #
    # PLUS `local.claudePlugins.declared` — ADR-008's second lane, added 2026-10-02.
    #
    # THE INVARIANT #648 BOUGHT, AND WHAT IT ACTUALLY SAYS. Its complaint was not "Nix
    # must name few plugins"; it was that `lib.genAttrs allIds (_: true)` DERIVED the
    # enabled set from the catalogue, so every plugin the repo merely listed was forced
    # on and a `/plugin` toggle died at the next rebuild. Stated precisely, and this is
    # the line any future widening has to hold:
    #
    #   Nix may write an `enabledPlugins` key ONLY for an id a human named ON PURPOSE.
    #   For every other id — including every id in `marketplaces.*.plugins` — the
    #   rendered attrset must have NO key at all, so the jq merge in
    #   ./claude-code-settings.nix (`.[0] * $nix[0]`, right operand wins per key)
    #   leaves the operator's value, `false` included, exactly as the UI wrote it.
    #
    # `declared` holds that invariant: it is an operator-written map of LITERAL ids, so
    # it can only ever name ids on purpose. `allIds` is never its source. The 2026-10-02
    # live state is the proof the merge does what this claims: 42 ids, 11 of them
    # `false`, of which Nix named 3 — the other 39 survived every activation since #648
    # precisely because no key existed for them.
    #
    # WHAT THIS LANE DOES NOT RESTORE: once an id IS in `declared`, its `/plugin` toggle
    # is durable only until the next `activate`. That is the trade, it is stated in the
    # option's description, and the escape is to name the id in neither map.
    #
    # Floor last, so it wins the `//` even though the assertions above already forbid an
    # overlap — a build-gated assertion and a structurally-correct merge order cost the
    # same here, and only one of them survives someone deleting the assertion.
    programs.claude-code.settings.enabledPlugins = cfg.declared // lib.genAttrs alwaysOnIds (_: true);

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
    # THE EARLIER PREMISE WAS MEASURED FALSE. Until 2026-09-30 this module
    # claimed a store-path marketplace was "NOT COVERED" by the declarations,
    # because `plugin install` COPIES into the cache and so a plain
    # already-registered guard "would keep serving a previous generation's
    # content forever". Finding 2 refutes that: there is no copy in the load
    # path to go stale. On that premise this block ran an uninstall →
    # marketplace-remove → re-add → re-install teardown; all of it is now
    # deleted, along with the `repin` option that named it.
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
      claude="${lib.getExe config.programs.claude-code.package}"
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
