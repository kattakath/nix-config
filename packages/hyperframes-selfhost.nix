# packages/hyperframes-selfhost.nix — flake apps for the HyperFrames self-host stack.
#
# Public product repo: github.com/ismailkattakath/hyperframes-selfhost
# TF is forged here via Terranix (infra/hyperframes/stack.nix) and stamped into
# the export as terraform/config.tf.json only — no hand main.tf in the public tree.
{
  writeShellApplication,
  opentofu,
  rsync,
  coreutils,
  python3,
  # Injected from flake (not from pkgs):
  hfStackConfig, # path to terranix-rendered config.tf.json
  operatorEmail,
  hyperframesSelfhostSrc ? ./hyperframes-selfhost,
}:
let
  src = hyperframesSelfhostSrc;
in
{
  hf-export = writeShellApplication {
    name = "hf-export";
    runtimeInputs = [
      rsync
      coreutils
      python3
    ];
    text = ''
      set -euo pipefail
      dest="''${1:-}"
      if [ -z "$dest" ]; then
        echo "Usage: hf-export <destination-dir>" >&2
        echo "  Copies packages/hyperframes-selfhost for the public product repo," >&2
        echo "  stamps terranix terraform/config.tf.json (no hand-written main.tf)." >&2
        exit 1
      fi
      mkdir -p "$dest"
      rsync -a --delete \
        --exclude '.env' \
        --exclude 'workspace/' \
        --exclude '.terraform/' \
        --exclude '*.tfstate*' \
        --exclude 'terraform/main.tf' \
        --exclude 'terraform/terraform.tfvars.example' \
        --exclude 'terraform/*.tfstate*' \
        "${src}/" "$dest/"
      # Nix store paths are read-only; make the export writable before stamping.
      chmod -R u+w "$dest"
      mkdir -p "$dest/terraform"
      # Forge: Terranix JSON is the only TF entrypoint in the public tree.
      rm -f "$dest/terraform/main.tf" "$dest/terraform/terraform.tfvars.example"
      cp -f "${hfStackConfig}" "$dest/terraform/config.tf.json"
      python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$dest/terraform/config.tf.json"
      test -f "$dest/.env.example"
      test ! -f "$dest/.env"
      chmod +x "$dest/install.sh" "$dest/scripts/"*.sh "$dest/image/entrypoint.sh" 2>/dev/null || true
      cat >"$dest/EXPORT_META.txt" <<EOF
      Exported from kattakath/nix-config via nix run .#hf-export
      Public product: https://github.com/ismailkattakath/hyperframes-selfhost
      TF: terraform/config.tf.json (Terranix-forged; do not pair with main.tf)
      Primary install: ./install.sh (Docker; no Nix required)
      .env.example: yes | .env: never
      Upstream model: see UPSTREAM.md
      EOF
      echo "Exported HyperFrames self-host tree → $dest"
      echo "Includes .env.example; excludes .env and hand-written terraform/main.tf"
      echo "Next: push to ismailkattakath/hyperframes-selfhost (or ./install.sh on a VM)"
    '';
  };

  hf-apply = writeShellApplication {
    name = "hf-apply";
    runtimeInputs = [
      opentofu
      coreutils
    ];
    text = ''
      set -euo pipefail
      # Must run ON the Linux VM (or any host with Docker + the stack tree).
      stack_dir="''${HF_STACK_DIR:-}"
      if [ -z "$stack_dir" ]; then
        if [ -f ./docker-compose.yml ] && [ -f ./install.sh ]; then
          stack_dir="$PWD"
        else
          echo "ERROR: set HF_STACK_DIR to the hyperframes-selfhost tree," >&2
          echo "  or run from a directory that contains docker-compose.yml + install.sh." >&2
          exit 1
        fi
      fi
      stack_dir="$(cd "$stack_dir" && pwd)"

      : "''${TF_VAR_ts_authkey:?export TF_VAR_ts_authkey=…}"
      : "''${TF_VAR_google_client_id:?export TF_VAR_google_client_id=…}"
      : "''${TF_VAR_google_client_secret:?export TF_VAR_google_client_secret=…}"
      : "''${TF_VAR_external_url:?export TF_VAR_external_url=https://…ts.net}"
      export TF_VAR_stack_dir="$stack_dir"
      export TF_VAR_google_allowed_users="''${TF_VAR_google_allowed_users:-${operatorEmail}}"

      work="$(mktemp -d)"
      trap 'rm -rf "$work"' EXIT
      # Prefer already-exported JSON in the tree; fall back to flake-rendered config.
      if [ -f "$stack_dir/terraform/config.tf.json" ]; then
        cp "$stack_dir/terraform/config.tf.json" "$work/config.tf.json"
      else
        cp "${hfStackConfig}" "$work/config.tf.json"
      fi
      cd "$work"
      tofu init
      tofu apply -auto-approve

      echo "----- HyperFrames self-host applied -----"
      echo "MCP URL: $(tofu output -raw mcp_url)"
      echo "Google redirect URI: $(tofu output -raw oauth_redirect_uri)"
      echo "Doctor: (cd \"$stack_dir\" && ./scripts/doctor.sh)"
    '';
  };

  hf-doctor = writeShellApplication {
    name = "hf-doctor";
    runtimeInputs = [
      coreutils
      python3
    ];
    text = ''
      set -euo pipefail
      stack_dir="''${HF_STACK_DIR:-$PWD}"
      if [ ! -x "$stack_dir/scripts/doctor.sh" ]; then
        echo "ERROR: $stack_dir/scripts/doctor.sh not found. Export the tree first:" >&2
        echo "  nix run .#hf-export -- /tmp/hf && HF_STACK_DIR=/tmp/hf nix run .#hf-doctor" >&2
        exit 1
      fi
      exec "$stack_dir/scripts/doctor.sh"
    '';
  };

  hyperframes-selfhost-src = src;
}
