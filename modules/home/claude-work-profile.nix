# `local.claudeWorkProfile` — a SECOND Claude Code profile for the work account,
# side by side with plain `claude` (the personal account), each with its own login.
#
# MECHANISM: Anthropic's documented one — "Log in with multiple accounts": give each
# account its own CLAUDE_CONFIG_DIR (code.claude.com/docs/en/authentication). The
# Keychain entry is keyed to the directory, so neither login ever replaces the other,
# and `claude-work` is a full claude.ai login: connectors and Remote Control work.
#
# WHAT IS SHARED, and how — the content, never the state:
#   - settings.json: the SAME Nix-owned floor, merged into this directory's own
#     writable file by claude-code-settings.nix (one rendered source, two targets).
#     Not a symlink: Claude Code rewrites that file, and a UI change made under one
#     account should not silently land in the other.
#   - CLAUDE.md, rules/, skills/, plugins/: out-of-store links to ~/.claude, so a
#     rebuild or a plugin install reaches both profiles at once.
# NEVER shared: projects/ and sessions/ (transcripts and the live-peer registry),
# the login, .claude.json, history.jsonl, and the org policy cache
# (remote-settings*, policy-limits*). Those are what keep the accounts apart.
#
# CONSEQUENCES, measured 2026-11-09 on 2.1.318:
#   - Peer discovery is per directory: a session under a separate CLAUDE_CONFIG_DIR
#     listed 0 peers while 6 were live under ~/.claude. Work and personal sessions
#     cannot message each other — the isolation is the point.
#   - The work org's server-managed settings apply ONLY here. They outrank the
#     root-owned managed file (managed sources are first-wins), and
#     `allowManagedPermissionRulesOnly` there drops user permission rules — so the
#     work profile runs on the org's rules, not this repo's floor. Under the old
#     design a global `/login` to the work account put that policy over EVERY
#     session; a Read the floor denies reached the filesystem.
#
# REPLACES the setup-token wrapper (CLAUDE_CODE_OAUTH_TOKEN over a shared ~/.claude,
# 2026-10-26, #947). That token is CI-scoped per the authentication docs — "can only
# make model requests", no claude.ai connectors, no Remote Control — so real work
# needed a global `/login`, which flipped every running session to the work account.
# The old header rejected a second CLAUDE_CONFIG_DIR because sharing HISTORY needs a
# symlink farm two live sessions write through; this design shares no history, so
# that premise no longer holds.
#
# upstream option home-manager.programs.claude-code.configDir exists, but it is
# single-valued (pinned options.nix `configDir`, one mkOption) → a second profile is
# custom. Community tool: clausona (larcane97/clausona) owns this exact mechanism →
# not using it, because it is a 0.x beta with one maintainer, installs by
# `curl | bash` and updates itself, edits the shell rc Home Manager owns, and its
# headline extra (quota routing across accounts) is what must NOT happen here.
# Retire this module if Claude Code ships first-class profiles.
{
  config,
  lib,
  pkgs,
  osConfig,
  ...
}:
let
  cfg = config.local.claudeWorkProfile;
  personalDir = config.programs.claude-code.configDir;
  link = name: {
    "${cfg.configDir}/${name}".source = config.lib.file.mkOutOfStoreSymlink "${personalDir}/${name}";
  };
in
{
  options.local.claudeWorkProfile = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = import ../_lib/is-macos-host.nix osConfig;
      description = "Install `claude-work`: Claude Code under its own CLAUDE_CONFIG_DIR for a second (work) account.";
    };
    configDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.claude-work";
      description = "The work profile's CLAUDE_CONFIG_DIR. Read by claude-code-settings.nix, which merges the settings floor into it.";
    };
  };

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isDarwin) {
    home.packages = [
      (pkgs.writeShellApplication {
        name = "claude-work";
        text = ''
          export CLAUDE_CONFIG_DIR=${lib.escapeShellArg cfg.configDir}
          exec claude "$@"
        '';
      })
    ];
    home.file = lib.mkMerge (
      map link [
        "CLAUDE.md"
        "rules"
        "skills"
        "plugins"
      ]
    );
  };
}
