# nix-darwin: generic per-directory file rotation via user LaunchAgents.
#
# Declares `services.fileRotation.paths`, a list of directories whose
# top-level files are periodically rotated once older than `maxAgeDays` —
# either moved to ~/.Trash (recoverable, the default) or deleted outright.
# Each entry becomes one `launchd.user.agent` running a small shell script.
#
# The agent's short label is DERIVED, not spelled out: "<action>-<folder>",
# where <folder> is the path's basename lowercased with every non-[a-z0-9]
# character stripped (e.g. path ~/Pictures/Screengrab + action "trash" →
# "trash-screengrab", full launchd label
# "com.kattakath.file-rotation.trash-screengrab"). The (action, folder-basename)
# pair is assumed unique across paths; if two entries collide — or a basename
# has no alphanumerics to derive from — evaluation FAILS with a clear message
# (see the guards in `config`) rather than silently dropping an agent.
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
    concatStringsSep
    concatStrings
    reverseList
    splitString
    stringToCharacters
    toLower
    filter
    last
    unique
    count
    throwIf
    ;

  cfg = config.services.fileRotation;

  # Derive the home from the declared user rather than hardcoding /Users/<name>.
  home = config.users.users.${userName}.home;

  # Identity-neutral reverse-DNS namespace derived from the fleet domain rather
  # than a personal handle: "kattakath.com" → "com.kattakath".
  rdns = concatStringsSep "." (reverseList (splitString "." domainName));

  # Last non-empty path component: "~/Pictures/Screengrab/" → "Screengrab".
  baseComponent =
    p:
    let
      parts = filter (x: x != "") (splitString "/" p);
    in
    if parts == [ ] then "" else last parts;

  # Lowercase, then keep only [a-z0-9]: "Screen Grab!" → "screengrab".
  sanitize =
    s: concatStrings (filter (c: builtins.match "[a-z0-9]" c != null) (stringToCharacters (toLower s)));

  # Derived short label component: "<action>-<sanitized-basename>".
  sanitizedBase = entry: sanitize (baseComponent entry.path);
  shortNameOf = entry: "${entry.action}-${sanitizedBase entry}";

  # Build one launchd user agent (a { name; value; } pair) per rotation entry.
  mkAgent =
    entry:
    let
      shortName = shortNameOf entry;

      # launchd Label under the domain-derived reverse-DNS namespace, e.g.
      # "com.kattakath.file-rotation.trash-screengrab".
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

  # ---- Eval-time safety nets -------------------------------------------------
  # Names are derived, so two paths could collide (same action + same sanitized
  # basename, e.g. ~/a/logs and ~/b/logs both as "trash-logs"), and a basename
  # with no alphanumerics (e.g. "~") would derive an empty component. Either case
  # would silently collapse/mangle agents under listToAttrs — so fail loudly.
  shortNames = map shortNameOf cfg.paths;
  emptyBase = filter (e: sanitizedBase e == "") cfg.paths;
  dupes = unique (filter (n: count (x: x == n) shortNames > 1) shortNames);

  guard =
    v:
    throwIf (emptyBase != [ ])
      "services.fileRotation: cannot derive an agent name from path(s) [${
        concatStringsSep ", " (map (e: ''"${e.path}"'') emptyBase)
      }] — the folder basename has no [a-z0-9] characters. Rotate a directory whose name contains letters/digits."
      (
        throwIf (dupes != [ ])
          "services.fileRotation: duplicate derived agent name(s) [${concatStringsSep ", " dupes}]. The (action, folder-basename) pair must be unique across paths; give the colliding entries distinct folder names or actions."
          v
      );
in
{
  options.services.fileRotation.paths = mkOption {
    type = types.listOf (
      types.submodule {
        options = {
          path = mkOption {
            type = types.str;
            description = "Directory whose top-level files are rotated (absolute, ~, or home-relative). Its basename derives the agent name.";
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
            description = "Move rotated files to ~/.Trash (recoverable) or delete them outright. Also the first component of the derived agent name (<action>-<folder>).";
          };
        };
      }
    );
    default = [ ];
    description = "Declarative per-directory file-rotation LaunchAgents (macOS). Each agent's label is derived as <action>-<sanitized-folder-basename>.";
  };

  # Guard wraps the agents VALUE (not the whole config attrset) so the config's
  # top-level keys stay static — wrapping the attrset itself makes its keys
  # depend on config values and the module system infinite-recurses.
  config = mkIf (cfg.paths != [ ]) {
    launchd.user.agents = guard (builtins.listToAttrs (map mkAgent cfg.paths));
  };
}
