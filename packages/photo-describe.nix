# photo-describe — make a photo describe ITSELF, so you can find it later.
#
#   photo-describe [--dry-run] [--overwrite] [--no-caption]
#                  [--model NAME] [--min-score N] <file-or-dir>...
#
# Why this exists: choosing which shot to post is a RETRIEVAL problem, and a
# photo library answers no questions about itself. Finder can sort by date and
# nothing else; `IMG_7454.jpg` tells you nothing. This writes what the image is
# INTO the image, so Spotlight, Finder, Lightroom and Bridge can all answer
# "which one was the hillside shot?" without a database in between.
#
# THE DURABILITY RULE, which is the whole design: words go in the FILE, vectors
# go in an INDEX. A caption survives every model upgrade and every move between
# machines; an embedding is invalidated the day you change embedding models. So
# the expensive, irreplaceable artifact (the sentence) is embedded, and the
# cheap, regenerable one (the vector) is left to `rclip`, which keeps its own
# SQLite index and can be rebuilt from these files at any time. Nothing here
# writes a vector into a photo.
#
# What gets written, and why these tags:
#
#   XMP:Description   the sentence. VERIFIED on this Mac: Spotlight indexes it
#                     as kMDItemDescription, so `mdfind` and Finder's search
#                     bar find it. This is the one that pays for the run.
#   XMP:Subject       the labels, as keywords. Also verified: it lands in
#                     kMDItemKeywords.
#   XMP:Rating        derived from the aesthetics score, for Lightroom/Bridge.
#                     NOT indexed by Spotlight (kMDItemStarRating stays null —
#                     measured), so it is a bonus for other tools, never the
#                     reason to run this.
#   IPTC:Keywords     the legacy IIM twin of dc:subject, for the older tools
#                     and indexers that read only that one.
#
# WHAT IS DELIBERATELY *NOT* WRITTEN: XMP-iptcCore:AltTextAccessibility. An
# earlier version put this same sentence there too, and that was wrong twice
# over. IPTC 2025.1 defines Alt Text as something that "should not be confused
# with" Description/Caption — the caption is the who/what/why and may name
# people, while alt text is replacement text for assistive technology — so one
# string cannot correctly be both. More seriously, the HTML Living Standard's
# "Guidance for markup generators" (§4.8.4.4.14) tells generators to obtain alt
# text FROM THE USER and, failing that, to write nothing, precisely so that the
# error of a missing alt attribute is not replaced by "the even more egregious
# error of providing phony alternative text". Alt text is defined by an image's
# purpose IN CONTEXT; this tool sees pixels and no context, so anything it wrote
# there would be an unreviewed guess sitting in the field WCAG conformance
# depends on. Nothing reads that field today, so writing it bought nothing and
# risked exactly that. If these photos are ever published, their alt text wants
# a human.
#
# (Kept for whoever adds it back: the family is `iptcCore`, NOT `iptcExt` —
# the tags live under "new IPTC Core 1.3 properties" in exiftool's XMP.pm, and
# an `-XMP-iptcExt:AltTextAccessibility=` write silently fails.)
#
# THE WALK IS NOT REIMPLEMENTED. Stage one is `fix-extension --only image
# --print0`, whose `--print0` seam exists for exactly this kind of caller. That
# buys, for free and already tested, the recursive walk, the refusal to enter a
# macOS package (`.photoslibrary`), and the three read-before-you-read guards:
# dataless iCloud files (sniffing one materialises it, so a folder sweep would
# quietly pull gigabytes down), in-flight `.crdownload`/`.part` files, and
# `._name` AppleDouble siblings. It also RENAMES a lying extension first, which
# matters here: `auge` and `exiftool` both dispatch on the extension, so a JPEG
# named `.png` would be analysed and tagged as the wrong format. Reusing it
# means those guards can never drift out of sync between the two tools.
#
# THREE TARGETED `auge` CALLS, NEVER `--all`. Measured on this Mac (macOS
# 26.6.2, auge 1.9.0), on one 18-megapixel JPEG:
#
#   --classify      0.07s     --aesthetics  0.12s     --face-quality  0.14s
#   --all          10.4s      AND its stdout is not parseable JSON — Vision
#                             writes framework noise (`FBBA: creating
#                             VNFaceBBoxAligner…`, a missing smudgenet bundle)
#                             into the stream, so `jq` fails on it.
#
# So `--all` is ~30x slower AND unusable from a script. The three calls are
# clean JSON and total ~0.33s. Combining flags does NOT work either — `auge
# --classify --aesthetics` silently reports only the LAST mode given, so each
# analysis genuinely needs its own invocation.
#
# `is_utility` SHORT-CIRCUITS THE EXPENSIVE HALF. Apple's aesthetics pass
# returns a flag meaning "this is a screenshot/receipt/document, not a
# photograph". Those still get labels, but never a caption: the VLM call is
# three orders of magnitude more expensive than the Vision calls, and a
# generated sentence about a screenshot is worth nothing for choosing a post.
#
# THE CAPTION GOES THROUGH OLLAMA'S HTTP API, NOT `ollama run`. The CLI finds
# images by parsing file paths out of the prompt STRING, which breaks on the
# spaces that fill every real photo library ("Screenshot 2026-08-30 at 6.14.18
# AM.png"). The API takes the image as base64 in a JSON field, where a filename
# cannot be misread as prose. Ollama is a soft dependency, deliberately: with
# it absent or the model unpulled, the run still writes labels and rating and
# says so, rather than failing and leaving the library half-tagged.
#
# `temperature: 0` AND A FIXED SEED ARE LOAD-BEARING, not tuning. At Ollama's
# default sampling the same photo gets a DIFFERENT caption on every run —
# measured, twice in a row on one image:
#
#   "…hillside path, holding cameras, with trees and steps…"
#   "…hillside with stone steps, enjoying a casual outdoor adventure."
#
# That makes re-describing a library non-reproducible and quietly shifts every
# downstream embedding, so an index built from these captions can never be
# rebuilt identically. At temperature 0 with a seed, two runs are byte-identical.
# Note what else that first sample shows: the model DOES see the cameras. An
# object missing from a caption is usually the sampler, not the model's sight.
#
# THE PROMPT ASKS FOR NOUNS, NOT MOOD, for the same retrieval reason. "Conveying
# casual, friendly camaraderie" spends a third of a 25-word budget on words
# nothing will ever search for. Measured against the older mood-first wording on
# the same three photos, the noun-first prompt recovered a camera, a wristwatch
# and a wall dispenser that the mood-first one had dropped — and lost nothing.
#
# HEIC is converted to a TEMPORARY JPEG for the caption step only. Every iPhone
# photo is HEIC and vision models generally reject it; the original is never
# rewritten by that conversion, only read.
#
# Idempotent by default: a file that already carries an XMP:Description is
# skipped, so re-running over a library only fills the gaps. `--overwrite`
# forces a re-describe when you change models.
#
# Output grammar (`done:` / `skip:` / `OK:` / `error:`, each naming the file in
# single quotes) is the one shared with the other media CLIs — see
# fix-extension.nix. It is a CONTRACT, not a style: media-queue's worker counts
# `done:` lines to report what changed and lifts the first `skip:`/`OK:` line as
# the reason a batch changed nothing, so a CLI that invents its own vocabulary
# is silently reported as having done nothing at all.
#
# `-overwrite_original` is deliberate. exiftool otherwise leaves a full
# `IMG_1234.jpg_original` copy beside every file, which in a photo library
# means doubling it on disk and showing the operator two of everything in
# Finder. The writes are metadata-segment-only — the compressed image data is
# preserved byte-for-byte, so there is nothing to roll back to.
{
  writeShellApplication,
  callPackage,
  auge,
  exiftool,
  jq,
  curl,
  coreutils,
  fix-extension ? callPackage ./fix-extension.nix { },
}:
writeShellApplication {
  name = "photo-describe";
  runtimeInputs = [
    fix-extension
    auge
    exiftool
    jq
    curl
    coreutils
  ];
  text = ''
    prog=photo-describe
    usage="usage: $prog [--dry-run] [--overwrite] [--no-caption] [--model NAME] [--min-score N] <file-or-directory>..."
    die() { echo "$prog: error: $*" >&2; exit 1; }
    info() { echo "$prog: $*" >&2; }

    dry=0
    overwrite=0
    caption=1
    model="qwen3-vl:4b-instruct"
    min_score=0
    host="''${OLLAMA_HOST:-http://127.0.0.1:11434}"
    # Bare host:port is a legal OLLAMA_HOST; curl needs a scheme.
    case "$host" in http://*|https://*) ;; *) host="http://$host" ;; esac

    while [ $# -gt 0 ]; do
      case "$1" in
        --dry-run)    dry=1; shift ;;
        --overwrite)  overwrite=1; shift ;;
        --no-caption) caption=0; shift ;;
        --model)      model="''${2:-}"; [ -n "$model" ] || die "--model needs a name"; shift 2 ;;
        --min-score)  min_score="''${2:-}"; [ -n "$min_score" ] || die "--min-score needs a number"; shift 2 ;;
        --help|-h)
          echo "$usage" >&2
          echo "  writes XMP:Description + XMP:Subject + XMP:Rating into each image" >&2
          echo "  --no-caption   labels and rating only; never calls the vision model" >&2
          echo "  --min-score N  only caption photos scoring above N (0-1)" >&2
          echo "  --overwrite    re-describe files that already have a description" >&2
          echo "  directories are walked recursively" >&2
          exit 0 ;;
        --) shift; break ;;
        -*) die "unknown option: $1" ;;
        *)  break ;;
      esac
    done

    [ $# -ge 1 ] || die "$usage"

    # Stage one: the walk, the package/dataless/in-flight/AppleDouble guards and
    # the extension repair all belong to fix-extension. Its stdout is the
    # surviving file list (NUL-separated), its log goes to stderr.
    list=$(mktemp)
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$list" "$tmpdir"' EXIT
    rc=0
    fix-extension --only image --print0 "$@" > "$list" 2> "$tmpdir/stage1.err" || rc=$?
    # Stage one's `OK:` lines say "nothing was wrong with the extension", which is
    # the normal case here and is never a reason for anything this CLI reports.
    # They must not reach the caller: media-queue lifts the FIRST skip:/OK: line
    # as the reason a batch changed nothing, so passing them through made a
    # right-click on an already-described photo announce "extension already
    # matches (image/jpeg)" instead of "already described". `done:`/`skip:`/
    # `error:` still pass — those are real outcomes the operator should see.
    grep -v ': OK: ' "$tmpdir/stage1.err" >&2 || true

    files=()
    while IFS= read -r -d "" f; do
      files+=("$f")
    done < "$list"

    if [ ''${#files[@]} -eq 0 ]; then
      info "OK: 'selection' — no image files to look at"
      exit "$rc"
    fi

    # One reachability probe for the whole run, not one per file.
    ollama_up=0
    if [ "$caption" -eq 1 ]; then
      if curl -fsS -m 3 "$host/api/tags" -o "$tmpdir/tags.json" 2>/dev/null; then
        if jq -e --arg m "$model" '.models[]?.name | select(. == $m)' "$tmpdir/tags.json" >/dev/null 2>&1; then
          ollama_up=1
        else
          info "note: model '$model' is not pulled — writing labels only (ollama pull $model)"
        fi
      else
        info "note: no ollama at $host — writing labels only"
      fi
    fi

    described=0
    skipped=0

    for f in "''${files[@]}"; do
      if [ "$overwrite" -eq 0 ]; then
        existing=$(exiftool -s3 -XMP:Description "$f" 2>/dev/null || true)
        if [ -n "$existing" ]; then
          skipped=$((skipped + 1))
          info "OK: '$f' — already described"
          continue
        fi
      fi

      # --- Apple Vision: labels + aesthetics, on-device, no network ---
      labels=()
      if auge --classify --top 12 --min-confidence 0.3 --json --compact "$f" > "$tmpdir/cls.json" 2>/dev/null; then
        while IFS= read -r l; do
          [ -n "$l" ] && labels+=("$l")
        done < <(jq -r '.results.classifications[]?.label // empty' "$tmpdir/cls.json" 2>/dev/null || true)
      fi

      score=""
      utility=false
      if auge --aesthetics --json --compact "$f" > "$tmpdir/aes.json" 2>/dev/null; then
        score=$(jq -r '.results.aesthetics.overall // empty' "$tmpdir/aes.json" 2>/dev/null || true)
        utility=$(jq -r '.results.aesthetics.is_utility // false' "$tmpdir/aes.json" 2>/dev/null || echo false)
      fi

      # Apple's 0-1 aesthetics score onto XMP's 0-5 stars, for Lightroom/Bridge.
      rating=""
      [ -n "$score" ] && rating=$(awk -v s="$score" 'BEGIN{ r=int(s*5+0.5); if(r>5)r=5; if(r<0)r=0; print r }')

      # --- the caption: skipped for screenshots, and for anything below the gate ---
      sentence=""
      want_caption=0
      if [ "$ollama_up" -eq 1 ] && [ "$utility" != "true" ]; then
        if [ -z "$score" ] || awk -v s="$score" -v m="$min_score" 'BEGIN{ exit !(s >= m) }'; then
          want_caption=1
        fi
      fi

      if [ "$want_caption" -eq 1 ]; then
        shot="$f"
        case "''${f##*.}" in
          heic|HEIC|heif|HEIF)
            shot="$tmpdir/shot.jpg"
            /usr/bin/sips -s format jpeg "$f" --out "$shot" >/dev/null 2>&1 || shot="$f" ;;
        esac
        if base64 < "$shot" | tr -d '\n' > "$tmpdir/b64" 2>/dev/null; then
          jq -n --arg m "$model" --rawfile b "$tmpdir/b64" \
            '{model:$m, stream:false, images:[$b],
              options:{temperature:0, seed:42},
              prompt:"Describe this photograph in one plain sentence under 25 words. Name the concrete things visible: how many people, what they wear or hold, the setting, and any notable objects. Prefer specific nouns over mood words. Do not begin with \"This image\" or \"The photo\"."}' \
            > "$tmpdir/req.json" 2>/dev/null || true
          if curl -fsS -m 180 -H 'Content-Type: application/json' \
               -d @"$tmpdir/req.json" "$host/api/generate" > "$tmpdir/resp.json" 2>/dev/null; then
            sentence=$(jq -r '.response // empty' "$tmpdir/resp.json" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
          fi
        fi
      fi

      if [ "$dry" -eq 1 ]; then
        echo "$prog: would describe: $f"
        [ -n "$score" ]  && echo "    score:   $score (rating $rating, utility=$utility)"
        [ ''${#labels[@]} -gt 0 ] && echo "    labels:  ''${labels[*]}"
        [ -n "$sentence" ] && echo "    caption: $sentence"
        described=$((described + 1))
        continue
      fi

      args=(-overwrite_original -q -q)
      # Clear first so a re-describe replaces the keyword list instead of
      # appending a second copy of it. IPTC:Keywords is the legacy IIM twin of
      # dc:subject, written alongside it because older tools and some indexers
      # read only that one; Lightroom writes both for the same reason.
      # AltTextAccessibility is CLEARED, not merely skipped: earlier versions of
      # this tool wrote the caption there, and leaving those behind would leave
      # exactly the unreviewed machine guess the header argues must not sit in
      # that field. Nothing else in this fleet writes it, so the only values
      # being removed are ones this tool put there.
      args+=(-XMP:Subject= -IPTC:Keywords= -XMP-iptcCore:AltTextAccessibility=)
      for l in ''${labels[@]+"''${labels[@]}"}; do
        # Apple's label identifiers are snake_case (`consumer_electronics`,
        # `wood_processed`). That underscore is an internal token, not a word:
        # it survives into Finder's Get Info, reads as machine output, and
        # breaks the substring search this metadata exists to serve.
        human=''${l//_/ }
        args+=("-XMP:Subject=$human" "-IPTC:Keywords=$human")
      done
      [ -n "$rating" ] && args+=("-XMP:Rating=$rating")
      [ -n "$sentence" ] && args+=("-XMP:Description=$sentence")

      if exiftool "''${args[@]}" "$f" 2>/dev/null; then
        described=$((described + 1))
        if [ -n "$sentence" ]; then
          info "done: '$f' — $sentence"
        else
          info "done: '$f' — labelled only (''${labels[*]-no labels})"
        fi
      else
        info "error: '$f' — could not write metadata"
        rc=1
      fi
    done

    info "OK: 'selection' — $described described, $skipped already had a description"
    exit "$rc"
  '';
}
