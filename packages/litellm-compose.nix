# litellm-compose.nix — Nix-RENDERED docker-compose file for the LiteLLM proxy +
# dedicated cloudflared connector.
#
# This is the container-runtime sibling of the terranix Cloudflare provisioning
# in infra/cloudflare/litellm.nix. It replaces the old hand-written
# deploy/litellm/docker-compose.yml: the topology is now declared as a Nix attrset
# and serialized to YAML by `pkgs.formats.yaml`, so there is exactly ONE source of
# truth and the file can never drift from an editor hand-edit.
#
# Topology (extends the retired hand-written compose with Postgres for the
# Admin UI / SSO / virtual keys):
#   - service `litellm`     : image litellm:latest (built by packages/litellm-image.nix),
#                             env_file .env, restart unless-stopped, internal-only
#                             `litellm-net`, NO published host port, TCP healthcheck.
#                             DATABASE_URL + Google-SSO env come from .env; it waits
#                             for `postgres` to report healthy before starting.
#   - service `postgres`    : postgres:16-alpine, named volume `litellm-pgdata` for
#                             persistence, internal-only, NO published host port,
#                             pg_isready healthcheck. Backs the Admin UI, virtual
#                             keys, spend tracking, and SSO user table — all of which
#                             REQUIRE a database (LiteLLM `general_settings.database_url`).
#   - service `cloudflared` : cloudflare/cloudflared:latest, remotely-managed
#                             (token) tunnel, TUNNEL_TOKEN from env, same net.
#
# Build the file:   nix build .#packages.<system>.litellmCompose
# Then either:      docker compose -f result up -d
#           or:     cp result deploy/litellm/docker-compose.yml && docker compose up -d
#
# The generated file is arch-agnostic text; it is exposed for all systems via the
# flake's forAllSystems fold.
{ pkgs, ... }:
let
  # LiteLLM proxy config — nix-generated (NOT hand-written), mounted read-only
  # into the official image. Only `os.environ/VAR` placeholders; the real
  # OPENAI_API_KEY / LITELLM_MASTER_KEY / DATABASE_URL arrive from the runtime
  # env (.env). DATABASE_URL + master_key unlock the DB-backed Admin UI, virtual
  # keys, spend tracking and the SSO user table. Google-SSO vars are read by
  # LiteLLM straight from the process environment and need no config key.
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
      database_url = "os.environ/DATABASE_URL";
    };
  };
  # The compose file itself, serialized from the attrset below.
  composeFile = (pkgs.formats.yaml { }).generate "docker-compose.yml" {
    services = {
      litellm = {
        # OFFICIAL digest-pinned LiteLLM image (linux/arm64), NOT the nixpkgs-built
        # litellm image. WHY: the nixpkgs litellm closure ships no Prisma query
        # engines, so in DB mode (DATABASE_URL set, for the Admin UI / SSO / virtual
        # keys) it crash-loops at startup with
        #   "Unable to find Prisma binaries. Please run 'prisma generate' first."
        # The official ghcr.io/berriai/litellm-database image bundles Prisma + the
        # engines and runs `prisma migrate deploy` on boot. Pinned by the arm64
        # platform digest of tag main-stable (Docker Desktop here is aarch64);
        # multi-arch index digest for the same tag is
        #   sha256:6151ddc97c5dc4590740bd14646d78d48267d8b7a1bf398eeaffcd6729b8f0b9
        # The config.yaml is still nix-generated (see `configFile` above) and mounted
        # read-only, so there is no hand-written config drift.
        image = "ghcr.io/berriai/litellm-database@sha256:ade02ef3dc6db262df99781b7ee696d4a13c8fd443069f2d6f2f941a82f5427b";
        # Mount the nix-generated config by a RELATIVE path (resolved against the
        # compose project dir on the deploy host, which has no nix store). The
        # sibling `config.yaml` is materialized next to this compose from the same
        # `configFile` derivation at generation time, so it stays nix-authored.
        volumes = [ "./config.yaml:/etc/litellm/config.yaml:ro" ];
        command = [
          "--config"
          "/etc/litellm/config.yaml"
          "--host"
          "0.0.0.0"
          "--port"
          "4000"
        ];
        env_file = [ ".env" ];
        restart = "unless-stopped";
        # NO `ports:` — the tunnel is the only ingress. Do not publish 4000.
        networks = [ "litellm-net" ];
        # Admin UI + virtual keys + SSO all need the DB reachable first. Start only
        # once Postgres reports healthy (see the postgres healthcheck below).
        depends_on.postgres.condition = "service_healthy";
        # DATABASE_URL, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, PROXY_BASE_URL,
        # LITELLM_MASTER_KEY, ALLOWED_EMAIL_DOMAINS, (optional) PROXY_ADMIN_ID and
        # STORE_MODEL_IN_DB all arrive from the env_file (.env) — nothing sensitive
        # is inlined here. LiteLLM reads the Google-SSO vars straight from the
        # process environment; the baked config.yaml resolves os.environ/… refs.
        environment = {
          DATABASE_URL = "\${DATABASE_URL}";
          GOOGLE_CLIENT_ID = "\${GOOGLE_CLIENT_ID}";
          GOOGLE_CLIENT_SECRET = "\${GOOGLE_CLIENT_SECRET}";
          PROXY_BASE_URL = "\${PROXY_BASE_URL}";
          ALLOWED_EMAIL_DOMAINS = "\${ALLOWED_EMAIL_DOMAINS}";
          # Optional: set to the SSO user_id to promote the first admin; blank is fine.
          PROXY_ADMIN_ID = "\${PROXY_ADMIN_ID:-}";
          # Persist UI-added models to the DB (survives restarts) rather than only
          # the baked config.yaml. Optional; defaults on here.
          STORE_MODEL_IN_DB = "\${STORE_MODEL_IN_DB:-True}";
        };
        healthcheck = {
          # The nix-built image is BASELESS (no curl/wget/sh on PATH, only the
          # litellm closure), so we probe with a bare TCP connect via python3
          # (present in the closure) rather than an HTTP client.
          test = [
            "CMD-SHELL"
            "python3 -c \"import socket; s=socket.create_connection(('127.0.0.1',4000),3); s.close()\" || exit 1"
          ];
          interval = "30s";
          timeout = "5s";
          retries = 5;
          start_period = "20s";
        };
      };

      # Postgres backing the Admin UI, virtual keys, spend tracking and the SSO
      # user table. Internal-only (no published host port); the litellm service
      # reaches it by docker-DNS name `postgres` inside litellm-net. Credentials
      # (POSTGRES_DB/USER/PASSWORD) come from .env — never inlined.
      postgres = {
        image = "postgres:16-alpine";
        restart = "unless-stopped";
        networks = [ "litellm-net" ];
        environment = {
          POSTGRES_DB = "\${POSTGRES_DB}";
          POSTGRES_USER = "\${POSTGRES_USER}";
          POSTGRES_PASSWORD = "\${POSTGRES_PASSWORD}";
        };
        volumes = [ "litellm-pgdata:/var/lib/postgresql/data" ];
        healthcheck = {
          # pg_isready ships in the postgres image; gate litellm's start on it.
          test = [
            "CMD-SHELL"
            "pg_isready -U \"\${POSTGRES_USER}\" -d \"\${POSTGRES_DB}\""
          ];
          interval = "10s";
          timeout = "5s";
          retries = 5;
          start_period = "10s";
        };
      };

      cloudflared = {
        image = "cloudflare/cloudflared:latest";
        command = "tunnel --no-autoupdate run";
        # Remotely-managed (token) tunnel — ingress config lives in the Cloudflare
        # account (provisioned by infra/cloudflare/litellm.nix via terranix), NOT in
        # a local config file. TUNNEL_TOKEN is the connector token, from ./.env.
        environment = {
          TUNNEL_TOKEN = "\${TUNNEL_TOKEN}";
        };
        restart = "unless-stopped";
        depends_on = [ "litellm" ];
        # Same network as litellm, so the account-side ingress `service` URL is the
        # docker-DNS name http://litellm:4000 (resolved inside this namespace).
        networks = [ "litellm-net" ];
      };
    };

    networks.litellm-net.driver = "bridge";

    # Named volume for Postgres data persistence (survives `docker compose down`;
    # removed only by `docker compose down -v`).
    volumes.litellm-pgdata = { };
  };
in
# Emit a directory holding BOTH the compose file and the nix-generated config.yaml
# side by side, so a single copy onto the deploy host lands the compose plus the
# `./config.yaml` its litellm service mounts by relative path (the host has no nix
# store, so an absolute store-path mount would not resolve there).
#
# Deploy:  nix build .#packages.<system>.litellmCompose
#          cp -f result/docker-compose.yml result/config.yaml deploy/litellm/
#          (cd deploy/litellm && docker compose up -d)
pkgs.runCommand "litellm-compose" { } ''
  mkdir -p "$out"
  cp ${composeFile} "$out/docker-compose.yml"
  cp ${configFile} "$out/config.yaml"
''
