FROM debian:bookworm-slim

ARG UID=1000
ARG GID=1000

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    bash \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://claude.ai/install.sh | bash -s latest

RUN cp /root/.local/bin/claude /usr/local/bin/claude \
    && chmod 755 /usr/local/bin/claude

RUN if [ -d /root/.local/share/claude ]; then \
      mkdir -p /usr/local/share \
      && cp -a /root/.local/share/claude /usr/local/share/; \
    fi

RUN set -e; \
    if getent group "${GID}" >/dev/null 2>&1; then \
      grp="$(getent group "${GID}" | cut -d: -f1)"; \
    else \
      groupadd -g "${GID}" claude; \
      grp=claude; \
    fi; \
    useradd --create-home --home-dir /home/claude -u "${UID}" -g "${grp}" claude

WORKDIR /workspace

USER claude
ENV HOME=/home/claude

ENTRYPOINT ["claude"]
