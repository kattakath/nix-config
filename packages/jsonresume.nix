# `jsonresume <download|print>` — fetch a JSON Resume (jsonresume.org) and render it
# to PDF. A thin, self-contained wrapper around the npm `resume` CLI (resume-cli):
#
#   jsonresume download [--url URL] [--destination DIR]
#       Download resume.json. --url overrides the baked-in default URL; if there is
#       neither it errors. Writes <DIR>/resume.json (DIR defaults to the cwd).
#
#   jsonresume print [--path FILE] [--theme NAME] [--destination DIR]
#       Render a JSON Resume to <DIR>/resume.pdf (DIR defaults to cwd). The input is
#       --path if given, else resume.json downloaded to /tmp from the default URL
#       (errors if there is no default). The theme is taken from the file's meta.theme
#       (errors if missing) unless --theme overrides it. resume-cli resolves themes
#       from the CWD's node_modules, so the theme package is installed on the fly into
#       a throwaway workdir before exporting.
#
# `defaultUrl` is baked in at build time (composed in flake.nix as `jsonResumeUrl`
# from jsonResumeGistId + handleName) — so there is NO ambient env var: the one
# consumer carries its own default, and `--url`/`--path` override per-invocation.
# curl/jq/coreutils are PINNED from Nix; node/npm/resume come from the CALLER's PATH
# (the fnm-managed Node + the globally-installed resume-cli — `npm i -g resume-cli`).
# PDF rendering drives puppeteer via $PUPPETEER_EXECUTABLE_PATH (set in the darwin
# home profile, modules/shared/home.nix), so a browser download is never needed.
{
  writeShellApplication,
  curl,
  jq,
  coreutils,
  # Default resume URL baked in at build time (flake.nix jsonResumeUrl). null → no
  # default, so download/print require an explicit --url / --path.
  defaultUrl ? null,
}:
let
  bakedUrl = if defaultUrl == null then "" else defaultUrl;
in
writeShellApplication {
  name = "jsonresume";
  runtimeInputs = [
    curl
    jq
    coreutils
  ];
  text = ''
    prog=jsonresume
    default_url="${bakedUrl}"

    die() {
      echo "$prog: error: $*" >&2
      exit 1
    }

    usage() {
      cat >&2 <<'EOF'
    Usage:
      jsonresume download [--url URL] [--destination DIR]
      jsonresume print    [--path FILE] [--theme NAME] [--destination DIR]

    download  Fetch resume.json (--url, else the built-in default) into DIR (default: .).
    print     Render a JSON Resume to <DIR>/resume.pdf (default DIR: .). Input is --path,
              else downloaded to /tmp from the built-in default URL. Theme is --theme,
              else the file's meta.theme (error if both absent).
    EOF
    }

    # Resolve the source URL: an explicit value wins, else the baked-in default.
    # Returns non-zero (empty) if neither is available.
    resolve_url() {
      if [ -n "$1" ]; then
        printf '%s' "$1"
        return 0
      fi
      if [ -n "$default_url" ]; then
        printf '%s' "$default_url"
        return 0
      fi
      return 1
    }

    # Normalise a theme to its npm package name (jsonresume-theme-<name>).
    theme_pkg() {
      case "$1" in
        jsonresume-theme-*) printf '%s' "$1" ;;
        *) printf 'jsonresume-theme-%s' "$1" ;;
      esac
    }

    cmd="''${1:-}"
    if [ "$#" -gt 0 ]; then shift; fi

    case "$cmd" in
      download)
        url="" ; dest="."
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --url) [ "$#" -ge 2 ] || die "--url needs a value"; url="$2"; shift 2 ;;
            --url=*) url="''${1#*=}"; shift ;;
            --destination) [ "$#" -ge 2 ] || die "--destination needs a value"; dest="$2"; shift 2 ;;
            --destination=*) dest="''${1#*=}"; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown flag for download: $1" ;;
          esac
        done

        url="$(resolve_url "$url")" || die "no --url given and no built-in default (set jsonResumeGistId in flake.nix)"
        mkdir -p "$dest"
        out="$dest/resume.json"
        curl -fsSL "$url" -o "$out" || die "download failed: $url"
        jq -e . "$out" >/dev/null 2>&1 || die "downloaded file is not valid JSON: $out"
        echo "downloaded → $out"
        ;;

      print)
        path="" ; theme="" ; dest="."
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --path) [ "$#" -ge 2 ] || die "--path needs a value"; path="$2"; shift 2 ;;
            --path=*) path="''${1#*=}"; shift ;;
            --theme) [ "$#" -ge 2 ] || die "--theme needs a value"; theme="$2"; shift 2 ;;
            --theme=*) theme="''${1#*=}"; shift ;;
            --destination) [ "$#" -ge 2 ] || die "--destination needs a value"; dest="$2"; shift 2 ;;
            --destination=*) dest="''${1#*=}"; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown flag for print: $1" ;;
          esac
        done

        command -v resume >/dev/null 2>&1 || die "resume-cli not on PATH — install it: npm i -g resume-cli"
        command -v npm >/dev/null 2>&1 || die "npm not on PATH (is fnm / Node active?)"

        # Resolve the input JSON Resume: --path, else download to /tmp from the default.
        if [ -n "$path" ]; then
          [ -f "$path" ] || die "no such file: $path"
          input="$path"
        else
          url="$(resolve_url "")" || die "no --path given and no built-in default URL (set jsonResumeGistId in flake.nix)"
          input="$(mktemp /tmp/jsonresume.XXXXXX.json)"
          curl -fsSL "$url" -o "$input" || die "download failed: $url"
        fi
        jq -e . "$input" >/dev/null 2>&1 || die "input is not valid JSON: $input"

        # Resolve the theme: --theme wins, else meta.theme (error if absent).
        if [ -z "$theme" ]; then
          theme="$(jq -r '.meta.theme // empty' "$input")"
          [ -n "$theme" ] || die "no --theme given and .meta.theme is missing in $input"
        fi
        pkg="$(theme_pkg "$theme")"

        # resume-cli resolves themes from the CWD's node_modules, so install the theme
        # into a throwaway workdir and export there, then move the PDF out.
        work="$(mktemp -d /tmp/jsonresume-work.XXXXXX)"
        trap 'rm -rf "$work"' EXIT
        cp "$input" "$work/resume.json"
        ( cd "$work" && npm init -y >/dev/null 2>&1 && npm i "$pkg" >/dev/null 2>&1 ) \
          || die "failed to install theme package: $pkg"
        ( cd "$work" && resume export resume.pdf --resume resume.json --theme "$pkg" ) \
          || die "resume export failed (theme: $pkg)"

        mkdir -p "$dest"
        mv "$work/resume.pdf" "$dest/resume.pdf"
        echo "exported → $dest/resume.pdf (theme: $pkg)"
        ;;

      -h|--help)
        usage
        exit 0
        ;;
      "")
        usage
        exit 1
        ;;
      *)
        die "unknown command: $cmd (expected: download | print)"
        ;;
    esac
  '';
}
