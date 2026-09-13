# `activate` -- the day-to-day activation CLI for a PRIVATE COMPOSITION flake
# that pins this public engine (docs/private-home-modules.md).
#
# THIS FILE IS MECHANISM, so it lives here in the public repo. It moved out of
# the private flake on 2026-09-13 under the shape/values contract: nix-config
# owns every mechanism generically, a private flake supplies only values. All
# the values this script needs arrive as parameters below -- the private
# checkout path, the local nix-config path, the hostname -- and the body
# contains none. The private flake instantiates it through
# `nix-config.lib.mkActivateCli` and gets the same binary it always had.
#
# What it does: replaces a bare `nix run <path>#<host>` alias (no freshness
# check at all -- could silently activate a nix-config revision that was weeks
# stale) with a safety gate. By default it refuses to activate if the private
# flake's locked nix-config revision is behind the comparison source (REMOTE
# main, or a LOCAL checkout path passed as an argument), forcing an explicit
# --hard/--yolo or --soft rather than letting staleness go unnoticed.
{
  pkgs,
  lib,
  # The CALLING private flake's live working directory -- needed because --hard
  # and --yolo mutate and commit flake.lock, which only makes sense against
  # a real mutable git checkout, not an immutable Nix store copy of `self`.
  # Same hardcoded-path assumption the alias it replaced already made; not a
  # new fragility.
  nixPersonalDir,
  # Default local nix-config checkout for --local. Same literal-path
  # rationale as nixPersonalDir: builtins.getEnv is --impure and returns
  # "" under pure eval. Do NOT use NIX_CONF_DIR / NIX_CONFIG — those are
  # Nix's own config-file knobs (system nix.conf dir / inline nix.conf).
  nixConfigDir,
  # NOT named `hostname`: that collides with pkgs.hostname (the shell_cmds
  # `hostname` CLI utility) -- callPackage's auto-argument injection matches
  # parameter names against pkgs attributes REGARDLESS of a default value,
  # so `hostname ? "macos"` would silently receive the pkgs.hostname
  # derivation instead of "macos" unless callPackage's call site passes it
  # explicitly. Confirmed live: without the rename, the usage text below
  # printed a /nix/store/...-hostname-shell_cmds-329 path instead of "macos".
  darwinHostname ? "macos",
  remoteUrl ? "https://github.com/kattakath/nix-config.git",
  remoteBranch ? "main",
}:
pkgs.writeShellApplication {
  name = "activate";
  runtimeInputs = [
    pkgs.git
    pkgs.jq
    pkgs.nix
  ];
  text = ''
    NP_DIR=${lib.escapeShellArg nixPersonalDir}
    NC_DIR=${lib.escapeShellArg nixConfigDir}
    # Runtime overrides -- bash, not builtins.getEnv. Empty/unset keeps the
    # literals above. NIX_FLEET_PRIVATE = this flake's checkout;
    # NIX_FLEET_PUBLIC = the nix-config input checkout. Not NIX_CONFIG /
    # NIX_CONF_DIR (Nix's own nix.conf knobs) and not NH_FLAKE (the flake
    # nh would switch -- that's this private flake, not the public input).
    if [ -n "''${NIX_FLEET_PRIVATE:-}" ]; then
      NP_DIR="''${NIX_FLEET_PRIVATE}"
    fi
    HOSTNAME=${lib.escapeShellArg darwinHostname}
    REMOTE_URL=${lib.escapeShellArg remoteUrl}
    REMOTE_BRANCH=${lib.escapeShellArg remoteBranch}

    usage() {
      cat <<'USAGE'
    Usage: activate [--hard|--yolo|--soft|--local] [LOCAL_NIX_CONFIG_PATH]

    Activates the private composition's #${darwinHostname} (the private-composed darwin config).

    By default, checks whether the private flake's locked nix-config revision is
    behind REMOTE main (or LOCAL_NIX_CONFIG_PATH's HEAD, if given) and
    refuses to activate if it is.

      --hard   Catch up before activating.
                 - No path argument: updates the private flake's flake.lock to
                   REMOTE main and commits the bump LOCALLY (a real,
                   reviewable commit -- never silent; not pushed).
                 - With a path argument: activates using that LOCAL
                   checkout for THIS RUN ONLY (an ephemeral
                   --override-input). flake.lock is never touched -- a
                   local path has no portable revision to pin. If local
                   HEAD equals the locked rev, the override is SKIPPED
                   (use --local).
      --yolo   Same as --hard, and (no path argument only) also PUSHES
                 the bump commit to the private flake's own remote -- least
                 caution, don't leave the bump stranded on this machine.
                 With a path argument, --yolo behaves identically to
                 --hard (there's nothing to push -- the local override
                 never touches flake.lock).
      --soft   Proceed with the currently locked revision anyway, even
                 though it's behind. May activate an older nix-config
                 than what's on REMOTE or LOCAL.
      --local  Activate using the local nix-config checkout for THIS RUN
                 ONLY (ephemeral --override-input). Always overrides,
                 even when HEAD equals the locked rev. flake.lock is
                 never touched. Path, first set wins: extra arg,
                 else $NIX_FLEET_PUBLIC, else ${nixConfigDir}.
                 $NIX_FLEET_PRIVATE overrides the private-flake checkout.

    If the freshness check itself can't reach the network (offline, GitHub
    unreachable), activate warns and proceeds with the locked revision --
    it never hard-fails purely because the check couldn't run.
    USAGE
    }

    hard=0
    yolo=0
    soft=0
    local_mode=0
    local_path=""

    while [ $# -gt 0 ]; do
      case "$1" in
        --hard) hard=1; shift ;;
        --yolo) yolo=1; shift ;;
        --soft) soft=1; shift ;;
        --local) local_mode=1; shift ;;
        -h | --help)
          usage
          exit 0
          ;;
        -*)
          echo "activate: unknown option: $1" >&2
          usage >&2
          exit 1
          ;;
        *)
          local_path="$1"
          shift
          ;;
      esac
    done

    catchup_count=$((hard + yolo + soft + local_mode))
    if [ "$catchup_count" -gt 1 ]; then
      echo "activate: --hard, --yolo, --soft, and --local are mutually exclusive" >&2
      exit 1
    fi

    if [ "$local_mode" -eq 1 ] && [ -z "$local_path" ]; then
      if [ -n "''${NIX_FLEET_PUBLIC:-}" ]; then
        local_path="''${NIX_FLEET_PUBLIC}"
      else
        local_path="$NC_DIR"
      fi
    fi

    cd "$NP_DIR"

    activate_local() {
      if [ ! -f "$local_path/flake.nix" ]; then
        echo "activate: $local_path doesn't look like a nix-config checkout (no flake.nix)" >&2
        exit 1
      fi
      local_rev="$(git -C "$local_path" rev-parse HEAD)"
      local_branch="$(git -C "$local_path" rev-parse --abbrev-ref HEAD)"
      echo "activate: LOCAL $local_path ($local_branch @ ''${local_rev:0:12}) for this run only (flake.lock untouched)" >&2
      do_switch --override-input nix-config "path:$local_path"
      exit 0
    }

    locked_rev="$(jq -r '.nodes["nix-config"].locked.rev' flake.lock)"

    target_rev=""
    source_desc=""
    network_unreachable=0

    if [ -n "$local_path" ]; then
      if [ ! -f "$local_path/flake.nix" ]; then
        echo "activate: $local_path doesn't look like a nix-config checkout (no flake.nix)" >&2
        exit 1
      fi
      target_rev="$(git -C "$local_path" rev-parse HEAD)"
      source_desc="LOCAL ($local_path)"
    else
      source_desc="REMOTE ($REMOTE_URL)"
      if ! target_rev="$(git ls-remote --exit-code "$REMOTE_URL" "refs/heads/$REMOTE_BRANCH" 2>/dev/null | cut -f1)"; then
        network_unreachable=1
        echo "activate: could not reach $REMOTE_URL to check freshness (offline?) -- proceeding with locked rev ''${locked_rev:0:12}" >&2
      fi
    fi

    need_catchup=0
    if [ "$network_unreachable" -eq 0 ] && [ -n "$target_rev" ] && [ "$locked_rev" != "$target_rev" ]; then
      need_catchup=1
    fi

    if [ "$need_catchup" -eq 1 ] && [ "$catchup_count" -eq 0 ]; then
      echo "activate: the private flake's locked nix-config (''${locked_rev:0:12}) is behind $source_desc (''${target_rev:0:12})." >&2
      echo "activate: re-run with --hard or --yolo to catch up, or --soft to activate the older locked revision anyway." >&2
      exit 1
    fi

    do_switch() {
      # nh, but ONLY on a terminal. It adds nom's live dependency tree while
      # building, a dix closure diff after ("PATHS 999 -> 999, DIFF 0 bytes"),
      # and since 4.3.0 it hides the ~50 activation lines that neither
      # home-manager nor nix-darwin exposes a quiet option for.
      #
      # The tty gate is not caution, it is a measurement: nh's own progress
      # ticker repaints ~15x/second and has NO off switch -- NH_NOM=0 and
      # NO_COLOR=1 were each measured to change nothing (42 escapes either
      # way) -- and it does not self-disable on a pipe. In a terminal that is
      # the feature; under a pipe (CI, a script, an agent's shell) it is worse
      # than plain darwin-rebuild, so those callers keep the path below
      # unchanged.
      #
      # Verified 2026-09-06 with --show-activation-logs: nh runs the FULL
      # home-manager activation (25 `Activating <x>` lines), so the
      # HOME=/var/root workaround below is not needed on nh's path.
      # ACTIVATE_NO_NH=1 forces the darwin-rebuild path for one run. nh is the
      # DEFAULT on a terminal and stays that way; this exists only because
      # `activate` is the single route to a switch, so an nh bug upstream would
      # otherwise leave no way through without rebuilding the CLI itself.
      if [ -z "''${ACTIVATE_NO_NH:-}" ] &&
        [ -t 1 ] && [ -t 2 ] && command -v nh >/dev/null 2>&1; then
        if [ "$#" -gt 0 ]; then
          # --override-input etc. go to `nix build` via nh's `--` passthrough.
          exec nh darwin switch "$NP_DIR" --hostname "$HOSTNAME" -- "$@"
        fi
        exec nh darwin switch "$NP_DIR" --hostname "$HOSTNAME"
      fi

      # Force root HOME under sudo: macOS sudo keeps HOME=/Users/<you> while
      # uid=0, which makes home-manager skip the user profile.
      rebuild="$(nix build ".#darwinConfigurations.$HOSTNAME.config.system.build.darwin-rebuild" --no-link --print-out-paths)/bin/darwin-rebuild"
      exec /usr/bin/sudo /usr/bin/env HOME=/var/root USER=root LOGNAME=root \
        "$rebuild" switch --flake ".#$HOSTNAME" "$@"
    }

    if [ "$local_mode" -eq 1 ]; then
      activate_local
    fi

    if [ "$need_catchup" -eq 1 ] && { [ "$hard" -eq 1 ] || [ "$yolo" -eq 1 ]; }; then
      if [ -n "$local_path" ]; then
        echo "activate: activating with LOCAL $local_path for this run only (flake.lock untouched)" >&2
        do_switch --override-input nix-config "path:$local_path"
        exit 0
      else
        echo "activate: bumping nix-config to ''${target_rev:0:12} and committing..." >&2
        nix flake lock --update-input nix-config
        git add flake.lock
        git commit -m "nix-config: bump to ''${target_rev:0:12}"
        if [ "$yolo" -eq 1 ]; then
          echo "activate: pushing the bump commit (--yolo)..." >&2
          git push
        fi
      fi
    fi

    if [ "$need_catchup" -eq 1 ] && [ "$soft" -eq 1 ]; then
      echo "activate: proceeding with locked nix-config ''${locked_rev:0:12}, behind $source_desc (--soft)" >&2
    fi

    do_switch
  '';
}
