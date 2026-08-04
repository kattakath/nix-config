# `jsonresume <download|print|validate|markdown|text>` — fetch a JSON Resume
# (jsonresume.org) and render/validate it. A thin, self-contained wrapper that is
# DUAL-ENGINE over the JSON Resume CLIs:
#
#   * PDF + validate → prefer `resumed` (@rbardini/resumed), the MAINTAINED CLI the
#     JSON Resume project now recommends (the official `resume-cli` was archived
#     2026-06-12). `resumed` renders PDF through the SAME puppeteer + system-Chrome
#     path as resume-cli, and `resumed validate` checks against the current
#     @jsonresume/schema v1.x. If `resumed` is absent (or its PDF export fails) the
#     wrapper falls back to `resume` (resume-cli), which still works.
#   * markdown / text → `resume` (resume-cli) ONLY. resumed has no flat-format
#     export; resume-cli's `--format md|txt` needs no theme and produces clean output.
#
#   jsonresume download [--url URL] [--destination DIR]
#       Download resume.json. --url overrides the baked-in default URL; if there is
#       neither it errors. Writes <DIR>/resume.json (DIR defaults to the cwd).
#
#   jsonresume print [--path FILE] [--theme NAME] [--destination DIR]
#       Render a JSON Resume to <DIR>/resume.pdf (DIR defaults to cwd). The input is
#       --path if given, else resume.json downloaded to /tmp from the default URL
#       (errors if there is no default). The theme is taken from the file's meta.theme
#       (errors if missing) unless --theme overrides it. Themes resolve from the CWD's
#       node_modules, so the theme package is installed on the fly into a throwaway
#       workdir before exporting. Uses `resumed export` (fallback `resume export`).
#
#   jsonresume validate [--path FILE] [--url URL]
#       Validate a JSON Resume against the schema. Prefers `resumed validate` (current
#       @jsonresume/schema v1.x); falls back to `resume validate` (legacy schema).
#       Input is --path, else the default/--url URL downloaded to a throwaway workdir.
#
#   jsonresume markdown [--path FILE] [--url URL] [--destination DIR] [--no-validate]
#   jsonresume text     [--path FILE] [--url URL] [--destination DIR] [--no-validate]
#       Render a JSON Resume to Markdown / plain text via resume-cli. Neither needs a
#       theme. By DESIGN there is no stored .md/.txt to drift: output goes to STDOUT (so
#       it is a derived, on-demand artifact regenerated from resume.json each time)
#       unless --destination writes <DIR>/resume.md|resume.txt. Input is --path, else the
#       default/--url URL downloaded to a throwaway workdir. Schema-validates the input
#       first unless --no-validate. Aliases: md, txt.
#
# `defaultUrl` is baked in at build time (composed in flake.nix as `jsonResumeUrl`
# from jsonResumeGistId + userName) — so there is NO ambient env var: the one
# consumer carries its own default, and `--url`/`--path` override per-invocation.
# curl/jq/coreutils are PINNED from Nix; node/npm/resumed/resume come from the CALLER's
# PATH (the fnm-managed Node + globally-installed CLIs — `npm i -g resumed puppeteer`
# for the primary path, plus `npm i -g resume-cli` for markdown/text + fallback).
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

    have() { command -v "$1" >/dev/null 2>&1; }

    usage() {
      cat >&2 <<'EOF'
    Usage:
      jsonresume download [--url URL] [--destination DIR]
      jsonresume print    [--path FILE] [--theme NAME] [--destination DIR]
      jsonresume validate [--path FILE] [--url URL]
      jsonresume markdown [--path FILE] [--url URL] [--destination DIR] [--no-validate]
      jsonresume text     [--path FILE] [--url URL] [--destination DIR] [--no-validate]

    download  Fetch resume.json (--url, else the built-in default) into DIR (default: .).
    print     Render a JSON Resume to <DIR>/resume.pdf (default DIR: .). Input is --path,
              else downloaded to /tmp from the built-in default URL. Theme is --theme,
              else the file's meta.theme (error if both absent). Uses resumed (fallback resume).
    validate  Schema-validate a JSON Resume. Prefers `resumed validate` (schema v1.x),
              falls back to `resume validate`. Input is --path, else the built-in default/--url.
    markdown  Render to Markdown (no theme, resume-cli). Prints to STDOUT unless --destination
              writes <DIR>/resume.md. Input is --path, else the built-in default/--url URL.
              Schema-validates the input first unless --no-validate. Alias: md.
    text      As markdown, but plain text → STDOUT or <DIR>/resume.txt. Alias: txt.
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

    # Schema-validate resume.json in the CWD. Prefer `resumed validate` (current
    # @jsonresume/schema v1.x); fall back to `resume validate` (legacy schema).
    # Returns the underlying CLI's exit status. Callers cd into the workdir first.
    validate_cwd() {
      if have resumed; then
        resumed validate resume.json >/dev/null 2>&1
      elif have resume; then
        resume validate resume.json >/dev/null 2>&1
      else
        return 127
      fi
    }

    # Export the resume.json in the CWD to resume.pdf using theme package $1.
    # Prefer the maintained `resumed export`; on absence OR failure fall back to
    # `resume export` (resume-cli). Both resolve the theme from ./node_modules and
    # drive puppeteer via $PUPPETEER_EXECUTABLE_PATH. Returns non-zero if both fail.
    pdf_export() {
      pkg="$1"
      if have resumed && resumed export resume.json -o resume.pdf -t "$pkg" >/dev/null 2>&1; then
        return 0
      fi
      if have resume && resume export resume.pdf --resume resume.json --theme "$pkg" >/dev/null 2>&1; then
        return 0
      fi
      return 1
    }

    # Render a JSON Resume to a THEME-LESS flat format (md or txt) via resume-cli.
    # Shared by the `markdown`/`text` subcommands — identical but for the extension.
    # Output defaults to stdout (ephemeral, nothing stored) unless --destination writes a file.
    render_flat() {
      fmt="$1"; shift   # md | txt
      path="" ; url="" ; dest="" ; validate=1
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --path) [ "$#" -ge 2 ] || die "--path needs a value"; path="$2"; shift 2 ;;
          --path=*) path="''${1#*=}"; shift ;;
          --url) [ "$#" -ge 2 ] || die "--url needs a value"; url="$2"; shift 2 ;;
          --url=*) url="''${1#*=}"; shift ;;
          --destination) [ "$#" -ge 2 ] || die "--destination needs a value"; dest="$2"; shift 2 ;;
          --destination=*) dest="''${1#*=}"; shift ;;
          --no-validate) validate=0; shift ;;
          -h|--help) usage; exit 0 ;;
          *) die "unknown flag for $fmt export: $1" ;;
        esac
      done

      # markdown/text are resume-cli ONLY (resumed has no flat-format export).
      have resume || die "resume-cli not on PATH (markdown/text need it) — install it: npm i -g resume-cli"
      have node || die "node not on PATH (is fnm / Node active?)"

      # Everything happens in a throwaway workdir named resume.json, so both
      # validation and `resume export` find their default input there.
      work="$(mktemp -d /tmp/jsonresume-flat.XXXXXX)"
      trap 'rm -rf "$work"' EXIT

      if [ -n "$path" ]; then
        [ -f "$path" ] || die "no such file: $path"
        cp "$path" "$work/resume.json"
      else
        url="$(resolve_url "$url")" || die "no --path/--url given and no built-in default URL (set jsonResumeGistId in flake.nix)"
        curl -fsSL "$url" -o "$work/resume.json" || die "download failed: $url"
      fi
      jq -e . "$work/resume.json" >/dev/null 2>&1 || die "input is not valid JSON"

      if [ "$validate" -eq 1 ]; then
        ( cd "$work" && validate_cwd ) \
          || die "JSON Resume schema validation failed; pass --no-validate to skip"
      fi

      ( cd "$work" && resume export "out.$fmt" --resume resume.json --format "$fmt" >/dev/null 2>&1 ) \
        || die "resume export failed (format: $fmt)"

      if [ -n "$dest" ]; then
        mkdir -p "$dest"
        mv "$work/out.$fmt" "$dest/resume.$fmt"
        echo "exported → $dest/resume.$fmt" >&2
      else
        cat "$work/out.$fmt"
      fi
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

      validate)
        path="" ; url=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --path) [ "$#" -ge 2 ] || die "--path needs a value"; path="$2"; shift 2 ;;
            --path=*) path="''${1#*=}"; shift ;;
            --url) [ "$#" -ge 2 ] || die "--url needs a value"; url="$2"; shift 2 ;;
            --url=*) url="''${1#*=}"; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown flag for validate: $1" ;;
          esac
        done

        have resumed || have resume || die "neither resumed nor resume-cli on PATH — install: npm i -g resumed"
        work="$(mktemp -d /tmp/jsonresume-val.XXXXXX)"
        trap 'rm -rf "$work"' EXIT
        if [ -n "$path" ]; then
          [ -f "$path" ] || die "no such file: $path"
          cp "$path" "$work/resume.json"
        else
          url="$(resolve_url "$url")" || die "no --path/--url given and no built-in default URL (set jsonResumeGistId in flake.nix)"
          curl -fsSL "$url" -o "$work/resume.json" || die "download failed: $url"
        fi
        jq -e . "$work/resume.json" >/dev/null 2>&1 || die "input is not valid JSON"
        if ( cd "$work" && validate_cwd ); then
          echo "valid ✓ (JSON Resume schema)"
        else
          die "JSON Resume schema validation failed"
        fi
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

        have resumed || have resume || die "no PDF engine on PATH — install one: npm i -g resumed puppeteer (or npm i -g resume-cli)"
        have npm || die "npm not on PATH (is fnm / Node active?)"

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

        # Themes resolve from the CWD's node_modules, so install the theme into a
        # throwaway workdir and export there, then move the PDF out.
        work="$(mktemp -d /tmp/jsonresume-work.XXXXXX)"
        trap 'rm -rf "$work"' EXIT
        cp "$input" "$work/resume.json"
        ( cd "$work" && npm init -y >/dev/null 2>&1 && npm i "$pkg" >/dev/null 2>&1 ) \
          || die "failed to install theme package: $pkg"
        ( cd "$work" && pdf_export "$pkg" ) \
          || die "PDF export failed (theme: $pkg) — tried resumed then resume-cli"

        mkdir -p "$dest"
        mv "$work/resume.pdf" "$dest/resume.pdf"
        echo "exported → $dest/resume.pdf (theme: $pkg)"
        ;;

      markdown|md)
        render_flat md "$@"
        ;;

      text|txt)
        render_flat txt "$@"
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
        die "unknown command: $cmd (expected: download | print | validate | markdown | text)"
        ;;
    esac
  '';
}
