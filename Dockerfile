# Build gog (gogcli) with Go 1.25+
FROM golang:1.25.6-bookworm AS gog-build
RUN apt-get update && apt-get install -y --no-install-recommends git make ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/steipete/gogcli.git /tmp/gogcli \
 && cd /tmp/gogcli \
 && make \
 && install -m 0755 ./bin/gog /usr/local/bin/gog

# Build clawdbot from source
FROM node:22-bookworm AS openclaw-build

# Dependencies needed for clawdbot build (drop golang here)
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    python3 \
    make \
    g++ \
 && rm -rf /var/lib/apt/lists/*

# Copy gog from the Go build stage
COPY --from=gog-build /usr/local/bin/gog /usr/local/bin/gog

# Install Bun (clawdbot build uses it)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /openclaw

# Pin to a known ref (tag/branch). If it doesn't exist, fall back to main.
ARG OPENCLAW_GIT_REF=main
RUN git clone --depth 1 --branch "${OPENCLAW_GIT_REF}" https://github.com/openclaw/openclaw.git .

# Patch: relax version requirements for packages that may reference unpublished versions.
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
COPY --from=openclaw-build /usr/local/bin/gog /usr/local/bin/gog
ENV XDG_CONFIG_HOME=/data/.config
ENV XDG_DATA_HOME=/data/.local/share
ENV HOME=/data
RUN mkdir -p /data/.config /data/.local/share


RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Wrapper deps
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

# Copy built openclaw
COPY --from=openclaw-build /openclaw /openclaw

# Provide an openclaw executable
RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /openclaw/dist/entry.js "$@"' > /usr/local/bin/openclaw \
  && chmod +x /usr/local/bin/openclaw

COPY src ./src

# The wrapper listens on this port.
ENV OPENCLAW_PUBLIC_PORT=8080
ENV PORT=8080
EXPOSE 8080
CMD ["node", "src/server.js"]
