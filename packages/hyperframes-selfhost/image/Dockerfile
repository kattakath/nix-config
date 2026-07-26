# Single image: mcp-auth-proxy (OAuth 2.1) + Kinocut (kino) + HyperFrames CLI.
# aarch64/amd64 multi-arch friendly (Debian bookworm base).

FROM node:22-bookworm-slim AS hyperframes-cli
# Official HyperFrames CLI (npm). Renderer deps (Chromium) pull at first render if needed.
RUN npm install -g hyperframes@latest \
  && command -v hyperframes \
  && (hyperframes --help >/dev/null 2>&1 || true)

FROM python:3.12-slim-bookworm

ARG MCP_AUTH_PROXY_VERSION=v2.10.2
ARG TARGETARCH

# ffmpeg + Chromium runtime libs (HyperFrames headless render) + tooling
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    ffmpeg \
    fonts-liberation \
    fonts-noto-color-emoji \
    git \
    gnupg \
    libasound2 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libcups2 \
    libdbus-1-3 \
    libdrm2 \
    libgbm1 \
    libgtk-3-0 \
    libnspr4 \
    libnss3 \
    libx11-xcb1 \
    libxcomposite1 \
    libxdamage1 \
    libxrandr2 \
    wget \
    xdg-utils \
    xz-utils \
  && rm -rf /var/lib/apt/lists/*

# Node 22 runtime + HyperFrames CLI from the builder stage
COPY --from=hyperframes-cli /usr/local /usr/local

# Kinocut (MCP video surface + HyperFrames tools)
RUN pip install --no-cache-dir "kinocut[image]==1.11.1"

# mcp-auth-proxy static binary (release assets are plain binaries, not archives)
RUN set -eux; \
  arch="${TARGETARCH:-amd64}"; \
  case "$arch" in \
    amd64|x86_64) asset_arch=amd64 ;; \
    arm64|aarch64) asset_arch=arm64 ;; \
    *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
  esac; \
  url="https://github.com/sigbit/mcp-auth-proxy/releases/download/${MCP_AUTH_PROXY_VERSION}/mcp-auth-proxy-linux-${asset_arch}"; \
  curl -fsSL "$url" -o /usr/local/bin/mcp-auth-proxy; \
  chmod 0755 /usr/local/bin/mcp-auth-proxy; \
  mcp-auth-proxy --help >/dev/null


RUN useradd --create-home --shell /usr/sbin/nologin --uid 10001 app \
  && mkdir -p /data /workspace \
  && chown -R app:app /data /workspace /home/app

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER app
WORKDIR /workspace
ENV HOME=/home/app \
    DATA_PATH=/data \
    MCP_VIDEO_ANALYTICS=0 \
    MCP_VIDEO_HYPERFRAMES_COMMAND=hyperframes \
    PATH="/usr/local/bin:${PATH}"

EXPOSE 8090
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
