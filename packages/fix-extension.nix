# fix-extension — rename files whose EXTENSION lies about their CONTENT.
#
#   fix-extension [--dry-run] [--only image|video|audio] [--print0] <file-or-dir>...
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
# `--only` and `--print0` exist for ONE caller, fix-media, and are what let it
# compose this with a repair step instead of reimplementing the sniffing:
#
#   --only  restricts the run to one media class, so "fix the videos in this
#           folder" does not quietly rename the photos next to them. A file
#           matches on its SNIFFED class or its EXTENSION's class, not just the
#           first — otherwise a `.mp4` whose type `file` cannot place would
#           drop out of a video run before anything could look at it.
#   --print0  writes the RESULTING path of every file considered to stdout,
#           NUL-separated, so the next stage receives the new name after a
#           rename. Diagnostics stay on stderr, so the two never mix.
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
    usage="usage: $prog [--dry-run] [--only image|video|audio] [--print0] <file-or-directory>..."
    die() { echo "$prog: error: $*" >&2; exit 1; }
    info() { echo "$prog: $*" >&2; }

    dry=0
    print0=0
    only=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --dry-run|-n) dry=1; shift ;;
        --print0)     print0=1; shift ;;
        --only)
          [ $# -ge 2 ] || die "--only needs a class (image, video or audio)"
          case "$2" in
            image|video|audio) only=$2 ;;
            *) die "unknown class '$2' (image, video or audio)" ;;
          esac
          shift 2 ;;
        --help|-h)
          echo "$usage" >&2
          echo "  renames files whose extension disagrees with their content" >&2
          echo "  (e.g. a JPEG named .png, which Finder cannot thumbnail)" >&2
          echo "  the bytes are never touched; directories are walked recursively" >&2
          exit 0 ;;
        --) shift; break ;;
        -*) die "unknown option '$1' (try --help)" ;;
        *) break ;;
      esac
    done

    [ $# -ge 1 ] || die "$usage"

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

    # The two halves of --only. A file matches on either, so a video whose type
    # `file` cannot place still counts as a video when it is named like one.
    class_of_mime() {
      case "$1" in
        image/*) echo image ;;
        video/*) echo video ;;
        audio/*) echo audio ;;
        *) return 1 ;;
      esac
    }
    class_of_ext() {
      case "$1" in
        jpg|jpeg|jpe|jfif|png|gif|webp|heic|heif|tiff|tif|bmp|svg|psd|ico) echo image ;;
        mp4|m4v|mov|qt|mkv|webm|avi|mpg|mpeg)                             echo video ;;
        mp3|m4a|wav|flac|ogg|oga)                                         echo audio ;;
        *) return 1 ;;
      esac
    }

    # Where the pipeline learns what a file is called NOW. Every path that
    # survived the class filter is reported, renamed or not, so the next stage
    # sees the whole selection rather than only what changed.
    emit() {
      [ "$print0" -eq 1 ] && printf '%s\0' "$1"
      return 0
    }

    # $1 = path, $2 = 1 when the path was named on the command line (so a skip
    # is worth reporting) and 0 when it came out of a directory walk.
    fix_one() {
      local f=$1 explicit=$2 base ext mime accepted canon target mclass eclass
      local -a accepted_arr

      if [ ! -f "$f" ]; then
        [ "$explicit" -eq 1 ] && info "skip: '$f' — not found"
        return 0
      fi

      mime=$(file -b --mime-type "$f" 2>/dev/null || true)

      base=$(basename "$f")
      case "$base" in
        *.*) ext=$(printf '%s' "''${base##*.}" | tr '[:upper:]' '[:lower:]') ;;
        *)   ext="" ;;
      esac

      if [ -n "$only" ]; then
        mclass=$(class_of_mime "$mime" || true)
        eclass=$(class_of_ext "$ext" || true)
        if [ "$only" != "$mclass" ] && [ "$only" != "$eclass" ]; then
          [ "$explicit" -eq 1 ] && info "skip: '$f' — not a(n) $only file"
          return 0
        fi
      fi

      if ! accepted=$(exts_for "$mime"); then
        [ "$explicit" -eq 1 ] && info "skip: '$f' — unrecognised type (''${mime:-unknown})"
        emit "$f"
        return 0
      fi

      read -ra accepted_arr <<< "$accepted"
      for a in "''${accepted_arr[@]}"; do
        if [ "$ext" = "$a" ]; then
          [ "$explicit" -eq 1 ] && info "OK: '$f' — extension already matches ($mime)"
          emit "$f"
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
        emit "$f"
        return 0
      fi

      if [ "$dry" -eq 1 ]; then
        info "would rename: '$f' -> '$(basename "$target")' (''${ext:-no extension} but $mime)"
        emit "$f"
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
        emit "$f"
        return 0
      fi
      info "done: '$target' (was .''${ext:-none}, actually $mime)"
      emit "$target"
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
