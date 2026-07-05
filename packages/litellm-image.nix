# LiteLLM proxy as a minimal, baseless container image — mirrors
# packages/docker-image.nix. There is no Debian/Alpine layer; the image is
# exactly the closure of litellm + the CA bundle, built reproducibly by Nix.
#
#   nix build .#packages.x86_64-linux.litellmImage
#   docker load < result
#   docker run --rm -p 4000:4000 \
#     -e OPENAI_API_KEY=sk-… -e LITELLM_MASTER_KEY=sk-… \
#     -e DATABASE_URL=postgresql://… litellm:latest
#
# For the Admin UI + Google SSO + virtual keys, run it via the compose file
# (packages/litellm-compose.nix) which also brings up the backing Postgres and
# supplies GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET / PROXY_BASE_URL /
# ALLOWED_EMAIL_DOMAINS from deploy/litellm/.env. See deploy/litellm/README.md.
#
# SECRETS AT RUNTIME ONLY: the baked config.yaml references keys via
# `os.environ/VAR` placeholders; the real values are supplied at `docker run`
# time with `-e OPENAI_API_KEY=…` / `-e LITELLM_MASTER_KEY=…` and are NEVER
# baked into an image layer (image layers, like the store, are not a secret store).
{
  pkgs,
  lib ? pkgs.lib,
  ...
}:

let
  # Top-level `pkgs.litellm` (a toPythonApplication wrapper), NOT
  # `python3Packages.litellm` — the latter is the bare library and omits the
  # proxy/extra_proxy extras, so `litellm --config …` would crash at runtime with
  # an ImportError. The wrapper bundles those extras and keeps the `litellm` bin.
  inherit (pkgs) litellm;

  # Default proxy config baked into the image. Only `os.environ/VAR`
  # placeholders — the actual OPENAI_API_KEY / LITELLM_MASTER_KEY / DATABASE_URL
  # arrive from the container's runtime environment (see the `docker run -e …`
  # invocation above, or the compose env_file).
  #
  # DATABASE_URL + master_key together unlock the Admin UI, virtual keys, spend
  # tracking and the SSO user table (all require a DB). The Google-SSO env vars
  # (GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET / PROXY_BASE_URL /
  # ALLOWED_EMAIL_DOMAINS / PROXY_ADMIN_ID) are read by LiteLLM directly from the
  # process environment — they need NO config.yaml key, so they stay entirely in
  # the runtime env and never touch this store-baked file.
  configFile = (pkgs.formats.yaml { }).generate "litellm-config.yaml" {
    model_list = [
      {
        model_name = "gpt-4o";
        litellm_params = {
          model = "openai/gpt-4o";
          api_key = "os.environ/OPENAI_API_KEY";
        };
      }
    ];
    general_settings = {
      master_key = "os.environ/LITELLM_MASTER_KEY";
      # Enables the DB-backed Admin UI + virtual keys. Resolved at runtime from
      # the env (a Postgres URL with embedded creds — never a store literal).
      database_url = "os.environ/DATABASE_URL";
    };
  };
in
pkgs.dockerTools.buildImage {
  name = "litellm";
  tag = "latest";

  # No `fromImage` → no base OS. The image is exactly the copied closures.
  copyToRoot = pkgs.buildEnv {
    name = "image-root";
    paths = [
      litellm
      pkgs.cacert
    ];
    pathsToLink = [
      "/bin"
      "/etc"
    ];
  };

  config = {
    Cmd = [
      "${lib.getExe' litellm "litellm"}"
      "--config"
      "${configFile}"
      "--host"
      "0.0.0.0"
      "--port"
      "4000"
    ];
    ExposedPorts = {
      "4000/tcp" = { };
    };
    Env = [
      "PATH=/bin"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
    ];
    WorkingDir = "/";
  };
}
