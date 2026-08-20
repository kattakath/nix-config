# fix-google-video — detect and re-encode video files with editor-incompatible
# codecs (most commonly VP9-in-MP4, the "space saver" flavor Google Photos'
# download button serves for videos not backed up at Original quality) into
# H.264 + AAC, so they import cleanly into CapCut/Premiere/Final Cut/etc.
#
# Root cause: Apple's AVFoundation (which QuickTime, Photos, and the Finder's
# built-in "Encode Selected Video Files" quick action all sit on top of) has
# never shipped a VP9 decoder, so that quick action fails silently on these
# files — it can't even read the video stream to re-encode it. Google Photos
# doesn't let you choose the download codec; the only real prevention is
# backing up FUTURE videos at "Original quality" in the Photos app (Storage
# Saver / old "High quality" tier videos get transcoded server-side at
# ingest, and what you download later is that transcode, not the original).
#
#   fix-google-video <file>...   # idempotent — skips already-editor-safe files
#
# Auto-detects VideoToolbox (Apple Silicon/Intel hardware H.264 encoder,
# ~7x realtime) and falls back to libx264 software encode (CRF 18) if it's
# unavailable in this ffmpeg build. Output is written alongside the input as
# <name>_h264.mp4; the original is never modified or deleted.
{
  writeShellApplication,
  ffmpeg,
  gnugrep,
  coreutils,
}:
writeShellApplication {
  name = "fix-google-video";
  runtimeInputs = [
    ffmpeg
    gnugrep
    coreutils
  ];
  text = ''
    prog=fix-google-video
    die() { echo "$prog: error: $*" >&2; exit 1; }
    info() { echo "$prog: $*" >&2; }

    [ $# -ge 1 ] || die "usage: $prog <video-file>..."

    # Codecs mainstream editors (CapCut, Premiere, Final Cut, Resolve) import
    # without a second thought. Anything else (VP9, AV1, etc.) gets re-encoded.
    VIDEO_OK="h264|hevc|prores|mpeg4|mjpeg"
    AUDIO_OK="aac|ac3|alac|mp3|pcm_s16le|pcm_s24le"

    has_videotoolbox() {
      ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "h264_videotoolbox"
    }

    for f in "$@"; do
      [ -f "$f" ] || { info "skip: '$f' not found"; continue; }

      vcodec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$f" 2>/dev/null || true)
      acodec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$f" 2>/dev/null || true)

      if [ -z "$vcodec" ]; then
        info "skip: '$f' — no readable video stream"
        continue
      fi

      need_video=1
      echo "$vcodec" | grep -qE "^($VIDEO_OK)$" && need_video=0

      need_audio=0
      if [ -n "$acodec" ] && ! echo "$acodec" | grep -qE "^($AUDIO_OK)$"; then
        need_audio=1
      fi

      if [ "$need_video" -eq 0 ] && [ "$need_audio" -eq 0 ]; then
        info "OK: '$f' already editor-safe (video=$vcodec''${acodec:+, audio=$acodec})"
        continue
      fi

      out="''${f%.*}_h264.mp4"
      if [ -e "$out" ]; then
        info "skip: '$out' already exists"
        continue
      fi

      vargs=(-c:v copy)
      if [ "$need_video" -eq 1 ]; then
        if has_videotoolbox; then
          vargs=(-c:v h264_videotoolbox -b:v 8M -pix_fmt yuv420p)
        else
          vargs=(-c:v libx264 -pix_fmt yuv420p -crf 18 -preset medium)
        fi
      fi
      aargs=(-c:a copy)
      [ "$need_audio" -eq 1 ] && aargs=(-c:a aac -b:a 192k)

      info "re-encoding '$f' (video=$vcodec, audio=''${acodec:-none}) -> '$out'"
      ffmpeg -y -i "$f" "''${vargs[@]}" "''${aargs[@]}" -movflags +faststart "$out" \
        || die "ffmpeg failed on '$f'"
      info "done: '$out'"
    done
  '';
}
