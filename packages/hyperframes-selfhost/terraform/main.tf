# DEPRECATED in the public export path.
# Terranix (infra/hyperframes/stack.nix) forges terraform/config.tf.json;
# `nix run .#hf-export` ships THAT file and excludes this main.tf so the two
# never collide. Prefer ../install.sh. Kept in the monorepo only as a readable
# HCL twin for local experiments — do not commit both into the public repo.
#
# Prefer ../install.sh for interactive first-time setup.

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

variable "stack_dir" {
  type        = string
  description = "Absolute path to the hyperframes-selfhost checkout (compose root)."
  default     = ".."
}

variable "external_url" {
  type        = string
  description = "Public HTTPS Funnel URL, e.g. https://hyperframes.tailnet.ts.net"
}

variable "google_client_id" {
  type      = string
  sensitive = true
}

variable "google_client_secret" {
  type      = string
  sensitive = true
}

variable "google_allowed_users" {
  type        = string
  description = "Comma-separated allowlisted emails"
}

variable "ts_authkey" {
  type      = string
  sensitive = true
}

variable "ts_hostname" {
  type    = string
  default = "hyperframes"
}

variable "workspace_dir" {
  type    = string
  default = "./workspace"
}

locals {
  root = abspath(var.stack_dir)
  env_content = <<-EOT
    TS_AUTHKEY=${var.ts_authkey}
    TS_HOSTNAME=${var.ts_hostname}
    EXTERNAL_URL=${var.external_url}
    GOOGLE_CLIENT_ID=${var.google_client_id}
    GOOGLE_CLIENT_SECRET=${var.google_client_secret}
    GOOGLE_ALLOWED_USERS=${var.google_allowed_users}
    WORKSPACE_DIR=${var.workspace_dir}
    CADDY_HTTP_PORT=8080
    MCP_LISTEN=:8090
  EOT
}

resource "local_sensitive_file" "env" {
  filename        = "${local.root}/.env"
  content         = local.env_content
  file_permission = "0600"
}

resource "null_resource" "workspace" {
  provisioner "local-exec" {
    command = "mkdir -p '${local.root}/${var.workspace_dir}'"
  }
}

resource "null_resource" "compose_up" {
  depends_on = [
    local_sensitive_file.env,
    null_resource.workspace,
  ]

  triggers = {
    env_sha = sha256(local.env_content)
  }

  provisioner "local-exec" {
    working_dir = local.root
    command     = "docker compose up -d --build"
  }
}

output "mcp_url" {
  value       = "${trimsuffix(var.external_url, "/")}/mcp"
  description = "MCP connector URL for Claude/Grok/Cursor"
}

output "oauth_redirect_uri" {
  value       = "${trimsuffix(var.external_url, "/")}/.auth/google/callback"
  description = "Register this as the Google OAuth Web client redirect URI"
}
