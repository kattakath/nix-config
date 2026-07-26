# packages/hyperframes-selfhost.nix — flake apps for the HyperFrames self-host stack.
#
# Exports:
#   hf-export  — copy the public tree (+ optional rendered config.tf.json) to a dest
#   hf-apply   — on a Linux VM: tofu apply the terranix-rendered plan against the tree
#   hf-doctor  — thin wrapper around scripts/doctor.sh
#
# The public, non-Nix-friendly tree lives at packages/hyperframes-selfhost/.
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
    ];
    text = ''
      set -euo pipefail
      dest="''${1:-}"
      if [ -z "$dest" ]; then
        echo "Usage: hf-export <destination-dir>" >&2
        echo "  Copies packages/hyperframes-selfhost to <dest> and drops" >&2
        echo "  the terranix-rendered config.tf.json for OpenTofu users." >&2
        exit 1
      fi
      mkdir -p "$dest"
      rsync -a --delete \
        --exclude '.env' \
        --exclude 'workspace/' \
        --exclude '.terraform/' \
        --exclude '*.tfstate*' \
        "${src}/" "$dest/"
      # Nix store paths are read-only; make the export writable before stamping.
      chmod -R u+w "$dest"
      mkdir -p "$dest/terraform"
      cp -f "${hfStackConfig}" "$dest/terraform/config.tf.json"
      chmod +x "$dest/install.sh" "$dest/scripts/"*.sh "$dest/image/entrypoint.sh" 2>/dev/null || true
      cat >"$dest/EXPORT_META.txt" <<EOF
      Exported from kattakath/nix-config (terranix + public tree)
      operatorEmail default allowlist: ${operatorEmail}
      Stack: Funnel(VM) → Caddy → mcp-auth-proxy(Google) → Kinocut+HyperFrames
      Install: ./install.sh
      OpenTofu: cd terraform && tofu init && tofu apply
      EOF
      echo "Exported HyperFrames self-host tree → $dest"
      echo "Next: rsync/scp to the Linux VM, then ./install.sh"
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
        # Default: sibling of this script's flake-exported tree, or CWD if it looks right
        if [ -f ./docker-compose.yml ] && [ -f ./install.sh ]; then
          stack_dir="$PWD"
        else
          echo "ERROR: set HF_STACK_DIR to the hyperframes-selfhost tree," >&2
          echo "  or run from a directory that contains docker-compose.yml + install.sh." >&2
          echo "  Tip: nix run .#hf-export -- /tmp/hf && cd /tmp/hf && HF_STACK_DIR=\$PWD nix run .#hf-apply" >&2
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
      cp "${hfStackConfig}" "$work/config.tf.json"
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

  # Path to the public tree (for packaging / CI introspection).
  hyperframes-selfhost-src = src;
}
