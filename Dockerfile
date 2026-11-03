# syntax=docker/dockerfile:1.7
# Pi coding agent + REA + Chrome DevTools MCP + superpowers, for a local LLM.
# The model server runs on the host (GPU stays on the host); this image only
# contains the agent harness, its tools and a headless Chromium.

FROM debian:trixie-slim

ARG NODE_VERSION=24.22.2
ARG PI_VERSION=1.5.0
ARG REA_VERSION=6.8.0
ARG CHROME_DEVTOOLS_MCP_VERSION=1.12.0
# obra/superpowers v7.0.1
ARG SUPERPOWERS_REF=2ce8aa15d05bd57213e6f746f953aafb7ded7a8b
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

# procps: REA's process supervisor needs a procps-compatible `ps` on Linux.
# gettext-base: envsubst for config rendering. chromium: shared headless browser.
# ripgrep, fd-find: Pi's search tools; PI_OFFLINE stops it downloading its own.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg procps jq gettext-base tmux less \
      xz-utils unzip python3 ripgrep fd-find \
      chromium fonts-liberation fonts-noto-color-emoji \
 && ln -s /usr/bin/fdfind /usr/local/bin/fd \
 && rm -rf /var/lib/apt/lists/*

# Node from the official tarball (Debian's nodejs is too old for rea-agents,
# which requires ^22.23.4 || ^24.22.1).
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) arch=x64 ;; \
      arm64) arch=arm64 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${arch}.tar.xz" \
      | tar -xJ -C /usr/local --strip-components=1 \
            --exclude='*/CHANGELOG.md' --exclude='*/README.md' --exclude='*/LICENSE'; \
    node --version; npm --version

RUN npm install -g --ignore-scripts --no-audit --no-fund \
      "@earendil-works/pi-coding-agent@${PI_VERSION}" \
      "rea-agents@${REA_VERSION}" \
      "chrome-devtools-mcp@${CHROME_DEVTOOLS_MCP_VERSION}" \
 && npm cache clean --force \
 && pi --version && rea --version && chrome-devtools-mcp --version

RUN useradd -m -u 1000 -s /bin/bash agent \
 && mkdir -p /data /workspace /opt/seed \
 && chown -R agent:agent /data /workspace /opt/seed

COPY --chown=agent:agent docker/ /docker/
RUN chmod +x /docker/*.sh

USER agent
ENV HOME=/home/agent \
    PI_OFFLINE=1 \
    PI_SKIP_VERSION_CHECK=1 \
    PI_TELEMETRY=0 \
    CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS=1 \
    CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS=1 \
    SUPERPOWERS_REF=${SUPERPOWERS_REF}

# Build-time seed of the Pi agent directory. On first boot the entrypoint
# copies /opt/seed into the persistent /data volume.
#  - superpowers is installed as a Pi package (pinned to a commit)
#  - `rea setup --client pi` installs REA's skill under ~/.agents/skills and
#    registers the MCP server; the registration is re-rendered from our
#    template at runtime so the env-driven settings apply.
RUN set -eux; \
    export HOME=/opt/seed/home PI_CODING_AGENT_DIR=/opt/seed/pi; \
    mkdir -p "$HOME" "$PI_CODING_AGENT_DIR"; \
    pi install "git:github.com/obra/superpowers@${SUPERPOWERS_REF}"; \
    rea setup --client pi --yes --json > /opt/seed/rea-setup.json; \
    test -f /opt/seed/home/.agents/skills/reverse-engineer-anything/SKILL.md; \
    test -d /opt/seed/pi/git/github.com/obra/superpowers/skills; \
    cp /docker/seed/pi/APPEND_SYSTEM.md /opt/seed/pi/

ENV PI_CODING_AGENT_DIR=/data/pi \
    PI_PACKAGE_DIR=/data/pi/npm \
    TERM=xterm-256color \
    COLORTERM=truecolor

WORKDIR /workspace
ENTRYPOINT ["/docker/entrypoint.sh"]
