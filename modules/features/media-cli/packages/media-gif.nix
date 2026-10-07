# media-gif — turn a short video into a looping GIF, optionally one that FITS A
# BYTE BUDGET, for the places GIFs still have to be GIFs (Tenor, GIPHY, Slack,
# a README).
#
#   media-gif <video>                          # <name>.gif beside it: ≤480px wide, 15 fps, loops forever
#   media-gif --budget 1M <video>              # best quality that lands UNDER 1,000,000 bytes
#   media-gif --square --width 256 <video>     # centre-crop to a square, then 256x256
#   media-gif --max-seconds 5 <video>          # speed the clip up until it runs ≤5 s
#   media-gif -o out.gif --budget 8M --max-seconds 6 <video>   # GIPHY's published spec
#
# Prints the output path on stdout (so a caller can capture it) and the
# measurements on stderr. Refuses to overwrite an existing output without --force.
#
# WHY A LADDER AND NOT A FORMULA. GIF has no rate control — there is no `-crf`
# — so "fit under N bytes" can only be answered by encoding and measuring. The
# ladder below is ORDERED by what each step costs in quality per byte it saves,
# and that order is measured, not guessed. On a 6 s 624x480 cartoon clip (one
# subject on a starfield), 2026-10-07:
#
#   - Bayer dither was the inflator: it adds per-frame noise LZW cannot fold.
#     Dropping it saved ~10% (1.59 MB -> 1.45 MB at 400 px).
#   - gifsicle --lossy=100 saved a further 34% (1.45 MB -> 0.96 MB); -O3 alone ~6%.
#   - A 256x256 centre crop of the same clip was BIGGER than its 400x308 letterbox
#     (1.14 MB vs 0.96 MB raw). The cropped-off strips were flat background, almost
#     free in LZW; the crop kept only the expensive part. Fewer pixels ≠ fewer bytes,
#     so resolution is the LAST lever here, not the first.
#   - 15 fps / 256 colours at 256 px was 1.74 MB; the 1 MB budget was met at
#     12 fps / 128 colours / lossy 60 — fps and palette before pixels.
#
# Two ffmpeg passes always: palettegen (stats_mode=diff) + paletteuse. A
# single-pass `-f gif` uses the generic 256-colour palette and bands visibly; the
# split/palettegen/paletteuse graph is ffmpeg's own documented high-quality path.
#
# `-loop 0` writes the NETSCAPE2.0 application extension with a loop count of 0
# (= forever). The script then VERIFIES those bytes in the output rather than
# trusting the flag — a GIF that plays once in a chat window is the failure this
# tool exists to prevent.
#
# `--max-seconds` speeds the clip up (setpts), it does not trim: a meme's beat is
# the whole clip. The target is 97% of the limit because GIF frame delays are
# 10 ms quanta, and a 4.80 s request measured 4.83 s on output.
#
# Budgets are DECIMAL (1M = 1,000,000) because every upload form quotes its limit
# that way; `1Mi` is the binary mebibyte if you need it.
{
  writeShellApplication,
  ffmpeg,
  gifsicle,
  coreutils,
  gawk,
  gnugrep,
}:
writeShellApplication {
  name = "media-gif";
  runtimeInputs = [
    ffmpeg
    gifsicle
    coreutils
    gawk
    gnugrep
  ];
  text = ''
    prog=media-gif
    die() { echo "$prog: error: $*" >&2; exit 1; }
    info() { echo "$prog: $*" >&2; }
    usage() {
      cat <<'EOF'
    usage: media-gif [options] <video>

    Turn a short video into a looping GIF. Prints the output path.

      -o, --output <file>    where to write (default: <video-name>.gif, or
                             <video-name>-square.gif with --square)
      --budget <size>        fit under this many bytes: 950K, 1M, 8M, 1Mi (decimal
                             unless Ki/Mi). Walks a quality ladder until one fits.
      --max-seconds <n>      speed the clip up until it runs no longer than n seconds
      --square               centre-crop to a square before scaling
      --width <px>           output width (default: source width, capped at 480;
                             with --budget this is the ladder's starting width)
      --fps <n>              frame rate (default 15; pins the ladder's fps)
      --colors <n>           palette size 2..256 (default 256; pins the ladder's palette)
      --lossy-max <n>        hardest gifsicle --lossy level the ladder may use (default 100;
                             150 visibly speckles flat areas, 0 = lossless -O3 only)
      --force                overwrite an existing output
      -h, --help             this text
    EOF
    }

    # ---- arguments ---------------------------------------------------------
    out=""; budget=""; max_seconds=""; square=0; width=""; fps=""; colors=""
    lossy_max=100; force=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -o|--output)    [ $# -ge 2 ] || die "$1 needs a value"; out=$2; shift 2 ;;
        --budget)       [ $# -ge 2 ] || die "$1 needs a value"; budget=$2; shift 2 ;;
        --max-seconds)  [ $# -ge 2 ] || die "$1 needs a value"; max_seconds=$2; shift 2 ;;
        --width)        [ $# -ge 2 ] || die "$1 needs a value"; width=$2; shift 2 ;;
        --fps)          [ $# -ge 2 ] || die "$1 needs a value"; fps=$2; shift 2 ;;
        --colors)       [ $# -ge 2 ] || die "$1 needs a value"; colors=$2; shift 2 ;;
        --square)       square=1; shift ;;
        --lossy-max)    [ $# -ge 2 ] || die "$1 needs a value"; lossy_max=$2; shift 2 ;;
        --force)        force=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        --)             shift; break ;;
        -*)             die "unknown option: $1 (try --help)" ;;
        *)              break ;;
      esac
    done
    [ $# -eq 1 ] || { usage >&2; exit 2; }
    in=$1
    [ -f "$in" ] || die "no such file: $in"
    for v in "$width" "$fps" "$colors" "$lossy_max"; do
      [ -z "$v" ] || [[ "$v" =~ ^[0-9]+$ ]] || die "expected a whole number, got: $v"
    done
    if [ -n "$colors" ] && { [ "$colors" -lt 2 ] || [ "$colors" -gt 256 ]; }; then
      die "--colors must be 2..256"
    fi

    # Decimal by default (1M = 1,000,000), binary with an i (1Mi = 1,048,576).
    parse_bytes() {
      local s=$1 n unit
      n=''${s%%[^0-9.]*}; unit=''${s#"$n"}
      [ -n "$n" ] || die "bad size: $s"
      case "$unit" in
        ""|B)    awk -v n="$n" 'BEGIN { printf "%d", n }' ;;
        K|KB)    awk -v n="$n" 'BEGIN { printf "%d", n * 1000 }' ;;
        M|MB)    awk -v n="$n" 'BEGIN { printf "%d", n * 1000000 }' ;;
        G|GB)    awk -v n="$n" 'BEGIN { printf "%d", n * 1000000000 }' ;;
        Ki|KiB)  awk -v n="$n" 'BEGIN { printf "%d", n * 1024 }' ;;
        Mi|MiB)  awk -v n="$n" 'BEGIN { printf "%d", n * 1048576 }' ;;
        *)       die "bad size unit in '$s' (use K, M, G, Ki or Mi)" ;;
      esac
    }

    # ---- probe -------------------------------------------------------------
    probe=$(ffprobe -v error -select_streams v:0 \
      -show_entries stream=width,height:format=duration -of default=nw=1 "$in") \
      || die "ffprobe could not read $in"
    src_w=$(printf '%s\n' "$probe" | awk -F= '$1 == "width"    { print $2 }')
    src_h=$(printf '%s\n' "$probe" | awk -F= '$1 == "height"   { print $2 }')
    src_dur=$(printf '%s\n' "$probe" | awk -F= '$1 == "duration" { print $2 }')
    [[ "$src_w" =~ ^[0-9]+$ ]] && [[ "$src_h" =~ ^[0-9]+$ ]] || die "no video stream in $in"
    [[ "$src_dur" =~ ^[0-9.]+$ ]] || die "could not read the duration of $in"

    # ---- speed (setpts), crop, base width ----------------------------------
    speed=1
    if [ -n "$max_seconds" ] && awk -v d="$src_dur" -v m="$max_seconds" 'BEGIN { exit !(d > m) }'; then
      # 97% of the limit: GIF delays are 10 ms quanta and round UP on output.
      speed=$(awk -v d="$src_dur" -v m="$max_seconds" 'BEGIN { printf "%.6f", (m * 0.97) / d }')
      info "clip runs $src_dur s > $max_seconds s: speeding up x$(awk -v s="$speed" 'BEGIN { printf "%.2f", 1 / s }')"
    fi

    crop_filter=""
    side=$src_w; [ "$src_h" -lt "$side" ] && side=$src_h
    if [ "$square" = 1 ]; then
      crop_filter="crop=''${side}:''${side}:$(( (src_w - side) / 2 )):$(( (src_h - side) / 2 )),"
    fi

    if [ -n "$width" ]; then
      base_w=$width
    else
      base_w=$src_w; [ "$square" = 1 ] && base_w=$side
      [ "$base_w" -gt 480 ] && base_w=480
    fi

    # ---- output path -------------------------------------------------------
    if [ -z "$out" ]; then
      stem=''${in%.*}
      if [ "$square" = 1 ]; then out="$stem-square.gif"; else out="$stem.gif"; fi
    fi
    if [ -e "$out" ] && [ "$force" != 1 ]; then
      die "$out exists (pass --force to overwrite)"
    fi

    tmpdir=$(mktemp -d "''${TMPDIR:-/tmp}/media-gif.XXXXXX")
    trap 'rm -rf "$tmpdir"' EXIT INT TERM
    raw="$tmpdir/raw.gif"
    opt="$tmpdir/opt.gif"

    # encode <width> <fps> <colors> <bayer|none> — two-pass palette, infinite loop
    encode() {
      local w=$1 f=$2 c=$3 d=$4 dither scale
      case "$d" in bayer) dither="bayer:bayer_scale=5" ;; *) dither="none" ;; esac
      if [ "$square" = 1 ]; then scale="scale=''${w}:''${w}:flags=lanczos"
      else scale="scale=''${w}:-1:flags=lanczos"; fi
      ffmpeg -v error -y -i "$in" -filter_complex \
        "[0:v]setpts=''${speed}*PTS,fps=''${f},''${crop_filter}''${scale},split[a][b];[a]palettegen=max_colors=''${c}:stats_mode=diff[p];[b][p]paletteuse=dither=''${dither}:diff_mode=rectangle" \
        -loop 0 "$raw"
    }
    # optimise <lossy-level>: 0 = lossless -O3 only
    optimise() {
      if [ "$1" = 0 ]; then gifsicle -O3 "$raw" -o "$opt"
      else gifsicle -O3 --lossy="$1" "$raw" -o "$opt"; fi
      wc -c < "$opt" | tr -d ' '
    }

    chosen=""
    if [ -z "$budget" ]; then
      f=''${fps:-15}; c=''${colors:-256}
      encode "$base_w" "$f" "$c" bayer
      sz=$(optimise 0)
      chosen="''${base_w}px ''${f}fps ''${c} colours bayer lossless: $sz bytes"
    else
      bytes=$(parse_bytes "$budget")
      info "budget $budget = $bytes bytes; walking the ladder from ''${base_w}px"
      # "<percent-of-base-width> <fps> <colours> <dither>", cheapest quality loss first.
      rungs=(
        "100 15 256 bayer"
        "100 15 128 none"
        "100 12 128 none"
        "100 10 128 none"
        "83 12 128 none"
        "83 10 128 none"
        "67 10 128 none"
        "67 10 64 none"
        "50 10 64 none"
        "50 8 64 none"
      )
      smallest=""
      for rung in "''${rungs[@]}"; do
        read -r pct f c d <<< "$rung"
        w=$(( base_w * pct / 100 )); [ $(( w % 2 )) -eq 0 ] || w=$(( w - 1 ))
        f=''${fps:-$f}; c=''${colors:-$c}
        encode "$w" "$f" "$c" "$d"
        # 0 = lossless -O3. Each step is ~5% of bytes on the measured clip; 150 is
        # where flat areas start to speckle, so it is opt-in via --lossy-max.
        for level in 0 60 100 150 200; do
          [ "$level" -le "$lossy_max" ] || break
          sz=$(optimise "$level")
          info "  ''${w}px ''${f}fps ''${c}c ''${d} lossy=''${level}: $sz bytes"
          if [ -z "$smallest" ] || [ "$sz" -lt "$smallest" ]; then smallest=$sz; fi
          if [ "$sz" -le "$bytes" ]; then
            chosen="''${w}px ''${f}fps ''${c} colours ''${d} lossy=''${level}: $sz bytes"
            break 2
          fi
        done
      done
      [ -n "$chosen" ] || die "nothing fit under $budget ($bytes bytes); smallest was $smallest bytes. Lower --width, pass --max-seconds, or raise the budget."
    fi

    # ---- verify the loop, then land it -------------------------------------
    # NETSCAPE2.0, sub-block 03 01, loop count 00 00 (= forever). GNU grep -P so the
    # NUL bytes can be spelled; -a so a binary file is searched as text.
    if ! LC_ALL=C grep -a -q -P 'NETSCAPE2\.0\x03\x01\x00\x00' "$opt"; then
      die "output lacks the infinite-loop extension — refusing to write it"
    fi
    mkdir -p "$(dirname "$out")"
    mv -f "$opt" "$out"

    final=$(ffprobe -v error -select_streams v:0 \
      -show_entries stream=width,height,nb_frames:format=duration -of default=nw=1 "$out" \
      | awk -F= '{ a[$1] = $2 } END { printf "%sx%s, %s frames, %.2f s", a["width"], a["height"], a["nb_frames"], a["duration"] }')
    info "wrote $out — $final — $chosen — loops forever"
    printf '%s\n' "$out"
  '';
}
