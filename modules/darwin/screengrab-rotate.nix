# nix-darwin user LaunchAgent: rotate ~/Pictures/Screengrab.
# Moves any top-level file older than 24h into ~/.Trash (recoverable),
# checked hourly. Declarative replacement for a hand-maintained plist.
{ pkgs, username, ... }:

let
  home = "/Users/${username}";

  # writeShellApplication yields a store binary literally named
  # "screengrab-rotate" — that basename is what macOS Background Activity
  # and `launchctl list` display, which is the identifiable name we want.
  # Pure: relocates into ~/.Trash with `mv` (no /usr/bin/trash dependency).
  rotate = pkgs.writeShellApplication {
    name = "screengrab-rotate";
    runtimeInputs = [
      pkgs.findutils
      pkgs.coreutils
    ];
    text = ''
      target="${home}/Pictures/Screengrab"
      trash="${home}/.Trash"
      [ -d "$target" ] || exit 0
      mkdir -p "$trash"

      # Top-level files older than 24h (1440 min), excluding .DS_Store.
      while IFS= read -r -d "" f; do
        base="$(basename "$f")"
        dest="$trash/$base"
        # Avoid clobbering an existing trashed file of the same name.
        if [ -e "$dest" ]; then
          dest="$trash/$base.$(date '+%Y%m%d%H%M%S')"
        fi
        mv "$f" "$dest"
      done < <(find "$target" -maxdepth 1 -type f ! -name '.DS_Store' -mmin +1440 -print0)
    '';
  };
in
{
  # Quoted attr name → "ai.aloshy.screengrab-rotate.plist" with that Label,
  # preserving the reverse-DNS namespace (matches ai.aloshy.nats-server etc).
  launchd.user.agents."ai.aloshy.screengrab-rotate" = {
    serviceConfig = {
      ProgramArguments = [ "${rotate}/bin/screengrab-rotate" ];
      StartInterval = 3600; # hourly
      RunAtLoad = true;
      # Errors-only logging: capture failures, no per-file success log.
      StandardErrorPath = "${home}/Library/Logs/screengrab-rotate.err.log";
    };
  };
}
