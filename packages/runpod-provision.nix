# packages/runpod-provision.nix — RunPod GPU pod-template provisioning (control plane,
# the RunPod analogue of the Vast vast-* apps). `runpod-template-apply` creates/replaces a
# RunPod POD template for a ComfyUI workflow on the official runpod/comfyui image
# (runpod-workers/comfyui-base). Because that image has NO Vast-style provisioning hook, the
# template overrides dockerEntrypoint + dockerStartCmd: a tiny wrapper git-clones the
# comfyui-workflows repo (private, via GITLAB_TOKEN) and exec's the workflow's
# runpod/provision.sh, which provisions (nodes+models+sha) then hands off to the image's
# /start.sh. Secrets are RunPod ACCOUNT secrets referenced as {{ RUNPOD_SECRET_name }} —
# never baked into the template. Convention: template name == workflow name.
{
  writeShellApplication,
  curl,
  jq,
  coreutils,
}:
let
  api = "https://rest.runpod.io/v1";
in
{
  template-apply = writeShellApplication {
    name = "runpod-template-apply";
    runtimeInputs = [
      curl
      jq
      coreutils
    ];
    text = ''
      security=/usr/bin/security
      account="$(id -un)"
      apikey="$("$security" find-generic-password -a "$account" -s RUNPOD_API_KEY -w 2>/dev/null || true)"
      [ -n "$apikey" ] || { echo "runpod-template-apply: RUNPOD_API_KEY not in the login Keychain." >&2; exit 1; }

      wfname=""
      repo="gitlab.com/ismailkattakath/comfyui-workflows"
      image="runpod/comfyui:cuda12.8"
      cdisk="30"
      vdisk="80"
      dryrun=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --workflow-name) wfname="''${2:?}"; shift 2 ;;
          --repo) repo="''${2:?}"; shift 2 ;;
          --image) image="''${2:?}"; shift 2 ;;
          --container-disk) cdisk="''${2:?}"; shift 2 ;;
          --volume-disk) vdisk="''${2:?}"; shift 2 ;;
          --dry-run) dryrun=1; shift ;;
          -h | --help)
            echo "usage: runpod-template-apply --workflow-name NAME \\"
            echo "         [--repo host/owner/repo] [--image IMG] [--container-disk GB] [--volume-disk GB] [--dry-run]"
            echo "Creates a RunPod POD template (name == workflow name) on runpod/comfyui, provisioned at boot"
            echo "from the private comfyui-workflows repo. Needs RunPod account secrets: gitlab_token, hf_token, civitai_token."
            exit 0 ;;
          *) echo "runpod-template-apply: unknown argument: $1" >&2; exit 1 ;;
        esac
      done
      [ -n "$wfname" ] || { echo "runpod-template-apply: --workflow-name is required." >&2; exit 1; }

      pubkey="$(cat "$HOME/.ssh/id_ed25519.pub" 2>/dev/null || true)"
      [ -n "$pubkey" ] || { echo "runpod-template-apply: ~/.ssh/id_ed25519.pub not found — cannot set PUBLIC_KEY." >&2; exit 1; }

      # dockerStartCmd wrapper (runs in the POD): clone the workflow repo with GITLAB_TOKEN
      # (a RunPod secret, expanded at pod launch) then exec the workflow's runpod/provision.sh.
      # $repo/$wfname are baked here; ''${GITLAB_TOKEN} is DELIBERATELY kept literal (single
      # quotes) so the POD — not this app — expands it at launch. Hence SC2016 is expected.
      # shellcheck disable=SC2016
      wrapper="$(printf 'set -e; export GIT_TERMINAL_PROMPT=0; rm -rf /tmp/prov; git clone --depth=1 "https://oauth2:''${GITLAB_TOKEN}@%s.git" /tmp/prov; exec bash "/tmp/prov/workflows/%s/runpod/provision.sh"' "$repo" "$wfname")"

      body="$(jq -n \
        --arg name "$wfname" --arg image "$image" --arg pubkey "$pubkey" \
        --arg wfname "$wfname" --arg repo "$repo" --arg wrapper "$wrapper" \
        --argjson cdisk "$cdisk" --argjson vdisk "$vdisk" '
        {
          name: $name,
          imageName: $image,
          category: "NVIDIA",
          isPublic: false,
          isServerless: false,
          containerDiskInGb: $cdisk,
          volumeInGb: $vdisk,
          volumeMountPath: "/workspace",
          ports: [ "8188/http", "8888/http", "8080/http", "22/tcp" ],
          env: {
            PUBLIC_KEY: $pubkey,
            WORKFLOW_NAME: $wfname,
            WORKFLOW_REPO: $repo,
            GITLAB_TOKEN: "{{ RUNPOD_SECRET_gitlab_token }}",
            HF_TOKEN: "{{ RUNPOD_SECRET_hf_token }}",
            CIVITAI_TOKEN: "{{ RUNPOD_SECRET_civitai_token }}"
          },
          dockerEntrypoint: [ "/bin/bash", "-c" ],
          dockerStartCmd: [ $wrapper ],
          readme: ("# " + $name + "\n\nComfyUI workflow provisioned at boot on runpod/comfyui from " + $repo + ".")
        }')"

      if [ -n "$dryrun" ]; then
        echo "runpod-template-apply: DRY RUN — template '$wfname' body (secrets are RunPod refs):"
        printf '%s\n' "$body" | jq '.env.PUBLIC_KEY = "<ssh-key>"'
        exit 0
      fi

      # Reconcile by name: find an existing same-name template and delete it, then create.
      list="$(curl -fsS -H "Authorization: Bearer $apikey" "${api}/templates" 2>/dev/null || true)"
      existing_id="$(printf '%s' "$list" | jq -r --arg n "$wfname" '(if type=="array" then . else (.templates // .data // []) end) | map(select(.name==$n)) | (.[0].id // empty)' 2>/dev/null || true)"
      action="created"
      if [ -n "$existing_id" ]; then
        curl -fsS -X DELETE "${api}/templates/$existing_id" -H "Authorization: Bearer $apikey" >/dev/null 2>&1 || true
        action="replaced"
      fi

      resp="$(printf '%s' "$body" | curl -fsS -X POST "${api}/templates" \
               -H "Authorization: Bearer $apikey" -H "Content-Type: application/json" --data @- 2>&1 || true)"
      tid="$(printf '%s' "$resp" | jq -r '.id // empty' 2>/dev/null || true)"
      if [ -n "$tid" ]; then
        echo "runpod-template-apply: $action — template '$wfname' (id $tid) on $image."
        echo "runpod-template-apply: ensure RunPod account secrets exist: gitlab_token, hf_token, civitai_token."
      else
        echo "runpod-template-apply: FAILED — $(printf '%s' "$resp" | head -c 400)" >&2
        exit 1
      fi
    '';
  };
}
