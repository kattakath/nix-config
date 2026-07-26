# `obs-fb-setup` (macOS only) — write an OBS "Facebook" profile configured to stream to
# Facebook Live, with the stream key injected FROM THE LOGIN KEYCHAIN at run time
# (`FB_PERSISTENT_STREAM_KEY`, set via `secret set`). The key is NEVER in git or the Nix
# store — this script reads it live from the Keychain (same source-of-truth pattern as the
# context7 / cloudflared passwordCommand wrappers) and writes it into OBS's own
# service.json (OBS stores stream keys in plaintext there regardless — that file is local,
# not committed). Re-run it any time the key rotates or the profile is reset.
#
#   obs-fb-setup            # or: nix run .#obs-fb-setup
#   → in OBS: Profile menu ▸ "Facebook", then Start Streaming.
{
  writeShellApplication,
  jq,
  coreutils,
}:
writeShellApplication {
  name = "obs-fb-setup";
  runtimeInputs = [
    jq
    coreutils
  ];
  text = ''
    prog=obs-fb-setup
    secret_name="FB_PERSISTENT_STREAM_KEY"
    profile="Facebook"
    server="rtmps://rtmp-api.facebook.com:443/rtmp/"
    obs_dir="$HOME/Library/Application Support/obs-studio"
    prof_dir="$obs_dir/basic/profiles/$profile"

    die() { echo "$prog: error: $*" >&2; exit 1; }

    [ -d "$obs_dir" ] || die "OBS config dir not found — launch OBS once first ($obs_dir)"

    # Read the persistent stream key live from the login Keychain (never in git/store).
    key="$(/usr/bin/security find-generic-password -a "$(id -un)" -s "$secret_name" -w 2>/dev/null || true)"
    [ -n "$key" ] || die "$secret_name is not in the Keychain — set it with: secret set $secret_name"

    # OBS rewrites profile files when it exits — warn so this write is not clobbered.
    if pgrep -x OBS >/dev/null 2>&1; then
      echo "$prog: WARNING: OBS is running. Quit it first (it overwrites profile files on exit), then re-run." >&2
    fi

    mkdir -p "$prof_dir"
    # basic.ini registers the profile NAME in the OBS UI (minimal is enough; OBS fills defaults).
    [ -f "$prof_dir/basic.ini" ] || printf '[General]\nName=%s\n' "$profile" > "$prof_dir/basic.ini"

    # service.json — Facebook Live via rtmp_common. The key is passed through the ENV to jq
    # ($ENV.<name>), never on the jq argv, and never echoed.
    umask 077
    FB_KEY="$key" jq -n --arg server "$server" '
      { type: "rtmp_common",
        settings: { service: "Facebook Live", server: $server, key: $ENV.FB_KEY, protocol: "RTMPS" } }
    ' > "$prof_dir/service.json" || die "failed to write $prof_dir/service.json"

    echo "$prog: wrote OBS profile \"$profile\" — Facebook Live, key from the Keychain."
    echo "$prog: in OBS choose Profile ▸ \"$profile\", then Start Streaming (restart OBS if it was open)."
  '';
}
