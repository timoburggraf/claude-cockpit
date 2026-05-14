FROM node:20-bookworm-slim

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    LANGUAGE=C.UTF-8

ARG TTYD_VERSION=1.7.7

RUN apt-get update && apt-get install -y --no-install-recommends \
    tmux \
    git \
    openssh-client \
    curl \
    jq \
    ripgrep \
    procps \
    iproute2 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL \
    "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.aarch64" \
    -o /usr/local/bin/ttyd \
    && chmod +x /usr/local/bin/ttyd

RUN npm install -g @anthropic-ai/claude-code --no-update-notifier

RUN userdel -r node 2>/dev/null || true \
    && groupdel node 2>/dev/null || true \
    && groupadd -g 1000 cockpit \
    && useradd -u 1000 -g cockpit -m -s /bin/bash cockpit

COPY tmux.conf /etc/tmux.conf
COPY bin/claude-mode /usr/local/bin/claude-mode

RUN chmod 644 /etc/tmux.conf \
    && chmod 755 /usr/local/bin/claude-mode

COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
