# media-toolkit — the fleet's local media-file CLIs, as one installable unit.
#
#   fix-google-video <file>...                    re-encode editor-hostile video
#   extract-audio [--mp3|--wav|--flac] <file>...  pull out the audio track
#   fix-extension <file-or-dir>...                rename a file whose extension
#                                                 lies about its content
#   fix-media <--video|--image> <file-or-dir>...  repair a media file by CLASS,
#                                                 deciding which of the above
#                                                 it actually needs
#
# A symlinkJoin, deliberately, not a single dispatching binary: each CLI stays
# its own derivation, keeps its own `nix run .#<name>` app, and is shellchecked
# and testable on its own. This only bundles them, so `home.packages` carries
# one entry instead of drifting out of sync as CLIs are added — which already
# happened once: extract-audio shipped as a flake package but was never added
# to home.nix, so it was reachable by `nix run` and absent from PATH.
#
# Membership rule — what belongs here is a CLI that ACTS ON A MEDIA FILE the
# operator selected, on this machine. That is the line that keeps the bundle
# meaningful:
#
#   - obs-fb-setup writes an OBS config profile and reads a Keychain secret.
#     It configures an app; it never touches a media file. Stays separate.
#   - fidelity-enhance is an MCP server / referee for an agentic image loop,
#     running an ephemeral uv environment. It judges images, generating and
#     transforming nothing. Stays separate.
#
# Both are media-ADJACENT, and folding them in would make "media-toolkit" mean
# only "vaguely about media", which is not a useful thing for it to mean.
#
# fix-extension is the one member that changes no bytes — it only renames. It
# still belongs: it operates directly on the selected media file and repairs it
# for the same consumer (Finder/Photos) the other two serve, and the rule above
# exists to exclude tools that never touch a file at all, not to require a
# re-encode.
#
# fix-media is the odd one out in the other direction: it transforms nothing
# itself, it DISPATCHES to the members that do. It belongs here because it is
# the entry point the Finder Services actually call, and because splitting a
# dispatcher from the things it dispatches to is how the two drift apart.
{
  symlinkJoin,
  callPackage,
  fix-google-video ? callPackage ./fix-google-video.nix { },
  extract-audio ? callPackage ./extract-audio.nix { },
  fix-extension ? callPackage ./fix-extension.nix { },
  fix-media ? callPackage ./fix-media.nix { },
}:
symlinkJoin {
  name = "media-toolkit";
  paths = [
    fix-google-video
    extract-audio
    fix-extension
    fix-media
  ];
  meta = {
    description = "Local media-file CLIs: fix-google-video (re-encode editor-hostile video), extract-audio (pull out the audio track) fix-extension (rename files whose extension lies about their content) and fix-media (repair a media file by class)";
    mainProgram = "fix-google-video";
  };
}
