# nix-darwin: generic per-directory file rotation via user LaunchAgents.
#
# Declares `services.fileRotation.paths`, a list of directories whose
# top-level files are periodically rotated once older than `maxAgeDays` —
# either moved to ~/.Trash (recoverable, the default) or deleted outright.
# Each entry becomes one `launchd.user.agent` running a small shell script.
#
# The rotation script uses ONLY stock macOS tools under /usr/bin and /bin
# (find, mv, mkdir, date, basename) — no Nix store runtime inputs — so the
# work it performs has zero closure beyond the launchd `.script` interpreter
# nix-darwin wraps it in.
{
  config,
  lib,
  userName,
  domainName,
  ...
}:

let
  inherit (lib)
    mkOption
    mkIf
    types
    imap0
    concatStringsSep
    reverseList
    splitString
    ;

  cfg = config.services.fileRotation;

  # Derive the home from the declared user rather than hardcoding /Users/<name>.
  home = config.users.users.${userName}.home;

  # Identity-neutral reverse-DNS namespace derived from the fleet domain rather
  # than a personal handle: "kattakath.com" → "com.kattakath".
  rdns = concatStringsSep "." (reverseList (splitString "." domainName));

  # Build one launchd user agent (a { name; value; } pair) per rotation entry.
  mkAgent =
    index: entry:
    let
      # Short, human-readable name for logs: caller-supplied, else positional.
      shortName = if entry.name != null then entry.name else toString index;

      # launchd Label under the domain-derived reverse-DNS namespace, e.g.
      # "com.kattakath.file-rotation.screengrab-rotate".
      label = "${rdns}.file-rotation.${shortName}";

      # maxAgeDays=1 ⇒ "older than 24h" ⇒ find -mmin +1440.
      ageMin = entry.maxAgeDays * 1440;

      logFile = "${home}/Library/Logs/file-rotation-${shortName}.log";

      # Top-level regular files older than the cutoff, excluding .DS_Store.
      # macOS /usr/bin/find (BSD) supports -mmin, so this needs no GNU findutils.
      findBase = ''/usr/bin/find "$target" -maxdepth 1 -type f ! -name '.DS_Store' -mmin +${toString ageMin}'';

      # POSIX-shell-safe: `find -exec sh -c '... for f do ...' _ {} +` batches the
      # matches and iterates them safely (spaces/newlines included) with zero
      # bashisms — no `read -d ""`, no `< <()` process substitution. So it runs
      # correctly whether launchd invokes the wrapper under /bin/sh or bash.
      rotate =
        if entry.action == "trash" then
          ''
            /bin/mkdir -p "${home}/.Trash"
            ${findBase} -exec /bin/sh -c 'for f do
              base=$(/usr/bin/basename "$f")
              dest="${home}/.Trash/$base"
              # Never clobber an existing trashed file of the same name.
              if [ -e "$dest" ]; then
                dest="$dest.$(/bin/date +%Y%m%d%H%M%S)"
              fi
              /bin/mv -- "$f" "$dest"
            done' _ {} +
          ''
        else
          ''
            ${findBase} -delete
          '';
    in
    {
      name = label;
      value = {
        serviceConfig = {
          # Explicit Label so it is the domain-derived rDNS string itself, not
          # nix-darwin's default "${labelPrefix}.${name}" (org.nixos.…) prefix.
          Label = label;
          StartInterval = entry.interval;
          RunAtLoad = true;
          StandardOutPath = logFile;
          StandardErrorPath = logFile;
        };
        script = ''
          set -eu

          /bin/mkdir -p "${home}/Library/Logs"

          # Resolve ~ / relative entry paths against the user's home; leave
          # absolute paths untouched. Callers normally pass absolute dirs.
          raw='${entry.path}'
          case "$raw" in
            '~') target='${home}' ;;
            '~/'*) target="${home}/''${raw#'~/'}" ;;
            /*) target="$raw" ;;
            *) target="${home}/$raw" ;;
          esac

          # Guarantee the directory exists so the first run never errors.
          /bin/mkdir -p "$target"

          ${rotate}
        '';
      };
    };
in
{
  options.services.fileRotation.paths = mkOption {
    type = types.listOf (
      types.submodule {
        options = {
          path = mkOption {
            type = types.str;
            description = "Directory whose top-level files are rotated (absolute, ~, or home-relative).";
          };
          maxAgeDays = mkOption {
            type = types.int;
            description = "Rotate files whose mtime is older than this many days.";
          };
          interval = mkOption {
            type = types.int;
            default = 3600;
            description = "How often the agent runs, in seconds (launchd StartInterval).";
          };
          action = mkOption {
            type = types.enum [
              "trash"
              "delete"
            ];
            default = "trash";
            description = "Move rotated files to ~/.Trash (recoverable) or delete them outright.";
          };
          name = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Short label component under the domain rDNS namespace (e.g. <rdns>.file-rotation.<name>); defaults to the positional index when null.";
          };
        };
      }
    );
    default = [ ];
    description = "Declarative per-directory file-rotation LaunchAgents (macOS).";
  };

  config = mkIf (cfg.paths != [ ]) {
    launchd.user.agents = builtins.listToAttrs (imap0 mkAgent cfg.paths);
  };
}
