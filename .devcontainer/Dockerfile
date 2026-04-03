FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG FLUTTER_VERSION=3.41.5

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    unzip \
    xz-utils \
    zip \
    ca-certificates \
    # Flutter Linux desktop dependencies
    clang \
    cmake \
    ninja-build \
    pkg-config \
    libgtk-3-dev \
    liblzma-dev \
    libstdc++-13-dev \
    # SQLite
    libsqlite3-dev \
    # Misc
    wget \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install Flutter
RUN git clone https://github.com/flutter/flutter.git -b ${FLUTTER_VERSION} --depth 1 /usr/local/flutter \
    && chmod -R a+rw /usr/local/flutter

ENV PATH="/usr/local/flutter/bin:/usr/local/flutter/bin/cache/dart-sdk/bin:${PATH}"
ENV CHROME_EXECUTABLE=""

# Mark flutter directory as safe for git
RUN git config --global --add safe.directory /usr/local/flutter

# Pre-cache Flutter artifacts for Linux desktop (run as root, remoteUser handles the switch)
RUN flutter precache --linux \
    && flutter config --enable-linux-desktop \
    && dart --disable-analytics \
    && flutter --disable-analytics

WORKDIR /workspace
