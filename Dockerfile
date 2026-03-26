# ─────────────────────────────────────────────────────────────────────────────
# Global build args (must be re-declared after each FROM when used)
# ─────────────────────────────────────────────────────────────────────────────
ARG FOCALBOARD_TAG=v7.1.0
ARG FOCALBOARD_DOCKER_TAG=7.1.0

# ─────────────────────────────────────────────────────────────────────────────
# Stage 1 – Clone source
# ─────────────────────────────────────────────────────────────────────────────
FROM alpine/git AS repo
ARG FOCALBOARD_TAG
RUN git clone -b ${FOCALBOARD_TAG} --depth 1 \
      https://github.com/mattermost/focalboard.git /focalboard

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2 – Grab the official pre-built frontend assets
#            (avoids Cypress/Chromium native-binary issues on ARM)
# ─────────────────────────────────────────────────────────────────────────────
FROM mattermost/focalboard:${FOCALBOARD_DOCKER_TAG} AS frontend_official

# ─────────────────────────────────────────────────────────────────────────────
# Stage 3 – Build the Go backend for linux/arm64
# ─────────────────────────────────────────────────────────────────────────────
FROM golang:1.21-bookworm AS backend

# TARGETARCH / TARGETOS are injected automatically by BuildKit when using
# `docker buildx build --platform linux/arm64`.
# Default to arm64 so plain `docker build` also works.
ARG TARGETARCH=arm64
ARG TARGETOS=linux

WORKDIR /focalboard
COPY --from=repo /focalboard .

# Patch the Makefile to honour the injected arch instead of hard-coding amd64
RUN sed -i "s/GOARCH=amd64/GOARCH=${TARGETARCH}/g" Makefile

# Build server binary only (skip plugin / enterprise / frontend)
RUN GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    EXCLUDE_PLUGIN=true EXCLUDE_SERVER=true EXCLUDE_ENTERPRISE=true \
    make server-linux

# ─────────────────────────────────────────────────────────────────────────────
# Stage 4 – Minimal Ubuntu runtime image
# ─────────────────────────────────────────────────────────────────────────────
FROM ubuntu:22.04

# Install only what the focalboard server needs at runtime
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      tzdata \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/focalboard

# Copy server binary
COPY --from=backend  --chown=nobody:nogroup /focalboard/bin/linux/focalboard-server ./bin/focalboard-server
COPY --from=backend  --chown=nobody:nogroup /focalboard/LICENSE.txt ./LICENSE.txt

# Copy pre-built frontend pack from official image
COPY --from=frontend_official --chown=nobody:nogroup /opt/focalboard/pack ./pack

# Copy configuration file
COPY --chown=nobody:nogroup config.json ./config.json

# Create directories the server writes to at runtime
RUN mkdir -p ./data/files \
 && chown -R nobody:nogroup ./data

# Run as non-root
USER nobody

EXPOSE 8000

CMD ["/opt/focalboard/bin/focalboard-server"]