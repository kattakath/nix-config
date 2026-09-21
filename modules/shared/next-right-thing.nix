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
  # The one LIVE consumer of sites/ismail-landing/. That site moved to GitHub Pages
  # 2026-09-16 and `hostedSites` no longer lists it (modules/parts/identity.nix), so
  # the tree reads as a dead archive — but this widget's typography comes out of its
  # fonts/ subdir, and deleting the archive would break an unrelated übersicht widget
  # with nothing in sites/ to warn you. Vendoring a second copy of two .woff2 files
  # to decouple them would trade a findable coupling for a silent divergence; the
  # comment is the cheaper half. identity.nix carries the matching back-pointer.
  fontDir = ../../sites/ismail-landing/fonts;

  libexec = pkgs.runCommand "next-right-thing-libexec" { } ''
    mkdir -p $out/libexec
    cp ${scriptDir}/render.sh ${scriptDir}/decide.sh ${scriptDir}/art.sh \
       ${scriptDir}/run.sh ${scriptDir}/probe.sh ${scriptDir}/gather.sh \
       $out/libexec/
    chmod +x $out/libexec/*.sh
  '';

  # $HOME-relative at runtime, derived lexically from outputPath so the verdict
  # always lands next to the card it produced. Nothing in-tree reads it any more
  # (the menu-bar surface is gone); it stays as the decision record — `jq .` on it
  # says why the card reads the way it does, and any future surface reads it free.
  verdictPath = "${builtins.dirOf cfg.outputPath}/verdict.json";

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
    home.packages = [ generator ];

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
