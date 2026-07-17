# Vast.ai template-provisioning toolkit — the macOS-side, all-Nix companion to
# packages/vast-bootstrap.sh, packages/vast-templates/, and
# docs/vastai-template-provisioning.md. Returns `writeShellApplication`s
# (shellcheck'd at `nix flake check`) plus a lint derivation for the committed
# instance-side scripts, wired as flake apps in flake.nix:
#
#   nix run .#vast-template-apply    — create/REPLACE (reconcile by name — delete+create)
#                                      a Vast.ai template that boots via PROVISIONING_SCRIPT;
#                                      gated by vast-repo-check unless --skip-check
#   nix run .#vast-repo-check        — validate that a repo is a legit provisioner
#                                      repo (structural: .provisioner-template.json
#                                      marker + required files; forge-agnostic)
#   nix run .#vast-account-vars-set  — sync read-only VAST_* Keychain tokens to Vast
#                                      ACCOUNT-level env vars
#   nix run .#vast-ssh-key-set       — register the operator SSH public key on the Vast
#                                      account (idempotent)
#   nix run .#vast-init-repo         — scaffold a provisioner repo from the baked
#                                      vast-templates/provisioner/ (GitHub or GitLab)
#
# Design (see the doc): no custom image, no registry auth; PROVISIONING_SCRIPT ->
# committed public bootstrap (pinned to THIS flake's rev) -> clone the target repo
# (public/private, token from account vars) -> run its constant, self-contained
# provision.sh. Secrets NEVER touch
# the template. macOS-only: VAST_API_KEY + VAST_* tokens live in the login Keychain
# (`/usr/bin/security`); curl/jq/sed pinned via runtimeInputs.
{
  writeShellApplication,
  runCommand,
  curl,
  jq,
  gnused,
  coreutils,
  gh,
  glab,
  git,
  shellcheck,
  orgName,
  repoName,
  rev,
}:
let
  api = "https://console.vast.ai/api/v0";
  # ?v=${rev} makes the URL change on every content change, defeating the base image's
  # Phase-9 URL-hash idempotency skip (so a fixed bootstrap actually re-runs).
  bootstrapUrl = "https://raw.githubusercontent.com/${orgName}/${repoName}/${rev}/packages/vast-bootstrap.sh?v=${rev}";
  # The shared, never-false-positive engine, pinned to this rev; the bootstrap fetches it.
  libUrl = "https://raw.githubusercontent.com/${orgName}/${repoName}/${rev}/packages/vast-templates/provisioner/provision-lib.sh";

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
      # Reconcile (create or REPLACE, by name) a Vast.ai template whose instances boot
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
      disk="64"
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

      # image[:tag] -> image + tag. NOTE: vastai/base-image has NO ":latest" tag —
      # a manifest-unknown pull failure — so default to a valid auto-CUDA tag.
      tag="cuda-12.6.3-auto"
      case "$image" in
        *:*) tag="''${image##*:}"; image="''${image%:*}" ;;
      esac

      # runtype=args PRESERVES the base image's ENTRYPOINT — unlike ssh/jupyter, which
      # replace it with /.launch. With the entrypoint intact, supervisord starts Caddy +
      # the Instance Portal AND the /etc/vast_boot.d phase auto-runs PROVISIONING_SCRIPT.
      # So we get native auto-provisioning (no onstart hack). OPEN_BUTTON_PORT=1111 is
      # what makes the dashboard render the "Open" button under args (jupyter/ssh set it
      # implicitly; args does not) → Open → Instance Portal (web Apps/Logs/Terminal).
      # PORTAL_CONFIG lists apps (hostname:external:internal:path:name|… — no spaces in
      # names, since the value rides in the -e docker-options string). SSH_PUBKEY_B64
      # carries the operator public key base64'd (no spaces) so provision.sh can plant it
      # for sshd — Vast's own ssh-key injection is tied to runtype=ssh and won't run here.
      pubkey_b64="$(base64 < "$HOME/.ssh/id_ed25519.pub" 2>/dev/null | tr -d '\n' || true)"
      # Fail LOUDLY rather than shipping an empty SSH_PUBKEY_B64 (which would silently
      # yield an instance with no SSH login).
      [ -n "$pubkey_b64" ] || { echo "vast-template-apply: ~/.ssh/id_ed25519.pub not found — cannot inject SSH_PUBKEY_B64" >&2; exit 1; }
      # PROVISION_LIB_URL: the pinned engine the bootstrap fetches. PROVISIONER_FAILURE_ACTION
      # + PROVISION_MAX_SECONDS drive the engine's fail-closed funnel (stop the box + watchdog).
      env_str="-e PROVISIONING_SCRIPT=${bootstrapUrl} -e PROVISION_LIB_URL=${libUrl} -e PROVISION_HOST=$host -e PROVISION_REPO=$repo -e PROVISION_REF=$ref -e PROVISION_ENTRYPOINT=$entry -e PROVISIONER_FAILURE_ACTION=stop -e PROVISION_MAX_SECONDS=5400 -e OPEN_BUTTON_PORT=1111 -e PORTAL_CONFIG=localhost:1111:11111:/:Portal|localhost:8188:18188:/:ComfyUI -e SSH_PUBKEY_B64=$pubkey_b64 -p 1111:1111 -p 8188:8188 -p 22:22"

      body="$(jq -n \
        --arg name "$name" --arg image "$image" --arg tag "$tag" \
        --arg env "$env_str" --argjson disk "$disk" '
        { name: $name, image: $image, tag: $tag, env: $env, onstart: "",
          runtype: "args",
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

      # Reconcile by name among MY templates: replace = delete existing + create. The
      # update (PUT) endpoint is broken server-side (returns "Invalid Creator ID" even
      # with the CLI's exact auth), and delete+create yields the same idempotent
      # end-state (templates only affect NEW instances, so replacing is safe). The
      # unfiltered /template/ list is the global public catalog, so filter by creator_id.
      myid="$(curl -fsS -H "Authorization: Bearer $apikey" "${api}/users/current/" 2>/dev/null | jq -r '.id // empty')"
      if [ -z "$myid" ]; then
        echo "vast-template-apply: could not resolve the Vast user id for reconcile." >&2
        exit 1
      fi
      list="$(curl -fsS -G -H "Authorization: Bearer $apikey" "${api}/template/" \
               --data-urlencode 'select_cols=["*"]' \
               --data-urlencode "select_filters={\"creator_id\":{\"eq\":$myid}}" 2>/dev/null || true)"
      existing_id="$(printf '%s' "$list" | jq -r --arg n "$name" '(.templates // []) | map(select(.name==$n)) | (.[0].id // empty)')"

      action="created"
      if [ -n "$existing_id" ]; then
        del="$(curl -fsS -X DELETE "${api}/template/" -H "Authorization: Bearer $apikey" \
                -H "Content-Type: application/json" --data "{\"template_id\":$existing_id}" 2>/dev/null || true)"
        if [ "$(printf '%s' "$del" | jq -r '.success // false' 2>/dev/null)" != true ]; then
          echo "vast-template-apply: failed to delete existing template $existing_id for replace — $(printf '%s' "$del" | jq -rc '{msg,error}' 2>/dev/null)" >&2
          exit 1
        fi
        action="replaced"
      fi
      resp="$(printf '%s' "$body" | curl -fsS -X POST "${api}/template/" \
               -H "Authorization: Bearer $apikey" -H "Content-Type: application/json" --data @- 2>/dev/null || true)"

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

  # Register the operator's SSH public key on the Vast account (idempotent). The
  # reproducible analog of a manual `vastai create ssh-key` — needed after a key
  # rotation / new machine / account reset. CAVEAT: Vast's auto-injection of account
  # SSH keys into instances is runtype=ssh ONLY; our runtype=args templates instead
  # plant the operator key via SSH_PUBKEY_B64 (provision.sh starts sshd). So this app
  # is for account registration, NOT the args SSH path.
  ssh-key-set = writeShellApplication {
    name = "vast-ssh-key-set";
    runtimeInputs = [
      curl
      jq
      coreutils
    ];
    text = ''
      security=/usr/bin/security
      account="$(id -un)"
      apikey="$("$security" find-generic-password -a "$account" -s VAST_API_KEY -w 2>/dev/null || true)"
      if [ -z "$apikey" ]; then
        echo "vast-ssh-key-set: VAST_API_KEY not in the login Keychain." >&2
        exit 1
      fi

      keyfile="$HOME/.ssh/id_ed25519.pub"
      while [ $# -gt 0 ]; do
        case "$1" in
          --key) keyfile="''${2:?}"; shift 2 ;;
          -h | --help) echo "usage: vast-ssh-key-set [--key PATH.pub]  (default ~/.ssh/id_ed25519.pub)"; exit 0 ;;
          *) echo "vast-ssh-key-set: unknown argument: $1" >&2; exit 1 ;;
        esac
      done
      [ -f "$keyfile" ] || { echo "vast-ssh-key-set: no public key at $keyfile" >&2; exit 1; }

      pub="$(cat "$keyfile")"
      body="$(cut -d' ' -f2 < "$keyfile")"   # key material, ignoring type + comment

      list="$(curl -fsS -H "Authorization: Bearer $apikey" "${api}/ssh/" 2>/dev/null || true)"
      if printf '%s' "$list" | jq -r '(if type=="array" then . else (.ssh_keys // .keys // []) end)[] | (.public_key // .ssh_key // .)' 2>/dev/null | grep -qF "$body"; then
        echo "vast-ssh-key-set: already registered ($(/usr/bin/ssh-keygen -lf "$keyfile" 2>/dev/null | awk '{print $2}'))."
        exit 0
      fi

      resp="$(jq -n --arg k "$pub" '{ssh_key: $k}' | curl -fsS -X POST "${api}/ssh/" \
               -H "Authorization: Bearer $apikey" -H "Content-Type: application/json" --data @- 2>/dev/null || true)"
      if [ "$(printf '%s' "$resp" | jq -r '.success // false' 2>/dev/null)" = true ]; then
        echo "vast-ssh-key-set: registered $keyfile on the Vast account."
      else
        echo "vast-ssh-key-set: FAILED — $(printf '%s' "$resp" | jq -rc '{success, msg, error}' 2>/dev/null || printf '%s' "$resp")" >&2
        exit 1
      fi
    '';
  };

  # Scaffold a new provisioner repo from the generic provisioner-template, on either
  # forge, public or private. The check is structural (not provenance), so this is a
  # convenience — a valid provisioner repo is just one containing provision.sh + the
  # marker. --template also flips is_template (GitHub only).
  init-repo = writeShellApplication {
    name = "vast-init-repo";
    runtimeInputs = [
      gh
      glab
      git
      coreutils
    ];
    text = ''
      security=/usr/bin/security
      account="$(id -un)"

      repo=""
      vis="--private"
      desc="Vast.ai provisioner repo (scaffolded from provisioner-template)"
      astemplate=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --repo) repo="''${2:?}"; shift 2 ;;
          --private) vis="--private"; shift ;;
          --public) vis="--public"; shift ;;
          --desc) desc="''${2:?}"; shift 2 ;;
          --template) astemplate=1; shift ;;
          -h | --help)
            echo "usage: vast-init-repo --repo [github:|gitlab:]owner/name [--public|--private] [--desc TEXT] [--template]"
            exit 0 ;;
          *) echo "vast-init-repo: unknown argument: $1" >&2; exit 1 ;;
        esac
      done
      [ -n "$repo" ] || { echo "vast-init-repo: --repo is required." >&2; exit 1; }

      host="github.com"
      case "$repo" in
        gitlab:*) host="gitlab.com"; repo="''${repo#gitlab:}" ;;
        github:*) host="github.com"; repo="''${repo#github:}" ;;
      esac

      # Seed a temp git repo with the baked scaffold files.
      tmp="$(mktemp -d)"
      trap 'rm -rf "$tmp"' EXIT
      cp ${./vast-templates/provisioner/provision.sh} "$tmp/provision.sh"
      cp ${./vast-templates/provisioner/.provisioner-template.json} "$tmp/.provisioner-template.json"
      cp ${./vast-templates/provisioner/README.md} "$tmp/README.md"
      chmod +x "$tmp/provision.sh"
      git -C "$tmp" init -q -b main
      git -C "$tmp" add -A
      git -C "$tmp" -c user.email="vast-init-repo@localhost" -c user.name="$account" \
        commit -q -m "Initialize from provisioner-template"

      case "$host" in
        github.com)
          ghtok="$("$security" find-generic-password -a "$account" -s GH_TOKEN -w 2>/dev/null || true)"
          [ -n "$ghtok" ] || { echo "vast-init-repo: GH_TOKEN not in Keychain." >&2; exit 1; }
          export GH_TOKEN="$ghtok"
          echo "vast-init-repo: creating github.com/$repo ($vis)"
          gh repo create "$repo" "$vis" --description "$desc"
          git -C "$tmp" remote add origin "https://github.com/$repo.git"
          # shellcheck disable=SC2016
          TOK="$ghtok" git -C "$tmp" -c credential.helper='!f(){ echo username=oauth2; echo "password=$TOK"; };f' \
            push -u origin main
          if [ -n "$astemplate" ]; then
            gh api -X PATCH "repos/$repo" -f is_template=true >/dev/null && echo "vast-init-repo: marked as template repository."
          fi
          echo "vast-init-repo: done -> https://github.com/$repo"
          ;;
        gitlab.com)
          gltok="$("$security" find-generic-password -a "$account" -s GITLAB_TOKEN -w 2>/dev/null || true)"
          [ -n "$gltok" ] || { echo "vast-init-repo: GITLAB_TOKEN not in Keychain." >&2; exit 1; }
          export GITLAB_TOKEN="$gltok"
          gvis="private"
          [ "$vis" = "--public" ] && gvis="public"
          echo "vast-init-repo: creating gitlab.com/$repo ($gvis)"
          glab repo create "$repo" "--$gvis" --description "$desc" >/dev/null
          git -C "$tmp" remote add origin "https://gitlab.com/$repo.git"
          # shellcheck disable=SC2016
          TOK="$gltok" git -C "$tmp" -c credential.helper='!f(){ echo username=oauth2; echo "password=$TOK"; };f' \
            push -u origin main
          [ -n "$astemplate" ] && echo "vast-init-repo: NOTE — GitLab has no per-repo template flag; use group custom project templates."
          echo "vast-init-repo: done -> https://gitlab.com/$repo"
          ;;
      esac
    '';
  };

  # Lint the committed instance-side scripts at `nix flake check` (served as raw
  # files / fetched at boot, so they can't be writeShellApplications).
  scripts-lint = runCommand "vast-scripts-lint" { nativeBuildInputs = [ shellcheck ]; } ''
    shellcheck \
      ${./vast-bootstrap.sh} \
      ${./vast-templates/provisioner/provision-lib.sh} \
      ${./vast-templates/provisioner/provision.sh}
    touch "$out"
  '';
in
{
  inherit
    template-apply
    repo-check
    account-vars-set
    ssh-key-set
    init-repo
    scripts-lint
    ;
}
