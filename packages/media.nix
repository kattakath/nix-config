# media — one name for the media CLIs, and one `--help` that lists them.
#
#   media describe [...]   write what an image IS into the image
#   media fix [...]        repair a media file by class
#   media audio [...]      pull the audio track out of a video
#
# WHY THIS EXISTS: discoverability, not ergonomics. The five media CLIs are
# individually well-named, but nothing tells an operator they are related, or
# that `photo-describe` exists at all — `media <TAB>` and `media --help` do.
# Typing `media describe` is LONGER than `photo-describe`, so if this were about
# saving keystrokes it would be a net loss.
#
# IT IS PURELY ADDITIVE. Every underlying binary stays on PATH under its own
# name, because three consumers already hardcode those names and must keep
# working: the Finder Services bake absolute /nix/store paths into their
# document.wflow, `nix run .#photo-describe` names the app, and the operator's
# own notes are written in the direct form. A dispatcher that REPLACED them
# would be a breaking change bought for a shorter help listing.
#
# WHAT IS DELIBERATELY NOT A VERB, and why each one would break if it were:
#
#   media-worker      launchd-only, takes no arguments, and its arg0 must stay
#                     `nix-media-queue` — per .claude/rules/launchd-naming.md a
#                     /nix/store arg0 is what grants it TCC access to the very
#                     folders it exists to read (~/Pictures, ~/Downloads).
#                     Behind a dispatcher the arg0 becomes `media`, and it
#                     silently loses that access: it would run, log nothing
#                     useful, and quietly do no work.
#   media-enqueue     the Finder Services call it by absolute store path.
#   fix-extension     `--only`/`--print0` are a COMPOSITION seam for fix-media
#                     and photo-describe, not a user feature. Promoting it
#                     invites hand use of a flag pair that exists so two other
#                     CLIs can pipeline through it.
#   fix-google-video  `fix-media --video` is the discoverable name for it; the
#                     menu deliberately names the media CLASS, not the defect.
#
# `exec` rather than a wrapper function: the verb's own exit status, stdout and
# stderr must reach the caller untouched, because media-queue's worker parses
# that grammar and counts `done:` lines from it.
{
  writeShellApplication,
  callPackage,
  fix-media ? callPackage ./fix-media.nix { },
  extract-audio ? callPackage ./extract-audio.nix { },
  photo-describe ? callPackage ./photo-describe.nix { },
}:
writeShellApplication {
  name = "media";
  runtimeInputs = [
    fix-media
    extract-audio
    photo-describe
  ];
  text = ''
    usage() {
      cat >&2 <<'EOF'
    usage: media <command> [args...]

      describe  <file-or-dir>...            write what an image IS into the image:
                                            Apple Vision labels + rating, and a
                                            caption from a local vision model, as
                                            XMP that Spotlight indexes
      fix       <--video|--image> <path>... repair a media file by class — fixes a
                                            lying extension, re-encodes an
                                            editor-hostile codec
      audio     [--mp3|--wav|--flac] <file> pull the audio track out of a video

    Each command takes --help of its own. The underlying CLIs remain on PATH
    under their own names (photo-describe, fix-media, extract-audio).
    EOF
    }

    case "''${1:-}" in
      describe) shift; exec photo-describe "$@" ;;
      fix)      shift; exec fix-media "$@" ;;
      audio)    shift; exec extract-audio "$@" ;;
      -h|--help|help|"") usage; [ $# -eq 0 ] && exit 1; exit 0 ;;
      *) echo "media: error: unknown command '$1'" >&2; usage; exit 1 ;;
    esac
  '';
  meta = {
    description = "One entry point for the media CLIs: media describe / fix / audio";
    mainProgram = "media";
  };
}
