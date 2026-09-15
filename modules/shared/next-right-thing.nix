# The generator behind the one Übersicht widget: pick ONE thing, render it, publish.
#
# Split from ./ubersicht.nix on purpose. That module owns "render whatever HTML
# is at this path"; this one owns "decide what that HTML says". Keeping them
# apart means `local.ubersicht.htmlWidget` stays reusable for any other page.
#
# WHY ONE CARD AND NOT A DASHBOARD — this is the whole design, not a style choice.
# A dashboard forgives a bad ranking: the eye finds the real item among nine and
# the ranker's mistakes stay invisible. With one card a wrong pick IS the product,
# and it spends the trust that makes the next card get read at all. Hence the art
# fallback: the generator must be willing to say nothing.
#
# upstream-first: grepped the pinned home-manager and nix-darwin option surfaces
# for a periodic user-job abstraction beyond `launchd.agents` (2026-09-15) — there
# is none, so this uses `launchd.agents` directly, and inherits the `nix-<name>`
# arg0 from ./launchd-launcher.nix rather than re-implementing it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.nextRightThing;

  # Repo-relative SOURCE path literals: evaluated relative to this file, hashed,
  # copied into the store. Not $HOME paths — those are impossible at eval time.
  scriptDir = ../../packages/next-right-thing;
  fontDir = ../../sites/ismail-landing/fonts;

  libexec = pkgs.runCommand "next-right-thing-libexec" { } ''
    mkdir -p $out/libexec
    cp ${scriptDir}/render.sh ${scriptDir}/decide.sh ${scriptDir}/art.sh \
       ${scriptDir}/run.sh ${scriptDir}/probe.sh ${scriptDir}/gather.sh \
       ${scriptDir}/render-swiftbar.sh \
       $out/libexec/
    chmod +x $out/libexec/*.sh
  '';

  # $HOME-relative at runtime, derived lexically from outputPath so the writer
  # and both readers can never disagree about where the verdict lives.
  verdictPath = "${builtins.dirOf cfg.outputPath}/verdict.json";

  # SwiftBar launches plugins with a minimal PATH, so the plugin is wrapped
  # rather than symlinked raw — otherwise `jq` is simply missing and the item
  # silently never appears.
  swiftbarPlugin = pkgs.writeShellApplication {
    name = "next-right-thing-swiftbar";
    runtimeInputs = with pkgs; [
      jq
      coreutils
    ];
    text = ''
      export NRT_VERDICT="${verdictPath}"
      exec ${libexec}/libexec/render-swiftbar.sh
    '';
  };

  generator = pkgs.writeShellApplication {
    name = "next-right-thing";
    runtimeInputs = with pkgs; [
      jq
      curl
      coreutils
      findutils
      gnused
      gnugrep
      file
      gh
    ];
    text = ''
      export NRT_OUT="${cfg.outputPath}"
      export NRT_VERDICT="${verdictPath}"
      export NRT_FONT_DIR="${fontDir}"
      export NRT_ART_FILE="''${XDG_CACHE_HOME:-$HOME/.cache}/ubersicht/art.jpg"
      export NRT_ART_TTL_HOURS="${toString cfg.artTtlHours}"
      # escapeShellArg, NOT double quotes: artSource carries a LITERAL `$RATING`
      # placeholder that art.sh substitutes itself. Interpolated into double
      # quotes, bash expands it here instead — and under `set -u` that is a hard
      # "RATING: unbound variable" that kills every run. Measured in production.
      # shellcheck disable=SC2016  # the single quotes are the POINT: $RATING is a
      # placeholder art.sh substitutes itself, and expanding it here is the bug.
      export NRT_ART_SOURCE=${lib.escapeShellArg cfg.artSource}
      export NRT_NSFW=${lib.escapeShellArg cfg.artRating}
      export NRT_AUDIENCE_GATE="${if cfg.audienceGate then "1" else "0"}"
      ${lib.optionalString (cfg.artTokenEnv != null) ''export NRT_ART_TOKEN="''${${cfg.artTokenEnv}:-}"''}
      exec ${libexec}/libexec/run.sh
    '';
  };
in
{
  options.local.nextRightThing = {
    enable = lib.mkEnableOption "the Next Right Thing Übersicht generator";

    outputPath = lib.mkOption {
      type = lib.types.str;
      default = "$HOME/.local/share/ubersicht/next-right-thing.html";
      description = ''
        Runtime path the generator publishes to. Must match
        `local.ubersicht.htmlWidget`, and must stay out of `~/Desktop`,
        `~/Documents` and `~/Downloads` — TCC denies `/bin/sh` there, and
        Übersicht shells out to read it.
      '';
    };

    startMinutes = lib.mkOption {
      type = lib.types.listOf lib.types.ints.unsigned;
      default = [
        0
        20
        40
      ];
      description = ''
        Minutes past the hour to run, as `StartCalendarInterval` entries.
        Not more often than ~every 10 min: Gmail's per-user-per-minute quota is
        6,000 units and one `search_emails` at 50 results already costs ~1,005.
      '';
    };

    artSource = lib.mkOption {
      type = lib.types.str;
      default = "https://civitai.red/api/v1/images?limit=40&nsfw=$RATING&sort=Most%20Reactions&period=Week";
      description = ''
        Image-listing endpoint for the fallback wallpaper. Must return JSON with
        an `items` array whose entries carry `url` and `browsingLevel`.
        `$RATING` interpolates `artRating`.

        Measured 2026-09-15: Civitai's public v1 endpoint returns
        `browsingLevel = 1` only, whatever `nsfw` is set to — with and without an
        API key. Point this elsewhere if you want anything else.
      '';
    };

    artRating = lib.mkOption {
      type = lib.types.enum [
        "None"
        "Soft"
        "Mature"
        "X"
      ];
      default = "X";
      description = ''
        Ceiling for fallback art, enforced twice: in the request, and again
        client-side against each item's `browsingLevel`. See `artSource` for why
        this is currently inert against Civitai.
      '';
    };

    audienceGate = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Force `artRating = "None"` while a call or screen-capture app is running.
        The widget renders behind every window, so it lands in screen shares.
      '';
    };

    swiftbar = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Publish the verdict to the macOS menu bar via SwiftBar, in addition to
          the Übersicht card.

          The menu bar is the PRIMARY surface, and the reason is measured rather
          than aesthetic: this operator runs one fullscreen app per desktop, and
          Übersicht draws at `kCGDesktopWindowLevel` with
          `setIgnoresMouseEvents:YES` — so its card is both covered by a
          fullscreen app and permanently unclickable. The menu bar strip stays
          drawn in fullscreen here (`_HIHideMenuBar = 0`,
          `AppleMenuBarVisibleInFullscreen = 1`) and its dropdown can carry a
          link, so the action is actually actionable.

          The plugin makes no model call — it reads the verdict the agent already
          published, so a second surface costs a `cat`.
        '';
      };

      pluginDir = lib.mkOption {
        type = lib.types.str;
        default = ".local/share/swiftbar-plugins";
        description = ''
          `$HOME`-relative SwiftBar plugin directory. Keep it a stable home path:
          pointing SwiftBar's own preference at a `/nix/store` path resolves and
          then breaks on every rebuild (SwiftBar issue #330).
        '';
      };

      refresh = lib.mkOption {
        type = lib.types.str;
        default = "5m";
        description = ''
          SwiftBar's filename-convention refresh interval. It can be far shorter
          than the generator's cadence because the plugin only re-reads a local
          file — the decision still happens once per agent run.
        '';
      };
    };

    artTokenEnv = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "CIVITAI_API_TOKEN";
      description = ''
        NAME of the environment variable holding a bearer token for `artSource`
        (never the value — that stays in the login Keychain, exported by the
        keychain-secrets loader). Some listing endpoints only return their full
        corpus when authenticated, and a token also lifts rate limits.
        `null` fetches anonymously.
      '';
    };

    artTtlHours = lib.mkOption {
      type = lib.types.ints.positive;
      default = 6;
      description = "Reuse the cached image for this long before refetching.";
    };
  };

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isDarwin) {
    home.packages = [ generator ] ++ lib.optional cfg.swiftbar.enable pkgs.swiftbar;

    home.file = lib.mkIf cfg.swiftbar.enable {
      # SwiftBar resolves symlinks for plugin files, so a Home Manager link into
      # the store is fine here (PluginManger.swift). The NAME carries the refresh
      # interval — that is SwiftBar's documented convention, not decoration.
      "${cfg.swiftbar.pluginDir}/next-right-thing.${cfg.swiftbar.refresh}.sh" = {
        source = lib.getExe swiftbarPlugin;
        executable = true;
      };
    };

    # SwiftBar reads its plugin folder from its own preference domain; without
    # this it opens a first-run folder picker and the plugin never loads.
    targets.darwin.defaults = lib.mkIf cfg.swiftbar.enable {
      "com.ameba.SwiftBar" = {
        PluginDirectory = "${config.home.homeDirectory}/${cfg.swiftbar.pluginDir}";
        SwiftBarLaunchAtLogin = true;
      };
    };

    launchd.agents.next-right-thing = {
      enable = true;
      config = {
        ProgramArguments = [ (lib.getExe generator) ];
        RunAtLoad = true;
        # StartCalendarInterval, NOT StartInterval. man 5 launchd.plist on
        # StartInterval: "If the system is asleep during the time of the next
        # scheduled interval firing, that interval will be missed" — close the
        # lid at 18:00, open at 09:00, and no run happens on wake, so the card is
        # 15 hours stale. StartCalendarInterval "will start the job the next time
        # the computer wakes up" and coalesces a backlog "into one event".
        StartCalendarInterval = map (m: { Minute = m; }) cfg.startMinutes;
        # Matches media-cli's prior art: this is background work and must never
        # compete with what the operator is actually doing.
        ProcessType = "Background";
        LowPriorityIO = true;
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/next-right-thing.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/next-right-thing.log";
        EnvironmentVariables = {
          # launchd agents start with a near-empty PATH. `sips`, `file` and
          # `pgrep` come from /usr/bin; `claude` and `gh` from the HM profile.
          PATH = "${config.home.profileDirectory}/bin:/usr/bin:/bin:/usr/sbin";
        };
      };
    };
  };
}
