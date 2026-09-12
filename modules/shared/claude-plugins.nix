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
    assertions = lib.mapAttrsToList (name: mp: {
      assertion = lib.hasPrefix "/nix/store/" mp.source || lib.hasPrefix "https://" mp.source;
      message = ''
        local.claudePlugins.marketplaces.${name}.source must be a /nix/store path
        or an https:// URL, got: ${mp.source}
        A path like /Users/... means `toString ../plugins` was used instead of
        string interpolation ("''${../plugins}") — that pins nothing and drifts.
      '';
    }) cfg.marketplaces;

    # Keeps every declared plugin switched ON once `claude plugin install` has
    # run below. Editing this in the Claude UI will not persist — a rebuild
    # reverts it; change the declaration instead.
    programs.claude-code.settings.enabledPlugins = lib.genAttrs allIds (_: true);

    # Materialise DECLARED marketplaces + plugins. installed_plugins.json /
    # known_marketplaces.json stay Claude-owned mutable state; settings.json is
    # Nix-managed, so temporarily materialise a writable copy for the install
    # and restore the store symlink afterwards.
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
        settings="${config.home.homeDirectory}/.claude/settings.json"
        settings_target=""
        if [ -L "$settings" ]; then
          settings_target=$(readlink "$settings")
          tmp=$(mktemp)
          cp -L "$settings" "$tmp"
          rm -f "$settings"
          mv "$tmp" "$settings"
          chmod u+w "$settings"
        fi

        known_mps="${config.home.homeDirectory}/.claude/plugins/known_marketplaces.json"

        ${lib.concatStringsSep "\n\n  " (
          lib.mapAttrsToList (
            name: mp:
            reindent (
              if mp.repin then
                ''
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
              else
                ''
                  # ${name} — fixed remote: register once. The elif repairs a machine
                  # still holding a stale DIRECTORY pin of this name (the reserved
                  # `claude-plugins-official` rejects directory pins as untrusted, and an
                  # SSH clone fails non-interactively — HTTPS is the only shape that
                  # works). A no-op on a healthy pin.
                  mp_src=${lib.escapeShellArg mp.source}
                  if ! "$claude" plugin marketplace list 2>/dev/null | grep -qF ${lib.escapeShellArg name}; then
                    echo "claude-code: adding ${name} marketplace -> $mp_src" >&2
                    "$claude" plugin marketplace add "$mp_src" 2>&1 || true
                  elif "$claude" plugin marketplace list 2>/dev/null | grep -A2 ${lib.escapeShellArg name} | grep -qF 'Directory'; then
                    echo "claude-code: replacing directory pin of ${name} with $mp_src..." >&2
                    "$claude" plugin marketplace remove ${lib.escapeShellArg name} 2>&1 || true
                    "$claude" plugin marketplace add "$mp_src" 2>&1 || true
                  fi
                ''
            )
          ) cfg.marketplaces
        )}

        for id in ${lib.escapeShellArgs allIds}; do
          if "$claude" plugin list 2>/dev/null | grep -qF "$id"; then
            : # already installed — idempotent skip
          else
            # Brace ''${id} — a bare `$id…` (unicode ellipsis) is one identifier under
            # bash nounset and aborts activation with "id…: unbound variable".
            echo "claude-code: installing plugin ''${id}..." >&2
            "$claude" plugin install "$id" 2>&1 || true
          fi
        done

        # Restore Nix-managed settings symlink for a clean next switch.
        if [ -n "$settings_target" ]; then
          rm -f "$settings"
          ln -s "$settings_target" "$settings"
        fi
      fi
    '';
  };
}
