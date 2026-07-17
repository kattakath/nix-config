# provisioner-template

Canonical **generic** template for Vast.ai provisioner-script repos consumed by the
flake-based Vast.ai template provisioner (`nix-config`). Create a new provisioner
repo **from this template** (GitHub "Use this template" / GitLab custom project
template); it inherits the constant `provision.sh` entrypoint and the marker that
`vast-repo-check` validates.

It is **stack-agnostic** — `nix-config` clones your repo and runs `provision.sh`,
making no assumption about what you provision. Build a stack-specific template (e.g.
a ComfyUI one, with its own engine/config schema) *from* this generic one; those
specifics live in your repos, never in `nix-config`.

## Files

- **`provision.sh`** — the constant entrypoint. Put ALL your stack logic here (or have
  it fetch/source whatever you like). Runs on first boot with the cloned repo as CWD;
  Vast account env vars (`HF_TOKEN`, `CIVITAI_TOKEN`, `GITLAB_TOKEN`, `GH_TOKEN`) are
  available. See its header.
- **`.provisioner-template.json`** — the marker `vast-repo-check` validates (schema
  version + required files) before `vast-template-apply` will provision. Keep it.

## How it runs

Vast template `PROVISIONING_SCRIPT` → `nix-config`'s bootstrap clones this repo
(private repos authenticate with a `GITLAB_TOKEN`/`GH_TOKEN` Vast account var) → runs
`provision.sh`. See `docs/vastai-template-provisioning.md` in nix-config.
