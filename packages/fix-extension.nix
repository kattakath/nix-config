# fix-extension — rename files whose EXTENSION lies about their CONTENT.
#
#   fix-extension <file-or-dir>...           # rename in place, bytes untouched
#   fix-extension --dry-run <file-or-dir>...  # report only
#
# Why this exists: Finder's thumbnail generator trusts the extension → UTI, so
# a JPEG named `.png` is handed to the PNG decoder, which rejects it, and the
# file falls back to a generic icon. Preview and Quick Look's full view sniff
# the magic bytes instead and open it fine — which is what makes the symptom so
# confusing: the file is clearly readable, yet Finder shows no thumbnail.
# Measured on a Google Photos/Picasa export: 10 of 15 `.png` files were JPEG,
# and exactly those 10 had no thumbnail.
#
# The fix is a RENAME, never a re-encode. The bytes are already a valid image;
# converting them would add a second lossy generation and gain nothing.
#
# Two guards keep this from being destructive:
#
#   - An extension is only rewritten when the sniffed type is in the table
#     below AND the current extension is not already an accepted spelling of
#     that type. Unknown types are left alone rather than guessed at, and
#     `.jpeg`/`.tif`/`.m4v` are not "corrected" to their canonical sibling.
#   - `video/quicktime` accepts `.mp4` too: some MP4s sniff as QuickTime, and
#     renaming a working `.mp4` to `.mov` would be a regression, not a fix.
#
# A directory argument is walked recursively, and files with no recognisable
# type are then passed over silently — a photo folder is full of them and one
# line each would bury the actual findings. Named explicitly, the same file
# reports why it was skipped.
#
# Output grammar (`done:` / `skip:` / `OK:` / `error:`) is shared with the other
# media-toolkit CLIs so the Finder Service wrapper can summarise it into a
# notification. See packages/media-quick-actions.nix.
{
  writeShellApplication,
  file,
  coreutils,
  findutils,
}:
writeShellApplication {
  name = "fix-extension";
  runtimeInputs = [
    file
    coreutils
    findutils
  ];
  text = ''
    prog=fix-extension
    die() { echo "$prog: error: $*" >&2; exit 1; }
    info() { echo "$prog: $*" >&2; }

    dry=0
    case "''${1:-}" in
      --dry-run|-n) dry=1; shift ;;
      --help|-h)
        echo "usage: $prog [--dry-run] <file-or-directory>..." >&2
        echo "  renames files whose extension disagrees with their content" >&2
        echo "  (e.g. a JPEG named .png, which Finder cannot thumbnail)" >&2
        echo "  the bytes are never touched; directories are walked recursively" >&2
        exit 0 ;;
      -*) die "unknown option '$1' (try --help)" ;;
    esac

    [ $# -ge 1 ] || die "usage: $prog [--dry-run] <file-or-directory>..."

    failed=0

    # mime-type -> accepted extensions, CANONICAL FIRST. A file is renamed only
    # when its current extension is absent from its type's list, so the aliases
    # here are what stops `.jpeg` and `.m4v` being churned into `.jpg`/`.mp4`.
    exts_for() {
      case "$1" in
        image/jpeg)                  echo "jpg jpeg jpe jfif" ;;
        image/png)                   echo "png" ;;
        image/gif)                   echo "gif" ;;
        image/webp)                  echo "webp" ;;
        image/heic|image/heif)       echo "heic heif" ;;
        image/tiff)                  echo "tiff tif" ;;
        image/bmp|image/x-ms-bmp)    echo "bmp" ;;
        image/svg+xml)               echo "svg" ;;
        image/vnd.adobe.photoshop)   echo "psd" ;;
        image/x-icon)                echo "ico" ;;
        video/mp4)                   echo "mp4 m4v" ;;
        # .mp4 stays accepted: some MP4s sniff as QuickTime, and renaming a
        # working .mp4 to .mov would break it for no gain.
        video/quicktime)             echo "mov qt mp4" ;;
        video/x-matroska)            echo "mkv" ;;
        video/webm)                  echo "webm" ;;
        video/x-msvideo)             echo "avi" ;;
        video/mpeg)                  echo "mpg mpeg" ;;
        audio/mpeg)                  echo "mp3" ;;
        audio/mp4|audio/x-m4a)       echo "m4a mp4" ;;
        audio/wav|audio/x-wav)       echo "wav" ;;
        audio/flac|audio/x-flac)     echo "flac" ;;
        audio/ogg|application/ogg)   echo "ogg oga" ;;
        application/pdf)             echo "pdf" ;;
        *) return 1 ;;
      esac
    }

    # $1 = path, $2 = 1 when the path was named on the command line (so a skip
    # is worth reporting) and 0 when it came out of a directory walk.
    fix_one() {
      local f=$1 explicit=$2 base ext mime accepted canon target
      local -a accepted_arr

      if [ ! -f "$f" ]; then
        [ "$explicit" -eq 1 ] && info "skip: '$f' — not found"
        return 0
      fi

      mime=$(file -b --mime-type "$f" 2>/dev/null || true)
      if ! accepted=$(exts_for "$mime"); then
        [ "$explicit" -eq 1 ] && info "skip: '$f' — unrecognised type (''${mime:-unknown})"
        return 0
      fi

      base=$(basename "$f")
      case "$base" in
        *.*) ext=$(printf '%s' "''${base##*.}" | tr '[:upper:]' '[:lower:]') ;;
        *)   ext="" ;;
      esac

      read -ra accepted_arr <<< "$accepted"
      for a in "''${accepted_arr[@]}"; do
        if [ "$ext" = "$a" ]; then
          [ "$explicit" -eq 1 ] && info "OK: '$f' — extension already matches ($mime)"
          return 0
        fi
      done

      canon=''${accepted%% *}
      if [ -n "$ext" ]; then
        target="''${f%.*}.$canon"
      else
        target="$f.$canon"
      fi

      # -ef, not a string compare: on a case-insensitive volume `IMG.JPG` and
      # `IMG.jpg` are the same file, and `mv` there is a legitimate case fix.
      if [ -e "$target" ] && ! [ "$target" -ef "$f" ]; then
        info "skip: '$f' — '$(basename "$target")' already exists"
        return 0
      fi

      if [ "$dry" -eq 1 ]; then
        info "would rename: '$f' -> '$(basename "$target")' (''${ext:-no extension} but $mime)"
        return 0
      fi

      # A rename preserves the bytes, xattrs and both timestamps, so there is
      # nothing here to verify or roll back.
      if ! mv "$f" "$target"; then
        # Reported, not fatal: one unwritable file must not abandon the rest of
        # a folder. `failed` makes the run exit non-zero anyway, which is what
        # tells the Finder Service wrapper to show the error rather than
        # "nothing to do".
        info "error: could not rename '$f'"
        failed=1
        return 0
      fi
      info "done: '$target' (was .''${ext:-none}, actually $mime)"
    }

    for arg in "$@"; do
      if [ -d "$arg" ]; then
        while IFS= read -r -d "" f; do
          fix_one "$f" 0
        done < <(find "$arg" -type f -print0)
      else
        fix_one "$arg" 1
      fi
    done

    [ "$failed" -eq 0 ] || exit 1
  '';
}
