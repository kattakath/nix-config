# Vast.ai Template Provisioning — Design

Status: **design / not yet implemented.** A flake-based tool that provisions
[Vast.ai](https://vast.ai) GPU templates from this mono-repo. Driving use case: the
ComfyUI workflow repo (e.g.
`gitlab.com/ismailkattakath/comfyui-workflows`), passed in per-run as `--repo`.

> **Architecture note (revised):** an earlier draft baked private code into a custom
> Docker image. That is **dropped.** We use `PROVISIONING_SCRIPT` exclusively, and
> solve private repos with **Vast account-level environment variables** (below). No
> custom images, no registry auth.

## Goals & hard constraints

1. **`vastai/base-image` (or `vastai/pytorch`) exclusively** — they ship Caddy + the
   Instance Portal UI + auth-token protection (baked into the image, not the platform).
2. **`PROVISIONING_SCRIPT` is the sole customization path.** Its value is a **URL** the
   base image fetches on first boot (no local-path support), running as a late boot
   phase *after* Caddy/Portal are up.
3. **Target provisioning repos may be public OR private.**
4. **Declarative, reproducible, secrets never in git / the Nix store.**

## The key enabler — Vast account-level environment variables

Vast injects **account-scoped** env vars into every instance, and its docs steer
secrets there rather than into templates:

- *"You can set environment variables in your Account Settings that will automatically
  be injected into every container you launch."*
- *"Place any variables with sensitive values into the Environment Variables section of
  your account settings page. They will then be made available in any instance you
  create, regardless of the template used."*
- Danger notice: *"Never save a template as public if it contains sensitive information
  or secrets. Use the account level environment variables as an alternative."*

This dissolves the private-repo problem **without a custom image**:

- Secrets — `GITLAB_TOKEN`/`GH_TOKEN`, `HF_TOKEN`, `CIVITAI_TOKEN` — live as **account
  variables** (set once, server-side, never in a template).
- The **template stays secret-free** (could even be public) — it carries only the
  `PROVISIONING_SCRIPT` URL plus *non-secret* config.
- `PROVISIONING_SCRIPT` is still fetched **anonymously**, but the **private `git clone`
  happens inside the script**, authenticated by the account-injected token.

## Public vs private target repo

| Target repo | `PROVISIONING_SCRIPT` value | Token needed |
|---|---|---|
| **Public** | The repo's own raw script URL, **pinned to a commit SHA** | None |
| **Private** | A small **public** bootstrap script that clones the private repo | Yes — from an **account variable**, never in the template |

For the private case the bootstrap does, in shell (where `$GITLAB_TOKEN` expands
normally — which it can't in a bare URL baked into the template):

```sh
git clone --depth 1 "https://oauth2:${GITLAB_TOKEN}@gitlab.com/${PROVISION_REPO}.git" /provision
git -C /provision checkout "${PROVISION_REF}"          # pinned SHA
exec /provision/<entrypoint>.sh
```

`PROVISION_REPO` (`owner/repo`) and `PROVISION_REF` (SHA) are **non-secret** and passed
via the template `env`, **flake-injected** (this is the moving part the old manual
`STACK_REPO` boot var used to be — now the flake owns it, not the human). One generic
public bootstrap serves every private stack.

> **Bootstrap hosting — decided: this repo, SHA-pinned raw URL.** `nix-config` is
> public (`github.com/kattakath/nix-config`), so the bootstrap lives at
> `packages/vast/provision-bootstrap.sh` and the flake emits
> `PROVISIONING_SCRIPT=https://raw.githubusercontent.com/kattakath/nix-config/${self.rev}/packages/vast/provision-bootstrap.sh`
> — pinned to the flake's own commit (immutable, reproducible; requires provisioning
> from a *pushed* commit). Chosen over a gist / Cloudflare route: same declarative
> source, versioned, no extra repo or infra. Contains **no secrets**.

## Stack templates & the `provision.sh` contract

`vast-template-apply` is **stack-agnostic**: it only ever assumes the constant
entrypoint **`provision.sh`**, never its contents. `provision.sh` is **self-contained
and stack-authored** — it owns ALL the provisioning logic (ComfyUI, a training rig, an
inference server, …). This maps directly onto the Vast `PROVISIONING_SCRIPT` model:
nix-config clones the repo and runs `provision.sh`, making no assumption about what you
install. **Stack-specific logic (e.g. a ComfyUI engine + its config schema) lives in
YOUR repos, never in nix-config.**

The constant entrypoint + a legitimacy marker are guaranteed by **scaffolding repos
from a template**:

- nix-config ships a **generic** `provisioner-template`
  (`packages/vast-templates/provisioner/`): a `provision.sh` stub +
  `.provisioner-template.json` marker + README. Publish it as a template repo; new
  provisioner repos are generated from it — GitHub template repos (`is_template`; `POST
  /repos/{owner}/{repo}/generate`) or GitLab custom project templates (`POST /projects`
  + `use_custom_template` + `template_project_id`). Both support private.
- Build **stack-specific** templates (a ComfyUI one, etc.) *from* the generic one —
  that is where a ComfyUI engine / `provisioner-config.sh` schema belongs, in your
  template, not nix-config.

## Repo legitimacy check — `vast-repo-check`

Template **provenance is asymmetric** (GitHub records `template_repository` on the
single-repo GET; GitLab records nothing), so validation is **structural, not
provenance-based** — the only approach robust across both forges:

- Fetch **only** `.provisioner-template.json` at the target ref via the single-file API
  — GitHub Contents (`GET /repos/{o}/{r}/contents/{path}?ref=…`, `Accept:
  application/vnd.github.raw+json`) or GitLab (`GET
  /projects/:id/repository/files/:path/raw?ref=…`, `PRIVATE-TOKEN`) — using the
  read-only token. No clone.
- Validate: `schema` version, required-files list, and that `provision.sh` exists.
  **Refuse to apply** otherwise. On GitHub, *optionally* corroborate with
  `template_repository` — bonus only, never the sole check.
- Runs standalone **and** is auto-invoked by `vast-template-apply` before create/update
  (a prerequisite gate, like account vars).

## Secrets model

- **Delivery to instances:** Vast **account-level env vars** carry every token. Set once
  per Vast account. The template holds no secret.
- **Source of truth on the Mac:** login Keychain (`VAST_API_KEY`, `GITLAB_TOKEN`,
  `HF_TOKEN`, `CIVITAI_TOKEN`), read via
  `security find-generic-password -a "$(id -un)" -s <KEY> -w` (the `set-secret` pattern).
- **Untrusted-host reality (unchanged):** Vast GPU hosts are third parties; any token
  injected into an instance is visible to the host operator. Account variables keep the
  secret out of the *template blob*, **not** out of the *running container*. Mitigation
  is blast-radius, not concealment: use a **read-only GitLab token** (`read_repository`
  scope — a group/personal read token covers all private stacks, or per-project deploy
  tokens for tighter granularity). **Decided: long-lived**, held as the Vast account var
  `GITLAB_TOKEN`, rotated periodically. Never a write-scoped or full personal PAT.

- **Storing tokens on the Mac:** `set-secret <KEY> <value>` (Keychain) for `VAST_API_KEY`,
  `GITLAB_TOKEN`, `HF_TOKEN`, `CIVITAI_TOKEN`. The flake reads them from there and pushes
  them to Vast account vars (`vast-account-vars-set`, or a one-time UI paste).

## Model weights (~24 GB)

With no custom image, weights were never baked — they arrive at boot via the
provisioning script. Two transports:

1. **Direct from HuggingFace / Civitai (decided)** using the account-injected
   `HF_TOKEN` / `CIVITAI_TOKEN`. Authentication is what raises rate limits and unlocks
   gated assets, so downloads must use them in the expected way:
   - **`HF_TOKEN`** — HF tooling (`hf` / `huggingface_hub`) reads it automatically and
     sends `Authorization: Bearer`; required for gated repos, higher rate limit.
   - **`CIVITAI_TOKEN`** — appended to the download URL as `?token=<key>` (or
     `Authorization: Bearer`); required for many models, avoids anonymous throttling.
2. *(Later optimization)* stage once in Backblaze B2, pull at boot via `rclone` —
   cheaper/faster/cross-host; deferred.

Verified storage facts that bound this (no free lunch on the 24 GB):

- **Volumes are host-locked** ("local volumes only… tied to the machine it was created
  on"), survive destroy (~$0.1/GB/mo) — a same-machine "home base" cache only, not a
  cross-host fix.
- **Container disk** survives stop/start, wiped on **destroy** → fresh rental
  re-downloads.
- **Host caching is Docker *layers* only**; **no** caching of runtime-downloaded weights.
- **Cloud Sync** (`vastai cloud copy` / `vastai copy`; S3/B2/Dropbox) is first-class.
- **Bandwidth billed per byte** → one ~24 GB transfer per fresh host is unavoidable
  (only a host-locked Volume avoids it); the goal is a cheap/fast *source* (B2).

## The template the tool creates

Fields on the Vast template (`POST/PUT /api/v0/template/`):

- `name` — **required** (`--template-name`); the reconcile key.
- `image` + `tag` — `vastai/base-image:<pinned-tag>` (or `vastai/pytorch`).
- `env` — `PROVISIONING_SCRIPT=<url>` plus **non-secret** config (`PROVISION_REPO`,
  `PROVISION_REF`, model target dir). **No secrets** — those are account variables.
- `recommended_disk_space` — sized for the weights (~32–64 GB).
- `runtype = ssh` (Portal + SSH); `private = true`.
- **No `docker_login_*`** — no private image anymore.

### Reconcile (idempotency)

No upsert exists and `hash_id` changes with content, so reconcile **by name**:
`GET /api/v0/template/` filtered on `name` → operator-owned match ⇒ `PUT` (full blob;
CLI-style update is a full replace) else `POST`.

## Proposed flake app surface (darwin-gated `writeShellApplication`, `curl`+`jq`)

- `vast-template-apply` — reconcile (create/update) the template by name via REST.
  `--template-name` required; assembles `PROVISIONING_SCRIPT` + non-secret env from the
  target repo ref (public → raw URL; private → bootstrap URL + `PROVISION_REPO/REF`).
- `vast-account-vars-set` — push the Keychain tokens into Vast **account-level env
  vars** (via API if one exists; else print the exact values to paste once). One-time-ish.
- `vast-weights-stage` *(optional)* — download the stack's `MODEL_MAP` weights and
  upload to B2.
- *(later)* `vast-template-destroy` — unlink (Vast delete is unlink, not hard-destroy).

Wired via `genAttrs darwinSystems` in `packages` (shellcheck in `nix flake check`) with
static `aarch64-darwin.<name>` `apps` entries — mirroring `set-secret` /
`nixpi-provision`. **No image build** — dropped.

## To verify on first run (docs did not confirm)

1. **Account vars are present in the `PROVISIONING_SCRIPT` env at boot.** Logically yes
   (injected as container env; the script runs in the container), but not stated
   explicitly — validate with a trivial `env | grep` provisioning run.
2. **Precedence** between account vars and template `env` (which wins on collision).
3. ~~Whether Vast exposes an API to set account-level env vars~~ — **yes:**
   `POST`/`PUT /api/v0/secrets/` (`{key,value}`; CLI `vastai update env-var`); `GET
   /api/v0/secrets/` lists them as a `{KEY: VALUE}` map with **values masked** (8-char
   placeholder). `vast-account-vars-set` can be fully API-driven. (The account's
   `GITLAB_TOKEN`/`HF_TOKEN`/`CIVITAI_TOKEN`/`GH_TOKEN` were set this way from the
   read-only `VAST_*` Keychain entries.)

## Decisions (settled)

1. **Bootstrap hosting** — this public repo, SHA-pinned raw URL (`self.rev`). ✓
2. **Git token** — long-lived read-only (`read_repository`) `GITLAB_TOKEN` in Vast
   account settings. ✓
3. **Weights transport** — direct HF/Civitai, authenticated via `HF_TOKEN` /
   `CIVITAI_TOKEN`; B2 deferred. ✓
4. **Mode selection** — auto-select simple (raw URL for public, bootstrap for private,
   chosen by probing repo visibility). ✓

Still to pin during implementation: the account-var *set* path (API vs. manual paste)
and the three boot-time unknowns above.

## References

- `packages/set-secret.nix`, `packages/nixpi-provision.nix` — Keychain-read + flake-app
  patterns to mirror.
- Vast docs: instances/docker-environment#user-account-variables,
  templates/template-settings#docker-repository-and-environment,
  templates/advanced-setup, instances/storage/{volumes,types,data-movement}.
