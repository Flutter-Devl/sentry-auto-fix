# Sentry Auto-Fix worker (Ubuntu + Flutter + Cursor Agent CLI + CodeGuardian)
#
# Build:
#   docker build -t sentry-autofix .
#
# Run once:
#   docker compose run --rm autofix once
#
# Daemon (poll forever):
#   docker compose up -d
#
# See docs/DOCKER.md

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    HOME=/home/autofix \
    PATH="/home/autofix/.local/bin:/opt/flutter/bin:/home/autofix/.pub-cache/bin:${PATH}" \
    FLUTTER_HOME=/opt/flutter \
    PUB_CACHE=/home/autofix/.pub-cache \
    # Avoid LaunchAgent on Linux/container
    AUTO_INSTALL_LAUNCHAGENT=false \
    CURSOR_BIN=/usr/local/bin/cursor

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      unzip \
      xz-utils \
      zip \
      python3 \
      python3-venv \
      python3-pip \
      openssh-client \
      bash \
      sudo \
      libglu1-mesa \
    && rm -rf /var/lib/apt/lists/*

# Non-root user (matches typical server practice)
RUN useradd -m -u 10001 -s /bin/bash autofix \
    && mkdir -p /opt/flutter /workspace /toolkit \
    && chown -R autofix:autofix /opt /workspace /toolkit

USER autofix
WORKDIR /home/autofix

# Flutter stable (for flutter test + Dart / CodeGuardian)
ARG FLUTTER_VERSION=stable
RUN git clone https://github.com/flutter/flutter.git -b "${FLUTTER_VERSION}" --depth 1 /opt/flutter \
    && /opt/flutter/bin/flutter config --no-analytics \
    && /opt/flutter/bin/flutter precache --no-android --no-ios \
    && /opt/flutter/bin/dart --disable-analytics \
    && /opt/flutter/bin/dart pub global activate melos

# Cursor Agent CLI (headless — auth via CURSOR_API_KEY at runtime)
RUN curl -fsS https://cursor.com/install | bash \
    && test -x /home/autofix/.local/bin/agent \
    && /home/autofix/.local/bin/agent --version || true

USER root
# run.sh expects: "$CURSOR_BIN" agent …  — map that to the installed `agent` binary
RUN printf '%s\n' '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      'AGENT_BIN="${HOME}/.local/bin/agent"' \
      'if [[ ! -x "$AGENT_BIN" ]]; then AGENT_BIN="$(command -v agent || true)"; fi' \
      'if [[ -z "${AGENT_BIN}" || ! -x "$AGENT_BIN" ]]; then' \
      '  echo "Cursor agent CLI not found (install failed or PATH issue)" >&2' \
      '  exit 127' \
      'fi' \
      'if [[ "${1:-}" == "agent" ]]; then shift; fi' \
      'exec "$AGENT_BIN" "$@"' \
    > /usr/local/bin/cursor \
    && chmod 755 /usr/local/bin/cursor

# Toolkit source
COPY --chown=autofix:autofix . /toolkit
WORKDIR /toolkit

USER autofix

# Python deps + Melos bootstrap for vendored CodeGuardian
RUN python3 -m venv /toolkit/.venv \
    && /toolkit/.venv/bin/pip install --no-cache-dir -r /toolkit/requirements.txt \
    && cd /toolkit/vendor/codeguardian \
    && dart pub get \
    && melos bootstrap \
    && chmod +x /toolkit/run.sh /toolkit/setup.sh /toolkit/vendor/codeguardian/bin/codeguardian.sh \
    && /toolkit/vendor/codeguardian/bin/codeguardian.sh --help >/dev/null

COPY --chown=autofix:autofix docker/entrypoint.sh /toolkit/docker/entrypoint.sh
USER root
RUN chmod +x /toolkit/docker/entrypoint.sh
USER autofix

VOLUME ["/workspace", "/toolkit/.state", "/toolkit/logs"]

ENTRYPOINT ["/toolkit/docker/entrypoint.sh"]
# Default: poll forever (systemd/compose restartPolicy handles crashes)
CMD ["daemon"]
