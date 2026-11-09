# Claude Code PROFILES — two named commands and NO bare `claude` on this Mac:
#   claude-personal  the personal account   (CLAUDE_CONFIG_DIR UNSET → ~/.claude, ~/.claude.json)
#   claude-work      the work account       (CLAUDE_CONFIG_DIR=~/.claude-work)
# Each has its own login. Typing bare `claude` prints which one to use.
#
# WHY NAMED-ONLY (decided 2026-11-09): with a bare `claude` = personal, habit ran a
# 4-day work handoff session on the personal account — personal quota, no org policy,
# invisible to `claude-work --resume` and to work peers, memory split 77 vs 2 notes.
# Nothing in the session tells you which account it is on until it is too late, so the
# choice is made explicit at launch. Rejected, with the evidence:
#   - a fresh ~/.claude-personal dir (symmetry): an EXPLICIT CLAUDE_CONFIG_DIR — even
#     =~/.claude — selects a different Keychain entry than unset (anthropics/claude-code
#     #92252, open), so it forces a re-login, a ~/.claude.json move and a 3.7 GB
#     transcript move; and Desktop (#101747, #90868), bridge-spawn (#98789), /statusline
#     (#106764) and scheduled tasks (#100138) recreate ~/.claude anyway.
#   - bare `claude` routed by cwd (like git includeIf): silent wrong-account switches,
#     and the most custom logic.
#   - keep bare `claude` = personal + a warning: habit unchanged.
# Precedent: Anthropic's maintainer suggests exactly these two aliases (#76656, closed
# 2026-08-17 as "use CLAUDE_CONFIG_DIR"). Every other multi-account CLI (gcloud, aws,
# kubectl, gh) keeps a default; this fleet deliberately does not.
# Checked before removing the bare name (2.1.318): teammate panes start the CURRENT
# binary (`pinToCurrentBinary`), and a subagent ran with no `claude` on PATH.
#
# MECHANISM: Anthropic's documented one — "Log in with multiple accounts": give each
# account its own CLAUDE_CONFIG_DIR (code.claude.com/docs/en/authentication). The
# Keychain entry is keyed to the directory, so neither login ever replaces the other,
# and `claude-work` is a full claude.ai login: connectors and Remote Control work.
# Both wrappers exec ONE store path. The old `exec claude` resolved by PATH name, so in
# a repo whose dev shell ships its own, older claude the work profile
# silently ran that older binary.
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
#   - GUI hosts (Desktop, the VS Code extension, the Agent SDK) run their own bundled
#     binary with the variable unset, i.e. personal. The status line below names the
#     profile in every session, however it was launched, and flags personal-in-a-work-repo.
#     A work repo is one whose git config sets `claude.profile = work` — the hand-placed
#     includeIf file that already routes the work git identity, so no org name lands here.
#
# REPLACES the setup-token wrapper (CLAUDE_CODE_OAUTH_TOKEN over a shared ~/.claude,
# 2026-10-26, #947). That token is CI-scoped per the authentication docs — "can only
# make model requests", no claude.ai connectors, no Remote Control — so real work
# needed a global `/login`, which flipped every running session to the work account.
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
  exe = lib.getExe config.local.claudeProfiles.package;
  link = name: {
    "${cfg.configDir}/${name}".source = config.lib.file.mkOutOfStoreSymlink "${personalDir}/${name}";
  };

  # No runtimeInputs: writeShellApplication would prepend them to PATH, and every Bash
  # call inside the session inherits that PATH.
  # OTEL_RESOURCE_ATTRIBUTES tags claude-otel.nix's events with the profile — both
  # profiles share one collector, so without it the two accounts' telemetry is mixed.
  profileEnv = name: ''
    export OTEL_RESOURCE_ATTRIBUTES="claude.profile=${name}''${OTEL_RESOURCE_ATTRIBUTES:+,$OTEL_RESOURCE_ATTRIBUTES}"
  '';
  # --allow-dangerously-skip-permissions OFFERS bypass in the Shift+Tab cycle without
  # starting in it (CLI help: "as an option, without it being enabled by default"); a
  # session launched without it tops out at auto. Operator's call, 2026-11-09. Under
  # claude-work the org's allowManagedPermissionRulesOnly drops the user deny/ask floor,
  # so bypass there has almost no guardrails. Checked with --version and the mcp, auth
  # and plugin subcommands: the flag does not break them.
  exec' = "exec ${exe} --allow-dangerously-skip-permissions";
  personal = pkgs.writeShellApplication {
    name = "claude-personal";
    text = ''
      # UNSET, never =~/.claude: an explicit value selects a different Keychain entry
      # than unset (anthropics/claude-code#92252) and moves .claude.json into the dir.
      # Unsetting also drops a value inherited from a claude-work session.
      unset CLAUDE_CONFIG_DIR
      ${profileEnv "personal"}
      ${exec'} "$@"
    '';
  };
  work = pkgs.writeShellApplication {
    name = "claude-work";
    text = ''
      export CLAUDE_CONFIG_DIR=${lib.escapeShellArg cfg.configDir}
      ${profileEnv "work"}
      ${exec'} "$@"
    '';
  };

  # Status line for BOTH profiles (the settings floor fans out to each dir). Reads only
  # the account's organisation name, never a token.
  statusLine = pkgs.writeShellApplication {
    name = "claude-profile-statusline";
    text = ''
      input=$(cat)
      cwd=$(printf '%s' "$input" | ${pkgs.jq}/bin/jq -r '.workspace.current_dir // .cwd // empty')
      if [ -n "''${CLAUDE_CONFIG_DIR:-}" ]; then
        state="$CLAUDE_CONFIG_DIR/.claude.json"
        case "''${CLAUDE_CONFIG_DIR%/}" in
          ${lib.escapeShellArg cfg.configDir}) profile=work ;;
          *) profile="custom:''${CLAUDE_CONFIG_DIR##*/}" ;;
        esac
      else
        state="$HOME/.claude.json"
        profile=personal
      fi
      org=$(${pkgs.jq}/bin/jq -r '.oauthAccount.organizationName // empty' "$state" 2>/dev/null || true)
      label="$profile''${org:+ · $org}"
      repo=""
      [ -n "$cwd" ] && repo=$(${pkgs.git}/bin/git -C "$cwd" config --get claude.profile 2>/dev/null || true)
      if [ "$repo" = work ] && [ "$profile" != work ]; then
        printf '\033[1;41;97m %s in a WORK repo — restart with claude-work \033[0m\n' "$label"
      else
        printf '\033[2m[%s]\033[0m\n' "$label"
      fi
    '';
  };
