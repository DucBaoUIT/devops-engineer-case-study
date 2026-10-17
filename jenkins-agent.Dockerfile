# Jenkins inbound agent with the toolchain the case-study pipeline needs.
#
# The stock jenkins/inbound-agent image has Java + the agent JAR but no
# Docker CLI, kubectl, kind or Python. This image adds them so a job on the
# `linux-docker-agent` label can: run unit tests, build/push images, and
# deploy to the kind cluster.
#
# Security notes:
#   * The Docker socket is mounted at RUNTIME (see docker-compose.yml), not
#     baked in. A job with socket access is effectively root on the host —
#     only run trusted pipelines on this agent.
#   * DOCKER_GID must match the host's `docker` group GID (990 on this VPS)
#     so the unprivileged `jenkins` user can talk to the socket. Rebuild with
#     --build-arg DOCKER_GID=$(getent group docker | cut -d: -f3) if it differs.

FROM jenkins/inbound-agent:latest-jdk17

USER root

ARG DOCKER_GID=990
ARG KUBECTL_VERSION=v1.34.0
ARG KIND_VERSION=v0.30.0
ARG DOCKER_CLI_VERSION=27.5.1
ARG BUILDX_VERSION=v0.38.0   # match host: docker buildx version

# Base utilities. git and curl already exist in the inbound-agent image but
# are listed for clarity/reproducibility.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip \
      python3 python3-venv python3-pip \
 && rm -rf /var/lib/apt/lists/*

# Docker CLI (static binary — no daemon installed in the agent).
RUN curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_CLI_VERSION}.tgz" \
      -o /tmp/docker.tgz \
 && tar -xzf /tmp/docker.tgz -C /tmp \
 && install -m 0755 /tmp/docker/docker /usr/local/bin/docker \
 && rm -rf /tmp/docker /tmp/docker.tgz

# docker buildx CLI plugin. REQUIRED: the app Dockerfile uses BuildKit features
# (`# syntax=docker/dockerfile:1.7` frontend + `--mount=type=cache`), and the
# static Docker CLI tarball does NOT bundle buildx. Without it, `docker build`
# fails with "BuildKit is enabled but the buildx component is missing".
RUN mkdir -p /usr/local/libexec/docker/cli-plugins \
 && curl -fsSL "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-amd64" \
      -o /usr/local/libexec/docker/cli-plugins/docker-buildx \
 && chmod 0755 /usr/local/libexec/docker/cli-plugins/docker-buildx

# kubectl (matches the kind cluster minor version).
RUN curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
      -o /usr/local/bin/kubectl \
 && chmod 0755 /usr/local/bin/kubectl

# kind (only needed if a job creates/loads clusters; harmless otherwise).
RUN curl -fsSL "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64" \
      -o /usr/local/bin/kind \
 && chmod 0755 /usr/local/bin/kind

# Give the unprivileged jenkins user access to the mounted Docker socket by
# creating a group with the host's docker GID and adding jenkins to it.
RUN if ! getent group "$DOCKER_GID" >/dev/null; then groupadd -g "$DOCKER_GID" docker; fi \
 && usermod -aG "$DOCKER_GID" jenkins

# Trust the read-only repo bind mount (/repo-src) for git. The mount is owned
# by root on the host while the agent runs as uid 1000, so git's "dubious
# ownership" guard would otherwise block `checkout scm` from file:///repo-src.
# safe.directory is only honored from SYSTEM/GLOBAL config (not `-c` or the
# GIT_CONFIG_* env), so it is set system-wide here. /repo-src/.git is the path
# git reports for a file:// remote of a non-bare repo.
RUN git config --system --add safe.directory /repo-src \
 && git config --system --add safe.directory /repo-src/.git

# Pre-trust GitHub's SSH host keys. When the multibranch source is switched to a
# git@github.com remote (SSH deploy key), CLI git+ssh runs as the jenkins user and
# the git-client "Known hosts file" strategy reads ~jenkins/.ssh/known_hosts. That
# path lives in the container layer (NOT the persisted /home/jenkins/agent volume),
# so it is baked here to survive `docker compose up --force-recreate`. Non-fatal if
# GitHub is unreachable at build time (seed at runtime via
# .jenkins-setup/ssh-deploykey-setup.sh instead). GitHub's published fingerprints:
# https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
RUN mkdir -p /home/jenkins/.ssh \
 && (ssh-keyscan -t rsa,ecdsa,ed25519 github.com > /home/jenkins/.ssh/known_hosts 2>/dev/null || true) \
 && chmod 700 /home/jenkins/.ssh && chmod 600 /home/jenkins/.ssh/known_hosts \
 && chown -R jenkins:jenkins /home/jenkins/.ssh \
 && if [ -s /home/jenkins/.ssh/known_hosts ]; then echo 'github.com host key baked: ok'; \
    else echo 'WARN: github host key not baked (no network at build?); seed at runtime'; fi

USER jenkins

# Sanity: these run at build time and fail the build if a tool is missing.
RUN docker --version && docker buildx version && kubectl version --client && kind version && python3 --version && git --version \
 && test "$(git config --system --get-all safe.directory | grep -c '/repo-src')" -ge 1 && echo 'git safe.directory: ok'
