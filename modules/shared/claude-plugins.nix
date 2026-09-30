# Claude Code plugin marketplaces — the MECHANISM, N of them.
#
# Claude Code installs plugins from "marketplaces": a directory (or git URL)
# carrying a .claude-plugin/marketplace.json. This module owns everything
# generic about registering them and installing their plugins; WHICH
# marketplaces exist and which plugins come from each is data, declared through
# `local.claudePlugins.marketplaces` — by this repo (modules/shared/home.nix)
# and, additively, by any private layer composed on top of it.
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
# known_marketplaces.json SYMLINK, while `claude plugin marketplace add` and
# `claude plugin install` need a mutable file; and the reserved name
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

  # "<plugin>@<marketplace>" — derived, never spelled twice. Single source for
  # BOTH settings.enabledPlugins and the install loop, so a plugin can never be
  # installed-but-disabled (or the reverse) through a typo.
  idsOf = name: mp: map (p: "${p}@${name}") mp.plugins;
  allIds = lib.concatLists (lib.mapAttrsToList idsOf cfg.marketplaces);

  # The imperative half, and ONLY it. An https marketplace is fully covered by
  # its `extraKnownMarketplaces` declaration plus `enabledPlugins`; a store-path
  # one is NOT, and the activation block below is the whole reason why.
  #
  # `repin` already defaults to `hasPrefix "/" source`, so this is exactly the
  # store-path set without a second predicate to keep in sync.
  repinMarketplaces = lib.filterAttrs (_: mp: mp.repin) cfg.marketplaces;
  repinIds = lib.concatLists (lib.mapAttrsToList idsOf repinMarketplaces);

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
      lib.types.submodule (
        { config, ... }:
        {
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

            repin = lib.mkOption {
              type = lib.types.bool;
              default = lib.hasPrefix "/" config.source;
              defaultText = lib.literalExpression ''lib.hasPrefix "/" config.source'';
              description = ''
                Re-pin whenever `source` differs from the path recorded in
                known_marketplaces.json: uninstall this marketplace's plugins,
                remove it, add it again.

                Required for a store-path marketplace, because `plugin install`
                COPIES into ~/.claude/plugins/cache — a plain "already
                registered?" guard would keep serving a previous generation's
                content forever. Pointless for a URL (a fixed remote), hence the
                derived default.
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
      )
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

  # macOS only — programs.claude-code is itself isDarwin-gated in
  # modules/shared/home.nix, so on nixpi/nixvm claude-code is a plain package
  # with no settings and no activation. Contributing an activation script there
  # would change those hosts' closures for no benefit.
  config = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    assertions =
      lib.mapAttrsToList (name: mp: {
        assertion = lib.hasPrefix "/nix/store/" mp.source || lib.hasPrefix "https://" mp.source;
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
          if lib.hasPrefix "/nix/store/" mp.source then
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

    # Keeps every declared plugin switched ON once `claude plugin install` has
    # run below. Editing this in the Claude UI will not persist — a rebuild
    # reverts it; change the declaration instead.
    programs.claude-code.settings.enabledPlugins = lib.genAttrs allIds (_: true);

    # STORE-PATH MARKETPLACES ONLY — the irreducible imperative remainder.
    #
    # This block used to register every marketplace and install every plugin.
    # An https marketplace no longer needs either: `extraKnownMarketplaces`
    # above declares it, `enabledPlugins` marks its plugins wanted, and Claude
    # Code clones the marketplace and downloads the plugins itself in the
    # background after session start (docs/en/plugins/loading § Plugins and
    # marketplaces that aren't on disk at session start).
    #
    # A STORE-PATH MARKETPLACE IS NOT COVERED BY THAT, measured 2026-09-30 in an
    # isolated CLAUDE_CONFIG_DIR against three generations of one directory
    # marketplace:
    #   - It installs as version `unknown` (no git repo, so no SHA), and
    #     `unknown` force-refreshes rather than pinning — that part is fine.
    #   - But a changed `source.path` in settings.json DOES NOT PROPAGATE.
    #     `known_marketplaces.json` is what the refresh actually reads, and only
    #     an explicit `plugin marketplace add` updates it. With settings pointing
    #     at generation C and known_marketplaces still at B, `plugin update`
    #     reported `"refreshed from source"` / `updateOutcome: "updated"` and
    #     served B. Silent success, stale content — the same shape as the
    #     version footgun this module's header warns about.
    #   - A settings-declared marketplace the CLI has never registered is
    #     invisible to it outright: "Available marketplaces:" comes back empty.
    #
    # So the re-pin stays, and it stays narrow. If the session-start path is
    # ever shown to re-point a directory source on a changed settings path, this
    # whole block can go — that is the one experiment left, and it needs a
    # logged-in interactive session, which an isolated config cannot have.
    #
    # TWO PHASES, deliberately not fused: every marketplace is pinned FIRST,
    # then one flat install loop runs. A per-marketplace pin-then-install would
    # let a later marketplace's re-pin teardown uninstall a plugin the loop had
    # already installed.
    home.activation.claudeCodePlugins = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      # home-manager activation scripts run with a bare PATH (no ~/.nix-profile,
      # no /etc/profiles/per-user/<user>/bin) — `claude` itself is invoked by
      # absolute store path below so that's fine, but ITS OWN subprocesses are
      # not: a "git-subdir" plugin source (e.g. neon@claude-plugins-official)
      # shells out to a bare `git` lookup and fails with "git ... not on PATH"
      # even though programs.git (same pkgs.git) is on every interactive PATH.
      export PATH="${pkgs.git}/bin:$PATH"
      claude="${lib.getExe config.programs.claude-code.package}"
      if [ -x "$claude" ]; then
       (
        # NO de-symlink dance here any more, and none is needed: since
        # modules/shared/claude-code-settings.nix, ~/.claude/settings.json is a
        # REAL writable file that Nix re-asserts its own keys into on every
        # rebuild. What stood here until 2026-09-22 de-symlinked it into a mutable
        # copy for the ~76 lines of NETWORKED `claude` calls below and restored it
        # under a subshell EXIT trap — because an abort in between stranded
        # settings.json as an unmanaged regular file that "looks completely normal
        # and silently stops tracking the flake, freezing this fleet's
        # permissions.deny floor at whatever it happened to be".
        #
        # That hazard is GONE rather than mitigated: there is no symlink to strand,
        # and an interrupt now leaves exactly the writable file the next activation
        # merges into. Do not re-add the trap — the subshell is kept only because
        # the plugin calls below still want their own scope.
        known_mps="${config.home.homeDirectory}/.claude/plugins/known_marketplaces.json"

        ${lib.concatStringsSep "\n\n  " (
          lib.mapAttrsToList (
            name: mp:
            reindent ''
              # ${name} — content-addressed source: its store path moves whenever the
              # pinned content changes, and `plugin install` COPIES into
              # ~/.claude/plugins/cache, so key off the path actually recorded in
              # known_marketplaces.json and tear the old pin down FIRST (uninstall
              # while the marketplace still resolves). Silent on a first switch:
              # there is nothing to remove and the CLI says so.
              mp_src=${lib.escapeShellArg mp.source}
              if ! grep -qF "$mp_src" "$known_mps" 2>/dev/null; then
                echo "claude-code: (re)pinning ${name} marketplace -> $mp_src" >&2
                if "$claude" plugin marketplace list 2>/dev/null | grep -qF ${lib.escapeShellArg name}; then
                  for id in ${lib.escapeShellArgs (idsOf name mp)}; do
                    "$claude" plugin uninstall --yes "$id" >/dev/null 2>&1 || true
                  done
                  "$claude" plugin marketplace remove ${lib.escapeShellArg name} >/dev/null 2>&1 || true
                fi
                "$claude" plugin marketplace add "$mp_src" 2>&1 || true
              fi
            ''
          ) repinMarketplaces
        )}

        # STORE-PATH IDS ONLY. The re-pin above UNINSTALLS this marketplace's
        # plugins before re-adding it, so something has to put them back in the
        # same activation — leaving that to Claude Code's own session-start
        # download would leave the plugin absent until the next session, and
        # absent entirely if that download does not cover directory sources.
        #
        # An https marketplace's plugins are NOT listed here: they are declared
        # in `enabledPlugins` above, and Claude Code downloads an enabled plugin
        # whose marketplace is settings-declared (docs/en/plugins/loading).
        for id in ${lib.escapeShellArgs repinIds}; do
          # WHOLE-LINE match, not a substring. `grep -qF "$id"` was a silent
          # install-skip whenever one marketplace name was a PREFIX of another:
          # measured 2026-09-12, renaming this repo's marketplace from
          # `kattakath-nix-config` to `kattakath` meant `llmstxt@kattakath`
          # matched the still-listed `llmstxt@kattakath-nix-config`, so the loop
          # declared it installed and installed nothing. Activation was green
          # and BOTH plugins were absent — the worst shape a guard can fail in.
          #
          # `plugin list` prints one id per line after a "❯ " bullet, so
          # anchoring the tail is enough to require an exact id. Plugin and
          # marketplace names are kebab-case, so no regex metacharacter can
          # reach the pattern from ''${id}.
          if "$claude" plugin list 2>/dev/null | grep -qE "(^|[[:space:]])''${id}[[:space:]]*$"; then
            : # already installed — idempotent skip
          else
            # Brace ''${id} — a bare `$id…` (unicode ellipsis) is one identifier under
            # bash nounset and aborts activation with "id…: unbound variable".
            echo "claude-code: installing plugin ''${id}..." >&2
            "$claude" plugin install "$id" 2>&1 || true
          fi
        done

        # No symlink restore: settings.json is a real file now
        # (modules/shared/claude-code-settings.nix). Nothing to put back.
       )
      fi
    '';
  };
}