in
{
  options.local.claudeProfiles.package = lib.mkOption {
    type = lib.types.package;
    description = "The one claude-code derivation every profile wrapper execs by store path.";
  };
  options.local.claudeWorkProfile = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = import ../_lib/is-macos-host.nix osConfig;
      description = "Install `claude-personal` and `claude-work`: Claude Code under one CLAUDE_CONFIG_DIR per account, with no bare `claude`.";
    };
    configDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.claude-work";
      description = "The work profile's CLAUDE_CONFIG_DIR. Read by claude-code-settings.nix, which merges the settings floor into it.";
    };
  };

  config = lib.mkMerge [
    # Every host gets `claude-personal`, so the habit is one command everywhere. Linux
    # hosts have one account and keep their bare `claude` too (default.nix).
    { home.packages = [ personal ]; }

    (lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isDarwin) {
      home.packages = [ work ];
      home.file = lib.mkMerge (
        map link [
          "CLAUDE.md"
          "rules"
          "skills"
          "plugins"
        ]
      );

      programs.claude-code.settings.statusLine = {
        type = "command";
        command = lib.getExe statusLine;
      };

      # zsh calls this for any unknown command; only `claude` gets the hint.
      programs.zsh.initContent = ''
        command_not_found_handler() {
          if [[ $1 == claude ]]; then
            print -u2 "claude: no default profile on this Mac — use claude-work (work account) or claude-personal."
          else
            print -u2 "zsh: command not found: $1"
          fi
          return 127
        }
      '';
    })
  ];
}
