# Download pre-built gog binary
FROM alpine:latest AS gog-build
RUN apk add --no-cache curl tar
RUN curl -L -o /tmp/gogcli.tar.gz https://github.com/steipete/gogcli/releases/download/v0.11.0/gogcli_0.11.0_linux_amd64.tar.gz \
 && tar -xzf /tmp/gogcli.tar.gz -C /tmp \
 && mv /tmp/gog /usr/local/bin/gog \
 && chmod +x /usr/local/bin/gog

# Build OpenClaw from source
FROM node:22-bookworm AS openclaw-build

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    python3 \
    make \
    g++ \
 && rm -rf /var/lib/apt/lists/*

COPY --from=gog-build /usr/local/bin/gog /usr/local/bin/gog

RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable && corepack prepare pnpm@10.23.0 --activate

WORKDIR /openclaw

ARG OPENCLAW_GIT_REF=v2026.2.9
RUN git clone --depth 1 --branch "${OPENCLAW_GIT_REF}" https://github.com/openclaw/openclaw.git .

RUN set -eux; \
    find ./extensions -name 'package.json' -type f | while read -r f; do \
      sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*">=[^"]+"/"openclaw": "*"/g' "$f"; \
      sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*"workspace:[^"]+"/"openclaw": "*"/g' "$f"; \
    done

RUN pnpm install --no-frozen-lockfile
RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:install && pnpm ui:build

# Runtime image
FROM node:22-bookworm

ENV NODE_ENV=production

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    gnupg \
    tini \
    python3 \
    python3-venv \
 && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI from GitHub's official apt repo
RUN mkdir -p -m 755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

COPY --from=gog-build /usr/local/bin/gog /usr/local/bin/gog

# Persisted state lives on Railway volume
ENV HOME=/data
ENV XDG_CONFIG_HOME=/data/.config
ENV XDG_DATA_HOME=/data/.local/share

RUN mkdir -p \
    /data/.config \
    /data/.local/share \
    /data/.claude

# openclaw update expects pnpm in runtime
RUN corepack enable && corepack prepare pnpm@10.23.0 --activate

# Install Claude Code into the image filesystem, not /data
RUN npm install -g @anthropic-ai/claude-code \
 && npm cache clean --force

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev \
 && npm cache clean --force

COPY --from=openclaw-build /openclaw /openclaw

RUN printf '#!/usr/bin/env bash\nexec node /openclaw/dist/entry.js "$@"\n' > /usr/local/bin/openclaw \
 && chmod +x /usr/local/bin/openclaw

COPY src ./src

EXPOSE 8080

ENTRYPOINT ["tini", "--"]
CMD ["node", "src/server.js"]
