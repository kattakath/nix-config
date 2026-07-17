#!/usr/bin/env bash
# provision.sh — the CONSTANT entrypoint every provisioner repo exposes. Runs once
# on first boot on the vastai base image (via PROVISIONING_SCRIPT -> nix-config's
# bootstrap -> this script, with the cloned repo as CWD).
#
# It is intentionally stack-AGNOSTIC: put whatever your stack needs here — this file
# owns all the logic (ComfyUI, a training rig, an inference server, …). nix-config
# only clones the repo and runs this; it makes no assumption about what you install.
#
# Available at runtime:
#   - CWD = this cloned repo (reference your own config/workflow files relatively).
#   - Vast ACCOUNT env vars: HF_TOKEN, CIVITAI_TOKEN, GITLAB_TOKEN, GH_TOKEN, …
#     (set once on your Vast account; injected into every instance).
#   - The vastai base image: Caddy + Instance Portal, venv at /venv/main, persistent
#     /workspace. Install into /workspace for persistence.
set -euo pipefail

echo "provision: replace this stub with your stack's provisioning logic."
# Example scaffolding:
#   . /venv/main/bin/activate
#   pip install ...
#   curl -fL -H "Authorization: Bearer ${HF_TOKEN:-}" -o /workspace/models/... "https://huggingface.co/..."
