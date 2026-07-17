# Vast.ai template-provisioning toolkit — the macOS-side, all-Nix companion to
# packages/vast-bootstrap.sh, packages/vast-templates/, and
# docs/vastai-template-provisioning.md. Returns `writeShellApplication`s
# (shellcheck'd at `nix flake check`) plus a lint derivation for the committed
# instance-side scripts, wired as flake apps in flake.nix:
#
#   nix run .#vast-template-apply    — create/update (reconcile-by-name) a Vast.ai
#                                      template that boots via PROVISIONING_SCRIPT;
#                                      gated by vast-repo-check unless --skip-check
#   nix run .#vast-repo-check        — validate that a repo is a legit provisioner
#                                      repo (structural: .provisioner-template.json
#                                      marker + required files; forge-agnostic)
#   nix run .#vast-account-vars-set  — sync read-only VAST_* Keychain tokens to Vast
#                                      ACCOUNT-level env vars
#
# Design (see the doc): no custom image, no registry auth; PROVISIONING_SCRIPT ->
# committed public bootstrap (pinned to THIS flake's rev) -> clone the target repo
# (public/private, token from account vars) -> run its constant provision.sh (a thin
# shim inherited from a template) -> fetch+run the pinned engine. Secrets NEVER touch
# the template. macOS-only: VAST_API_KEY + VAST_* tokens live in the login Keychain
# (`/usr/bin/security`); curl/jq/sed pinned via runtimeInputs.
{
  writeShellApplication,
  runCommand,
  curl,
  jq,
  gnused,
  coreutils,
  shellcheck,
  orgName,
  repoName,
  rev,
}:
let
  api = "https://console.vast.ai/api/v0";
  bootstrapUrl = "https://raw.githubusercontent.com/${orgName}/${repoName}/${rev}/packages/vast-bootstrap.sh";

  # Validate that a repo is a legitimate provisioner repo — structurally (forge
  # provenance is asymmetric: GitHub has template_repository, GitLab has nothing),
  # by fetching ONLY the marker + required files via each forge's single-file API.
  repo-check = writeShellApplication {
    name = "vast-repo-check";
    runtimeInputs = [
      curl
      jq
      gnused
      coreutils
    ];
    text = ''
      security=/usr/bin/security
      account="$(id -un)"
      repo=""
      ref="main"
      while [ $# -gt 0 ]; do
        case "$1" in
          --repo) repo="''${2:?}"; shift 2 ;;
          --ref) ref="''${2:?}"; shift 2 ;;
          -h | --help) echo "usage: vast-repo-check --repo [github:|gitlab:]owner/repo [--ref REF]"; exit 0 ;;
          *) echo "vast-repo-check: unknown argument: $1" >&2; exit 1 ;;
        esac
      done
      [ -n "$repo" ] || { echo "vast-repo-check: --repo is required." >&2; exit 1; }

      host="github.com"
      case "$repo" in
        gitlab:*) host="gitlab.com"; repo="''${repo#gitlab:}" ;;
        github:*) host="github.com"; repo="''${repo#github:}" ;;
      esac

      # Fetch one file's raw contents (empty output + nonzero on 404/denied).
      fetch_file() {
        local path="$1" tok
        case "$host" in
          github.com)
            tok="$("$security" find-generic-password -a "$account" -s GH_TOKEN -w 2>/dev/null || true)"
            curl -fsSL -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github.raw+json" \
              "https://api.github.com/repos/$repo/contents/$path?ref=$ref" ;;
          gitlab.com)
            tok="$("$security" find-generic-password -a "$account" -s GITLAB_TOKEN -w 2>/dev/null || true)"
            local enc pe
            enc="$(printf '%s' "$repo" | sed 's|/|%2F|g')"
            pe="$(printf '%s' "$path" | sed 's|/|%2F|g')"
            curl -fsSL -H "PRIVATE-TOKEN: $tok" \
              "https://gitlab.com/api/v4/projects/$enc/repository/files/$pe/raw?ref=$ref" ;;
        esac
      }

      marker="$(fetch_file ".provisioner-template.json" 2>/dev/null || true)"
      if [ -z "$marker" ]; then
        echo "vast-repo-check: FAIL — $host/$repo@$ref has no .provisioner-template.json (not a provisioner repo)." >&2
        exit 1
      fi
      schema="$(printf '%s' "$marker" | jq -r '.schema // empty' 2>/dev/null || true)"
      tmpl="$(printf '%s' "$marker" | jq -r '.template // empty' 2>/dev/null || true)"
      if [ "$schema" != "1" ]; then
        echo "vast-repo-check: FAIL — unsupported marker schema '$schema' (expected 1)." >&2
        exit 1
      fi

      ok=1
      while IFS= read -r rf; do
        [ -n "$rf" ] || continue
        if ! fetch_file "$rf" >/dev/null 2>&1; then
          echo "vast-repo-check: FAIL — required file '$rf' missing." >&2
          ok=0
        fi
      done < <(printf '%s' "$marker" | jq -r '(.required_files // ["provision.sh"])[]' 2>/dev/null)
      [ "$ok" = 1 ] || exit 1

      echo "vast-repo-check: OK — $host/$repo@$ref (template=$tmpl schema=$schema)."
    '';
  };

  template-apply = writeShellApplication {
    name = "vast-template-apply";
    runtimeInputs = [
      curl
      jq
      coreutils
    ];
    text = ''
      # Reconcile (create or update, BY NAME) a Vast.ai template whose instances boot
      # via PROVISIONING_SCRIPT -> bootstrap -> clone target repo -> run provision.sh.
      # Gated by vast-repo-check (skip with --skip-check). No secrets in the template.
      security=/usr/bin/security
      account="$(id -un)"
      apikey="$("$security" find-generic-password -a "$account" -s VAST_API_KEY -w 2>/dev/null || true)"
      if [ -z "$apikey" ]; then
        echo "vast-template-apply: VAST_API_KEY not in the login Keychain (set-secret VAST_API_KEY)." >&2
        exit 1
      fi

      name=""
      repo=""
      ref="main"
      entry="provision.sh"
      image="vastai/base-image"
      disk="32"
      dryrun=""
      skipcheck=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --template-name) name="''${2:?}"; shift 2 ;;
          --repo) repo="''${2:?}"; shift 2 ;;
          --ref) ref="''${2:?}"; shift 2 ;;
          --entrypoint) entry="''${2:?}"; shift 2 ;;
          --image) image="''${2:?}"; shift 2 ;;
          --disk) disk="''${2:?}"; shift 2 ;;
          --dry-run) dryrun=1; shift ;;
          --skip-check) skipcheck=1; shift ;;
          -h | --help)
            echo "usage: vast-template-apply --template-name NAME --repo [github:|gitlab:]owner/repo \\"
            echo "         [--ref REF] [--entrypoint PATH] [--image IMG[:TAG]] [--disk GB] [--dry-run] [--skip-check]"
            exit 0 ;;
          *) echo "vast-template-apply: unknown argument: $1" >&2; exit 1 ;;
        esac
      done
      [ -n "$name" ] || { echo "vast-template-apply: --template-name is required." >&2; exit 1; }
      [ -n "$repo" ] || { echo "vast-template-apply: --repo is required." >&2; exit 1; }

      # Forge scheme -> host. Bare owner/repo defaults to github.com.
      host="github.com"
      case "$repo" in
        gitlab:*) host="gitlab.com"; repo="''${repo#gitlab:}" ;;
        github:*) host="github.com"; repo="''${repo#github:}" ;;
      esac

      # image[:tag] -> image + tag (default latest).
      tag="latest"
      case "$image" in
        *:*) tag="''${image##*:}"; image="''${image%:*}" ;;
      esac

      env_str="-e PROVISIONING_SCRIPT=${bootstrapUrl} -e PROVISION_HOST=$host -e PROVISION_REPO=$repo -e PROVISION_REF=$ref -e PROVISION_ENTRYPOINT=$entry"

      body="$(jq -n \
        --arg name "$name" --arg image "$image" --arg tag "$tag" \
        --arg env "$env_str" --argjson disk "$disk" '
        { name: $name, image: $image, tag: $tag, env: $env, onstart: "",
          runtype: "ssh", use_ssh: true, ssh_direct: true,
          recommended_disk_space: $disk, private: true }')"

      if [ -n "$dryrun" ]; then
        echo "vast-template-apply: DRY RUN — template '$name' body:"
        printf '%s\n' "$body" | jq .
        exit 0
      fi

      # Gate: the target repo must be a legitimate provisioner repo at this ref.
      if [ -z "$skipcheck" ]; then
        check_repo="github:$repo"
        [ "$host" = gitlab.com ] && check_repo="gitlab:$repo"
        if ! ${repo-check}/bin/vast-repo-check --repo "$check_repo" --ref "$ref"; then
          echo "vast-template-apply: repo legitimacy check failed — refusing to apply (--skip-check to override)." >&2
          exit 1
        fi
      fi

      # Reconcile by name: find an existing template of this name, then PUT (update
      # with its hash_id) else POST (create).
      list="$(curl -fsS -H "Authorization: Bearer $apikey" "${api}/template/?select_cols=%5B%22%2A%22%5D" 2>/dev/null || true)"
      hash_id="$(printf '%s' "$list" | jq -r --arg n "$name" '(.templates // []) | map(select(.name==$n)) | (.[0].hash_id // empty)')"

      if [ -n "$hash_id" ]; then
        full="$(printf '%s' "$body" | jq --arg h "$hash_id" '. + {hash_id: $h}')"
        resp="$(printf '%s' "$full" | curl -fsS -X PUT "${api}/template/" \
                 -H "Authorization: Bearer $apikey" -H "Content-Type: application/json" --data @- 2>/dev/null || true)"
        action="updated"
      else
        resp="$(printf '%s' "$body" | curl -fsS -X POST "${api}/template/" \
                 -H "Authorization: Bearer $apikey" -H "Content-Type: application/json" --data @- 2>/dev/null || true)"
        action="created"
      fi

      summary="$(printf '%s' "$resp" | jq -rc '{success, name: (.template.name // .name), id: (.template.id // .id), hash_id: (.template.hash_id // .hash_id)}' 2>/dev/null || true)"
      if [ "$(printf '%s' "$resp" | jq -r '.success // false' 2>/dev/null)" = true ]; then
        echo "vast-template-apply: $action — $summary"
      else
        echo "vast-template-apply: FAILED — $(printf '%s' "$resp" | jq -rc '{success, msg, error}' 2>/dev/null || printf '%s' "$resp")" >&2
        exit 1
      fi
    '';
  };

  account-vars-set = writeShellApplication {
    name = "vast-account-vars-set";
    runtimeInputs = [
      curl
      jq
      coreutils
    ];
    text = ''
      # Sync read-only tokens from the login Keychain (VAST_<NAME>) to Vast.ai
      # ACCOUNT-level environment variables (<NAME>), injected into every instance.
      # Default set: GITLAB_TOKEN HF_TOKEN CIVITAI_TOKEN GH_TOKEN; pass NAMEs to
      # override. Values are never printed (only their lengths, as proof).
      security=/usr/bin/security
      account="$(id -un)"
      apikey="$("$security" find-generic-password -a "$account" -s VAST_API_KEY -w 2>/dev/null || true)"
      if [ -z "$apikey" ]; then
        echo "vast-account-vars-set: VAST_API_KEY not in the login Keychain." >&2
        exit 1
      fi

      names=("$@")
      if [ "''${#names[@]}" -eq 0 ]; then
        names=(GITLAB_TOKEN HF_TOKEN CIVITAI_TOKEN GH_TOKEN)
      fi

      rc=0
      for name in "''${names[@]}"; do
        val="$("$security" find-generic-password -a "$account" -s "VAST_$name" -w 2>/dev/null || true)"
        if [ -z "$val" ]; then
          echo "$name: SKIP (Keychain VAST_$name missing)"; rc=1; continue
        fi
        body="$(val="$val" jq -n --arg k "$name" '{key: $k, value: env.val}')"
        resp="$(printf '%s' "$body" | curl -fsS -X POST "${api}/secrets/" \
                 -H "Authorization: Bearer $apikey" -H "Content-Type: application/json" --data @- 2>/dev/null || true)"
        if [ "$(printf '%s' "$resp" | jq -r '.success // false' 2>/dev/null)" != true ]; then
          resp="$(printf '%s' "$body" | curl -fsS -X PUT "${api}/secrets/" \
                   -H "Authorization: Bearer $apikey" -H "Content-Type: application/json" --data @- 2>/dev/null || true)"
        fi
        if [ "$(printf '%s' "$resp" | jq -r '.success // false' 2>/dev/null)" = true ]; then
          echo "$name: set on Vast (value length ''${#val})"
        else
          echo "$name: FAILED ($(printf '%s' "$resp" | jq -rc '{msg, error}' 2>/dev/null || true))"; rc=1
        fi
        val=""
      done
      exit "$rc"
    '';
  };

  # Lint the committed instance-side scripts at `nix flake check` (served as raw
  # files / fetched at boot, so they can't be writeShellApplications).
  scripts-lint = runCommand "vast-scripts-lint" { nativeBuildInputs = [ shellcheck ]; } ''
    shellcheck \
      ${./vast-bootstrap.sh} \
      ${./vast-templates/provisioner/provision.sh}
    touch "$out"
  '';
in
{
  inherit
    template-apply
    repo-check
    account-vars-set
    scripts-lint
    ;
}
